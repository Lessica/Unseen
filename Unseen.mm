#import "dobby.h"

#import <Foundation/Foundation.h>
#import <libproc.h>
#import <mach/mach.h>
#import <mach/message.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <substrate.h>
#import <sys/types.h>
#import <unistd.h>

extern "C" bool gUnseenEnabled = true;
extern "C" bool gUnseenDisableUpdateMaskPatchEnabled = true;
extern "C" bool gUnseenScreenshotActionFilterEnabled = true;
extern "C" bool gUnseenCaptureStateMaskEnabled = true;

#pragma mark - Logging

static os_log_t tweak_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.82flex.unseen", "tweak");
    });
    return log;
}

static os_log_t patchfinder_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.82flex.unseen", "patchfinder");
    });
    return log;
}

static os_log_t screenshot_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.82flex.unseen", "screenshot-actions");
    });
    return log;
}

static os_log_t capture_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.82flex.unseen", "capture-state");
    });
    return log;
}

#pragma mark - Preferences

static NSString *const kUnseenPreferencesDomain = @"com.82flex.unseen";

static NSDictionary *load_preferences_dictionary(void) {
    NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] persistentDomainForName:kUnseenPreferencesDomain];
    if (prefs) {
        return prefs;
    }

    NSString *plistPath = @"/var/mobile/Library/Preferences/com.82flex.unseen.plist";
    prefs = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (prefs) {
        os_log(tweak_log(), "Loaded preferences from %{public}s", plistPath.UTF8String);
    }
    return prefs;
}

static BOOL bool_preference(NSDictionary *prefs, NSString *key, BOOL defaultValue) {
    id value = [prefs objectForKey:key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value boolValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value boolValue];
    }
    return defaultValue;
}

static void load_preferences(void) {
    NSDictionary *prefs = load_preferences_dictionary();

    gUnseenEnabled = bool_preference(prefs, @"Enabled", YES);
    gUnseenDisableUpdateMaskPatchEnabled = bool_preference(prefs, @"DisableUpdateMaskPatchEnabled", YES);
    gUnseenScreenshotActionFilterEnabled = bool_preference(prefs, @"ScreenshotActionFilterEnabled", YES);
    gUnseenCaptureStateMaskEnabled = bool_preference(prefs, @"CaptureStateMaskEnabled", YES);

    os_log(tweak_log(),
           "Preferences applied enabled=%{public}s updateMask=%{public}s screenshot=%{public}s capture=%{public}s",
           gUnseenEnabled ? "YES" : "NO", gUnseenDisableUpdateMaskPatchEnabled ? "YES" : "NO",
           gUnseenScreenshotActionFilterEnabled ? "YES" : "NO", gUnseenCaptureStateMaskEnabled ? "YES" : "NO");
}

#pragma mark - Process Filter

static const uid_t kTargetUid = 501;
static const char *kTargetPathNeedle = "/var/containers/Bundle/Application/";

static bool pid_has_target_uid(pid_t pid, uid_t expectedUid) {
    struct proc_bsdinfo info;
    int ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (ret != sizeof(info)) {
        return false;
    }
    return info.pbi_uid == expectedUid;
}

static bool client_is_target_pid(pid_t pid, char *pathOut, size_t pathOutLen) {
    if (pid <= 0) {
        return false;
    }

    if (!pid_has_target_uid(pid, kTargetUid)) {
        return false;
    }

    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int pathLen = proc_pidpath(pid, path, sizeof(path));
    if (pathLen <= 0) {
        return false;
    }

    if (!strstr(path, kTargetPathNeedle)) {
        return false;
    }

    if (pathOut && pathOutLen > 0) {
        strlcpy(pathOut, path, pathOutLen);
    }
    return true;
}

static bool client_is_target_audit_token(audit_token_t token, pid_t *pidOut, char *pathOut, size_t pathOutLen) {
    pid_t pid = (pid_t)token.val[5];
    uid_t euid = (uid_t)token.val[1];
    if (pidOut) {
        *pidOut = pid;
    }
    if (pid <= 0 || euid != kTargetUid) {
        return false;
    }
    return client_is_target_pid(pid, pathOut, pathOutLen);
}

