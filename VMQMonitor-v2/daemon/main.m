// vmqmond/main.m
// 后台守护进程主入口（设计文档 §5.3/§6/§13/§14/§16）。
// 职责：
//   - 启动 Unix datagram 服务端，接收监听组件原始事件；
//   - 用统一解析器判定收款、提取金额、去重入队；
//   - 定时心跳、队列上报、指数退避重试；
//   - 每 5 分钟检查主 App 是否仍注册，未注册则暂停并写禁用标记；
//   - 稳定运行 60 秒后清除待稳定标记（§16.2）。
//
// 平台无关，纯 Foundation。由 LaunchDaemon 拉起，常驻运行。

#import <Foundation/Foundation.h>
#import "VMQProtocol.h"
#import "VMQBoot.h"
#import "VMQEvent.h"
#import "VMQParser.h"
#import "VMQConfig.h"
#import "VMQStore.h"
#import "VMQReporter.h"
#import "VMQSocketServer.h"

// ---- 可调参数 ----
static const NSTimeInterval kHeartbeatInterval = 30.0;   // §13.1
static const NSTimeInterval kQueueTick         = 5.0;    // 队列轮询
static const NSTimeInterval kAppCheckInterval  = 300.0;  // §5.3 每 5 分钟
static const NSTimeInterval kStabilizeAfter    = 60.0;   // §16.2 稳定 60 秒
static const NSInteger      kMaxBackoff        = 300;    // §14 最大退避 5 分钟
static const NSInteger      kBatchLimit        = 16;

@interface VMQDaemon : NSObject
@property (nonatomic, strong) VMQConfig *config;
@property (nonatomic, strong) VMQStore *store;
@property (nonatomic, strong) VMQReporter *reporter;
@property (nonatomic, strong) VMQSocketServer *server;
@property (nonatomic, strong) dispatch_queue_t workQ;
@property (nonatomic, strong) dispatch_source_t heartbeatTimer;
@property (nonatomic, strong) dispatch_source_t queueTimer;
@property (nonatomic, strong) dispatch_source_t appCheckTimer;
@property (nonatomic, assign) NSInteger currentBackoff;
@property (nonatomic, assign) NSTimeInterval nextSendAllowedAt;
@property (nonatomic, assign) BOOL disabled;
@end

@implementation VMQDaemon

- (instancetype)init {
    if ((self = [super init])) {
        _workQ = dispatch_queue_create("com.z010genleman.vmqmonitor.v2.mond", DISPATCH_QUEUE_SERIAL);
        _config = [VMQConfig load];
        _store = [VMQStore sharedStore];
        _currentBackoff = 0;
        _nextSendAllowedAt = 0;
        _disabled = NO;
    }
    return self;
}

- (void)start {
    [self.store open];
    [self.store recoverSending];   // §14 残留 sending -> pending
    [self.store log:VMQLogLevelInfo category:VMQLogCatLifecycle message:@"vmqmond 启动"];

    self.reporter = [[VMQReporter alloc] initWithConfig:self.config];

    // socket 服务端：收到原始事件 -> 解析 -> 入队
    __weak typeof(self) weakSelf = self;
    self.server = [[VMQSocketServer alloc] initWithHandler:^(VMQEvent *event) {
        [weakSelf handleIncomingEvent:event];
    }];
    if (![self.server start]) {
        [self.store log:VMQLogLevelError category:VMQLogCatLifecycle message:@"socket 绑定失败"];
    }

    [self scheduleTimers];
    [self scheduleStabilizeClear];
}

#pragma mark - 事件入口

- (void)handleIncomingEvent:(VMQEvent *)event {
    dispatch_async(self.workQ, ^{
        // 渠道开关检查
        if (![self.config isChannelEnabled:event.channelType]) {
            return;
        }
        VMQParseResult *r = [VMQParser parseEvent:event];
        if (!r.accepted) {
            [self.store log:VMQLogLevelInfo category:VMQLogCatNotification
                    message:[NSString stringWithFormat:@"拒绝(%@) type=%ld", r.reason, (long)event.channelType]];
            return;
        }
        event.normalizedAmount = r.normalizedAmount;
        if (event.eventId.length == 0) {
            event.eventId = [event computedFallbackEventId];
        }
        BOOL ok = [self.store enqueueEvent:event];
        [self.store log:VMQLogLevelInfo category:VMQLogCatNotification
                message:[NSString stringWithFormat:@"收款入队 type=%ld amount=%@ %@",
                         (long)event.channelType, event.normalizedAmount, ok ? @"" : @"(重复忽略)"]];
    });
}

#pragma mark - 定时器

- (void)scheduleTimers {
    self.heartbeatTimer = [self timerEvery:kHeartbeatInterval block:^{ [self tickHeartbeat]; }];
    self.queueTimer     = [self timerEvery:kQueueTick block:^{ [self tickQueue]; }];
    self.appCheckTimer  = [self timerEvery:kAppCheckInterval block:^{ [self tickAppAlive]; }];
}

- (dispatch_source_t)timerEvery:(NSTimeInterval)interval block:(void(^)(void))block {
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.workQ);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                              (uint64_t)(interval * NSEC_PER_SEC), (uint64_t)(1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(t, block);
    dispatch_resume(t);
    return t;
}

