#import "CaptureStateHooks.h"
#import "ProcessFilter.h"
#import "dobby.h"

#import <Foundation/Foundation.h>
#import <libproc.h>
#import <mach/mach.h>
#import <mach/message.h>
#import <os/log.h>
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
static XGetDisplayInfoIMP orig_XGetDisplayInfo;
static atomic_uint gLayoutFailureLogCount;

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

static BOOL clear_cloned_bit_in_get_display_info_reply(mach_msg_header_t *reply, BOOL *hadClonedBit) {
    if (hadClonedBit) {
        *hadClonedBit = NO;
    }
    if (!reply || !(reply->msgh_bits & MACH_MSGH_BITS_COMPLEX)) {
        return NO;
    }

    uint8_t *base = (uint8_t *)reply;
    mach_msg_size_t size = reply->msgh_size;
    if (size < 512 || size > 0x4000) {
        return NO;
    }

    uint32_t descriptorCount = *(uint32_t *)(base + 24);
    if (descriptorCount != 2) {
        return NO;
    }

    uint32_t inlineNameLength = *(uint32_t *)(base + 76);
    if (inlineNameLength == 0 || inlineNameLength > 1024) {
        return NO;
    }

    size_t roundedName = ((size_t)inlineNameLength + 3) & ~3UL;
    size_t encodedModeLengthOffset = roundedName + 84;
    if (encodedModeLengthOffset + sizeof(uint32_t) > size) {
        return NO;
    }

    uint32_t encodedModeLength = *(uint32_t *)(base + encodedModeLengthOffset);
    if (encodedModeLength > 4096) {
        return NO;
    }

    size_t roundedMode = ((size_t)encodedModeLength + 3) & ~3UL;
    size_t encodedColorModeLengthOffset = roundedName + roundedMode + 92;
    if (encodedColorModeLengthOffset + sizeof(uint32_t) > size) {
        return NO;
    }

    uint32_t encodedColorModeLength = *(uint32_t *)(base + encodedColorModeLengthOffset);
    if (encodedColorModeLength > 4096) {
        return NO;
    }

    size_t roundedColorMode = ((size_t)encodedColorModeLength + 3) & ~3UL;
    size_t flagsOffset = roundedName + roundedMode + roundedColorMode + 284;
    if (flagsOffset + sizeof(uint32_t) > size) {
        return NO;
    }

    uint32_t *flags = (uint32_t *)(base + flagsOffset);
    if (hadClonedBit) {
        *hadClonedBit = ((*flags & 0x4) != 0);
    }
    *flags &= ~0x4U;
    return YES;
}

static void repl_XGetDisplayInfo(mach_msg_header_t *request, mach_msg_header_t *reply) {
    audit_token_t token;
    BOOL hasToken = audit_token_from_request(request, &token);
    pid_t pid = -1;
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    BOOL target = hasToken && client_is_target_audit_token(token, &pid, path, sizeof(path));

    orig_XGetDisplayInfo(request, reply);

    if (!target) {
        return;
    }

    BOOL hadClonedBit = NO;
    BOOL cleared = clear_cloned_bit_in_get_display_info_reply(reply, &hadClonedBit);
    if (cleared && hadClonedBit) {
        os_log(capture_log(), "Cleared cloned display bit for pid %d path %{public}s", pid, path);
    } else if (!cleared && atomic_fetch_add(&gLayoutFailureLogCount, 1) < 5) {
        os_log_error(capture_log(), "Target pid %d matched but GetDisplayInfo reply layout was not recognized", pid);
    }
}

void install_capture_state_hooks(void) {
    void *symbol =
        DobbySymbolResolver("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", "__XGetDisplayInfo");
    if (!symbol) {
        os_log_error(capture_log(), "__XGetDisplayInfo not found");
        return;
    }

    int ret = DobbyHook(symbol, (dobby_dummy_func_t)repl_XGetDisplayInfo, (dobby_dummy_func_t *)&orig_XGetDisplayInfo);
    if (ret == 0) {
        os_log(capture_log(), "Installed __XGetDisplayInfo hook at %p", symbol);
    } else {
        os_log_error(capture_log(), "DobbyHook __XGetDisplayInfo failed ret=%d", ret);
    }
}
