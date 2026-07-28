// VMQSign.m
// 签名实现。CommonCrypto 提供 HMAC-SHA256 与 MD5。

#import "VMQSign.h"
#import <CommonCrypto/CommonCrypto.h>

@implementation VMQSign

+ (NSString *)newNonce {
    // 16 字节高熵随机 -> hex
    uint8_t buf[16];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(buf), buf) != 0) {
        // 退化兜底：时间 + arc4random
        uint64_t a = (uint64_t)[[NSDate date] timeIntervalSince1970];
        for (int i = 0; i < 16; i++) buf[i] = (uint8_t)((a >> (i % 8)) ^ arc4random());
    }
    NSMutableString *s = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) [s appendFormat:@"%02x", buf[i]];
    return s;
}

+ (NSString *)hmacSha256Hex:(NSString *)message key:(NSString *)key {
    NSData *keyData = [key dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSData *msgData = [message dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    uint8_t mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, keyData.bytes, keyData.length, msgData.bytes, msgData.length, mac);
    NSMutableString *s = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", mac[i]];
    return s;
}

+ (NSString *)md5Hex:(NSString *)message {
    NSData *msgData = [message dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    uint8_t digest[CC_MD5_DIGEST_LENGTH];
    // CC_MD5 在新 SDK 标记 deprecated，但 VMQ 旧模式协议要求，属于兼容用途。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5(msgData.bytes, (CC_LONG)msgData.length, digest);
#pragma clang diagnostic pop
    NSMutableString *s = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", digest[i]];
    return s;
}

+ (NSString *)heartbeatSignWithKey:(NSString *)key
                             nonce:(NSString *)nonce
                                 t:(NSString *)t
                          signType:(VMQSignType)signType {
    if (signType == VMQSignTypeMD5) {
        // 旧模式心跳无标准约定，沿用 md5(t + key) 兜底（服务端多以 t 为准）。
        return [self md5Hex:[NSString stringWithFormat:@"%@%@", t, key]];
    }
    NSString *canonical = [NSString stringWithFormat:@"nonce=%@&signType=HMAC_SHA256&t=%@", nonce, t];
    return [self hmacSha256Hex:canonical key:key];
}

+ (NSString *)pushSignWithKey:(NSString *)key
                         type:(NSString *)type
                        price:(NSString *)price
                            t:(NSString *)t
                    eventTime:(NSString *)eventTime
                        nonce:(NSString *)nonce
                     signType:(VMQSignType)signType {
    if (signType == VMQSignTypeMD5) {
        // md5(type + price + t + eventTime + key)
        NSString *raw = [NSString stringWithFormat:@"%@%@%@%@%@", type, price, t, eventTime, key];
        return [self md5Hex:raw];
    }
    // 字段名升序: eventTime, nonce, price, signType, t, type
    NSString *canonical = [NSString stringWithFormat:
        @"eventTime=%@&nonce=%@&price=%@&signType=HMAC_SHA256&t=%@&type=%@",
        eventTime, nonce, price, t, type];
    return [self hmacSha256Hex:canonical key:key];
}

@end
