#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <signal.h>
#import <stdlib.h>
#import <string.h>
#import <sys/sysctl.h>

NS_INLINE void UnseenEnumerateProcesses(void (^enumerator)(pid_t pid, NSString *executablePath, BOOL *stop)) {
    static int kMaximumArgumentSize = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        size_t valSize = sizeof(kMaximumArgumentSize);
        if (sysctl((int[]){CTL_KERN, KERN_ARGMAX}, 2, &kMaximumArgumentSize, &valSize, NULL, 0) < 0) {
            kMaximumArgumentSize = 4096;
        }
    });

    size_t procInfoLength = 0;
    if (sysctl((int[]){CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0}, 4, NULL, &procInfoLength, NULL, 0) < 0) {
        return;
    }

    struct kinfo_proc *procInfo = (struct kinfo_proc *)calloc(1, procInfoLength + 1);
    if (!procInfo)
        return;
    if (sysctl((int[]){CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0}, 4, procInfo, &procInfoLength, NULL, 0) < 0) {
        free(procInfo);
        return;
    }

    char *argBuffer = (char *)calloc(1, (size_t)kMaximumArgumentSize + 1);
    if (!argBuffer) {
        free(procInfo);
        return;
    }

    int procInfoCnt = (int)(procInfoLength / sizeof(struct kinfo_proc));
    for (int i = 0; i < procInfoCnt; i++) {
        pid_t pid = procInfo[i].kp_proc.p_pid;
        if (pid <= 1)
            continue;

        size_t argSize = (size_t)kMaximumArgumentSize;
        if (sysctl((int[]){CTL_KERN, KERN_PROCARGS2, pid, 0}, 4, NULL, &argSize, NULL, 0) < 0)
            continue;
        memset(argBuffer, 0, argSize + 1);
        if (sysctl((int[]){CTL_KERN, KERN_PROCARGS2, pid, 0}, 4, argBuffer, &argSize, NULL, 0) < 0)
            continue;

        BOOL stop = NO;
        @autoreleasepool {
            NSString *exePath = [NSString stringWithUTF8String:(argBuffer + sizeof(int))] ?: @"";
            enumerator(pid, exePath, &stop);
        }
        if (stop)
            break;
    }

    free(argBuffer);
    free(procInfo);
}

NS_INLINE void UnseenRestartProcesses(NSSet<NSString *> *processNames) {
    UnseenEnumerateProcesses(^(pid_t pid, NSString *executablePath, BOOL *stop) {
        if ([processNames containsObject:executablePath.lastPathComponent]) {
            kill(pid, SIGTERM);
        }
    });
}

@interface UnseenRootListController : PSListController
@end

@implementation UnseenRootListController

- (NSBundle *)localizationBundle {
    return [NSBundle bundleForClass:[self class]];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)restartRenderServices {
    NSBundle *bundle = [self localizationBundle];
    NSString *title = NSLocalizedStringFromTableInBundle(@"Restart Rendering Services", @"Localizable", bundle, nil);
    NSString *message = NSLocalizedStringFromTableInBundle(
        @"Are you sure you want to restart backboardd and SpringBoard? The screen may briefly go black and the Home Screen will reload.",
        @"Localizable", bundle, nil);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];

    NSString *cancel = NSLocalizedStringFromTableInBundle(@"Cancel", @"Localizable", bundle, nil);
    NSString *restart = NSLocalizedStringFromTableInBundle(@"Restart", @"Localizable", bundle, nil);

    [alert addAction:[UIAlertAction actionWithTitle:cancel style:UIAlertActionStyleCancel handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:restart
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
                                                UnseenRestartProcesses([NSSet setWithObjects:@"backboardd",
                                                                                            @"SpringBoard", nil]);
                                                [weakSelf.view endEditing:YES];
                                            }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)support {
    NSURL *url = [NSURL URLWithString:@"https://havoc.app/search/82Flex"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

#pragma mark - UITableViewDataSource & UITableViewDelegate

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSString *cellType = [specifier propertyForKey:@"cell"];
    if ([cellType isEqualToString:@"PSButtonCell"]) {
        UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];

        BOOL isDestructive =
            ([specifier propertyForKey:@"isDestructive"] && [[specifier propertyForKey:@"isDestructive"] boolValue]);
        if (isDestructive) {
            cell.textLabel.textColor = [UIColor systemRedColor];
            cell.textLabel.highlightedTextColor = [UIColor systemRedColor];
        }
        return cell;
    }

    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
}

@end
