// VMQParser.h
// 统一收款判定 + 金额提取（设计文档 §7/§8/§9/§12）。
// 微信和支付宝共用同一套代码路径，渠道差异只来自 VMQChannelConfig 数据。
// 平台无关，纯 Foundation，可在 Linux 上用 objc 运行时做逻辑单测。

#import <Foundation/Foundation.h>
#import "VMQEvent.h"

NS_ASSUME_NONNULL_BEGIN

/// 解析拒绝原因，用于日志（不落完整正文）。
typedef NS_ENUM(NSInteger, VMQParseReject) {
    VMQParseRejectNone = 0,        // 未拒绝（已接受）
    VMQParseRejectBundle,          // Bundle ID 不匹配
    VMQParseRejectTitle,           // 标题不在允许列表
    VMQParseRejectNoIncomeSemantic,// 缺少明确入账语义
    VMQParseRejectExcluded,        // 命中排除关键词
    VMQParseRejectNoAmount,        // 无法确定唯一金额
};

/// 解析结果。
@interface VMQParseResult : NSObject
@property (nonatomic, assign) BOOL accepted;
@property (nonatomic, assign) VMQParseReject reject;
@property (nonatomic, copy, nullable) NSString *normalizedAmount; // "12.30"
@property (nonatomic, assign) VMQChannelType channelType;
/// 供日志使用的简短原因描述（中文，不含金额外的敏感正文）。
@property (nonatomic, copy) NSString *reason;
@end

@interface VMQParser : NSObject

/// 对一个原始事件执行完整管线判定。event.bundleId 必须已设置。
+ (VMQParseResult *)parseEvent:(VMQEvent *)event;

/// 从一段文本中提取靠近入账关键词的唯一金额，规范化为最多两位小数的正十进制字符串。
/// 找不到或存在多个无法唯一确定的金额时返回 nil。
/// 暴露为独立方法以便单元测试。
+ (nullable NSString *)extractAmountFromText:(NSString *)text
                              incomeKeywords:(NSArray<NSString *> *)incomeKeywords;

@end

NS_ASSUME_NONNULL_END