#pragma mark - Instruction Decode

static inline int is_tst_xn_disableUpdateMask(uint32_t insn) {
    uint32_t masked = insn & 0xFFFFFC1F;
    return masked == 0xF26C181F || masked == 0xF26C1C1F;
}

static inline int is_b_ne(uint32_t insn) { return (insn & 0xFF00001F) == 0x54000001; }

static inline void *decode_bl_target(const uint32_t *insn_addr) {
    uint32_t insn = *insn_addr;
    if ((insn & 0xFC000000) != 0x94000000) {
        return NULL;
    }

    int32_t imm26 = (int32_t)(insn & 0x03FFFFFF);
    if (imm26 & 0x02000000) {
        imm26 |= (int32_t)0xFC000000;
    }

    return (void *)((uintptr_t)insn_addr + (((intptr_t)imm26) << 2));
}

static inline int is_tbnz_w0_bit0(uint32_t insn) { return (insn & 0xFFF8001F) == 0x37000000; }

static inline int decode_unsigned_store_64(uint32_t insn, uint8_t *rt, uint8_t *rn, uint32_t *offset) {
    if ((insn & 0xFFC00000) != 0xF9000000) {
        return 0;
    }
    if (rt) {
        *rt = insn & 0x1F;
    }
    if (rn) {
        *rn = (insn >> 5) & 0x1F;
    }
    if (offset) {
        *offset = ((insn >> 10) & 0xFFF) << 3;
    }
    return 1;
}

static inline int decode_unsigned_load_32(uint32_t insn, uint8_t *rt, uint8_t *rn, uint32_t *offset) {
    if ((insn & 0xFFC00000) != 0xB9400000) {
        return 0;
    }
    if (rt) {
        *rt = insn & 0x1F;
    }
    if (rn) {
        *rn = (insn >> 5) & 0x1F;
    }
    if (offset) {
        *offset = ((insn >> 10) & 0xFFF) << 2;
    }
    return 1;
}

static inline int decode_unsigned_store_32(uint32_t insn, uint8_t *rt, uint8_t *rn, uint32_t *offset) {
    if ((insn & 0xFFC00000) != 0xB9000000) {
        return 0;
    }
    if (rt) {
        *rt = insn & 0x1F;
    }
    if (rn) {
        *rn = (insn >> 5) & 0x1F;
    }
    if (offset) {
        *offset = ((insn >> 10) & 0xFFF) << 2;
    }
    return 1;
}

static inline int decode_add_immediate_64(uint32_t insn, uint8_t *rd, uint8_t *rn, uint32_t *imm) {
    if ((insn & 0x80000000) == 0 || (insn & 0x7F000000) != 0x11000000) {
        return 0;
    }

    uint32_t shift = (insn >> 22) & 0x3;
    if (shift > 1) {
        return 0;
    }

    uint32_t value = (insn >> 10) & 0xFFF;
    if (shift == 1) {
        value <<= 12;
    }
    if (rd) {
        *rd = insn & 0x1F;
    }
    if (rn) {
        *rn = (insn >> 5) & 0x1F;
    }
    if (imm) {
        *imm = value;
    }
    return 1;
}

#pragma mark - Patch Finding

static void *resolve_prepare_layer0(void) {
    const char *image = "/System/Library/Frameworks/QuartzCore.framework/QuartzCore";
    const char *candidates[] = {
        "__ZN2CA6Render7Updater14prepare_layer0ERNS1_11GlobalStateEPNS0_9LayerNodeEPNS0_5LayerERNS1_11LocalState0Ey",
        "__ZN2CA6Render7Updater14prepare_layer0ERNS1_11GlobalStateEPNS0_9LayerNodeEPKNS0_5LayerERNS1_11LocalState0Ey",
    };

    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        void *sym = DobbySymbolResolver(image, candidates[i]);
        if (sym) {
            os_log(patchfinder_log(), "Resolved prepare_layer0 via DobbySymbolResolver: %p", sym);
            return sym;
        }
    }

    os_log_error(patchfinder_log(), "Could not resolve prepare_layer0 symbol");
    return NULL;
}

