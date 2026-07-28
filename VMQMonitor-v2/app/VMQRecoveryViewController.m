// VMQRecoveryViewController.m
// 恢复页（§18.5）——完整一键注入实现。
// 职责：越狱类型自动检测、posix_spawn 调用 vmqhelper、进度 UI、结果解析与显示。

#import "VMQRecoveryViewController.h"
#import "../common/VMQProtocol.h"

#include <spawn.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <unistd.h>
#include <errno.h>
#include <crt_externs.h>   // _NSGetEnviron()（iOS 上取 environ 的官方方式）

// ---- persona SPI（TrollStore root-spawn 机制）----
// TrollStore App（mobile 身份）需以 root 拉起 helper 才能 dpkg -i 写系统路径。
// 通过 posix_spawnattr 设置 persona = root（uid/gid 0），配合 App 的
// com.apple.private.persona-mgmt entitlement 生效。
#define VMQ_PERSONA_FLAGS_OVERRIDE 1
typedef uint32_t vmq_persona_id_t;
int posix_spawnattr_set_persona_np(posix_spawnattr_t *__restrict, vmq_persona_id_t, uint32_t);
int posix_spawnattr_set_persona_uid_np(posix_spawnattr_t *__restrict, uid_t);
int posix_spawnattr_set_persona_gid_np(posix_spawnattr_t *__restrict, gid_t);

@interface VMQRecoveryViewController ()
@property (nonatomic, strong) UILabel          *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIButton         *enableBtn;
@property (nonatomic, strong) UIButton         *disableBtn;
@property (nonatomic, strong) UIButton         *uninstallBtn;
@property (nonatomic, strong) UIButton         *probeBtn;
@end

@implementation VMQRecoveryViewController

#pragma mark - 越狱环境检测

// 检测越狱 scheme。
// 关键：TrollStore App 内 getenv("JBROOT") 通常为空，不能作唯一依据。
// 真正的区分特征是 /var/jb 本身的类型：
//   - RootHide：/var/jb 是符号链接（-> 随机 jbroot / 根），lstat 得到 S_ISLNK
//   - 标准 rootless(Dopamine/Ellekit)：/var/jb 是真实目录，lstat 得到 S_ISDIR
- (NSString *)detectedScheme {
    const char *jbroot = getenv("JBROOT");
    if (jbroot && strlen(jbroot) > 0) return @"roothide";
    struct stat lst;
    if (lstat("/var/jb", &lst) == 0) {
        if (S_ISLNK(lst.st_mode)) return @"roothide";   // /var/jb -> / 是 RootHide 特征
        if (S_ISDIR(lst.st_mode)) return @"rootless";
    }
    return nil;
}

// 监听组件 dylib 是否已安装到 bootstrap。
// /var/jb 在两种方案下都能正确解析到 bootstrap 根：
//   roothide: /var/jb -> /（符号链接）→ /var/jb/Library/... 即 /Library/...
//   rootless: /var/jb 是真实目录
// 故统一用 /var/jb 前缀探测，无需依赖 JBROOT 环境变量。
- (BOOL)isListenerInstalled {
    struct stat st;
    if (stat("/var/jb/Library/MobileSubstrate/DynamicLibraries/VMQListener.dylib", &st) == 0)
        return YES;
    // 兜底：直接根路径（roothide 下 /var/jb 已等价于 /，此项冗余但无害）
    if (stat("/Library/MobileSubstrate/DynamicLibraries/VMQListener.dylib", &st) == 0)
        return YES;
    return NO;
}

#pragma mark - Helper 调用（posix_spawn + 管道捕获 stdout）

