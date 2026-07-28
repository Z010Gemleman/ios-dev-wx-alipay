// VMQStore.h
// 可靠队列 + 持久日志（设计文档 §14/§15），基于系统 SQLite，无第三方依赖。
// 平台无关，纯 Foundation + libsqlite3。

#import <Foundation/Foundation.h>
#import "VMQEvent.h"

NS_ASSUME_NONNULL_BEGIN

/// 队列条目状态（设计文档 §14）。
typedef NS_ENUM(NSInteger, VMQItemState) {
    VMQItemStatePending = 0,  // 等待发送
    VMQItemStateSending = 1,  // 本次正在发送
    VMQItemStateDone    = 2,  // 服务端已确认
    VMQItemStatePaused  = 3,  // 配置或业务错误，需用户处理
};

/// 日志级别。
typedef NS_ENUM(NSInteger, VMQLogLevel) {
    VMQLogLevelInfo = 0,
    VMQLogLevelWarn = 1,
    VMQLogLevelError = 2,
};

/// 日志分类（设计文档 §15）。
typedef NS_ENUM(NSInteger, VMQLogCategory) {
    VMQLogCatEnvironment = 0,
    VMQLogCatLifecycle   = 1,
    VMQLogCatNotification = 2,
    VMQLogCatNetwork     = 3,
    VMQLogCatSecurity    = 4,
};

@interface VMQStore : NSObject

/// 打开（或创建）位于固定路径的 SQLite 队列库与日志库，建表并设权限 0600。
+ (instancetype)sharedStore;

- (BOOL)open;
- (void)close;

#pragma mark - 队列

/// 入队一个已接受的收款事件。eventId 唯一约束去重；重复直接忽略并返回 NO。
- (BOOL)enqueueEvent:(VMQEvent *)event;

/// 取出最多 limit 条 pending 条目并置为 sending。返回字典数组（含 rowid 与各字段）。
- (NSArray<NSDictionary *> *)claimPendingBatch:(NSInteger)limit;

/// 标记某条目完成。
- (void)markDone:(int64_t)rowid;
/// 标记某条目回到 pending（重试）。
- (void)markPending:(int64_t)rowid;
/// 标记某条目暂停（业务/配置错误）。
- (void)markPaused:(int64_t)rowid reason:(NSString *)reason;

/// 进程重启恢复：所有残留 sending 重置为 pending（设计文档 §14）。
- (void)recoverSending;

/// 待上传数量（pending + sending）。
- (NSInteger)pendingCount;

/// 清理 7 天前的 done 审计摘要（设计文档 §14）。
- (void)pruneDoneOlderThanDays:(NSInteger)days;

#pragma mark - 日志

/// 写一条日志。message 已由调用方脱敏（不含密钥/完整正文）。
- (void)log:(VMQLogLevel)level
   category:(VMQLogCategory)category
    message:(NSString *)message;

/// 读取日志（倒序），可按分类过滤（category<0 表示全部）。
- (NSArray<NSDictionary *> *)readLogsCategory:(NSInteger)category limit:(NSInteger)limit;

/// 容量清理：超过保留天数或字节上限时删除最旧记录（设计文档 §15）。
- (void)pruneLogsKeepDays:(NSInteger)days maxBytes:(NSInteger)maxBytes;

/// 清空全部日志。
- (void)clearLogs;

@end

NS_ASSUME_NONNULL_END