static void *resolve_allowed_in_update(void) {
    const char *image = "/System/Library/Frameworks/QuartzCore.framework/QuartzCore";
    const char *symbol = "__ZN2CA6Render6Update17allowed_in_updateEPNS0_7ContextEPKNS0_5LayerE";
    void *sym = DobbySymbolResolver(image, symbol);
    if (sym) {
        os_log(patchfinder_log(), "Resolved allowed_in_update via DobbySymbolResolver: %p", sym);
    } else {
        os_log_error(patchfinder_log(), "Could not resolve allowed_in_update symbol");
    }
    return sym;
}

static void *resolve_get_display_info(void) {
    const char *image = "/System/Library/Frameworks/QuartzCore.framework/QuartzCore";
    const char *symbol = "__ZN2CA12WindowServer6Server16get_display_infoEPNS_6Render6ObjectEPvS5_";
    void *sym = DobbySymbolResolver(image, symbol);
    if (!sym) {
        os_log_error(patchfinder_log(), "Could not resolve get_display_info symbol");
    }
    return sym;
}

static uint32_t find_get_display_info_flags_offset(void) {
    void *func = resolve_get_display_info();
    if (!func) {
        return 0;
    }

    const uint32_t *insns = (const uint32_t *)func;

    for (uint32_t i = 0; i + 6 < 512; i++) {
        uint8_t loadRt = 0;
        uint8_t loadRn = 0;
        uint32_t loadOffset = 0;
        if (!decode_unsigned_load_32(insns[i], &loadRt, &loadRn, &loadOffset)) {
            continue;
        }

        uint8_t storeRt = 0;
        uint8_t storeRn = 0;
        uint32_t storeOffset = 0;
        if (!decode_unsigned_store_32(insns[i + 1], &storeRt, &storeRn, &storeOffset) || storeRt != loadRt) {
            continue;
        }

        for (uint32_t j = i + 2; j < i + 6; j++) {
            uint8_t addRd = 0;
            uint8_t addRn = 0;
            uint32_t addImm = 0;
            if (!decode_add_immediate_64(insns[j], &addRd, &addRn, &addImm)) {
                continue;
            }
            if (addRn == loadRn && addImm == loadOffset + 4) {
                os_log(patchfinder_log(), "Resolved get_display_info flags offset 0x%X from display offset 0x%X",
                       storeOffset, loadOffset);
                return storeOffset;
            }
        }
    }

    os_log_error(patchfinder_log(), "Could not find get_display_info flags offset");
    return 0;
}

static void *find_disableUpdateMask_branch(void) {
    void *func_start = resolve_prepare_layer0();
    if (!func_start) {
        os_log_error(patchfinder_log(), "Cannot resolve prepare_layer0 - aborting");
        return NULL;
    }

    const size_t max_scan_size = 65536;
    const uint32_t *insns = (const uint32_t *)func_start;
    size_t count = max_scan_size / sizeof(uint32_t);

    os_log_info(patchfinder_log(), "Scanning prepare_layer0 at %p (%zu instructions max)", func_start, count);

    for (size_t i = 0; i + 4 < count; i++) {
        if (is_tst_xn_disableUpdateMask(insns[i])) {
            os_log_info(patchfinder_log(), "Found TST at %p (insn=0x%x)", (void *)&insns[i], insns[i]);
            for (size_t j = 1; j <= 4 && (i + j) < count; j++) {
                if (is_b_ne(insns[i + j])) {
                    void *branch_addr = (void *)&insns[i + j];
                    os_log(patchfinder_log(), "Found B.NE at %p (offset +%zu from TST)", branch_addr, j);
                    return branch_addr;
                }
            }
            os_log_error(patchfinder_log(), "TST found but no B.NE within 4 instructions");
        }
    }

    void *allowed_in_update = resolve_allowed_in_update();
    if (allowed_in_update) {
        for (size_t i = 0; i + 8 < count; i++) {
            void *target = decode_bl_target(&insns[i]);
            if (target != allowed_in_update) {
                continue;
            }

            os_log_info(patchfinder_log(), "Found allowed_in_update call at %p", (void *)&insns[i]);
            for (size_t j = 1; j <= 4 && (i + j + 1) < count; j++) {
                if (!is_tbnz_w0_bit0(insns[i + j])) {
                    continue;
                }

                for (size_t k = j + 1; k <= j + 3 && (i + k) < count; k++) {
                    uint8_t storeRt = 0;
                    uint8_t storeRn = 0;
                    uint32_t storeOffset = 0;
                    if (!decode_unsigned_store_64(insns[i + k], &storeRt, &storeRn, &storeOffset) || storeRt != 31) {
                        continue;
                    }

                    void *store_addr = (void *)&insns[i + k];
                    os_log(patchfinder_log(),
                           "Found iOS 18 allowed_in_update clear store at %p (base X%u + 0x%X, offset +%zu from call)",
                           store_addr, storeRn, storeOffset, k);
                    return store_addr;
                }

                os_log_error(patchfinder_log(), "allowed_in_update TBNZ found but no nearby STR XZR clear");
            }
        }
    }

    os_log_error(patchfinder_log(), "Pattern not found in prepare_layer0 (%zu instructions scanned)", count);
    return NULL;
}

