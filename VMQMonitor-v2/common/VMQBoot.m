// VMQBoot.m
// 崩溃日记实现。分两类代码：
//   1) 普通路径（init / trace / bootguard）：可用 Foundation。
//   2) 信号处理器：只允许 async-signal-safe 调用（write/open/close/_exit/time），
//      绝不 malloc、不 NSLog、不用 stdio 缓冲。
//
// 设计原则（设计文档 §16）：捕获崩溃并留证据后，交回系统默认处理，绝不吞崩溃。

#import <Foundation/Foundation.h>
#import "VMQBoot.h"
#import "VMQProtocol.h"

#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>
#include <execinfo.h>
#include <stdlib.h>

// 组件名（init 时复制，信号处理器只读）。
static char g_component[32] = "unknown";
// 崩溃日志 fd 预开，避免信号处理器里 open 失败时无处可写（open 本身 async-signal-safe，
// 但预开可减少处理器内工作量）。-1 表示未开。
static int g_crash_fd = -1;
static volatile sig_atomic_t g_in_handler = 0;

#pragma mark - async-signal-safe 原语

// 无符号整数转十进制字符串，返回长度。async-signal-safe。
static int vmq_utoa(unsigned long v, char *buf) {
    char tmp[24];
    int n = 0;
    if (v == 0) { tmp[n++] = '0'; }
    while (v > 0) { tmp[n++] = (char)('0' + (v % 10)); v /= 10; }
    for (int i = 0; i < n; i++) buf[i] = tmp[n - 1 - i];
    return n;
}

// 向 fd 写一个 C 字符串。async-signal-safe。
static void vmq_swrite(int fd, const char *s) {
    if (fd < 0 || !s) return;
    size_t len = strlen(s);
    ssize_t off = 0;
    while ((size_t)off < len) {
        ssize_t w = write(fd, s + off, len - off);
        if (w <= 0) break;
        off += w;
    }
}

#pragma mark - 信号处理器（async-signal-safe only）

static void vmq_signal_handler(int sig) {
    // 防重入
    if (g_in_handler) { _exit(128 + sig); }
    g_in_handler = 1;

    int fd = g_crash_fd;
    if (fd < 0) {
        // 兜底：现开。O_APPEND 保证多次写不覆盖。
        fd = open(VMQ_CRASH_LOG, O_WRONLY | O_CREAT | O_APPEND, 0666);
    }
    if (fd >= 0) {
        char nbuf[24]; int nl;
        vmq_swrite(fd, "\n=== CRASH sig=");
        nl = vmq_utoa((unsigned long)sig, nbuf); (void)write(fd, nbuf, nl);
        vmq_swrite(fd, " comp=");
        vmq_swrite(fd, g_component);
        vmq_swrite(fd, " pid=");
        nl = vmq_utoa((unsigned long)getpid(), nbuf); (void)write(fd, nbuf, nl);
        vmq_swrite(fd, " t=");
        nl = vmq_utoa((unsigned long)time(NULL), nbuf); (void)write(fd, nbuf, nl);
        vmq_swrite(fd, "\n");

        // 调用栈：backtrace + backtrace_symbols_fd 不 malloc，可用于信号处理器。
        void *frames[64];
        int fn = backtrace(frames, 64);
        backtrace_symbols_fd(frames, fn, fd);
        vmq_swrite(fd, "=== END CRASH ===\n");
        fsync(fd);
    }

    // 恢复默认处理并重新触发，把崩溃交回系统（绝不吞）。
    signal(sig, SIG_DFL);
    raise(sig);
}

static void vmq_install_signal_handlers(void) {
    // 预开崩溃日志 fd
    g_crash_fd = open(VMQ_CRASH_LOG, O_WRONLY | O_CREAT | O_APPEND, 0666);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = vmq_signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NODEFER;   // 处理器内可再次收到同号信号后 _exit
    int sigs[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP };
    for (size_t i = 0; i < sizeof(sigs)/sizeof(sigs[0]); i++) {
        sigaction(sigs[i], &sa, NULL);
    }
}

#pragma mark - ObjC 未捕获异常处理器

