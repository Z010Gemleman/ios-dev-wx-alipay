// VMQDatagramClient.c
// 最小非阻塞 datagram 发送实现。设计原则（§16.1）：
//   - 先执行系统原实现（由调用方保证），此处只做被动上报；
//   - 非阻塞 sendto，失败立即返回，绝不等待；
//   - 无全局锁、无堆积、无落盘。

#include "VMQDatagramClient.h"
#include "../common/VMQProtocol.h"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <stdlib.h>

// 缓存的客户端 socket fd（-1 表示未创建）。监听进程内复用。
static int g_fd = -1;

static int vmq_client_fd(void) {
    if (g_fd >= 0) return g_fd;
    int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    // 设为非阻塞，保证 sendto 永不阻塞 SpringBoard。
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    g_fd = fd;
    return fd;
}

static size_t clamp_copy(char *dst, size_t cap, const char *src, uint16_t *outLen) {
    if (!src) { *outLen = 0; return 0; }
    size_t n = strnlen(src, cap);
    memcpy(dst, src, n);
    *outLen = (uint16_t)n;
    return n;
}

int vmq_send_event(uint16_t channelCode,
                   uint32_t eventTime,
                   const char *title,
                   const char *subtitle,
                   const char *body,
                   const char *eventId) {
    int fd = vmq_client_fd();
    if (fd < 0) return -1;

    // 组装缓冲区：[header][title][subtitle][body][eventId]
    static char buf[VMQ_WIRE_MAX_BYTES];
    VMQWireHeader hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.version = VMQ_WIRE_VERSION;
    hdr.bundleIdCode = channelCode;
    hdr.eventTime = eventTime;

    size_t off = sizeof(VMQWireHeader);
    size_t remain = sizeof(buf) - off;

    // 逐字段拷贝，受剩余容量限制；超限则截断（宁可短，不放大）。
    uint16_t tl = 0, sl = 0, bl = 0, el = 0;
    size_t n;
    n = clamp_copy(buf + off, remain, title, &tl);     off += n; remain -= n;
    n = clamp_copy(buf + off, remain, subtitle, &sl);  off += n; remain -= n;
    n = clamp_copy(buf + off, remain, body, &bl);      off += n; remain -= n;
    n = clamp_copy(buf + off, remain, eventId, &el);   off += n; remain -= n;

    hdr.titleLen = tl;
    hdr.subtitleLen = sl;
    hdr.bodyLen = bl;
    hdr.eventIdLen = el;
    memcpy(buf, &hdr, sizeof(hdr));

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, VMQ_SOCKET_PATH, sizeof(addr.sun_path) - 1);

    ssize_t sent = sendto(fd, buf, off, 0,
                          (struct sockaddr *)&addr, sizeof(addr));
    if (sent < 0) {
        // 服务端未运行 / 队列满 / 无权限：直接放弃本次事件，不重试、不阻塞。
        return -2;
    }
    return 0;
}
