// Tweak.x — VMQ Monitor V2 通知监听组件（安全极简版）
//
// Hook 点：BBServer::publishBulletin:destinations:（iOS 15/16 SpringBoard 真实存在，
//          已由设备上 ioswa-main 项目验证；旧版误用 SBBBObserver 导致监听未加载）。
//
// 原则：SpringBoard %ctor 必须在毫秒级完成。
// 禁止在 %ctor 里：枚举所有类、安装信号处理器、替换 ObjC 异常处理器、重IO。
// 唯一允许的：stat 检查标志文件、objc_getClass 单次查询、写一行 trace 文件。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <string.h>
#include <os/log.h>

#import "../common/VMQProtocol.h"
#import "VMQDatagramClient.h"

// 前置声明：CFPreferences 信标（定义在 %ctor 之前、hook 之后引用，需前置声明）
static void vmq_beacon(const char *key);

// ---- trace：三通道，确保至少一条可见 ----
// 设备无 /usr/bin/log（os_log 读不到），且 SpringBoard 沙盒疑似阻止写
// /var/mobile/Library/Application Support/...。而 Preferences 目录 SpringBoard
// 自己一直在写（大量 .plist），是沙盒白名单内、SSH 可读的可靠通道。
// 权威通道 = Preferences 文件：/var/mobile/Library/Preferences/vmqtrace.log
#define VMQ_PREF_TRACE "/var/mobile/Library/Preferences/vmqtrace.log"
static void trace(const char *step) {
    char buf[256];
    int n = snprintf(buf, sizeof(buf), "%ld Tweak %d %s\n",
                     (long)time(NULL), (int)getpid(), step);
    size_t len = (n > 0 ? (size_t)n : 0);

    // 通道1（权威）：Preferences 目录，SpringBoard 沙盒允许，SSH 可读
    int pf = open(VMQ_PREF_TRACE, O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (pf >= 0) { (void)write(pf, buf, len); close(pf); }

    // 通道2：统一日志（若设备有 log 工具可读）
    os_log(OS_LOG_DEFAULT, "[VMQ] %{public}s pid=%d", step, (int)getpid());

    // 通道3（兼容）：原数据目录（沙盒允许则可读，否则静默失败）
    mkdir(VMQ_DATA_DIR, 0755);
    mkdir(VMQ_DIAG_DIR, 0777);
    chmod(VMQ_DIAG_DIR, 0777);
    int fd = open(VMQ_BOOT_TRACE, O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd < 0) return;
    (void)write(fd, buf, len);
    close(fd);
}

static BOOL flag_exists(const char *path) { struct stat st; return stat(path, &st) == 0; }
static void flag_touch(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) close(fd);
}

// ---- 渠道映射 ----
static uint16_t channel_code(NSString *bid) {
    if ([bid isEqualToString:@VMQ_BUNDLE_WECHAT]) return VMQChannelWeChat;
    if ([bid isEqualToString:@VMQ_BUNDLE_ALIPAY]) return VMQChannelAlipay;
    return VMQChannelUnknown;
}

// ---- 全局状态 ----
static BOOL g_armed = NO;
static volatile sig_atomic_t g_first_cb = 0;

// ---- 通知字段提取（§6/§16.1：非阻塞，异常安全）----
static void observe_bulletin(id bulletin) {
    @try {
        if (![bulletin respondsToSelector:@selector(sectionID)]) return;
        NSString *bid = [bulletin performSelector:@selector(sectionID)];
        if (![bid isKindOfClass:[NSString class]]) return;
        uint16_t code = channel_code(bid);
        if (!code) return;

        NSString *title = nil, *subtitle = nil, *body = nil, *bId = nil;
        if ([bulletin respondsToSelector:@selector(title)])
            title = [bulletin performSelector:@selector(title)];
        if ([bulletin respondsToSelector:@selector(subtitle)])
            subtitle = [bulletin performSelector:@selector(subtitle)];
        if ([bulletin respondsToSelector:@selector(message)])
            body = [bulletin performSelector:@selector(message)];
        if ([bulletin respondsToSelector:@selector(bulletinID)])
            bId = [bulletin performSelector:@selector(bulletinID)];

        title    = [title    isKindOfClass:[NSString class]] ? title    : nil;
        subtitle = [subtitle isKindOfClass:[NSString class]] ? subtitle : nil;
        body     = [body     isKindOfClass:[NSString class]] ? body     : nil;
        bId      = [bId      isKindOfClass:[NSString class]] ? bId      : nil;

        vmq_send_event(code, (uint32_t)time(NULL),
                       title.UTF8String, subtitle.UTF8String,
                       body.UTF8String, bId.UTF8String);
    } @catch (__unused NSException *e) {}
}