static void vmq_uncaught_exception(NSException *e) {
    // 此处不在信号上下文，可用 Foundation。
    @try {
        NSMutableString *s = [NSMutableString string];
        [s appendFormat:@"\n=== NSException comp=%s pid=%d t=%ld ===\n",
            g_component, getpid(), (long)time(NULL)];
        [s appendFormat:@"name=%@\nreason=%@\n", e.name, e.reason];
        for (NSString *frame in e.callStackSymbols) {
            [s appendFormat:@"%@\n", frame];
        }
        [s appendString:@"=== END NSException ===\n"];
        int fd = open(VMQ_CRASH_LOG, O_WRONLY | O_CREAT | O_APPEND, 0666);
        if (fd >= 0) {
            const char *u = s.UTF8String;
            if (u) vmq_swrite(fd, u);
            fsync(fd);
            close(fd);
        }
    } @catch (__unused NSException *inner) {
    }
    // 不吞：交回默认（进程随后会被 abort）。
}

#pragma mark - 公共 API

static void vmq_ensure_dirs(void) {
    // VMQ_DATA_DIR 设 0755（可遍历），diag 设 0777（mobile 与 root 都能写）。
    mkdir(VMQ_DATA_DIR, 0755);
    chmod(VMQ_DATA_DIR, 0755);
    mkdir(VMQ_DIAG_DIR, 0777);
    chmod(VMQ_DIAG_DIR, 0777);
}

void vmq_boot_init(const char *component) {
    if (component) {
        strncpy(g_component, component, sizeof(g_component) - 1);
        g_component[sizeof(g_component) - 1] = '\0';
    }
    vmq_ensure_dirs();
    vmq_install_signal_handlers();
    NSSetUncaughtExceptionHandler(&vmq_uncaught_exception);
    vmq_boot_trace("boot_init");
}

void vmq_boot_trace(const char *step) {
    if (!step) return;
    int fd = open(VMQ_BOOT_TRACE, O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd < 0) return;
    char line[256];
    int off = 0;
    // 格式: <t> <comp> <pid> <step>\n
    off += vmq_utoa((unsigned long)time(NULL), line + off);
    line[off++] = ' ';
    { size_t n = strlen(g_component); if (off + (int)n < 240) { memcpy(line+off, g_component, n); off += n; } }
    line[off++] = ' ';
    off += vmq_utoa((unsigned long)getpid(), line + off);
    line[off++] = ' ';
    { size_t n = strlen(step); if (off + (int)n < 250) { memcpy(line+off, step, n); off += n; } }
    line[off++] = '\n';
    (void)write(fd, line, off);
    fsync(fd);
    close(fd);
}

bool vmq_bootguard_check(void) {
    // 读取最近加载时间戳列表（每行一个 epoch 秒），追加本次，
    // 保留窗口内的，若数量 >= 阈值则写死禁用标记并返回 false。
    time_t now = time(NULL);

    NSMutableArray<NSNumber *> *stamps = [NSMutableArray array];
    NSString *path = @(VMQ_BOOTGUARD);
    NSString *existing = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    if (existing.length) {
        for (NSString *ln in [existing componentsSeparatedByString:@"\n"]) {
            if (ln.length == 0) continue;
            long long v = [ln longLongValue];
            if (v > 0 && (now - (time_t)v) <= VMQ_BOOTGUARD_WINDOW_SEC) {
                [stamps addObject:@(v)];
            }
        }
    }
    [stamps addObject:@((long long)now)];

    // 写回窗口内的时间戳
    NSMutableString *out = [NSMutableString string];
    for (NSNumber *n in stamps) [out appendFormat:@"%lld\n", n.longLongValue];
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod(VMQ_BOOTGUARD, 0666);

    if (stamps.count >= (NSUInteger)VMQ_BOOTGUARD_MAX_LOADS) {
        // 崩溃循环：写死禁用标记（§16.2），下次 %ctor 直接退出。
        int fd = open(VMQ_DISABLE_FLAG, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            vmq_swrite(fd, "bootguard tripped\n");
            close(fd);
        }
        vmq_boot_trace("bootguard_TRIPPED_disabled");
        return false;
    }
    vmq_boot_trace("bootguard_ok");
    return true;
}

void vmq_bootguard_clear_on_stable(void) {
    // 稳定运行达标：清除 pending 与 bootguard 计数（保留 disable 标记，需用户显式解除）。
    unlink(VMQ_PENDING_FLAG);
    unlink(VMQ_BOOTGUARD);
    vmq_boot_trace("stable_cleared_bootguard");
}
