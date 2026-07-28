// VMQParser.m
// 统一收款判定与金额提取实现。金额一律用 NSDecimalNumber，禁止 double（设计文档 §8.4/§12）。

#import "VMQParser.h"

@implementation VMQParseResult
- (instancetype)init {
    if ((self = [super init])) {
        _accepted = NO;
        _reject = VMQParseRejectNone;
        _channelType = VMQChannelUnknown;
        _reason = @"";
    }
    return self;
}
@end

@implementation VMQParser

+ (BOOL)text:(NSString *)text containsAny:(NSArray<NSString *> *)keywords {
    if (text.length == 0 || keywords.count == 0) return NO;
    for (NSString *kw in keywords) {
        if (kw.length == 0) continue;
        if ([text rangeOfString:kw].location != NSNotFound) return YES;
    }
    return NO;
}

+ (BOOL)title:(NSString *)title matchesAllowed:(NSArray<NSString *> *)allowed {
    if (title.length == 0 || allowed.count == 0) return NO;
    for (NSString *a in allowed) {
        if (a.length == 0) continue;
        // 标题采用包含匹配：系统通知标题常带 App 名前缀或后缀。
        if ([title rangeOfString:a].location != NSNotFound) return YES;
    }
    return NO;
}

+ (VMQParseResult *)parseEvent:(VMQEvent *)event {
    VMQParseResult *r = [VMQParseResult new];

    // 1. Bundle ID 精确匹配
    VMQChannelConfig *cfg = [VMQChannelConfig configForBundleId:event.bundleId ?: @""];
    if (!cfg) {
        r.reject = VMQParseRejectBundle;
        r.reason = @"bundle不匹配";
        return r;
    }
    r.channelType = cfg.type;

    NSString *title = event.title ?: @"";
    NSString *combined = [event combinedText];
    if (combined.length == 0) {
        r.reject = VMQParseRejectNoIncomeSemantic;
        r.reason = @"通知内容不足";
        return r;
    }

    // 2. 排除规则优先：命中任何排除语义直接丢弃（退款/支出/红包/待确认等）
    if ([self text:combined containsAny:cfg.excludeKeywords]) {
        r.reject = VMQParseRejectExcluded;
        r.reason = @"命中排除语义";
        return r;
    }

    // 3. 标题层：标题必须落在已验证收款标题集合
    if (![self title:title matchesAllowed:cfg.allowedTitles]) {
        r.reject = VMQParseRejectTitle;
        r.reason = @"标题非收款标题";
        return r;
    }

    // 4. 入账语义层：标题/副标题/正文需包含明确入账语义
    if (![self text:combined containsAny:cfg.incomeKeywords]) {
        r.reject = VMQParseRejectNoIncomeSemantic;
        r.reason = @"无明确入账语义";
        return r;
    }

    // 5. 金额提取：必须唯一确定
    NSString *amount = [self extractAmountFromText:combined incomeKeywords:cfg.incomeKeywords];
    if (amount == nil) {
        r.reject = VMQParseRejectNoAmount;
        r.reason = @"金额无法唯一确定";
        return r;
    }

    r.accepted = YES;
    r.reject = VMQParseRejectNone;
    r.normalizedAmount = amount;
    r.reason = @"收款";
    return r;
}

#pragma mark - 金额提取

// 将匹配到的数字字符串规范化为最多两位小数的正十进制字符串。
// 失败（<=0 或非法）返回 nil。使用 NSDecimalNumber，禁止 double。
+ (nullable NSString *)normalizeDecimalString:(NSString *)raw {
    if (raw.length == 0) return nil;
    // 去掉千分位逗号
    NSString *cleaned = [raw stringByReplacingOccurrencesOfString:@"," withString:@""];
    NSDecimalNumber *num = [NSDecimalNumber decimalNumberWithString:cleaned];
    if (num == nil || [num isEqual:[NSDecimalNumber notANumber]]) return nil;
    if ([num compare:[NSDecimalNumber zero]] != NSOrderedDescending) return nil; // 必须 > 0

    // 规范化为两位小数（银行家舍入不适用于金额展示，这里用 plain 截断到 2 位）。
    NSDecimalNumberHandler *handler =
        [NSDecimalNumberHandler decimalNumberHandlerWithRoundingMode:NSRoundPlain
                                                               scale:2
                                                    raiseOnExactness:NO
                                                     raiseOnOverflow:NO
                                                    raiseOnUnderflow:NO
                                                 raiseOnDivideByZero:NO];
    NSDecimalNumber *rounded = [num decimalNumberByRoundingAccordingToBehavior:handler];
    if ([rounded compare:[NSDecimalNumber zero]] != NSOrderedDescending) return nil;

    // 固定两位小数输出
    NSDecimalNumber *scaled = rounded;
    NSString *s = [scaled stringValue];
    // 补齐两位小数
    NSRange dot = [s rangeOfString:@"."];
    if (dot.location == NSNotFound) {
        s = [s stringByAppendingString:@".00"];
    } else {
        NSInteger decimals = s.length - (dot.location + 1);
        if (decimals == 1) s = [s stringByAppendingString:@"0"];
    }
    return s;
}

+ (nullable NSString *)extractAmountFromText:(NSString *)text
                              incomeKeywords:(NSArray<NSString *> *)incomeKeywords {
    if (text.length == 0) return nil;

    // 金额形式：¥12.30 / ￥12.30 / 12.30元 / 收款12元 等。
    // 用正则找出所有候选金额及其位置，再要求其靠近入账关键词。
    NSString *pattern = @"(?:¥|￥|人民币)\\s*([0-9]+(?:,[0-9]{3})*(?:\\.[0-9]{1,2})?)"
                         "|([0-9]+(?:,[0-9]{3})*(?:\\.[0-9]{1,2})?)\\s*元";
    NSError *err = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                       options:0
                                                                         error:&err];
    if (err) return nil;

    NSArray<NSTextCheckingResult *> *matches =
        [re matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    if (matches.count == 0) return nil;

    // 收集唯一规范化金额，并要求金额附近（前后 12 字符窗口）出现入账关键词。
    NSMutableSet<NSString *> *uniqueAmounts = [NSMutableSet set];
    for (NSTextCheckingResult *m in matches) {
        NSString *captured = nil;
        for (NSUInteger gi = 1; gi <= 2; gi++) {
            NSRange g = [m rangeAtIndex:gi];
            if (g.location != NSNotFound) { captured = [text substringWithRange:g]; break; }
        }
        if (captured.length == 0) continue;

        // 语义邻近校验：金额附近需有入账关键词，避免抓到余额/时间/笔数。
        NSRange full = m.range;
        NSInteger winStart = MAX(0, (NSInteger)full.location - 12);
        NSInteger winEnd = MIN((NSInteger)text.length, (NSInteger)(full.location + full.length) + 12);
        NSString *window = [text substringWithRange:NSMakeRange(winStart, winEnd - winStart)];
        BOOL near = NO;
        for (NSString *kw in incomeKeywords) {
            if (kw.length == 0) continue;
            if ([window rangeOfString:kw].location != NSNotFound) { near = YES; break; }
        }
        // 若整段仅此一个金额，即便不在窗口内也接受；多个金额则必须靠近入账词。
        if (!near && matches.count > 1) continue;

        NSString *norm = [self normalizeDecimalString:captured];
        if (norm) [uniqueAmounts addObject:norm];
    }

    // 必须唯一确定；0 个或多个不同金额都拒绝（设计文档 §12：宁可拒绝不猜测）。
    if (uniqueAmounts.count == 1) return uniqueAmounts.anyObject;
    return nil;
}

@end