#pragma mark - Disable Update Mask Patch

static void install_disableUpdateMask_patch(void) {
    if (!gUnseenDisableUpdateMaskPatchEnabled) {
        os_log(tweak_log(), "disableUpdateMask patch disabled");
        return;
    }

    void *branch_addr = find_disableUpdateMask_branch();
    if (!branch_addr) {
        os_log_error(tweak_log(), "Patch target not found - aborting");
        return;
    }

    uint32_t nop = 0xD503201F;
    int ret = DobbyCodePatch(branch_addr, (uint8_t *)&nop, sizeof(nop));
    if (ret == 0) {
        os_log(tweak_log(), "Successfully patched disableUpdateMask instruction at %p -> NOP", branch_addr);
    } else {
        os_log_error(tweak_log(), "DobbyCodePatch failed at %p (ret=%d)", branch_addr, ret);
    }
}

#pragma mark - Screenshot Action Hooks

typedef void (*ActionDispatchIMP)(id self, SEL _cmd, id actions);

static ActionDispatchIMP orig_FBScene_sendActions;

static BOOL object_responds_to(id object, SEL selector) {
    return object && selector && [object respondsToSelector:selector];
}

static BOOL action_is_screenshot(id action) {
    if (!action) {
        return NO;
    }

    const char *className = object_getClassName(action);
    if (className && strcmp(className, "UIDidTakeScreenshotAction") == 0) {
        return YES;
    }

    SEL UIActionType = sel_registerName("UIActionType");
    if (object_responds_to(action, UIActionType)) {
        NSInteger type = ((NSInteger (*)(id, SEL))objc_msgSend)(action, UIActionType);
        if (type == 18) {
            return YES;
        }
    }

    SEL actionType = sel_registerName("actionType");
    if (object_responds_to(action, actionType)) {
        NSInteger type = ((NSInteger (*)(id, SEL))objc_msgSend)(action, actionType);
        if (type == 18) {
            return YES;
        }
    }

    return NO;
}

static id filtered_actions(id actions, BOOL *removedAny) {
    if (removedAny) {
        *removedAny = NO;
    }
    if (!actions) {
        return actions;
    }

    if ([actions isKindOfClass:[NSArray class]]) {
        NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:[actions count]];
        for (id action in (NSArray *)actions) {
            if (action_is_screenshot(action)) {
                if (removedAny) {
                    *removedAny = YES;
                }
            } else {
                [filtered addObject:action];
            }
        }
        return filtered;
    }

    if ([actions isKindOfClass:[NSSet class]]) {
        NSMutableSet *filtered = [NSMutableSet setWithCapacity:[actions count]];
        for (id action in (NSSet *)actions) {
            if (action_is_screenshot(action)) {
                if (removedAny) {
                    *removedAny = YES;
                }
            } else {
                [filtered addObject:action];
            }
        }
        return filtered;
    }

    if (action_is_screenshot(actions)) {
        if (removedAny) {
            *removedAny = YES;
        }
        return nil;
    }

    return actions;
}

