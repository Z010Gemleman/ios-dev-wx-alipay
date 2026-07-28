// VMQBaseViewController.m
#import "VMQBaseViewController.h"

@implementation VMQBaseViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    // 大标题导航栏（iOS 15+ 可用，§11.1）。
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAutomatic;
}

@end
