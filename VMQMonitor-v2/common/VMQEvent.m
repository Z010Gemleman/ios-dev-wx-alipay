// VMQEvent.m
// 统一事件结构与渠道配置实现。平台无关，纯 Foundation + CommonCrypto。

#import "VMQEvent.h"
#import <CommonCrypto/CommonDigest.h>

@implementation VMQEvent

- (NSString *)combinedText {
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:3];
    if (self.title.length)    { [parts addObject:self.title]; }
    if (self.subtitle.length) { [parts addObject:self.subtitle]; }
    if (self.body.length)     { [parts addObject:self.body]; }
    return [parts componentsJoinedByString:@"\n"];
}

- (NSString *)computedFallbackEventId {
    // bundleId + title + subtitle + body + eventTime 的 SHA-256（设计文档 §12）。
    NSMutableString *seed = [NSMutableString string];
    [seed appendString:self.bundleId ?: @""];
    [seed appendString:@"|"];
    [seed appendString:self.title ?: @""];
    [seed appendString:@"|"];
    [seed appendString:self.subtitle ?: @""];
    [seed appendString:@"|"];
    [seed appendString:self.body ?: @""];
    [seed appendString:@"|"];
    // eventTime 取整秒，避免浮点抖动导致同一事件产生不同 ID。
    [seed appendFormat:@"%lld", (long long)llround(self.eventTime)];

    NSData *data = [seed dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

@end

@implementation VMQChannelConfig

+ (VMQChannelConfig *)weChatConfig {
    VMQChannelConfig *c = [VMQChannelConfig new];
    c.bundleId = @VMQ_BUNDLE_WECHAT;
    c.type = VMQChannelWeChat;
    // §8.2 已验证的收款标题
    c.allowedTitles = @[ @"微信收款助手", @"微信支付", @"收款小助手", @"微信收款商业版" ];
    // §8.2 明确入账语义
    c.incomeKeywords = @[ @"收款", @"成功收款", @"已到账", @"向你付款", @"向您付款" ];
    // §8.3 排除语义
    c.excludeKeywords = @[ @"红包", @"待收款", @"请确认收款", @"转账", @"退款", @"撤回",
                           @"付款失败", @"支出", @"群聊", @"好友申请" ];
    return c;
}

+ (VMQChannelConfig *)alipayConfig {
    VMQChannelConfig *c = [VMQChannelConfig new];
    c.bundleId = @VMQ_BUNDLE_ALIPAY;
    c.type = VMQChannelAlipay;
    // §9.2 强收款语义标题
    c.allowedTitles = @[ @"收钱码收款通知", @"支付宝收款", @"到账通知" ];
    // §9.2 正文入账语义
    c.incomeKeywords = @[ @"通过扫码向你付款", @"你已收款", @"成功收款", @"到账", @"向你付款" ];
    // §9.3 排除语义
    c.excludeKeywords = @[ @"付款", @"消费", @"扣款", @"账单", @"退款", @"退款到账",
                           @"撤销", @"付款失败" ];
    return c;
}

+ (nullable VMQChannelConfig *)configForBundleId:(NSString *)bundleId {
    if ([bundleId isEqualToString:@VMQ_BUNDLE_WECHAT]) { return [self weChatConfig]; }
    if ([bundleId isEqualToString:@VMQ_BUNDLE_ALIPAY]) { return [self alipayConfig]; }
    return nil;
}

@end
