// VMQReporter.m
// VMQ 联网上报实现。系统 TLS 校验，不关闭证书验证（设计文档 §13.3）。

#import "VMQReporter.h"
#import "VMQSign.h"

@implementation VMQTestResult
- (instancetype)init {
    if ((self = [super init])) {
        _dnsTlsOK = NO; _httpStatus = 0; _businessCode = -1; _message = @"";
    }
    return self;
}
@end

@interface VMQReporter ()
@property (nonatomic, strong) VMQConfig *config;
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation VMQReporter

- (instancetype)initWithConfig:(VMQConfig *)config {
    if ((self = [super init])) {
        _config = config;
        NSURLSessionConfiguration *c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        c.timeoutIntervalForRequest = 15;
        c.timeoutIntervalForResource = 30;
        c.waitsForConnectivity = NO;
        _session = [NSURLSession sessionWithConfiguration:c];
    }
    return self;
}

- (NSString *)signTypeParam {
    return self.config.signType == VMQSignTypeMD5 ? @"MD5" : @"HMAC_SHA256";
}

// 同步执行一个 GET 请求，返回 (status, body)。使用信号量把异步 API 包装为同步，供 daemon 队列线程调用。
- (NSInteger)syncGET:(NSURL *)url body:(NSString *_Nullable *_Nullable)outBody error:(NSError *_Nullable *_Nullable)outErr {
    __block NSInteger status = 0;
    __block NSString *bodyStr = nil;
    __block NSError *reqErr = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url
                                            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) {
            reqErr = error;
        } else if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
            status = ((NSHTTPURLResponse *)resp).statusCode;
            if (data) bodyStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (outBody) *outBody = bodyStr;
    if (outErr) *outErr = reqErr;
    return status;
}

// 解析 VMQ JSON 返回的 code 字段；取不到返回 -1。
- (NSInteger)businessCodeFromBody:(NSString *)body {
    if (body.length == 0) return -1;
    NSData *d = [body dataUsingEncoding:NSUTF8StringEncoding];
    NSError *e = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:&e];
    if (e || ![obj isKindOfClass:[NSDictionary class]]) return -1;
    id code = obj[@"code"];
    if ([code respondsToSelector:@selector(integerValue)]) return [code integerValue];
    return -1;
}

- (NSString *)encode:(NSString *)s {
    NSCharacterSet *allowed = [NSCharacterSet URLQueryAllowedCharacterSet];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

- (VMQNetResult)sendHeartbeat {
    if (![self.config isNetworkReady]) return VMQNetResultPause;

    NSString *t = [NSString stringWithFormat:@"%ld", (long)[[NSDate date] timeIntervalSince1970]];
    NSString *nonce = [VMQSign newNonce];
    NSString *sign = [VMQSign heartbeatSignWithKey:self.config.key
                                             nonce:nonce
                                                 t:t
                                          signType:self.config.signType];

    NSString *urlStr = [NSString stringWithFormat:@"%@/appHeart?t=%@&nonce=%@&signType=%@&sign=%@",
                        self.config.serverBase, [self encode:t], [self encode:nonce],
                        [self encode:[self signTypeParam]], [self encode:sign]];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return VMQNetResultPause;

    NSString *body = nil; NSError *err = nil;
    NSInteger status = [self syncGET:url body:&body error:&err];
    if (err) return VMQNetResultRetry;
    if (status >= 500) return VMQNetResultRetry;
    if (status != 200) return VMQNetResultRetry;
    NSInteger code = [self businessCodeFromBody:body];
    if (code == 1) return VMQNetResultSuccess;
    // 业务失败：可能是密钥/签名错误
    return VMQNetResultPause;
}

- (VMQNetResult)sendPushType:(NSString *)type price:(NSString *)price eventTime:(NSString *)eventTime {
    if (![self.config isNetworkReady]) return VMQNetResultPause;

    NSString *t = [NSString stringWithFormat:@"%ld", (long)[[NSDate date] timeIntervalSince1970]];
    NSString *nonce = [VMQSign newNonce];
    NSString *sign = [VMQSign pushSignWithKey:self.config.key
                                         type:type
                                        price:price
                                            t:t
                                    eventTime:eventTime
                                        nonce:nonce
                                     signType:self.config.signType];

    NSString *urlStr = [NSString stringWithFormat:
                        @"%@/appPush?type=%@&price=%@&t=%@&eventTime=%@&nonce=%@&signType=%@&sign=%@",
                        self.config.serverBase,
                        [self encode:type], [self encode:price], [self encode:t],
                        [self encode:eventTime], [self encode:nonce],
                        [self encode:[self signTypeParam]], [self encode:sign]];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return VMQNetResultPause;

    NSString *body = nil; NSError *err = nil;
    NSInteger status = [self syncGET:url body:&body error:&err];
    if (err) return VMQNetResultRetry;
    if (status >= 500) return VMQNetResultRetry;
    if (status != 200) return VMQNetResultRetry;
    NSInteger code = [self businessCodeFromBody:body];
    if (code == 1) return VMQNetResultSuccess;
    return VMQNetResultPause;
}

- (VMQTestResult *)testConnection {
    VMQTestResult *r = [VMQTestResult new];
    if (![self.config isNetworkReady]) {
        r.message = @"配置不完整（缺少服务器地址或密钥）";
        return r;
    }
    VMQNetResult net = [self sendHeartbeat];
    // 复用心跳做连通性测试；细分 DNS/TLS 需要更底层的探测，这里给出综合结论。
    NSString *t = [NSString stringWithFormat:@"%ld", (long)[[NSDate date] timeIntervalSince1970]];
    NSString *nonce = [VMQSign newNonce];
    NSString *sign = [VMQSign heartbeatSignWithKey:self.config.key nonce:nonce t:t signType:self.config.signType];
    NSString *urlStr = [NSString stringWithFormat:@"%@/appHeart?t=%@&nonce=%@&signType=%@&sign=%@",
                        self.config.serverBase, [self encode:t], [self encode:nonce],
                        [self encode:[self signTypeParam]], [self encode:sign]];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSString *body = nil; NSError *err = nil;
    NSInteger status = [self syncGET:url body:&body error:&err];
    if (err) {
        r.dnsTlsOK = NO;
        r.message = [NSString stringWithFormat:@"网络错误：%@", err.localizedDescription];
        return r;
    }
    r.dnsTlsOK = YES; // 能拿到 HTTP 响应即说明 DNS/TLS 通过
    r.httpStatus = status;
    r.businessCode = [self businessCodeFromBody:body];
    switch (net) {
        case VMQNetResultSuccess: r.message = @"连接正常，VMQ 业务校验通过"; break;
        case VMQNetResultRetry:   r.message = @"网络可达但服务端暂时不可用"; break;
        case VMQNetResultPause:   r.message = @"连接到服务端但业务校验失败（检查密钥/签名模式）"; break;
    }
    return r;
}

@end