- (void)scheduleStabilizeClear {
    // §16.2：稳定运行 60 秒后清除待稳定标记与 bootguard 崩溃计数。
    // 关键：只有真正稳定跑满 60s 才清 bootguard，这样崩溃循环时计数会累积并触发熔断。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStabilizeAfter * NSEC_PER_SEC)),
                   self.workQ, ^{
        vmq_boot_trace("vmqmond:stable_60s -> clear pending & bootguard");
        // 清除 pending 标记 + bootguard 计数（VMQBoot 内部同时删两者）。
        vmq_bootguard_clear_on_stable();
        [self.store log:VMQLogLevelInfo category:VMQLogCatSecurity message:@"稳定60s：已清除待稳定标记与崩溃计数"];
    });
}

#pragma mark - 心跳

- (void)tickHeartbeat {
    if (self.disabled) return;
    if (!self.config.reportingEnabled) return;
    if (![self.config isNetworkReady]) return;
    VMQNetResult r = [self.reporter sendHeartbeat];
    [self.store log:VMQLogLevelInfo category:VMQLogCatNetwork
            message:[NSString stringWithFormat:@"心跳 result=%ld", (long)r]];
}

#pragma mark - 队列上报

- (void)tickQueue {
    if (self.disabled) return;
    if (!self.config.reportingEnabled) return;
    if (![self.config isNetworkReady]) return;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now < self.nextSendAllowedAt) return;  // 退避中

    NSArray<NSDictionary *> *batch = [self.store claimPendingBatch:kBatchLimit];
    if (batch.count == 0) return;

    BOOL anyRetry = NO;
    for (NSDictionary *item in batch) {
        int64_t rowid = [item[@"rowid"] longLongValue];
        NSString *type = [item[@"channelType"] stringValue];
        NSString *price = item[@"amount"];
        NSString *eventTime = [NSString stringWithFormat:@"%.0f", [item[@"eventTime"] doubleValue]];

        VMQNetResult r = [self.reporter sendPushType:type price:price eventTime:eventTime];
        if (r == VMQNetResultSuccess) {
            [self.store markDone:rowid];
        } else if (r == VMQNetResultPause) {
            [self.store markPaused:rowid reason:@"密钥/签名/配置错误"];
            [self.store log:VMQLogLevelError category:VMQLogCatNetwork message:@"上报暂停：需用户处理"];
        } else {
            [self.store markPending:rowid];
            anyRetry = YES;
        }
    }

    if (anyRetry) {
        // 指数退避，上限 5 分钟（§14）
        self.currentBackoff = self.currentBackoff == 0 ? 5 : MIN(self.currentBackoff * 2, kMaxBackoff);
        self.nextSendAllowedAt = now + self.currentBackoff;
        [self.store log:VMQLogLevelWarn category:VMQLogCatNetwork
                message:[NSString stringWithFormat:@"网络失败，退避 %lds", (long)self.currentBackoff]];
    } else {
        self.currentBackoff = 0;
        self.nextSendAllowedAt = 0;
    }
}

#pragma mark - 主 App 存活检查（§5.3）

- (void)tickAppAlive {
    // TrollStore 删除 App 不会执行卸载脚本；主 App 未注册时暂停并写禁用标记。
    // 真机实现：检查 App bundle 是否仍在 /var/containers 注册。骨架先用占位逻辑。
    BOOL appPresent = [self isMainAppRegistered];
    if (!appPresent) {
        self.disabled = YES;
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createFileAtPath:@(VMQ_DISABLE_FLAG) contents:[NSData data] attributes:nil];
        [self.store log:VMQLogLevelWarn category:VMQLogCatSecurity
                message:@"主App未注册，暂停心跳与上报并写禁用标记"];
    }
}

- (BOOL)isMainAppRegistered {
    // TODO(真机): 通过 LSApplicationWorkspace / installd 记录判断 VMQ_APP_BUNDLE_ID 是否安装。
    // 骨架阶段：只要禁用标记不存在即视为存活，避免误熔断。
    NSFileManager *fm = [NSFileManager defaultManager];
    return ![fm fileExistsAtPath:@(VMQ_DISABLE_FLAG)];
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // 黑匣子最先初始化：装信号/异常处理器，之后 vmqmond 任何崩溃都留 crash.log。
        vmq_boot_init("vmqmond");
        vmq_boot_trace("main:enter");

        // 确保数据目录存在。权限用 0755 而非 0700：
        // 监听组件在 SpringBoard 内以 mobile 运行，需要能遍历本目录并写入 diag/ 与 pending 标记。
        // 真正敏感的文件（config/queue/log/key）各自用 0600，仅 root 可读写（见 VMQConfig/VMQStore）。
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:@(VMQ_DATA_DIR)
      withIntermediateDirectories:YES
                       attributes:@{ NSFilePosixPermissions : @(0755) }
                            error:nil];

        // 启动时若存在固定禁用标记，进入受限模式（不接收、不上报）。
        BOOL hardDisabled = [fm fileExistsAtPath:@(VMQ_DISABLE_FLAG)];
        vmq_boot_trace(hardDisabled ? "main:hard_disabled (受限模式)" : "main:normal_start");

        VMQDaemon *daemon = [VMQDaemon new];
        if (hardDisabled) {
            [daemon.store open];
            [daemon.store log:VMQLogLevelWarn category:VMQLogCatSecurity
                      message:@"检测到固定禁用标记，vmqmond 进入受限模式"];
        } else {
            [daemon start];
        }

        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
