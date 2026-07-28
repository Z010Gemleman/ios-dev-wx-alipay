// VMQProtocol.h
// 监听组件 <-> vmqmond 之间的本机 IPC 协议，以及全局固定路径常量。
// 该头文件被 App、vmqmond、监听组件、Root Helper 共同引用，
// 只允许放置与平台无关的常量与纯 C 声明，禁止引入 UIKit。

#ifndef VMQ_PROTOCOL_H
#define VMQ_PROTOCOL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- 身份标识 ----
#define VMQ_APP_BUNDLE_ID        "com.z010genleman.vmqmonitor.v2"
#define VMQ_RUNTIME_PACKAGE_ID   "com.z010genleman.vmqmonitor.v2.runtime"

// ---- 渠道类型（对应 VMQ 服务端 type）----
typedef enum {
    VMQChannelUnknown = 0,
    VMQChannelWeChat  = 1,   // 微信  com.tencent.xin
    VMQChannelAlipay  = 2,   // 支付宝 com.alipay.iphoneclient
} VMQChannelType;

#define VMQ_BUNDLE_WECHAT  "com.tencent.xin"
#define VMQ_BUNDLE_ALIPAY  "com.alipay.iphoneclient"

// ---- 固定数据目录（不依赖 RootHide 随机 jbroot 前缀，便于 SSH/Filza 恢复）----
// 设计文档 §16.2 / §17：固定禁用标记与运行数据放在稳定的 /var/mobile 路径下。
#define VMQ_DATA_DIR        "/var/mobile/Library/Application Support/VMQMonitorV2"
#define VMQ_DISABLE_FLAG    VMQ_DATA_DIR "/listener.disabled"
#define VMQ_PENDING_FLAG    VMQ_DATA_DIR "/listener.pending"
#define VMQ_CONFIG_FILE     VMQ_DATA_DIR "/config.plist"     // 0600
#define VMQ_QUEUE_DB        VMQ_DATA_DIR "/queue.sqlite"     // 0600
#define VMQ_LOG_DB          VMQ_DATA_DIR "/log.sqlite"       // 0600

// ---- 崩溃日记（黑匣子）目录 ----
// 关键：监听组件注入在 SpringBoard 内，以 mobile(uid 501) 运行；vmqmond 以 root 运行。
// 两者都要能写日记，因此日记目录单独放，权限 0777；崩溃/面包屑文件 0666。
// 敏感文件（config/queue/key）仍在 VMQ_DATA_DIR 且保持 0600，只有 root 可读写。
// VMQ_DATA_DIR 自身设为 0755（可遍历），使 mobile 能进入其子目录 diag/。
#define VMQ_DIAG_DIR        VMQ_DATA_DIR "/diag"
// 启动面包屑：%ctor 每一步写入，SpringBoard 崩溃后最后一行即死亡位置。
#define VMQ_BOOT_TRACE      VMQ_DIAG_DIR "/boot.trace"
// 崩溃转储：信号/未捕获异常的原因与调用栈。
#define VMQ_CRASH_LOG       VMQ_DIAG_DIR "/crash.log"
// 崩溃循环计数（bootguard）：记录最近若干次监听加载时间戳。
#define VMQ_BOOTGUARD       VMQ_DIAG_DIR "/bootguard"
// 只读类枚举结果：ctor 中把 SpringBoard 内通知相关类与方法签名 dump 到此，供适配 hook 点。
#define VMQ_CLASSES_DUMP    VMQ_DIAG_DIR "/classes.txt"

// bootguard 阈值（设计文档 §16.2）：窗口 5 分钟内累计 N 次加载即判定崩溃循环，写死禁用标记。
#define VMQ_BOOTGUARD_WINDOW_SEC   300
#define VMQ_BOOTGUARD_MAX_LOADS    3
// 监听加载后需稳定运行的秒数，由 vmqmond 计时清除 pending 与 bootguard（§16.2）。
#define VMQ_STABLE_SECONDS         60

// ---- 本机 Unix datagram socket（仅本机访问，无 TCP 端口）----
// 放在数据目录下，权限受限；监听组件为客户端，vmqmond 为服务端。
#define VMQ_SOCKET_PATH     VMQ_DATA_DIR "/vmqmond.sock"

// ---- IPC 线格式版本 ----
#define VMQ_WIRE_VERSION    1

// 监听组件通过 datagram 发送的原始事件（定长头 + 变长 UTF-8 字段）。
// 所有业务判断都在 vmqmond 完成；监听组件只做最小复制后立即返回。
// 布局：[VMQWireHeader][title][subtitle][body][eventId(可选)]
typedef struct {
    uint16_t version;        // = VMQ_WIRE_VERSION
    uint16_t bundleIdCode;   // VMQChannelType，快速丢弃用途
    uint32_t eventTime;      // Unix 秒
    uint16_t titleLen;       // 字节数（UTF-8，不含结尾）
    uint16_t subtitleLen;
    uint16_t bodyLen;
    uint16_t eventIdLen;     // 系统 bulletin id，可能为 0
} VMQWireHeader;

// datagram 最大体积上限，超过直接丢弃，防止监听端阻塞或放大。
#define VMQ_WIRE_MAX_BYTES  8192

#ifdef __cplusplus
}
#endif

#endif // VMQ_PROTOCOL_H
