// VMQConfigViewController.m
#import "VMQConfigViewController.h"
#import "VMQConfig.h"

@interface VMQConfigViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *serverField;
@property (nonatomic, strong) UITextField *keyField;
@property (nonatomic, strong) UISegmentedControl *signSeg;
@property (nonatomic, strong) UILabel *resultLabel;
@property (nonatomic, strong) VMQConfig *config;
@end

@implementation VMQConfigViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.config = [VMQConfig load];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:20],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor constant:-20],
        [stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor constant:-40],
    ]];

    [stack addArrangedSubview:[self labelWithText:@"VMQ 服务器地址"]];
    self.serverField = [self fieldWithPlaceholder:@"https://pay.example.com" secure:NO];
    self.serverField.text = self.config.serverBase;
    self.serverField.keyboardType = UIKeyboardTypeURL;
    self.serverField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [stack addArrangedSubview:self.serverField];

    [stack addArrangedSubview:[self labelWithText:@"通信密钥"]];
    self.keyField = [self fieldWithPlaceholder:@"VMQ key" secure:YES];
    self.keyField.text = self.config.key;
    [stack addArrangedSubview:self.keyField];

    [stack addArrangedSubview:[self labelWithText:@"签名模式"]];
    self.signSeg = [[UISegmentedControl alloc] initWithItems:@[@"HMAC-SHA256", @"MD5(兼容)"]];
    self.signSeg.selectedSegmentIndex = (self.config.signType == VMQSignTypeMD5) ? 1 : 0;
    [stack addArrangedSubview:self.signSeg];

    UIButton *saveBtn = [self buttonWithTitle:@"保存配置" action:@selector(saveTapped)];
    [stack addArrangedSubview:saveBtn];

    UIButton *testBtn = [self buttonWithTitle:@"测试连接" action:@selector(testTapped)];
    [stack addArrangedSubview:testBtn];

    self.resultLabel = [UILabel new];
    self.resultLabel.numberOfLines = 0;
    self.resultLabel.font = [UIFont systemFontOfSize:13];
    self.resultLabel.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:self.resultLabel];
}

- (UILabel *)labelWithText:(NSString *)text {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [UIFont boldSystemFontOfSize:14];
    return l;
}

- (UITextField *)fieldWithPlaceholder:(NSString *)ph secure:(BOOL)secure {
    UITextField *f = [UITextField new];
    f.placeholder = ph;
    f.secureTextEntry = secure;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.delegate = self;
    f.translatesAutoresizingMaskIntoConstraints = NO;
    [f.heightAnchor constraintEqualToConstant:40].active = YES;
    return f;
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    b.backgroundColor = UIColor.systemBlueColor;
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.layer.cornerRadius = 10;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.heightAnchor constraintEqualToConstant:46].active = YES;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)saveTapped {
    self.config.serverBase = self.serverField.text;
    self.config.key = self.keyField.text;
    self.config.signType = (self.signSeg.selectedSegmentIndex == 1) ? VMQSignTypeMD5 : VMQSignTypeHMACSHA256;
    BOOL ok = [self.config save];
    self.resultLabel.text = ok ? @"配置已保存 (0600)" : @"保存失败";
}

- (void)testTapped {
    // 骨架阶段：仅提示。真机版由 vmqmond 或直接 NSURLSession 执行 §13.3 测试。
    self.resultLabel.text = @"测试连接：骨架占位，待接入 VMQReporter testConnection。";
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
