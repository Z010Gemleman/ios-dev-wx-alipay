// VMQBoot.h
// 崩溃日记模块 —— 面包屑 + 信号捕获 + bootguard 崩溃循环防护。
// 固定路径 /var/mobile，SSH/Filza 可直接读取。
// 异步信号处理器内仅用 async-signal-safe POSIX 调用。

#ifndef VMQ_BOOT_H
#define VMQ_BOOT_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// 初始化：建立日记目录、安装信号/异常处理器、写 session 开始行。
// component: 短标识，如 "Tweak" / "vmqmond"
void vmq_boot_init(const char *component);

// 写一行面包屑（带时间戳与进程 ID）。
// 在 %ctor 每步、关键函数入口调用；不写每条通知事件（§16.1）。
void vmq_boot_trace(const char *step);

// bootguard：记录本次加载时间戳并检查是否触发崩溃循环。
// 返回 true 表示安全继续；返回 false 表示已写死禁用标记，调用方必须立即放弃加载。
bool vmq_bootguard_check(void);

// vmqmond 在监听稳定运行 VMQ_STABLE_SECONDS 后调用，清除 pending/bootguard。
void vmq_bootguard_clear_on_stable(void);

#ifdef __cplusplus
}
#endif

#endif // VMQ_BOOT_H