- (void)runHelperArgs:(NSArray<NSString *> *)args
          completion:(void(^)(BOOL ok, NSString *message))completion {
    NSString *helperPath = [NSBundle.mainBundle.bundlePath
                            stringByAppendingPathComponent:@"vmqhelper"];
    // 确保可执行
    chmod(helperPath.fileSystemRepresentation, 0755);
    if (access(helperPath.fileSystemRepresentation, X_OK) != 0) {
        completion(NO, [NSString stringWithFormat:@"vmqhelper 不可执行：%s", strerror(errno)]);
        return;
    }

    // 构建 argv
    NSMutableArray<NSString *> *all = [@[@"vmqhelper"] mutableCopy];
    [all addObjectsFromArray:args];
    const char **argv = calloc(all.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < all.count; i++) argv[i] = all[i].UTF8String;
    argv[all.count] = NULL;

    // 建管道捕获 stdout
    int pfd[2];
    if (pipe(pfd) != 0) {
        free(argv);
        completion(NO, [NSString stringWithFormat:@"pipe 失败: %s", strerror(errno)]);
        return;
    }

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addclose(&fa, pfd[0]);
    posix_spawn_file_actions_adddup2(&fa, pfd[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&fa, pfd[1]);

    // 关键：设置 persona = root，让 helper 以 root 运行（否则 dpkg 写系统路径权限不足）。
    // 这是 TrollStore App 提权 spawn 的标准做法（persona 99 = root）。
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, VMQ_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, helperPath.UTF8String, &fa, &attr,
                         (char *const *)argv, *_NSGetEnviron());
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&fa);
    free(argv);
    close(pfd[1]);

    if (rc != 0) {
        close(pfd[0]);
        completion(NO, [NSString stringWithFormat:@"spawn 失败: %s", strerror(rc)]);
        return;
    }

    // block 内不能引用数组类型的 pfd，先复制读端到标量。
    int readFD = pfd[0];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 读取 stdout
        NSMutableData *data = [NSMutableData data];
        char buf[1024]; ssize_t n;
        while ((n = read(readFD, buf, sizeof(buf))) > 0)
            [data appendBytes:buf length:(NSUInteger)n];
        close(readFD);
        waitpid(pid, NULL, 0);

        NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        // 解析 JSON {"ok":bool,"message":"..."}
        NSData *jd = [raw dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *r = [NSJSONSerialization JSONObjectWithData:jd ?: [NSData data]
                                                          options:0 error:nil];
        BOOL ok  = [r[@"ok"] boolValue];
        NSString *msg = [r[@"message"] length] ? r[@"message"] : (raw.length ? raw : @"(无输出)");

        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, msg); });
    });
}

#pragma mark - UI 构建

- (void)viewDidLoad {
    [super viewDidLoad];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor    constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    UIStackView *stack = [UIStackView new];
    stack.axis    = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor     constraintEqualToAnchor:scroll.topAnchor constant:20],
        [stack.leadingAnchor  constraintEqualToAnchor:scroll.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor constant:-20],
        [stack.widthAnchor    constraintEqualToAnchor:scroll.widthAnchor constant:-40],
        [stack.bottomAnchor  constraintEqualToAnchor:scroll.bottomAnchor constant:-20],
    ]];

    // 环境状态标签
    self.statusLabel = [UILabel new];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.text = @"点击「环境探针」查看当前状态。";
    [stack addArrangedSubview:self.statusLabel];

    // 转圈（操作中显示）
    self.spinner = [[UIActivityIndicatorView alloc]
                    initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    [stack addArrangedSubview:self.spinner];

    // 按钮组
    self.probeBtn     = [self btn:@"环境探针"       color:UIColor.systemGrayColor      sel:@selector(probeTapped)];
    self.enableBtn    = [self btn:@"一键启用监听"   color:UIColor.systemGreenColor     sel:@selector(enableTapped)];
    self.disableBtn   = [self btn:@"停用监听"       color:UIColor.systemOrangeColor    sel:@selector(disableTapped)];
    self.uninstallBtn = [self btn:@"彻底卸载监听"   color:UIColor.systemRedColor       sel:@selector(uninstallTapped)];
    for (UIButton *b in @[self.probeBtn, self.enableBtn, self.disableBtn, self.uninstallBtn])
        [stack addArrangedSubview:b];

    // 紧急恢复说明
    UILabel *note = [UILabel new];
    note.numberOfLines = 0;
    note.font = [UIFont systemFontOfSize:11];
    note.textColor = UIColor.secondaryLabelColor;
    note.text =
        @"紧急禁用（SSH/Filza）：\n"
        "touch \"/var/mobile/Library/Application Support/VMQMonitorV2/listener.disabled\"\n"
        "sbreload";
    note.backgroundColor = UIColor.secondarySystemBackgroundColor;
    note.layer.cornerRadius = 8;
    note.layer.masksToBounds = YES;
    UIView *w = [UIView new];
    note.translatesAutoresizingMaskIntoConstraints = NO;
    [w addSubview:note];
    [NSLayoutConstraint activateConstraints:@[
        [note.topAnchor     constraintEqualToAnchor:w.topAnchor constant:10],
        [note.bottomAnchor  constraintEqualToAnchor:w.bottomAnchor constant:-10],
        [note.leadingAnchor  constraintEqualToAnchor:w.leadingAnchor constant:10],
        [note.trailingAnchor constraintEqualToAnchor:w.trailingAnchor constant:-10],
    ]];
    [stack addArrangedSubview:w];

    // 进入后立即刷新环境状态
    [self refreshStatus];
}

