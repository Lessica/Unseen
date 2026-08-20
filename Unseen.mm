#import "dobby.h"

#import <Foundation/Foundation.h>
#import <libproc.h>
#import <mach/mach.h>
#import <mach/message.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <pthread.h>
#import <ptrauth.h>
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
extern "C" bool gUnseenProcessAwareUpdateMaskBypassEnabled = false;
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
    gUnseenProcessAwareUpdateMaskBypassEnabled =
        bool_preference(prefs, @"ProcessAwareUpdateMaskBypassEnabled", NO);
    gUnseenScreenshotActionFilterEnabled = bool_preference(prefs, @"ScreenshotActionFilterEnabled", YES);
    gUnseenCaptureStateMaskEnabled = bool_preference(prefs, @"CaptureStateMaskEnabled", YES);

    os_log(tweak_log(),
           "Preferences applied enabled=%{public}s updateMask=%{public}s processAware=%{public}s "
           "screenshot=%{public}s capture=%{public}s",
           gUnseenEnabled ? "YES" : "NO", gUnseenDisableUpdateMaskPatchEnabled ? "YES" : "NO",
           gUnseenProcessAwareUpdateMaskBypassEnabled ? "YES" : "NO",
           gUnseenScreenshotActionFilterEnabled ? "YES" : "NO", gUnseenCaptureStateMaskEnabled ? "YES" : "NO");
}

#pragma mark - Process Filter

static const uid_t kTargetUid = 501;
static const char *kSandboxedAppPathNeedle = "/var/containers/Bundle/Application/";
static const char *kApplicationsPathComponent = "/Applications/";
static const size_t kTargetPidCacheSize = 16;

typedef struct {
    pid_t pid;
    bool valid;
    bool isTarget;
    char path[PROC_PIDPATHINFO_MAXSIZE];
} TargetPidCacheEntry;

static pthread_mutex_t gTargetPidCacheLock = PTHREAD_MUTEX_INITIALIZER;
static TargetPidCacheEntry gTargetPidCache[kTargetPidCacheSize];
static size_t gTargetPidCacheCursor;

static bool pid_has_target_uid(pid_t pid, uid_t expectedUid) {
    struct proc_bsdinfo info;
    int ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (ret != sizeof(info)) {
        return false;
    }
    return info.pbi_uid == expectedUid;
}

static bool path_is_jailbreak_application(const char *path) {
    if (!path) {
        return false;
    }

    // Rootful, rootless and RootHide installations use different prefixes, but
    // their GUI applications all retain an Applications/Foo.app/Foo suffix.
    // Require the process to be the top-level executable, not an app extension,
    // framework helper or arbitrary file below the bundle.
    const char *applications = strstr(path, kApplicationsPathComponent);
    if (!applications) {
        return false;
    }

    const char *bundleStart = applications + strlen(kApplicationsPathComponent);
    const char *bundleEnd = strstr(bundleStart, ".app/");
    if (!bundleEnd || bundleEnd == bundleStart) {
        return false;
    }

    const char *executable = bundleEnd + strlen(".app/");
    return executable[0] != '\0' && strchr(executable, '/') == NULL;
}

static bool client_is_target_pid_uncached(pid_t pid, bool uidAlreadyMatched, char *pathOut, size_t pathOutLen) {
    if (pid <= 0) {
        return false;
    }

    if (!uidAlreadyMatched && !pid_has_target_uid(pid, kTargetUid)) {
        return false;
    }

    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int pathLen = proc_pidpath(pid, path, sizeof(path));
    if (pathLen <= 0) {
        return false;
    }

    bool isSandboxedApp = strstr(path, kSandboxedAppPathNeedle) != NULL;
    bool isJailbreakApp = path_is_jailbreak_application(path);
    if (!isSandboxedApp && !isJailbreakApp) {
        return false;
    }

    if (pathOut && pathOutLen > 0) {
        strlcpy(pathOut, path, pathOutLen);
    }
    return true;
}

