#import "CaptureStateHooks.h"
#import "ScreenshotActionHooks.h"
#import "dobby.h"
#import "patchfinder.h"

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <string.h>

static os_log_t get_tweak_logger(void) {
    static os_log_t logger;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        logger = os_log_create("com.82flex.layerpropresearch", "tweak");
    });
    return logger;
}

__attribute__((constructor)) static void tweak_init(void) {
    os_log_t log = get_tweak_logger();
    os_log(log, "LayerPropResearch loading in %{public}s (pid %d)", getprogname(), getpid());

    const char *process = getprogname();
    if (process && strcmp(process, "SpringBoard") == 0) {
        install_screenshot_action_hooks();
        return;
    }

    void *branch_addr = find_disableUpdateMask_branch();
    if (!branch_addr) {
        os_log_error(log, "Patch target not found — aborting");
        return;
    }

    // NOP the B.NE instruction so the mask-check branch is never taken
    uint32_t nop = 0xD503201F; // ARM64 NOP
    int ret = DobbyCodePatch(branch_addr, (uint8_t *)&nop, sizeof(nop));
    if (ret == 0) {
        os_log(log, "Successfully patched B.NE at %p → NOP", branch_addr);
    } else {
        os_log_error(log, "DobbyCodePatch failed at %p (ret=%d)", branch_addr, ret);
    }

    install_capture_state_hooks();
}
