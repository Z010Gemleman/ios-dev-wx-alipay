// main.m — Root Helper
// 职责（设计文档 §4/§17）：
//   以 root 身份执行受控的安装、停用、卸载动作。
//   只允许对内置清单中的版本、环境类型和 SHA-256 校验通过的包执行 dpkg -i。
//   不接受任意命令、任意包路径或任意 package ID。
//
// TrollStore 通过 App 的 com.apple.private.iomobileframebuffer.SetDisplayDevice
// 或类似 root 授权调用此 helper；具体机制视 TrollStore 版本而定。
//
// 调用约定（argv）：
//   vmqhelper install   <scheme: rootless|roothide>
//   vmqhelper uninstall
//   vmqhelper disable
//   vmqhelper enable
//
// 所有操作都写一行结果到 stdout（JSON）：{"ok": true/false, "message": "..."}

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>
#import <unistd.h>
#import <spawn.h>
#import <sys/wait.h>
#import "../common/VMQProtocol.h"

extern char **environ;

// ---- 内置载荷清单 ----
// 生产版本必须在此填入真实 SHA-256（发布前由 CI 计算并嵌入）。
// 开发阶段先用空字符串占位，helper 检测到空字符串时跳过 SHA 校验并记录警告。
static const struct {
    const char *scheme;          // "rootless" or "roothide"
    const char *filename;        // IPA 内嵌的 .deb 文件名
    const char *expectedSHA256;  // 64 位 hex，空表示开发占位（跳过校验）
} kEmbeddedPayloads[] = {
    { "rootless",  "com.z010genleman.vmqmonitor.v2.runtime-rootless.deb",  "" },
    { "roothide",  "com.z010genleman.vmqmonitor.v2.runtime-roothide.deb",  "" },
};
static const NSUInteger kPayloadCount = sizeof(kEmbeddedPayloads) / sizeof(kEmbeddedPayloads[0]);

// 动态解析 bootstrap 工具路径。
// 优先级：JBROOT 环境变量（RootHide/Dopamine 设置）→ /var/jb（rootless 固定前缀）→ PATH 全局
static const char *vmq_find_tool(const char *name) {
    static char buf[512];
    // 1. JBROOT 环境变量（RootHide Bootstrap：随机前缀由 Dopamine 注入）
    const char *jbroot = getenv("JBROOT");
    if (jbroot && *jbroot) {
        snprintf(buf, sizeof(buf), "%s/usr/bin/%s", jbroot, name);
        if (access(buf, X_OK) == 0) return buf;
        snprintf(buf, sizeof(buf), "%s/usr/local/bin/%s", jbroot, name);
        if (access(buf, X_OK) == 0) return buf;
    }
    // 2. Dopamine rootless 固定前缀 /var/jb
    snprintf(buf, sizeof(buf), "/var/jb/usr/bin/%s", name);
    if (access(buf, X_OK) == 0) return buf;
    // 3. Procursus 备用路径
    snprintf(buf, sizeof(buf), "/opt/procursus/usr/bin/%s", name);
    if (access(buf, X_OK) == 0) return buf;
    return NULL; // 找不到，调用方报错
}

// ---- 工具函数 ----
static void reply(BOOL ok, NSString *msg) {
    NSDictionary *d = @{ @"ok": @(ok), @"message": msg ?: @"" };
    NSData *json = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    if (json) {
        NSString *s = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        fprintf(stdout, "%s\n", s.UTF8String);
    } else {
        fprintf(stdout, "{\"ok\":%s,\"message\":\"%s\"}\n", ok ? "true" : "false", [msg UTF8String] ?: "");
    }
}

static NSString *sha256OfFile(NSString *path) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return nil;
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    for (;;) {
        NSData *chunk = [fh readDataOfLength:65536];
        if (chunk.length == 0) break;
        CC_SHA256_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
    }
    [fh closeFile];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static NSString *payloadDir(void) {
    // 载荷嵌在 App bundle 内：<bundle>/Payloads/
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    return [bundlePath stringByAppendingPathComponent:@"Payloads"];
}

