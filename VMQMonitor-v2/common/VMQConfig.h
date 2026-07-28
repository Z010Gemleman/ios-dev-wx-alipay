// VMQConfig.h
// 运行配置（设计文档 §13/§17）。App 写入，vmqmond 读取。
// 存储于 VMQ_CONFIG_FILE（0600 plist）。平台无关，纯 Foundation。

#import <Foundation/Foundation.h>
#import "VMQProtocol.h"
#import "VMQSign.h"

NS_ASSUME_NONNULL_BEGIN

@interface VMQConfig : NSObject

/// VMQ 服务端基址，例如 https://pay.example.com （末尾无斜杠）。
@property (nonatomic, copy, nullable) NSString *serverBase;
/// 通信密钥（不进入日志/导出）。
@property (nonatomic, copy, nullable) NSString *key;
/// 签名模式，默认 HMAC-SHA256。
@property (nonatomic, assign) VMQSignType signType;

/// 渠道开关。
@property (nonatomic, assign) BOOL weChatEnabled;
@property (nonatomic, assign) BOOL alipayEnabled;

/// 正式上报开关。首次启用为“只监听不上报”，稳定后由用户开启。
@property (nonatomic, assign) BOOL reportingEnabled;

/// 从固定路径加载；文件缺失返回带默认值的实例。
+ (instancetype)load;
/// 原子写入固定路径，并将权限设为 0600。返回是否成功。
- (BOOL)save;

/// 配置是否足以进行联网（有 base 和 key）。
- (BOOL)isNetworkReady;

/// 指定 bundleId 对应渠道是否开启。
- (BOOL)isChannelEnabled:(VMQChannelType)type;

@end

NS_ASSUME_NONNULL_END