static bool client_is_target_pid_with_uid_hint(pid_t pid, bool uidAlreadyMatched, char *pathOut, size_t pathOutLen) {
    if (pid <= 0) {
        return false;
    }

    pthread_mutex_lock(&gTargetPidCacheLock);
    for (size_t i = 0; i < kTargetPidCacheSize; i++) {
        TargetPidCacheEntry *entry = &gTargetPidCache[i];
        if (entry->valid && entry->pid == pid) {
            bool isTarget = entry->isTarget;
            if (isTarget && pathOut && pathOutLen > 0) {
                strlcpy(pathOut, entry->path, pathOutLen);
            }
            pthread_mutex_unlock(&gTargetPidCacheLock);
            return isTarget;
        }
    }
    pthread_mutex_unlock(&gTargetPidCacheLock);

    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    bool isTarget = client_is_target_pid_uncached(pid, uidAlreadyMatched, path, sizeof(path));

    pthread_mutex_lock(&gTargetPidCacheLock);
    TargetPidCacheEntry *entry = &gTargetPidCache[gTargetPidCacheCursor++ % kTargetPidCacheSize];
    entry->pid = pid;
    entry->valid = true;
    entry->isTarget = isTarget;
    if (isTarget) {
        strlcpy(entry->path, path, sizeof(entry->path));
    } else {
        entry->path[0] = '\0';
    }
    pthread_mutex_unlock(&gTargetPidCacheLock);

    if (isTarget && pathOut && pathOutLen > 0) {
        strlcpy(pathOut, path, pathOutLen);
    }
    return isTarget;
}

static bool client_is_target_pid(pid_t pid, char *pathOut, size_t pathOutLen) {
    return client_is_target_pid_with_uid_hint(pid, false, pathOut, pathOutLen);
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
    return client_is_target_pid_with_uid_hint(pid, true, pathOut, pathOutLen);
}

#pragma mark - Instruction Decode

static inline uint64_t decode_tst_disableUpdateMask(uint32_t insn) {
    uint32_t masked = insn & 0xFFFFFC1F;
    switch (masked) {
        case 0xF26C101F:
            return 0x01F00000ULL;
        case 0xF26C141F:
            return 0x03F00000ULL;
        case 0xF26C181F:
            return 0x07F00000ULL;
        case 0xF26C1C1F:
            return 0x0FF00000ULL;
        default:
            return 0;
    }
}

static inline int is_tst_xn_disableUpdateMask(uint32_t insn) {
    return decode_tst_disableUpdateMask(insn) != 0;
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

static inline const uint32_t *decode_nonzero_w0_branch_target(const uint32_t *insn_addr, const char **kind) {
    uint32_t insn = *insn_addr;
    int32_t immediate = 0;

    if ((insn & 0xFFF8001F) == 0x37000000) { // TBNZ W0, #0, target
        immediate = (int32_t)((insn >> 5) & 0x3FFF);
        if (immediate & 0x2000) {
            immediate |= (int32_t)0xFFFFC000;
        }
        if (kind) {
            *kind = "TBNZ";
        }
    } else if ((insn & 0xFF00001F) == 0x35000000) { // CBNZ W0, target
        immediate = (int32_t)((insn >> 5) & 0x7FFFF);
        if (immediate & 0x40000) {
            immediate |= (int32_t)0xFFF80000;
        }
        if (kind) {
            *kind = "CBNZ";
        }
    } else {
        return NULL;
    }

    return (const uint32_t *)((uintptr_t)insn_addr + (((intptr_t)immediate) << 2));
}

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
    const char *candidates[] = {
        // iOS 17.x declares allowed_in_update as a const member function;
        // iOS 18.3 uses the non-const spelling again.
        "__ZNK2CA6Render6Update17allowed_in_updateEPNS0_7ContextEPKNS0_5LayerE",
        "__ZN2CA6Render6Update17allowed_in_updateEPNS0_7ContextEPKNS0_5LayerE",
    };

    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        void *sym = DobbySymbolResolver(image, candidates[i]);
        if (sym) {
            os_log(patchfinder_log(), "Resolved allowed_in_update via DobbySymbolResolver: %p", sym);
            return sym;
        }
    }

    os_log_error(patchfinder_log(), "Could not resolve allowed_in_update symbol");
    return NULL;
}