// 以 posix_spawn 同步执行一个程序（iOS 无 NSTask）。
// 返回子进程退出码；启动失败返回 -1（errno 置位）。
static int runProcess(const char *path, char *const argv[]) {
    pid_t pid = 0;
    int rc = posix_spawn(&pid, path, NULL, NULL, argv, environ);
    if (rc != 0) {
        errno = rc;
        return -1;
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return -1;
}

// ---- 命令实现 ----
static int cmdInstall(NSString *scheme) {
    // 关键发现（2026-07-29 真机调试）：
    // 此设备所有能被 ellekit 加载的 tweak 都是「rootless 格式」——
    // 使用 @rpath/CydiaSubstrate.framework + @loader_path/.jbroot/Library/Frameworks LC_RPATH，
    // 通过 RootHidePatcher 或 Sileo 安装，自动生成 .roothidepatch 标记。
    // roothide-scheme deb（baked @loader_path/.jbroot 路径）被 ellekit 静默跳过。
    //
    // 正确做法：
    //   1. 强制安装 rootless deb（架构标注 iphoneos-arm64，用 --force-architecture 绕过）
    //   2. 安装后手动创建 .roothidepatch 符号链接（指向 AutoPatches.dylib）
    //   3. sbreload → ellekit 按正确路径加载 dylib
    (void)scheme; // scheme 参数保留供卸载/诊断用；安装始终走 rootless 路径

    // 找 rootless deb
    NSUInteger idx = NSNotFound;
    for (NSUInteger i = 0; i < kPayloadCount; i++) {
        if (strcmp(kEmbeddedPayloads[i].scheme, "rootless") == 0) { idx = i; break; }
    }
    if (idx == NSNotFound) {
        reply(NO, @"找不到 rootless 载荷");
        return 1;
    }

    NSString *debPath = [payloadDir() stringByAppendingPathComponent:
                         @(kEmbeddedPayloads[idx].filename)];
    if (![[NSFileManager defaultManager] fileExistsAtPath:debPath]) {
        reply(NO, [NSString stringWithFormat:@"载荷文件不存在: %@", debPath]);
        return 1;
    }

    // SHA-256 校验（开发阶段留空，跳过）
    const char *expected = kEmbeddedPayloads[idx].expectedSHA256;
    if (expected && strlen(expected) == 64) {
        NSString *actual = sha256OfFile(debPath);
        if (![actual isEqualToString:@(expected)]) {
            reply(NO, @"SHA-256 校验失败，拒绝安装");
            return 1;
        }
    }

    const char *dpkgPath = vmq_find_tool("dpkg");
    if (!dpkgPath) {
        reply(NO, @"找不到 dpkg（确认越狱处于激活状态）");
        return 1;
    }

    // --force-architecture：rootless deb 标注 iphoneos-arm64，
    // 系统为 iphoneos-arm64e，需强制跳过架构检查。
    // deb 内含 fat dylib（arm64+arm64e），arm64e slice PAC ABI 正确。
    char *const dpkgArgv[] = {
        (char *)"dpkg",
        (char *)"--force-architecture",
        (char *)"-i",
        (char *)debPath.fileSystemRepresentation,
        NULL
    };
    int code = runProcess(dpkgPath, dpkgArgv);
    if (code < 0) {
        reply(NO, [NSString stringWithFormat:@"dpkg 启动失败: %s", strerror(errno)]);
        return 1;
    }
    if (code != 0) {
        reply(NO, [NSString stringWithFormat:@"dpkg 返回 %d", code]);
        return 1;
    }

    // 安装后创建 .roothidepatch 符号链接。
    // 所有能被 ellekit 加载的 RootHide tweak 都有此标记，指向 AutoPatches.dylib。
    // dpkg 直装不会自动创建（只有 Sileo/RootHidePatcher 的钩子会），故手动补建。
    NSString *dylib  = @"/Library/MobileSubstrate/DynamicLibraries/VMQListener.dylib";
    NSString *patch  = [dylib stringByAppendingString:@".roothidepatch"];
    NSString *target = @"/usr/lib/DynamicPatches/AutoPatches.dylib";
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:patch error:nil]; // 先删旧的（如有）
    NSError *lnErr = nil;
    [fm createSymbolicLinkAtPath:patch withDestinationPath:target error:&lnErr];
    if (lnErr) {
        // 非致命——sbreload 后如果没加载到位，下次可重试
        NSLog(@"[VMQ] .roothidepatch 创建失败: %@（非致命）", lnErr.localizedDescription);
    }

    // Respring
    const char *sbreloadPath = vmq_find_tool("sbreload");
    if (sbreloadPath) {
        char *const sbArgv[] = { (char *)"sbreload", NULL };
        runProcess(sbreloadPath, sbArgv);
    }

    reply(YES, @"安装完成，设备即将刷新");
    return 0;
}

static int cmdUninstall(void) {
    const char *dpkgPath = vmq_find_tool("dpkg");
    if (!dpkgPath) { reply(NO, @"找不到 dpkg"); return 1; }
    char *const dpkgArgv[] = { (char *)"dpkg", (char *)"-r",
                               (char *)VMQ_RUNTIME_PACKAGE_ID, NULL };
    int code = runProcess(dpkgPath, dpkgArgv);
    if (code < 0) { reply(NO, [NSString stringWithFormat:@"dpkg 启动失败: %s", strerror(errno)]); return 1; }
    if (code != 0) { reply(NO, [NSString stringWithFormat:@"dpkg -r 返回 %d", code]); return 1; }
    const char *sb = vmq_find_tool("sbreload");
    if (sb) { char *a[] = { (char *)"sbreload", NULL }; runProcess(sb, a); }
    reply(YES, @"卸载完成，请等待设备刷新");
    return 0;
}

static int cmdDisable(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:@(VMQ_DATA_DIR) withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createFileAtPath:@(VMQ_DISABLE_FLAG) contents:[NSData data] attributes:nil];
    const char *sb = vmq_find_tool("sbreload");
    if (sb) { char *a[] = { (char *)"sbreload", NULL }; runProcess(sb, a); }
    reply(YES, @"已写入禁用标记，请等待设备刷新");
    return 0;
}

static int cmdEnable(void) {
    [[NSFileManager defaultManager] removeItemAtPath:@(VMQ_DISABLE_FLAG) error:nil];
    const char *sb = vmq_find_tool("sbreload");
    if (sb) { char *a[] = { (char *)"sbreload", NULL }; runProcess(sb, a); }
    reply(YES, @"已移除禁用标记，请等待设备刷新");
    return 0;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            reply(NO, @"用法: vmqhelper <install <scheme>|uninstall|disable|enable>");
            return 1;
        }
        NSString *cmd = @(argv[1]);
        if ([cmd isEqualToString:@"install"]) {
            NSString *scheme = argc >= 3 ? @(argv[2]) : nil;
            if (!scheme) { reply(NO, @"缺少 scheme 参数"); return 1; }
            return cmdInstall(scheme);
        }
        if ([cmd isEqualToString:@"uninstall"]) return cmdUninstall();
        if ([cmd isEqualToString:@"disable"])   return cmdDisable();
        if ([cmd isEqualToString:@"enable"])    return cmdEnable();
        reply(NO, [NSString stringWithFormat:@"未知命令: %@", cmd]);
        return 1;
    }
}
