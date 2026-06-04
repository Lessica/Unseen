#import "ProcessFilter.h"
#import "ScreenshotActionHooks.h"
#import "dobby.h"

#import <Foundation/Foundation.h>
#import <libproc.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <string.h>

static os_log_t screenshot_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.82flex.layerpropresearch", "screenshot-actions");
    });
    return log;
}

typedef void (*ActionDispatchIMP)(id self, SEL _cmd, id actions);

static ActionDispatchIMP orig_FBScene_sendActions;
static ActionDispatchIMP orig_FBSScene_sendActions;
static ActionDispatchIMP orig_FBSSceneImpl_sendActions;
static ActionDispatchIMP orig_FBScene__sendActions;

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

static pid_t verified_pid_for_action_dispatch(id self, id actions) {
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
    pid_t pid = verified_pid_for_action_dispatch(self, actions);
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

static void repl_FBSScene_sendActions(id self, SEL _cmd, id actions) {
    handle_action_dispatch(self, _cmd, actions, orig_FBSScene_sendActions);
}

static void repl_FBSSceneImpl_sendActions(id self, SEL _cmd, id actions) {
    handle_action_dispatch(self, _cmd, actions, orig_FBSSceneImpl_sendActions);
}

static void repl_FBScene__sendActions(id self, SEL _cmd, id actions) {
    handle_action_dispatch(self, _cmd, actions, orig_FBScene__sendActions);
}

static BOOL dbl_hook_method(const char *className, const char *selectorName, void *replacement, void **original) {
    Class cls = objc_getClass(className);
    if (!cls) {
        return NO;
    }
    SEL selector = sel_registerName(selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return NO;
    }
    IMP imp = method_getImplementation(method);
    if (!imp) {
        return NO;
    }

    int ret = DobbyHook((void *)imp, replacement, original);
    if (ret == 0) {
        os_log(screenshot_log(), "Installed hook %{public}s -%{public}s", className, selectorName);
        return YES;
    }
    os_log_error(screenshot_log(), "Failed hook %{public}s -%{public}s ret=%d", className, selectorName, ret);
    return NO;
}

void install_screenshot_action_hooks(void) {
    unsigned installed = 0;

    if (dbl_hook_method("FBScene", "sendActions:", (void *)repl_FBScene_sendActions,
                        (void **)&orig_FBScene_sendActions)) {
        installed++;
    }
    if (dbl_hook_method("FBSScene", "sendActions:", (void *)repl_FBSScene_sendActions,
                        (void **)&orig_FBSScene_sendActions)) {
        installed++;
    }
    if (dbl_hook_method("FBSSceneImpl", "sendActions:", (void *)repl_FBSSceneImpl_sendActions,
                        (void **)&orig_FBSSceneImpl_sendActions)) {
        installed++;
    }
    if (dbl_hook_method("FBScene", "_sendActions:", (void *)repl_FBScene__sendActions,
                        (void **)&orig_FBScene__sendActions)) {
        installed++;
    }

    if (installed == 0) {
        os_log_error(screenshot_log(), "No screenshot action dispatch hooks installed");
    }
}
