// VMQReporter.h
// VMQ 联网上报（设计文档 §13）。心跳 + 到账上报，系统 TLS，自动重试。
// 平台无关，纯 Foundation（NSURLSession）。

#import <Foundation/Foundation.h>
#import "VMQConfig.h"

NS_ASSUME_NONNULL_BEGIN

/// 单次网络结果分类，供队列决定重试/暂停/成功。
typedef NS_ENUM(NSInteger, VMQNetResult) {
    VMQNetResultSuccess = 0,   // HTTP 2xx 且业务 code=1
    VMQNetResultRetry   = 1,   // DNS/连接/超时/5xx，可重试
    VMQNetResultPause   = 2,   // 密钥/签名/非法配置，需用户处理
};

/// 测试连接的详细结果（设计文档 §13.3）。
@interface VMQTestResult : NSObject
@property (nonatomic, assign) BOOL dnsTlsOK;
@property (nonatomic, assign) NSInteger httpStatus;
@property (nonatomic, assign) NSInteger businessCode;   // VMQ code 字段，-1 表示未取到
@property (nonatomic, copy, nullable) NSString *message;
@end

@interface VMQReporter : NSObject

- (instancetype)initWithConfig:(VMQConfig *)config;

/// 发送心跳（同步，供 daemon 定时器调用）。
- (VMQNetResult)sendHeartbeat;

/// 上报一条到账（同步）。type/price/eventTime 为字符串形式。
- (VMQNetResult)sendPushType:(NSString *)type
                       price:(NSString *)price
                   eventTime:(NSString *)eventTime;

/// 测试连接（供 App 调用）。
- (VMQTestResult *)testConnection;

@end

NS_ASSUME_NONNULL_END
