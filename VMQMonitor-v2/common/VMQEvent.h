// VMQEvent.h
// 统一事件结构（设计文档 §7）与渠道配置。平台无关，纯 Foundation。

#import <Foundation/Foundation.h>
#import "VMQProtocol.h"

NS_ASSUME_NONNULL_BEGIN

/// 统一通知事件。监听组件产出原始事件，vmqmond 解析后填充金额等结果字段。
@interface VMQEvent : NSObject

@property (nonatomic, copy)   NSString *eventId;      // 去重主键
@property (nonatomic, copy)   NSString *bundleId;
@property (nonatomic, assign) VMQChannelType channelType;
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *subtitle;
@property (nonatomic, copy, nullable) NSString *body;
@property (nonatomic, assign) NSTimeInterval eventTime; // Unix 秒

/// 解析结果：规范化后的金额字符串（最多两位小数，如 "12.30"）。nil 表示未确定。
@property (nonatomic, copy, nullable) NSString *normalizedAmount;

/// 拼接标题/副标题/正文，供语义匹配使用（任一为空则跳过）。
- (NSString *)combinedText;

/// 依据 bundleId+title+subtitle+body+eventTime 计算 SHA-256，作为无 bulletin id 时的兜底事件 ID。
- (NSString *)computedFallbackEventId;

@end

/// 单个渠道的纯数据配置（设计文档 §7：代码只维护一个解析器，渠道仅提供数据）。
@interface VMQChannelConfig : NSObject

@property (nonatomic, copy)   NSString *bundleId;
@property (nonatomic, assign) VMQChannelType type;
@property (nonatomic, copy)   NSArray<NSString *> *allowedTitles;    // 已验证的收款标题
@property (nonatomic, copy)   NSArray<NSString *> *incomeKeywords;   // 明确入账语义
@property (nonatomic, copy)   NSArray<NSString *> *excludeKeywords;  // 排除语义

+ (VMQChannelConfig *)weChatConfig;
+ (VMQChannelConfig *)alipayConfig;

/// 根据 bundleId 精确匹配返回对应配置；无匹配返回 nil。
+ (nullable VMQChannelConfig *)configForBundleId:(NSString *)bundleId;

@end

NS_ASSUME_NONNULL_END