static void *resolve_context_process_id(void) {
    const char *image = "/System/Library/Frameworks/QuartzCore.framework/QuartzCore";
    const char *candidates[] = {
        "__ZNK2CA6Render7Context10process_idEv",
        "__ZN2CA6Render7Context10process_idEv",
    };

    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        void *sym = DobbySymbolResolver(image, candidates[i]);
        if (sym) {
            os_log(patchfinder_log(), "Resolved Context::process_id via DobbySymbolResolver: %p", sym);
            return sym;
        }
    }

    os_log_info(patchfinder_log(), "Context::process_id is not exported; trying the inlined pattern");
    return NULL;
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

    for (uint32_t i = 0; i + 5 < 512; i++) {
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
        // DisplayInfo is a large transport struct on every supported release.
        // Reject small-offset copy loops such as the mode-list copier on iOS 18.
        if (storeOffset < 0x1000) {
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

    // iOS 18 expanded the display-state block from one word followed by an
    // 8-byte value into three consecutive words. The first word retains the
    // cloned-display flag, but its output offset moved from 0x11D8 to 0x21D8.
    for (uint32_t i = 0; i + 5 < 512; i++) {
        uint8_t loadRt[3] = {0};
        uint8_t loadRn[3] = {0};
        uint32_t loadOffset[3] = {0};
        uint8_t storeRt[3] = {0};
        uint8_t storeRn[3] = {0};
        uint32_t storeOffset[3] = {0};
        bool matched = true;

        for (uint32_t pair = 0; pair < 3; pair++) {
            uint32_t loadIndex = i + pair * 2;
            uint32_t storeIndex = loadIndex + 1;
            if (!decode_unsigned_load_32(insns[loadIndex], &loadRt[pair], &loadRn[pair], &loadOffset[pair]) ||
                !decode_unsigned_store_32(insns[storeIndex], &storeRt[pair], &storeRn[pair], &storeOffset[pair]) ||
                loadRt[pair] != storeRt[pair]) {
                matched = false;
                break;
            }
        }

        if (!matched || storeOffset[0] < 0x1000) {
            continue;
        }
        if (loadRn[1] != loadRn[0] || loadRn[2] != loadRn[0] || storeRn[1] != storeRn[0] ||
            storeRn[2] != storeRn[0] || loadOffset[1] != loadOffset[0] + 4 ||
            loadOffset[2] != loadOffset[0] + 8 || storeOffset[1] != storeOffset[0] + 4 ||
            storeOffset[2] != storeOffset[0] + 8) {
            continue;
        }

        os_log(patchfinder_log(),
               "Resolved expanded get_display_info flags offset 0x%X from display offset 0x%X", storeOffset[0],
               loadOffset[0]);
        return storeOffset[0];
    }

    os_log_error(patchfinder_log(), "Could not find get_display_info flags offset");
    return 0;
}

typedef struct {
    const uint32_t *call;
    const uint32_t *clearStore;
} AllowedUpdateCallsite;

typedef struct {
    const uint32_t *test;
    const uint32_t *branch;
} LegacyUpdateCallsite;

static bool find_allowed_update_callsite(void *func_start, void *allowed_in_update, AllowedUpdateCallsite *result) {
    if (!func_start || !allowed_in_update || !result) {
        return false;
    }
    const size_t max_scan_size = 65536;
    const uint32_t *insns = (const uint32_t *)func_start;
    size_t count = max_scan_size / sizeof(uint32_t);
    for (size_t i = 0; i + 8 < count; i++) {
        void *target = decode_bl_target(&insns[i]);
        if (target != allowed_in_update) {
            continue;
        }

        os_log_info(patchfinder_log(), "Found allowed_in_update call at %p", (void *)&insns[i]);
        for (size_t j = 1; j <= 4 && (i + j + 1) < count; j++) {
            const char *branchKind = NULL;
            const uint32_t *branchTarget = decode_nonzero_w0_branch_target(&insns[i + j], &branchKind);
            if (!branchTarget) {
                continue;
            }

            for (size_t k = j + 1; k <= j + 3 && (i + k) < count; k++) {
                uint8_t storeRt = 0;
                uint8_t storeRn = 0;
                uint32_t storeOffset = 0;
                if (!decode_unsigned_store_64(insns[i + k], &storeRt, &storeRn, &storeOffset) || storeRt != 31) {
                    continue;
                }
                if (branchTarget != &insns[i + k + 1]) {
                    continue;
                }

                result->call = &insns[i];
                result->clearStore = &insns[i + k];
                os_log(patchfinder_log(),
                       "Found allowed_in_update %s/clear-store path at %p (base X%u + 0x%X, offset +%zu from call)",
                       branchKind, (void *)result->clearStore, storeRn, storeOffset, k);
                return true;
            }

            os_log_error(patchfinder_log(),
                         "allowed_in_update %s found but no matching fallthrough STR XZR clear", branchKind);
        }
    }

    os_log_error(patchfinder_log(), "allowed_in_update callsite pattern not found in prepare_layer0");
    return false;
}

static inline int decode_ldar_32(uint32_t insn, uint8_t *rt, uint8_t *rn) {
    if ((insn & 0xFFFFFC00) != 0x88DFFC00) {
        return 0;
    }
    if (rt) {
        *rt = insn & 0x1F;
    }
    if (rn) {
        *rn = (insn >> 5) & 0x1F;
    }
    return 1;
}

static inline void *canonical_function_pointer(void *address) {
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(address, ptrauth_key_function_pointer);
#else
    return address;
#endif
}

static uint32_t find_cached_context_pid_offset(void *function, uint8_t contextRegister,
                                               int requiredLoadRegister) {
    if (!function) {
        return 0;
    }

    const uint32_t *insns = (const uint32_t *)canonical_function_pointer(function);
    for (size_t i = 0; i + 1 < 64; i++) {
        uint8_t addRd = 0;
        uint8_t addRn = 0;
        uint32_t addImm = 0;
        if (!decode_add_immediate_64(insns[i], &addRd, &addRn, &addImm) || addRn != contextRegister ||
            addImm < 0x40 ||
            addImm > 0x400) {
            continue;
        }

        uint8_t loadRt = 0;
        uint8_t loadRn = 0;
        if (decode_ldar_32(insns[i + 1], &loadRt, &loadRn) && loadRn == addRd &&
            (requiredLoadRegister < 0 || loadRt == (uint8_t)requiredLoadRegister)) {
            return addImm;
        }
    }

    // iOS 16's Context::process_id() starts with a direct
    // LDR W0, [X0, #cached_pid]. Later releases changed this to ADD+LDAR.
    for (size_t i = 0; contextRegister == 0 && requiredLoadRegister == 0 && i < 32; i++) {
        uint8_t loadRt = 0;
        uint8_t loadRn = 0;
        uint32_t loadOffset = 0;
        if (decode_unsigned_load_32(insns[i], &loadRt, &loadRn, &loadOffset) &&
            loadRn == contextRegister && loadOffset >= 0x40 && loadOffset <= 0x400 &&
            (requiredLoadRegister < 0 || loadRt == (uint8_t)requiredLoadRegister)) {
            return loadOffset;
        }
    }

    return 0;
}

static uint32_t find_context_pid_offset_from_insecure_process_ids(void) {
    Class windowServerClass = objc_getClass("CAWindowServer");
    Method method = windowServerClass
                        ? class_getInstanceMethod(windowServerClass, sel_registerName("insecureProcessIds"))
                        : NULL;
    void *implementation = method ? (void *)method_getImplementation(method) : NULL;
    if (!implementation) {
        return 0;
    }

    // iOS 18 inlines Context::process_id() into an internal helper called by
    // this Objective-C method. Follow direct calls and accept only one semantic
    // ADD Context,#offset; LDAR sequence, so an unexpected layout fails closed.
    const uint32_t *insns = (const uint32_t *)canonical_function_pointer(implementation);
    uint32_t foundOffset = 0;
    for (size_t i = 0; i < 128; i++) {
        void *target = decode_bl_target(&insns[i]);
        if (!target) {
            continue;
        }
        uint32_t candidate = find_cached_context_pid_offset(target, 1, -1);
        if (candidate == 0) {
            continue;
        }
        if (foundOffset != 0 && foundOffset != candidate) {
            os_log_error(patchfinder_log(), "Ambiguous inlined Render::Context PID offsets 0x%X and 0x%X",
                         foundOffset, candidate);
            return 0;
        }
        foundOffset = candidate;
    }
    return foundOffset;
}

static uint32_t find_render_context_pid_offset(void) {
    uint32_t offset = find_cached_context_pid_offset(resolve_context_process_id(), 0, 0);
    if (offset == 0) {
        offset = find_context_pid_offset_from_insecure_process_ids();
    }
    if (offset != 0) {
        os_log(patchfinder_log(), "Resolved Render::Context cached PID offset 0x%X", offset);
        return offset;
    }

    os_log_error(patchfinder_log(), "Could not resolve Render::Context cached PID offset");
    return 0;
}

static bool find_legacy_update_callsite(void *func_start, LegacyUpdateCallsite *result) {
    if (!func_start || !result) {
        return false;
    }

    const size_t max_scan_size = 65536;
    const uint32_t *insns = (const uint32_t *)func_start;
    size_t count = max_scan_size / sizeof(uint32_t);

    // Older QuartzCore builds test disableUpdateMask directly instead of
    // consulting allowed_in_update.
    for (size_t i = 0; i + 4 < count; i++) {
        if (!is_tst_xn_disableUpdateMask(insns[i])) {
            continue;
        }

        for (size_t j = 1; j <= 4 && (i + j + 1) < count; j++) {
            if (!is_b_ne(insns[i + j])) {
                continue;
            }

            result->test = &insns[i];
            result->branch = &insns[i + j];
            os_log(patchfinder_log(), "Found legacy TST/B.NE at %p/%p",
                   (void *)result->test, (void *)result->branch);
            return true;
        }
    }

    os_log_error(patchfinder_log(), "Legacy pattern not found in prepare_layer0 (%zu instructions scanned)", count);
    return false;
}

#pragma mark - Disable Update Mask Patch

typedef bool (*AllowedInUpdateIMP)(void *update, void *context, const void *layer);

static AllowedInUpdateIMP orig_allowed_in_update;
static uintptr_t prepare_allowed_return_address;
static uint32_t render_context_pid_offset;
static pid_t springboard_pid;
static id springboard_shell_observer;
static id springboard_shell_observer_registration;

static id system_shell_sentinel(void) {
    Class sentinelClass = objc_getClass("BKSystemShellSentinel");
    SEL sharedInstanceSelector = sel_registerName("sharedInstance");
    if (!sentinelClass || !class_getClassMethod(sentinelClass, sharedInstanceSelector)) {
        return nil;
    }
    return ((id(*)(id, SEL))objc_msgSend)((id)sentinelClass, sharedInstanceSelector);
}

static pid_t springboard_pid_from_shell_descriptor(id descriptor) {
    SEL bundleIdentifierSelector = sel_registerName("bundleIdentifier");
    SEL pidSelector = sel_registerName("pid");
    if (!descriptor || ![descriptor respondsToSelector:bundleIdentifierSelector] ||
        ![descriptor respondsToSelector:pidSelector]) {
        return 0;
    }

    NSString *bundleIdentifier =
        ((id(*)(id, SEL))objc_msgSend)(descriptor, bundleIdentifierSelector);
    if (![bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
        return 0;
    }
    pid_t pid = ((pid_t(*)(id, SEL))objc_msgSend)(descriptor, pidSelector);
    return pid > 0 ? pid : 0;
}

static void publish_springboard_pid(pid_t found, const char *reason) {
    pid_t previous = __atomic_exchange_n(&springboard_pid, found, __ATOMIC_RELEASE);
    if (previous != found) {
        os_log(tweak_log(), "SpringBoard system-shell PID %{public}d -> %{public}d (%{public}s)", previous,
               found, reason);
    }
}

static void refresh_springboard_pid_from_system_shells(const char *reason) {
    id sentinel = system_shell_sentinel();
    SEL systemShellsSelector = sel_registerName("systemShells");
    if (!sentinel || ![sentinel respondsToSelector:systemShellsSelector]) {
        publish_springboard_pid(0, reason);
        return;
    }

    NSArray *shells = ((id(*)(id, SEL))objc_msgSend)(sentinel, systemShellsSelector);
    pid_t found = 0;
    for (id descriptor in shells) {
        found = springboard_pid_from_shell_descriptor(descriptor);
        if (found > 0) {
            break;
        }
    }
    publish_springboard_pid(found, reason);
}

@interface UnseenSystemShellObserver : NSObject
@end

@implementation UnseenSystemShellObserver

- (void)systemShellWillBootstrap {
    publish_springboard_pid(0, "system shell will bootstrap");
}

- (void)systemShellDidFinishLaunching:(id)descriptor {
    pid_t pid = springboard_pid_from_shell_descriptor(descriptor);
    if (pid > 0) {
        publish_springboard_pid(pid, "system shell finished launching");
    } else {
        refresh_springboard_pid_from_system_shells("system shell finished launching");
    }
}

- (void)systemShellChangedWithPrimary:(id)descriptor {
    // Sentinel invokes observers while holding its state lock. The callback
    // argument is the new primary descriptor; querying systemShells here would
    // recursively acquire that lock and trap.
    publish_springboard_pid(springboard_pid_from_shell_descriptor(descriptor),
                            "primary system shell changed");
}

@end


static void start_springboard_system_shell_observer(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Defer until backboardd's main queue is running so the existing system
        // shell sentinel owns initialization and callback serialization.
        dispatch_async(dispatch_get_main_queue(), ^{
            id sentinel = system_shell_sentinel();
            SEL addObserverSelector = sel_registerName("addSystemShellObserver:reason:");
            if (!sentinel || ![sentinel respondsToSelector:addObserverSelector]) {
                os_log_error(tweak_log(), "BKSystemShellSentinel observer API unavailable");
                return;
            }

            springboard_shell_observer = [UnseenSystemShellObserver new];
            springboard_shell_observer_registration =
                ((id(*)(id, SEL, id, id))objc_msgSend)(sentinel, addObserverSelector,
                                                       springboard_shell_observer,
                                                       @"Unseen render ownership filter");
            if (!springboard_shell_observer_registration) {
                os_log_error(tweak_log(), "BKSystemShellSentinel observer registration failed");
                springboard_shell_observer = nil;
                return;
            }
            refresh_springboard_pid_from_system_shells("initial system shell state");
        });
    });
}

