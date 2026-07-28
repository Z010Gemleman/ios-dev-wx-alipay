// VMQDatagramClient.h
// 监听组件专用的最小非阻塞 datagram 发送器（设计文档 §6/§16.1）。
// 纯 C，无 Objective-C 依赖，禁止在 Hook 回调里阻塞、联网、落盘或等待锁。

#ifndef VMQ_DATAGRAM_CLIENT_H
#define VMQ_DATAGRAM_CLIENT_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// 组装并以非阻塞方式发送一条原始事件到 vmqmond。
// 所有字符串为 UTF-8，可为 NULL。发送失败（服务端未运行/队列满）直接返回，不重试。
// 返回 0 表示已提交发送，非 0 表示被丢弃。
int vmq_send_event(uint16_t channelCode,
                   uint32_t eventTime,
                   const char *title,
                   const char *subtitle,
                   const char *body,
                   const char *eventId);

#ifdef __cplusplus
}
#endif

#endif // VMQ_DATAGRAM_CLIENT_H
