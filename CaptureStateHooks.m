#import "CaptureStateHooks.h"
#import "ProcessFilter.h"
#import "dobby.h"
#import "patchfinder.h"

#import <Foundation/Foundation.h>
#import <libproc.h>
#import <mach/mach.h>
#import <mach/message.h>
#import <os/log.h>
#import <pthread.h>
#import <stdatomic.h>

static os_log_t capture_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.82flex.layerpropresearch", "capture-state");
    });
    return log;
}

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
    uint32_t originalFlags = *flags;
    BOOL hadClonedBit = ((*flags & 0x4) != 0);
    *flags &= ~0x4U;
    os_log(capture_log(), "get_display_info called by target client, original flags=0x%X, modified flags=0x%X",
           originalFlags, *flags);

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

void install_capture_state_hooks(void) {
    const char *quartzCore = "/System/Library/Frameworks/QuartzCore.framework/QuartzCore";
    const char *getDisplayInfoSymbol = "__ZN2CA12WindowServer6Server16get_display_infoEPNS_6Render6ObjectEPvS5_";

    display_flags_info_offset = find_get_display_info_flags_offset();
    if (display_flags_info_offset == 0) {
        return;
    }

    install_hook_symbol(quartzCore, "__XGetDisplayInfo", (void *)repl_XGetDisplayInfo, (void **)&orig_XGetDisplayInfo);
    install_hook_symbol(quartzCore, getDisplayInfoSymbol, (void *)repl_get_display_info, (void **)&orig_get_display_info);
}