static inline uintptr_t canonical_return_address(void *address) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip(address, ptrauth_key_return_address);
#else
    return (uintptr_t)address;
#endif
}

static inline bool context_is_allowed_to_bypass_update_mask(const void *context) {
    if (!context || render_context_pid_offset == 0) {
        return false;
    }

    // The render hot path is deliberately limited to cached integer loads.
    // Unknown ownership fails closed and preserves QuartzCore's restriction.
    pid_t ownerPid = __atomic_load_n(
        (const pid_t *)((const uint8_t *)context + render_context_pid_offset), __ATOMIC_ACQUIRE);
    pid_t springBoardPid = __atomic_load_n(&springboard_pid, __ATOMIC_ACQUIRE);
    return ownerPid > 0 && springBoardPid > 0 && ownerPid != springBoardPid;
}

static bool repl_allowed_in_update(void *update, void *context, const void *layer) {
    uintptr_t caller = canonical_return_address(__builtin_return_address(0));
    bool allowed = orig_allowed_in_update(update, context, layer);

    // allowed_in_update has another QuartzCore caller. Reproduce the old
    // prepare_layer0-only patch scope instead of changing the helper globally.
    if (allowed || caller != prepare_allowed_return_address || !context) {
        return allowed;
    }

    return context_is_allowed_to_bypass_update_mask(context);
}

