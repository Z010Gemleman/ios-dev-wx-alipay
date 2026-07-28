// VMQSocketServer.m
// Unix datagram 服务端实现。绑定 VMQ_SOCKET_PATH，非阻塞接收，解码线格式。

#import "VMQSocketServer.h"
#import "VMQProtocol.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

@implementation VMQSocketServer {
    int _fd;
    dispatch_source_t _source;
    dispatch_queue_t _queue;
    VMQSocketEventHandler _handler;
}

- (instancetype)initWithHandler:(VMQSocketEventHandler)handler {
    if ((self = [super init])) {
        _fd = -1;
        _handler = [handler copy];
        _queue = dispatch_queue_create("com.z010genleman.vmqmonitor.v2.socket", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)start {
    // 清理残留 socket 文件
    unlink(VMQ_SOCKET_PATH);

    _fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (_fd < 0) return NO;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, VMQ_SOCKET_PATH, sizeof(addr.sun_path) - 1);

    if (bind(_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(_fd);
        _fd = -1;
        return NO;
    }

    // 仅本机所有者可读写
    chmod(VMQ_SOCKET_PATH, 0600);

    // 非阻塞
    int flags = fcntl(_fd, F_GETFL, 0);
    fcntl(_fd, F_SETFL, flags | O_NONBLOCK);

    __weak typeof(self) weakSelf = self;
    _source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _fd, 0, _queue);
    dispatch_source_set_event_handler(_source, ^{
        [weakSelf drain];
    });
    dispatch_resume(_source);
    return YES;
}

- (void)drain {
    uint8_t buf[VMQ_WIRE_MAX_BYTES];
    for (;;) {
        ssize_t n = recv(_fd, buf, sizeof(buf), 0);
        if (n <= 0) {
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
            if (n < 0) break;
            break;
        }
        VMQEvent *event = [self decode:buf length:(size_t)n];
        if (event && _handler) _handler(event);
    }
}

// 解码线格式：[VMQWireHeader][title][subtitle][body][eventId]
- (VMQEvent *)decode:(const uint8_t *)buf length:(size_t)len {
    if (len < sizeof(VMQWireHeader)) return nil;
    VMQWireHeader hdr;
    memcpy(&hdr, buf, sizeof(hdr));
    if (hdr.version != VMQ_WIRE_VERSION) return nil;

    size_t need = sizeof(VMQWireHeader) + hdr.titleLen + hdr.subtitleLen + hdr.bodyLen + hdr.eventIdLen;
    if (need != len) return nil;  // 长度必须精确匹配，防止越界

    const uint8_t *base = buf + sizeof(VMQWireHeader);
    __block size_t cursor = 0;
    NSString *(^readStr)(uint16_t) = ^NSString *(uint16_t l) {
        if (l == 0) return nil;
        NSString *s = [[NSString alloc] initWithBytes:(base + cursor) length:l encoding:NSUTF8StringEncoding];
        cursor += l;
        return s;
    };

    VMQEvent *e = [VMQEvent new];
    e.title = readStr(hdr.titleLen);
    e.subtitle = readStr(hdr.subtitleLen);
    e.body = readStr(hdr.bodyLen);
    NSString *eid = readStr(hdr.eventIdLen);

    switch ((VMQChannelType)hdr.bundleIdCode) {
        case VMQChannelWeChat: e.bundleId = @VMQ_BUNDLE_WECHAT; break;
        case VMQChannelAlipay: e.bundleId = @VMQ_BUNDLE_ALIPAY; break;
        default: e.bundleId = @""; break;
    }
    e.channelType = (VMQChannelType)hdr.bundleIdCode;
    e.eventTime = (NSTimeInterval)hdr.eventTime;
    e.eventId = eid ?: [e computedFallbackEventId];
    return e;
}

- (void)stop {
    if (_source) {
        dispatch_source_cancel(_source);
        _source = nil;
    }
    if (_fd >= 0) {
        close(_fd);
        _fd = -1;
    }
    unlink(VMQ_SOCKET_PATH);
}

@end