static pid_t verified_pid_for_action_dispatch(id self) {
    SEL clientProcessSelector = sel_registerName("clientProcess");
    SEL pidSelector = sel_registerName("pid");
    if (!object_responds_to(self, clientProcessSelector)) {
        return -1;
    }

    id process = ((id (*)(id, SEL))objc_msgSend)(self, clientProcessSelector);
    if (!object_responds_to(process, pidSelector)) {
        return -1;
    }

    return (pid_t)((int (*)(id, SEL))objc_msgSend)(process, pidSelector);
}

static void handle_action_dispatch(id self, SEL _cmd, id actions, ActionDispatchIMP original) {
    pid_t pid = verified_pid_for_action_dispatch(self);
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (pid <= 0 || !client_is_target_pid(pid, path, sizeof(path))) {
        original(self, _cmd, actions);
        return;
    }

    BOOL removedAny = NO;
    id filtered = filtered_actions(actions, &removedAny);
    if (!removedAny) {
        original(self, _cmd, actions);
        return;
    }

    NSUInteger originalCount = [actions respondsToSelector:@selector(count)] ? [actions count] : 1;
    NSUInteger filteredCount = [filtered respondsToSelector:@selector(count)] ? [filtered count] : (filtered ? 1 : 0);
    os_log(screenshot_log(), "Filtered screenshot action for pid %d path %{public}s (%lu -> %lu)", pid, path,
           (unsigned long)originalCount, (unsigned long)filteredCount);

    if (filteredCount == 0) {
        return;
    }
    original(self, _cmd, filtered);
}

static void repl_FBScene_sendActions(id self, SEL _cmd, id actions) {
    handle_action_dispatch(self, _cmd, actions, orig_FBScene_sendActions);
}

static BOOL hook_method(const char *className, const char *selectorName, void *replacement, void **original) {
    Class cls = objc_getClass(className);
    if (!cls) {
        return NO;
    }

    SEL selector = sel_registerName(selectorName);
    if (!selector) {
        return NO;
    }

    MSHookMessageEx(cls, selector, (IMP)replacement, (IMP *)original);
    os_log(screenshot_log(), "Installed hook %{public}s -%{public}s", className, selectorName);
    return YES;
}

static void install_screenshot_action_hooks(void) {
    if (!gUnseenScreenshotActionFilterEnabled) {
        os_log(screenshot_log(), "Screenshot action filter disabled");
        return;
    }

    unsigned installed = 0;
    if (hook_method("FBScene", "sendActions:", (void *)repl_FBScene_sendActions, (void **)&orig_FBScene_sendActions)) {
        installed++;
    }
    if (installed == 0) {
        os_log_error(screenshot_log(), "No screenshot action dispatch hooks installed");
    }
}

#pragma mark - Capture State Hooks

typedef void (*XGetDisplayInfoIMP)(mach_msg_header_t *request, mach_msg_header_t *reply);
typedef uint64_t (*GetDisplayInfoIMP)(void *server, void *object, uint8_t *info, void *context);

static XGetDisplayInfoIMP orig_XGetDisplayInfo;
static GetDisplayInfoIMP orig_get_display_info;
static pthread_key_t current_target_key;
static pthread_once_t current_target_key_once = PTHREAD_ONCE_INIT;
static atomic_uint gMaskedLogCount;
static uint32_t display_flags_info_offset;

static void make_current_target_key(void) { pthread_key_create(&current_target_key, NULL); }

static void set_current_target_client(BOOL target) {
    pthread_once(&current_target_key_once, make_current_target_key);
    pthread_setspecific(current_target_key, target ? (void *)1 : NULL);
}

static BOOL current_client_is_target(void) {
    pthread_once(&current_target_key_once, make_current_target_key);
    return pthread_getspecific(current_target_key) != NULL;
}