static bool install_scoped_allowed_in_update_hook(void *allowed_in_update,
                                                  const AllowedUpdateCallsite *callsite) {
    if (!allowed_in_update || !callsite || !callsite->call) {
        return false;
    }
    uint32_t pidOffset = find_render_context_pid_offset();
    if (pidOffset == 0) {
        return false;
    }

    prepare_allowed_return_address = canonical_return_address((void *)(callsite->call + 1));
    render_context_pid_offset = pidOffset;
    start_springboard_system_shell_observer();
    int ret = DobbyHook(allowed_in_update, (dobby_dummy_func_t)repl_allowed_in_update,
                        (dobby_dummy_func_t *)&orig_allowed_in_update);
    if (ret != 0 || !orig_allowed_in_update) {
        os_log_error(tweak_log(), "DobbyHook allowed_in_update failed at %p (ret=%d)", allowed_in_update, ret);
        return false;
    }

    os_log(tweak_log(),
           "Installed scoped allowed_in_update hook at %p (caller return=%p, context PID=0x%X)",
           allowed_in_update, (void *)prepare_allowed_return_address, render_context_pid_offset);
    return true;
}

static bool patch_update_mask_instruction_to_nop(void *target, const char *path) {
    if (!target) {
        return false;
    }
    uint32_t nop = 0xD503201F;
    int ret = DobbyCodePatch(target, (uint8_t *)&nop, sizeof(nop));
    if (ret != 0) {
        os_log_error(tweak_log(), "DobbyCodePatch failed for %{public}s at %p (ret=%d)", path, target, ret);
        return false;
    }
    os_log(tweak_log(), "Installed original %{public}s update-mask patch at %p -> NOP", path, target);
    return true;
}

