// VMQSign.h
// VMQ 上报签名工具（设计文档 §13.2）。
// 默认 HMAC-SHA256，兼容旧 VMQ 的 MD5 模式。平台无关，纯 Foundation + CommonCrypto。

#import <Foundation/Foundation.h>
#import "VMQProtocol.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VMQSignType) {
    VMQSignTypeHMACSHA256 = 0,  // 默认
    VMQSignTypeMD5        = 1,  // 兼容旧 VMQ
};

@interface VMQSign : NSObject

/// 生成高熵 nonce（hex）。
+ (NSString *)newNonce;

/// 心跳签名。
/// HMAC 模式 canonical: nonce={nonce}&signType=HMAC_SHA256&t={t}
+ (NSString *)heartbeatSignWithKey:(NSString *)key
                             nonce:(NSString *)nonce
                                 t:(NSString *)t
                          signType:(VMQSignType)signType;

/// 到账上报签名。
/// HMAC 模式 canonical（字段名升序）:
///   eventTime={eventTime}&nonce={nonce}&price={price}&signType=HMAC_SHA256&t={t}&type={type}
/// MD5 模式: md5(type + price + t + eventTime + key)
+ (NSString *)pushSignWithKey:(NSString *)key
                         type:(NSString *)type
                        price:(NSString *)price
                            t:(NSString *)t
                    eventTime:(NSString *)eventTime
                        nonce:(NSString *)nonce
                     signType:(VMQSignType)signType;

// 暴露底层原语以便单元测试。
+ (NSString *)hmacSha256Hex:(NSString *)message key:(NSString *)key;
+ (NSString *)md5Hex:(NSString *)message;

@end

NS_ASSUME_NONNULL_END