- (UIButton *)btn:(NSString *)title color:(UIColor *)color sel:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font      = [UIFont boldSystemFontOfSize:15];
    b.backgroundColor      = color;
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [b setTitleColor:[UIColor.whiteColor colorWithAlphaComponent:0.4]
            forState:UIControlStateDisabled];
    b.layer.cornerRadius   = 10;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.heightAnchor constraintEqualToConstant:46].active = YES;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)setAllButtonsEnabled:(BOOL)on {
    for (UIButton *b in @[self.probeBtn, self.enableBtn, self.disableBtn, self.uninstallBtn])
        b.enabled = on;
}

#pragma mark - 环境状态刷新

- (void)refreshStatus {
    NSString *scheme  = [self detectedScheme];
    const char *jbr   = getenv("JBROOT");
    BOOL installed    = [self isListenerInstalled];
    BOOL disabled     = [[NSFileManager defaultManager]
                         fileExistsAtPath:@(VMQ_DISABLE_FLAG)];

    struct utsname u; uname(&u);
    NSString *info = [NSString stringWithFormat:
        @"iOS %@  %s\n"
        "越狱方案: %@\n"
        "JBROOT: %s\n"
        "监听组件: %@\n"
        "监听状态: %@",
        [[UIDevice currentDevice] systemVersion],
        u.machine,
        scheme ?: @"未检测到",
        jbr ?: "(未设置)",
        installed ? @"已安装" : @"未安装",
        disabled  ? @"已禁用（存在禁用标记）" : (installed ? @"运行中" : @"未安装")
    ];
    self.statusLabel.text = info;
}

#pragma mark - 按钮动作

- (void)probeTapped {
    [self refreshStatus];
}

- (void)enableTapped {
    NSString *scheme = [self detectedScheme];
    if (!scheme) {
        [self alert:@"未检测到越狱环境" msg:@"请确认 Dopamine + RootHide Bootstrap 处于激活状态。"];
        return;
    }

    NSString *warning = [NSString stringWithFormat:
        @"检测到越狱方案：%@\n\n"
        "将执行：\n"
        "  1. dpkg -i 安装监听运行时\n"
        "  2. sbreload（设备会短暂黑屏刷新）\n\n"
        "继续？",
        scheme
    ];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"确认启用监听"
                                                                message:warning
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"确认安装" style:UIAlertActionStyleDestructive
                                         handler:^(__unused UIAlertAction *a) {
        [self executeInstallScheme:scheme];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)executeInstallScheme:(NSString *)scheme {
    self.statusLabel.text = [NSString stringWithFormat:@"正在安装 %@ 运行时…\n（设备即将刷新，请稍候）", scheme];
    [self setAllButtonsEnabled:NO];
    [self.spinner startAnimating];

    [self runHelperArgs:@[@"install", scheme]
            completion:^(BOOL ok, NSString *msg) {
        [self.spinner stopAnimating];
        [self setAllButtonsEnabled:YES];
        [self refreshStatus];
        // 安装成功后 sbreload 会杀掉当前进程，所以这个 alert 可能来不及显示——没关系。
        [self alert:(ok ? @"安装成功" : @"安装失败") msg:msg];
    }];
}

- (void)disableTapped {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"确认停用监听"
                                                                message:@"将写入禁用标记并刷新设备。"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"停用" style:UIAlertActionStyleDestructive
                                         handler:^(__unused UIAlertAction *a) {
        [self setAllButtonsEnabled:NO];
        [self.spinner startAnimating];
        [self runHelperArgs:@[@"disable"] completion:^(BOOL ok, NSString *msg) {
            [self.spinner stopAnimating];
            [self setAllButtonsEnabled:YES];
            [self refreshStatus];
            [self alert:(ok ? @"已停用" : @"停用失败") msg:msg];
        }];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)uninstallTapped {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"确认彻底卸载"
                                                                message:@"将卸载监听运行时包并刷新设备。\n卸载完成后再从 TrollStore 删除 App。"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"卸载" style:UIAlertActionStyleDestructive
                                         handler:^(__unused UIAlertAction *a) {
        [self setAllButtonsEnabled:NO];
        [self.spinner startAnimating];
        [self runHelperArgs:@[@"uninstall"] completion:^(BOOL ok, NSString *msg) {
            [self.spinner stopAnimating];
            [self setAllButtonsEnabled:YES];
            [self refreshStatus];
            [self alert:(ok ? @"卸载完成" : @"卸载失败") msg:msg];
        }];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)alert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