static bool system_supports_process_aware_update_mask(void) {
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    return version.majorVersion >= 17;
}

static void install_disableUpdateMask_patch(void) {
    if (!gUnseenDisableUpdateMaskPatchEnabled) {
        os_log(tweak_log(), "disableUpdateMask patch disabled");
        return;
    }

    void *prepare_layer0 = resolve_prepare_layer0();
    if (!prepare_layer0) {
        os_log_error(tweak_log(), "Cannot resolve prepare_layer0 - aborting");
        return;
    }

    bool processAware =
        gUnseenProcessAwareUpdateMaskBypassEnabled && system_supports_process_aware_update_mask();
    if (gUnseenProcessAwareUpdateMaskBypassEnabled && !processAware) {
        os_log_info(tweak_log(), "System UI protection requires iOS 17 or later; using original path");
    }

    void *allowed_in_update = resolve_allowed_in_update();
    if (allowed_in_update) {
        AllowedUpdateCallsite callsite = {0};
        if (find_allowed_update_callsite(prepare_layer0, allowed_in_update, &callsite)) {
            if (processAware) {
                if (!install_scoped_allowed_in_update_hook(allowed_in_update, &callsite)) {
                    // Never fall back to the unconditional patch when the user
                    // requested System UI protection.
                    os_log_error(tweak_log(), "Scoped update-mask hook unavailable - leaving QuartzCore unchanged");
                }
            } else {
                patch_update_mask_instruction_to_nop((void *)callsite.clearStore,
                                                     "allowed_in_update clear-store");
            }
            return;
        }

        if (processAware) {
            os_log_error(tweak_log(),
                         "Scoped update-mask callsite unavailable - leaving QuartzCore unchanged");
            return;
        }

        // iOS 16 exports allowed_in_update but prepare_layer0 still uses the
        // older direct TST/B.NE sequence. Continue to the original matcher.
        os_log_info(tweak_log(), "No prepare_layer0 allowed_in_update callsite; trying legacy pattern");
    }

    if (processAware) {
        os_log_error(tweak_log(), "allowed_in_update unavailable - leaving QuartzCore unchanged");
        return;
    }

    LegacyUpdateCallsite legacyCallsite = {0};
    if (!find_legacy_update_callsite(prepare_layer0, &legacyCallsite)) {
        os_log_error(tweak_log(), "Legacy patch target not found - aborting");
        return;
    }

    patch_update_mask_instruction_to_nop((void *)legacyCallsite.branch, "legacy B.NE");
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

static BOOL actions_contains_screenshot(id actions) {
    if (!actions) {
        return NO;
    }

    if ([actions isKindOfClass:[NSArray class]]) {
        for (id action in (NSArray *)actions) {
            if (action_is_screenshot(action)) {
                return YES;
            }
        }
        return NO;
    }

    if ([actions isKindOfClass:[NSSet class]]) {
        for (id action in (NSSet *)actions) {
            if (action_is_screenshot(action)) {
                return YES;
            }
        }
        return NO;
    }

    return action_is_screenshot(actions);
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
    if (!actions_contains_screenshot(actions)) {
        original(self, _cmd, actions);
        return;
    }

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
