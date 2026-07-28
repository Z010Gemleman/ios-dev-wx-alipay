// VMQAppDelegate.m
#import "VMQAppDelegate.h"
#import "VMQHomeViewController.h"
#import "VMQChannelViewController.h"
#import "VMQConfigViewController.h"
#import "VMQLogViewController.h"
#import "VMQRecoveryViewController.h"

@implementation VMQAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.backgroundColor = UIColor.systemBackgroundColor;

    UITabBarController *tab = [UITabBarController new];
    tab.viewControllers = @[
        [self wrapVC:[VMQHomeViewController new]
               title:@"首页"
               image:@"house.fill"],
        [self wrapVC:[VMQChannelViewController new]
               title:@"通道"
               image:@"bell.badge.fill"],
        [self wrapVC:[VMQConfigViewController new]
               title:@"配置"
               image:@"gear"],
        [self wrapVC:[VMQLogViewController new]
               title:@"日志"
               image:@"text.alignleft"],
        [self wrapVC:[VMQRecoveryViewController new]
               title:@"恢复"
               image:@"wrench.and.screwdriver.fill"],
    ];
    self.window.rootViewController = tab;
    [self.window makeKeyAndVisible];
    return YES;
}

- (UINavigationController *)wrapVC:(UIViewController *)vc
                              title:(NSString *)title
                              image:(NSString *)sfName {
    vc.title = title;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    // SF Symbols available on iOS 13+; iOS 15 minimum satisfied (§11.1).
    UIImage *img = [UIImage systemImageNamed:sfName];
    nav.tabBarItem = [[UITabBarItem alloc] initWithTitle:title image:img tag:0];
    return nav;
}

@end
