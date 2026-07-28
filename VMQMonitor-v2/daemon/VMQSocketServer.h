// VMQSocketServer.h
// 本机 Unix datagram 服务端（设计文档 §6）。接收监听组件发来的原始事件，
// 解码为 VMQEvent 后交给回调。仅本机访问，无 TCP 端口。
// 平台无关，纯 Foundation + POSIX socket。

#import <Foundation/Foundation.h>
#import "VMQEvent.h"

NS_ASSUME_NONNULL_BEGIN

/// 收到一个解码后的原始事件时回调（在内部 GCD 队列上执行）。
typedef void (^VMQSocketEventHandler)(VMQEvent *event);

@interface VMQSocketServer : NSObject

- (instancetype)initWithHandler:(VMQSocketEventHandler)handler;

/// 绑定固定路径 socket 并开始接收。返回是否成功。
- (BOOL)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