// ---- Hook（只有 %ctor 校验通过后 %init 才调用）----
// 正确 hook 点：BBServer::publishBulletin:destinations:
// （设备上 ioswa-main 项目已验证，iOS 15/16 SpringBoard 真实存在此类此方法）
// BBServer 先由 %orig 发布通知（绝不拦截/延迟），随后我们被动观察 bulletin。
%group VMQHooks
%hook BBServer
- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations {
    %orig;
    if (!g_armed) return;
    if (!g_first_cb) { g_first_cb = 1; vmq_beacon("hook_first_cb"); trace("hook:first_callback"); }
    observe_bulletin(bulletin);
}
%end
%end

// CFPreferences 信标：经 cfprefsd 持久化（SpringBoard 自己就这样写 Preferences），
// 沙盒放行，比 raw open() 可靠。SSH 侧读：
//   plutil -p /var/mobile/Library/Preferences/com.z010genleman.vmqmonitor.v2.beacon.plist
// 或 defaults read com.z010genleman.vmqmonitor.v2.beacon
static void vmq_beacon(const char *key) {
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    if (!k) return;
    CFStringRef appID = CFSTR("com.z010genleman.vmqmonitor.v2.beacon");
    CFDateRef now = CFDateCreate(NULL, CFAbsoluteTimeGetCurrent());
    CFPreferencesSetValue(k, now ? (CFPropertyListRef)now : (CFPropertyListRef)kCFBooleanTrue,
                          appID, kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(appID, kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    if (now) CFRelease(now);
    CFRelease(k);
}

// ---- %ctor：必须在毫秒级完成 ----
%ctor {
    @autoreleasepool {
        vmq_beacon("ctor_enter");   // 沙盒放行的加载信标（第一优先）
        trace("ctor:enter");

        // 1. 固定禁用标记
        if (flag_exists(VMQ_DISABLE_FLAG)) {
            trace("ctor:DISABLED -> abort");
            return;
        }

        // 2. bootguard（读写文件，快速）
        {
            time_t now = time(NULL);
            NSString *bgPath = @(VMQ_BOOTGUARD);
            NSString *content = [NSString stringWithContentsOfFile:bgPath
                                                          encoding:NSUTF8StringEncoding error:nil] ?: @"";
            NSMutableArray *stamps = [NSMutableArray array];
            for (NSString *ln in [content componentsSeparatedByString:@"\n"]) {
                if (!ln.length) continue;
                long long v = ln.longLongValue;
                if (v > 0 && (now - (time_t)v) <= VMQ_BOOTGUARD_WINDOW_SEC)
                    [stamps addObject:@(v)];
            }
            [stamps addObject:@((long long)now)];
            NSMutableString *out = [NSMutableString string];
            for (NSNumber *n in stamps) [out appendFormat:@"%lld\n", n.longLongValue];
            [out writeToFile:bgPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            chmod(VMQ_BOOTGUARD, 0666);
            if (stamps.count >= VMQ_BOOTGUARD_MAX_LOADS) {
                trace("ctor:BOOTGUARD_TRIPPED -> disabled");
                int fd = open(VMQ_DISABLE_FLAG, O_WRONLY|O_CREAT|O_APPEND, 0644);
                if (fd>=0){const char *m="bootguard\n";write(fd,m,strlen(m));close(fd);}
                return;
            }
            trace("ctor:bootguard_ok");
        }

        // 3. 查目标类（仅单次 objc_getClass，极快）
        trace("ctor:lookup BBServer");
        Class cls = objc_getClass("BBServer");
        if (!cls) {
            trace("ctor:CLASS_MISSING BBServer -> hook not registered");
            return;  // hook 不注册，SpringBoard 完全不受影响
        }

        // 4. 签名校验（去掉偏移数字后比较）
        // publishBulletin:destinations: 期望 encoding = v@:@Q
        //   v(void) @(self) :(_cmd) @(bulletin) Q(unsigned long long destinations)
        trace("ctor:verify_selector publishBulletin:destinations:");
        SEL sel = @selector(publishBulletin:destinations:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { trace("ctor:SELECTOR_MISSING -> abort"); return; }
        const char *enc = method_getTypeEncoding(m);
        // 写实际 encoding 供调试
        char encMsg[128] = "actual_encoding:";
        if (enc) strncat(encMsg, enc, sizeof(encMsg)-strlen(encMsg)-2);
        trace(encMsg);

        // 去数字后与期望比较
        NSMutableString *stripped = [NSMutableString string];
        for (const char *p = enc ?: ""; *p; p++)
            if (!isdigit((unsigned char)*p)) [stripped appendFormat:@"%c", *p];
        if (![stripped hasPrefix:@"v@:@Q"]) {
            trace("ctor:SIGNATURE_MISMATCH -> hook not registered");
            return;
        }

        // 5. 一切通过，注册 hook
        trace("ctor:all_ok -> %init");
        %init(VMQHooks);
        flag_touch(VMQ_PENDING_FLAG);
        g_armed = YES;
        trace("ctor:ARMED");
    }
}
