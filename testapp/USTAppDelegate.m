#import "USTAppDelegate.h"

#import "USTTestViewController.h"

@implementation USTAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    USTTestViewController *testController = [[USTTestViewController alloc] init];
    UINavigationController *navigationController =
        [[UINavigationController alloc] initWithRootViewController:testController];
    navigationController.navigationBar.prefersLargeTitles = YES;

    self.window.rootViewController = navigationController;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
