// VMQChannelViewController.m
#import "VMQChannelViewController.h"
#import "VMQConfig.h"

@interface VMQChannelViewController ()
@property (nonatomic, strong) UISwitch *weChatSwitch;
@property (nonatomic, strong) UISwitch *alipaySwitch;
@property (nonatomic, strong) VMQConfig *config;
@end

@implementation VMQChannelViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.config = [VMQConfig load];

    UIStackView *stack = [self makeStack];
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
    ]];
}

- (UIStackView *)makeStack {
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    [stack addArrangedSubview:[self rowWithTitle:@"微信收款 (com.tencent.xin)"
                                        selector:@selector(weChatChanged:)
                                              on:self.config.weChatEnabled
                                          assign:^(UISwitch *s){ self.weChatSwitch = s; }]];
    [stack addArrangedSubview:[self rowWithTitle:@"支付宝收款 (com.alipay.iphoneclient)"
                                        selector:@selector(alipayChanged:)
                                              on:self.config.alipayEnabled
                                          assign:^(UISwitch *s){ self.alipaySwitch = s; }]];

    UILabel *hint = [UILabel new];
    hint.numberOfLines = 0;
    hint.font = [UIFont systemFontOfSize:13];
    hint.textColor = UIColor.secondaryLabelColor;
    hint.text = @"提示：需在系统设置中为对应 App 开启通知及“通知预览”，否则监听端拿不到金额（§10）。";
    [stack addArrangedSubview:hint];

    return stack;
}

- (UIView *)rowWithTitle:(NSString *)title
                selector:(SEL)sel
                      on:(BOOL)on
                  assign:(void(^)(UISwitch *))assign {
    UIView *row = [UIView new];
    UILabel *label = [UILabel new];
    label.text = title;
    label.font = [UIFont systemFontOfSize:15];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.numberOfLines = 0;

    UISwitch *sw = [UISwitch new];
    sw.on = on;
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    [sw addTarget:self action:sel forControlEvents:UIControlEventValueChanged];
    assign(sw);

    [row addSubview:label];
    [row addSubview:sw];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:sw.leadingAnchor constant:-12],
        [sw.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [sw.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    ]];
    return row;
}

- (void)weChatChanged:(UISwitch *)sw {
    self.config.weChatEnabled = sw.on;
    [self.config save];
}

- (void)alipayChanged:(UISwitch *)sw {
    self.config.alipayEnabled = sw.on;
    [self.config save];
}

@end
