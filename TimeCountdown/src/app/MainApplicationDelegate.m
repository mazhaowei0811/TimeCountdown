#import "MainApplicationDelegate.h"
#import "SetupViewController.h"

@implementation MainApplicationDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions
{
    (void)application; (void)launchOptions;

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    SetupViewController *setup = [[SetupViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:setup];
    nav.navigationBar.prefersLargeTitles = NO;
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