static BOOL audit_token_from_request(mach_msg_header_t *request, audit_token_t *tokenOut) {
    if (!request || !tokenOut) {
        return NO;
    }

    mach_msg_size_t size = request->msgh_size;
    if (size < sizeof(mach_msg_header_t) || size > 0x4000) {
        return NO;
    }

    mach_msg_size_t alignedSize = (mach_msg_size_t)((size + 3) & ~3U);
    mach_msg_audit_trailer_t *trailer = (mach_msg_audit_trailer_t *)((uint8_t *)request + alignedSize);
    if (trailer->msgh_trailer_type != MACH_MSG_TRAILER_FORMAT_0 ||
        trailer->msgh_trailer_size < sizeof(mach_msg_audit_trailer_t)) {
        return NO;
    }

    *tokenOut = trailer->msgh_audit;
    return YES;
}

static void repl_XGetDisplayInfo(mach_msg_header_t *request, mach_msg_header_t *reply) {
    audit_token_t token;
    pid_t pid = -1;
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    BOOL target =
        audit_token_from_request(request, &token) && client_is_target_audit_token(token, &pid, path, sizeof(path));

    set_current_target_client(target);
    orig_XGetDisplayInfo(request, reply);
    set_current_target_client(NO);
}

static uint64_t repl_get_display_info(void *server, void *object, uint8_t *info, void *context) {
    uint64_t result = orig_get_display_info(server, object, info, context);
    if (!current_client_is_target() || !info) {
        return result;
    }

    uint32_t offset = display_flags_info_offset;
    if (offset == 0) {
        return result;
    }

    uint32_t *flags = (uint32_t *)(info + offset);
    BOOL hadClonedBit = ((*flags & 0x4) != 0);
    *flags &= ~0x4U;

    if (hadClonedBit && atomic_fetch_add(&gMaskedLogCount, 1) < 20) {
        os_log(capture_log(), "Cleared cloned bit in get_display_info output");
    }
    return result;
}

static BOOL install_hook_symbol(const char *image, const char *symbolName, void *replacement, void **original) {
    void *symbol = DobbySymbolResolver(image, symbolName);
    if (!symbol) {
        os_log_error(capture_log(), "Symbol %{public}s not found", symbolName);
        return NO;
    }

    int ret = DobbyHook(symbol, (dobby_dummy_func_t)replacement, (dobby_dummy_func_t *)original);
    if (ret == 0) {
        os_log(capture_log(), "Installed hook %{public}s at %p", symbolName, symbol);
        return YES;
    }

    os_log_error(capture_log(), "DobbyHook %{public}s failed ret=%d", symbolName, ret);
    return NO;
}

static void install_capture_state_hooks(void) {
    if (!gUnseenCaptureStateMaskEnabled) {
        os_log(capture_log(), "Capture state mask disabled");
        return;
    }

    const char *quartzCore = "/System/Library/Frameworks/QuartzCore.framework/QuartzCore";
    const char *getDisplayInfoSymbol = "__ZN2CA12WindowServer6Server16get_display_infoEPNS_6Render6ObjectEPvS5_";

    display_flags_info_offset = find_get_display_info_flags_offset();
    if (display_flags_info_offset == 0) {
        return;
    }

    install_hook_symbol(quartzCore, "__XGetDisplayInfo", (void *)repl_XGetDisplayInfo, (void **)&orig_XGetDisplayInfo);
    install_hook_symbol(quartzCore, getDisplayInfoSymbol, (void *)repl_get_display_info,
                        (void **)&orig_get_display_info);
}

#pragma mark - Entry Point

__attribute__((constructor)) static void tweak_init(void) {
    os_log(tweak_log(), "Unseen loading in %{public}s (pid %d)", getprogname(), getpid());
    load_preferences();

    if (!gUnseenEnabled) {
        os_log(tweak_log(), "Unseen disabled");
        return;
    }

    const char *process = getprogname();
    if (process && strcmp(process, "SpringBoard") == 0) {
        install_screenshot_action_hooks();
        return;
    }

    install_disableUpdateMask_patch();
    install_capture_state_hooks();
}
