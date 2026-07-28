// VMQHomeViewController.m
#import "VMQHomeViewController.h"

// 一个简单的状态行视图：左标题 + 右值。
@interface VMQStatusRow : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
+ (instancetype)rowWithTitle:(NSString *)title;
- (void)setValue:(NSString *)value;
@end

@implementation VMQStatusRow
+ (instancetype)rowWithTitle:(NSString *)title {
    VMQStatusRow *r = [[self alloc] initWithFrame:CGRectZero];
    r.titleLabel = [UILabel new];
    r.titleLabel.text = title;
    r.titleLabel.font = [UIFont systemFontOfSize:15];
    r.titleLabel.textColor = UIColor.secondaryLabelColor;
    r.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    r.valueLabel = [UILabel new];
    r.valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];
    r.valueLabel.textColor = UIColor.labelColor;
    r.valueLabel.textAlignment = NSTextAlignmentRight;
    r.valueLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [r addSubview:r.titleLabel];
    [r addSubview:r.valueLabel];
    [NSLayoutConstraint activateConstraints:@[
        [r.titleLabel.leadingAnchor constraintEqualToAnchor:r.leadingAnchor],
        [r.titleLabel.centerYAnchor constraintEqualToAnchor:r.centerYAnchor],
        [r.valueLabel.trailingAnchor constraintEqualToAnchor:r.trailingAnchor],
        [r.valueLabel.centerYAnchor constraintEqualToAnchor:r.centerYAnchor],
        [r.heightAnchor constraintEqualToConstant:32],
    ]];
    return r;
}
- (void)setValue:(NSString *)value { self.valueLabel.text = value; }
@end


@interface VMQHomeViewController ()
@property (nonatomic, strong) VMQStatusRow *listenerRow;
@property (nonatomic, strong) VMQStatusRow *serverRow;
@property (nonatomic, strong) VMQStatusRow *heartbeatRow;
@property (nonatomic, strong) VMQStatusRow *lastIncomeRow;
@property (nonatomic, strong) VMQStatusRow *pendingRow;
@end

@implementation VMQHomeViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 4;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
    ]];

    self.listenerRow  = [VMQStatusRow rowWithTitle:@"监听状态"];
    self.serverRow    = [VMQStatusRow rowWithTitle:@"服务器状态"];
    self.heartbeatRow = [VMQStatusRow rowWithTitle:@"最近心跳"];
    self.lastIncomeRow = [VMQStatusRow rowWithTitle:@"最近到账"];
    self.pendingRow   = [VMQStatusRow rowWithTitle:@"待上传数量"];

    for (VMQStatusRow *r in @[self.listenerRow, self.serverRow, self.heartbeatRow,
                              self.lastIncomeRow, self.pendingRow]) {
        [stack addArrangedSubview:r];
    }

    // 骨架阶段：占位数据。后续接入 vmqmond 状态查询（读取 SQLite / IPC）。
    [self.listenerRow  setValue:@"未加载"];
    [self.serverRow    setValue:@"未配置"];
    [self.heartbeatRow setValue:@"—"];
    [self.lastIncomeRow setValue:@"—"];
    [self.pendingRow   setValue:@"0"];
}

@end
