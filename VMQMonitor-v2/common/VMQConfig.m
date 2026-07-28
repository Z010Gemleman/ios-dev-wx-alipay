// VMQConfig.m
#import "VMQConfig.h"
#import <sys/stat.h>

@implementation VMQConfig

+ (instancetype)load {
    VMQConfig *c = [VMQConfig new];
    c.signType = VMQSignTypeHMACSHA256;
    c.weChatEnabled = YES;
    c.alipayEnabled = YES;
    c.reportingEnabled = NO;

    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@(VMQ_CONFIG_FILE)];
    if (d) {
        c.serverBase = d[@"serverBase"];
        c.key = d[@"key"];
        c.signType = [d[@"signType"] integerValue];
        if (d[@"weChatEnabled"]) c.weChatEnabled = [d[@"weChatEnabled"] boolValue];
        if (d[@"alipayEnabled"]) c.alipayEnabled = [d[@"alipayEnabled"] boolValue];
        c.reportingEnabled = [d[@"reportingEnabled"] boolValue];
    }
    return c;
}

- (BOOL)save {
    // 确保目录存在，权限 0700
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = @(VMQ_DATA_DIR);
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir
      withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions: @(0700)}
                            error:nil];
    }

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (self.serverBase) d[@"serverBase"] = self.serverBase;
    if (self.key) d[@"key"] = self.key;
    d[@"signType"] = @(self.signType);
    d[@"weChatEnabled"] = @(self.weChatEnabled);
    d[@"alipayEnabled"] = @(self.alipayEnabled);
    d[@"reportingEnabled"] = @(self.reportingEnabled);

    NSString *path = @(VMQ_CONFIG_FILE);
    BOOL ok = [d writeToFile:path atomically:YES];
    if (ok) {
        chmod(path.fileSystemRepresentation, 0600);
    }
    return ok;
}

- (BOOL)isNetworkReady {
    return self.serverBase.length > 0 && self.key.length > 0;
}

- (BOOL)isChannelEnabled:(VMQChannelType)type {
    switch (type) {
        case VMQChannelWeChat: return self.weChatEnabled;
        case VMQChannelAlipay: return self.alipayEnabled;
        default: return NO;
    }
}

@end
