#import "SMGCommon.h"

// ===========================================================================
// 安全模式卫士 · 核心状态机实现
// ===========================================================================
//
// ⚠️ 本文件是插件的「保险丝」，它自己绝不能成为新的崩溃源。
//    三条纪律：
//      ① 所有磁盘 IO 一律包 @try，失败静默跳过
//      ② 所有写入用原子写（NSData writeToFile:options:NSDataWritingAtomic）
//         —— 避免「写一半被杀」产生损坏文件，下一轮读出来是垃圾
//      ③ 任何函数都不允许「因为读不到文件就崩」
// ===========================================================================

// 日志文件大小上限（防无限增长占满磁盘）
static const NSUInteger kSMGLogMaxBytes = 256 * 1024;
// 启动历史保留条数
static const NSInteger kSMGBootHistoryMax = 40;

#pragma mark - 路径

NSString *SMGSharedDir(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // /var/mobile/Documents 是 SpringBoard 与「设置」进程都能读写的位置
        NSString *base = @"/var/mobile/Documents";
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:base]) {
            // 兜底：万一没有（理论上不可能），退回本进程沙盒
            NSString *doc = NSSearchPathForDirectoriesInDomains(
                NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            base = doc.length ? doc : NSTemporaryDirectory();
        }
        dir = [base stringByAppendingPathComponent:@"安全模式卫士"];
    });
    return dir;
}

static void SMGEnsureDir(void) {
    @try {
        NSString *d = SMGSharedDir();
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:d isDirectory:&isDir] && isDir) return;
        [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
        [fm setAttributes:@{NSFilePosixPermissions: @(0777)} ofItemAtPath:d error:NULL];
    } @catch (__unused NSException *e) { }
}

NSString *SMGConfigPath(void) {
    return [SMGSharedDir() stringByAppendingPathComponent:@"_config.plist"];
}

NSString *SMGBootLogPath(void) {
    return [SMGSharedDir() stringByAppendingPathComponent:@"_bootlog.txt"];
}

NSString *SMGPendingPath(void) {
    // 「本轮进行中」标记。存在 = 上一轮没能销号。
    return [SMGSharedDir() stringByAppendingPathComponent:@"_pending.txt"];
}

NSString *SMGSafeModeFlagPath(void) {
    // ⭐ ElleKit 官方安全模式标记（根路径，非 jbroot）
    return @"/var/mobile/.eksafemode";
}

#pragma mark - 日志

void SMGLog(NSString *fmt, ...) {
    @try {
        if (!fmt) return;
        va_list ap;
        va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);

        SMGEnsureDir();
        NSString *line = [NSString stringWithFormat:@"[%@] %@ pid=%d %@\n",
                          [NSDate date],
                          NSProcessInfo.processInfo.processName,
                          (int)getpid(),
                          msg ?: @""];

        NSString *path = SMGBootLogPath();
        NSFileManager *fm = [NSFileManager defaultManager];

        // 体积封顶：超了就截半（保留后半段，最近的记录最重要）
        NSDictionary *attr = [fm attributesOfItemAtPath:path error:NULL];
        unsigned long long sz = [attr fileSize];
        if (sz > kSMGLogMaxBytes) {
            NSString *old = [NSString stringWithContentsOfFile:path
                                                      encoding:NSUTF8StringEncoding
                                                         error:NULL];
            if (old.length > kSMGLogMaxBytes / 2) {
                NSString *half = [old substringFromIndex:old.length - kSMGLogMaxBytes / 2];
                [half writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            } else {
                [fm removeItemAtPath:path error:NULL];
            }
        }

        // 追加写（不能用 NSDataWritingAtomic —— 那会覆盖而非追加）
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            [fm setAttributes:@{NSFilePosixPermissions: @(0666)} ofItemAtPath:path error:NULL];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (__unused NSException *e) { }
}

NSString *SMGLogRead(void) {
    @try {
        NSString *s = [NSString stringWithContentsOfFile:SMGBootLogPath()
                                                encoding:NSUTF8StringEncoding
                                                   error:NULL];
        return s ?: @"（暂无日志。插件可能还没在 SpringBoard 里跑过。）";
    } @catch (__unused NSException *e) {
        return @"（日志读取失败）";
    }
}

void SMGLogClear(void) {
    @try {
        [[NSFileManager defaultManager] removeItemAtPath:SMGBootLogPath() error:NULL];
    } @catch (__unused NSException *e) { }
}

#pragma mark - 配置读写

NSDictionary *SMGConfigAll(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    @try {
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:SMG_PREFS_DOMAIN];
        NSDictionary *snap = [d dictionaryRepresentation];
        if (snap.count) [out addEntriesFromDictionary:snap];

        NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:SMGConfigPath()];
        if (file.count) [out addEntriesFromDictionary:file];
    } @catch (__unused NSException *e) { }
    return out;
}

id SMGConfigGet(NSString *key) {
    if (!key.length) return nil;
    @try {
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:SMG_PREFS_DOMAIN];
        id v = [d objectForKey:key];
        if (v) return v;
        NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:SMGConfigPath()];
        return file[key];
    } @catch (__unused NSException *e) { return nil; }
}

void SMGConfigSet(NSString *key, id value) {
    if (!key.length) return;
    @try {
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:SMG_PREFS_DOMAIN];
        if (value) [d setObject:value forKey:key];
        else       [d removeObjectForKey:key];
        [d synchronize];

        // 同一份内容再写共享 plist —— SpringBoard 进程读这里更稳
        SMGEnsureDir();
        NSMutableDictionary *all = [NSMutableDictionary dictionary];
        NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:SMGConfigPath()];
        if (old.count) [all addEntriesFromDictionary:old];
        if (value) all[key] = value;
        else       [all removeObjectForKey:key];
        [all writeToFile:SMGConfigPath() atomically:YES];
    } @catch (__unused NSException *e) { }
}

#pragma mark - 便捷读取（都带默认值）

BOOL SMGEnabled(void) {
    id v = SMGConfigGet(@"enabled");
    return v ? [v boolValue] : YES;              // 默认开
}

NSInteger SMGMaxFailCount(void) {
    id v = SMGConfigGet(@"maxFailCount");
    NSInteger n = v ? [v integerValue] : 3;      // 默认连续 3 次
    if (n < 1) n = 1;
    if (n > 20) n = 20;
    return n;
}

double SMGAliveDelay(void) {
    id v = SMGConfigGet(@"aliveDelay");
    double d = v ? [v doubleValue] : 30.0;       // 默认 30 秒
    if (d < 5.0)   d = 5.0;                      // 下限：太短会把「启动慢」误判成异常
    if (d > 300.0) d = 300.0;                    // 上限：太长则保护来得太晚
    return d;
}

BOOL SMGAutoSafeMode(void) {
    id v = SMGConfigGet(@"autoSafeMode");
    return v ? [v boolValue] : YES;              // 默认自动进
}

#pragma mark - 计数（持久化，崩溃不丢）

NSInteger SMGFailCount(void) {
    @try {
        NSString *s = [NSString stringWithContentsOfFile:
                       [SMGSharedDir() stringByAppendingPathComponent:@"_failcount.txt"]
                                                encoding:NSUTF8StringEncoding error:NULL];
        return s ? (NSInteger)[s integerValue] : 0;
    } @catch (__unused NSException *e) { return 0; }
}

void SMGSetFailCount(NSInteger n) {
    @try {
        SMGEnsureDir();
        NSString *p = [SMGSharedDir() stringByAppendingPathComponent:@"_failcount.txt"];
        [[NSString stringWithFormat:@"%ld", (long)n]
            writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (__unused NSException *e) { }
}

NSInteger SMGBootTotal(void) {
    @try {
        NSString *s = [NSString stringWithContentsOfFile:
                       [SMGSharedDir() stringByAppendingPathComponent:@"_boottotal.txt"]
                                                encoding:NSUTF8StringEncoding error:NULL];
        return s ? (NSInteger)[s integerValue] : 0;
    } @catch (__unused NSException *e) { return 0; }
}

static void SMGSetBootTotal(NSInteger n) {
    @try {
        SMGEnsureDir();
        NSString *p = [SMGSharedDir() stringByAppendingPathComponent:@"_boottotal.txt"];
        [[NSString stringWithFormat:@"%ld", (long)n]
            writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (__unused NSException *e) { }
}

#pragma mark - 本标记（pending）

static BOOL SMGPendingExists(void) {
    @try {
        return [[NSFileManager defaultManager] fileExistsAtPath:SMGPendingPath()];
    } @catch (__unused NSException *e) { return NO; }
}

static void SMGWritePending(void) {
    @try {
        SMGEnsureDir();
        // 原子写：即使写到一半被杀，也不会留下半截文件
        NSString *stamp = [NSString stringWithFormat:@"%.0f\n", [NSDate date].timeIntervalSince1970];
        [stamp writeToFile:SMGPendingPath() atomically:YES
                  encoding:NSUTF8StringEncoding error:NULL];
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0666)}
                                         ofItemAtPath:SMGPendingPath() error:NULL];
    } @catch (__unused NSException *e) { }
}

static void SMGClearPending(void) {
    @try {
        [[NSFileManager defaultManager] removeItemAtPath:SMGPendingPath() error:NULL];
    } @catch (__unused NSException *e) { }
}

#pragma mark - 启动历史

static void SMGAppendHistory(NSString *line) {
    @try {
        SMGEnsureDir();
        NSString *p = [SMGSharedDir() stringByAppendingPathComponent:@"_history.plist"];
        NSMutableArray *arr = [NSMutableArray array];
        NSArray *old = [NSArray arrayWithContentsOfFile:p];
        if (old.count) [arr addObjectsFromArray:old];
        [arr addObject:line ?: @""];
        while (arr.count > kSMGBootHistoryMax) [arr removeObjectAtIndex:0];

        // ⚠️ 原子写：NSArray writeToFile:atomically: 已自带
        [arr writeToFile:p atomically:YES];
    } @catch (__unused NSException *e) { }
}

NSArray<NSString *> *SMGBootHistory(void) {
    @try {
        NSString *p = [SMGSharedDir() stringByAppendingPathComponent:@"_history.plist"];
        NSArray *a = [NSArray arrayWithContentsOfFile:p];
        // 倒序返回：最新在前，面板上更好看
        return a.count ? [[a reverseObjectEnumerator] allObjects] : @[];
    } @catch (__unused NSException *e) { return @[]; }
}

void SMGClearBootHistory(void) {
    @try {
        NSString *p = [SMGSharedDir() stringByAppendingPathComponent:@"_history.plist"];
        [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
    } @catch (__unused NSException *e) { }
}

#pragma mark - 安全模式标记

BOOL SMGSafeModeFlagExists(void) {
    @try {
        return [[NSFileManager defaultManager] fileExistsAtPath:SMGSafeModeFlagPath()];
    } @catch (__unused NSException *e) { return NO; }
}

BOOL SMGEnterSafeMode(NSString *reason) {
    @try {
        NSString *content = [NSString stringWithFormat:
            @"SafeModeGuard %@\n%@\n%@\n",
            SMG_VERSION,
            [NSDate date],
            reason ?: @"（未提供原因）"];

        BOOL ok = [content writeToFile:SMGSafeModeFlagPath() atomically:YES
                              encoding:NSUTF8StringEncoding error:NULL];
        if (ok) {
            // 权限：确保其它进程也认（ElleKit 只做存在性检查，权限宽松些无妨）
            [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0644)}
                                             ofItemAtPath:SMGSafeModeFlagPath() error:NULL];
            SMGLog(@"[安全模式] ✅ 已写入标记 %@（%@）", SMGSafeModeFlagPath(), reason);
        } else {
            // ⭐ 关键失败路径：写不进去必须留证据，否则用户以为插件在保护他
            SMGLog(@"[安全模式] ❌ 写入标记失败 %@（%@）", SMGSafeModeFlagPath(), reason);
            // 兜底：尝试写到共享目录作为「请求」，供用户手动处理
            SMGEnsureDir();
            NSString *alt = [SMGSharedDir() stringByAppendingPathComponent:@"_safemode_request.txt"];
            [content writeToFile:alt atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }
        SMGAppendHistory([NSString stringWithFormat:@"%@ 写入安全模式标记：%@",
                          [NSDate date], ok ? @"成功" : @"失败"]);
        return ok;
    } @catch (__unused NSException *e) { return NO; }
}

BOOL SMGExitSafeMode(void) {
    @try {
        BOOL existed = SMGSafeModeFlagExists();
        if (!existed) return YES;
        BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:SMGSafeModeFlagPath() error:NULL];
        SMGLog(@"[安全模式] %@ 标记 %@", ok ? @"已删除" : @"❌ 删除失败", SMGSafeModeFlagPath());
        SMGAppendHistory([NSString stringWithFormat:@"%@ 退出安全模式：%@",
                          [NSDate date], ok ? @"成功" : @"失败"]);
        return ok;
    } @catch (__unused NSException *e) { return NO; }
}

#pragma mark - 核心状态机

BOOL SMGBootBegin(void) {
    // 返回 YES = 上一轮被判定为异常启动
    BOOL lastWasAbnormal = NO;
    @try {
        // 总开关关掉时完全不记账（用户主动禁用时的正常行为）
        if (!SMGEnabled()) return NO;

        SMGEnsureDir();

        NSInteger total = SMGBootTotal() + 1;
        SMGSetBootTotal(total);

        // —— 判定上一轮 ——
        if (SMGPendingExists()) {
            lastWasAbnormal = YES;
            NSInteger n = SMGFailCount() + 1;
            SMGSetFailCount(n);
            SMGLog(@"[启动] ⚠️ 第 %ld 轮：检测到上一轮未销号（未存活到确认点）→ 连续异常 %ld 次",
                  (long)total, (long)n);
            SMGAppendHistory([NSString stringWithFormat:@"%@ 异常启动（第 %ld 次连续）",
                              [NSDate date], (long)n]);
        } else {
            // 上一轮正常，计数已在销号时清零；这里只报告当前值
            NSInteger n = SMGFailCount();
            SMGLog(@"[启动] 第 %ld 轮：上一轮正常收尾（当前连续异常 %ld 次）",
                  (long)total, (long)n);
            SMGAppendHistory([NSString stringWithFormat:@"%@ 启动（正常收尾后）",
                              [NSDate date]]);
        }

        // —— 写下本轮 pending（关键：必须在判定之后、且尽早写） ——
        SMGWritePending();

        // —— 达阈值则触发安全模式 ——
        NSInteger n = SMGFailCount();
        NSInteger maxN = SMGMaxFailCount();
        if (n >= maxN) {
            SMGLog(@"[判定] 🔴 连续异常 %ld 次（阈值 %ld）→ 判定为无限注销循环",
                  (long)n, (long)maxN);
            if (SMGAutoSafeMode()) {
                NSString *reason = [NSString stringWithFormat:
                    @"连续 %ld 次启动未能存活到确认点（阈值 %ld），判定设备陷入无限注销循环。"
                    @"写入此标记后，下次重启将跳过全部插件注入。",
                    (long)n, (long)maxN];
                BOOL ok = SMGEnterSafeMode(reason);
                // ⭐ 写成功后清掉 pending：本轮就是来进安全模式的，
                //   不该被下一轮再算一次异常；且避免反复写标记。
                //   如果写入失败，保留 pending 让计数继续涨（无害且更保守）。
                if (ok) {
                    SMGClearPending();
                    SMGSetFailCount(0);
                }
            } else {
                SMGLog(@"[判定] 自动进安全模式已关闭 → 仅记录，等用户手动处理");
                SMGClearPending();   // 不自动进，就不再累积，避免无限涨
            }
        }
    } @catch (__unused NSException *e) {
        // 兜底：即使这里出问题，也绝不让 SpringBoard 受影响
    }
    return lastWasAbnormal;
}

void SMGBootConfirmAlive(void) {
    @try {
        if (!SMGEnabled()) return;

        NSInteger before = SMGFailCount();
        SMGClearPending();
        SMGSetFailCount(0);

        SMGLog(@"[存活] ✅ SpringBoard 已存活到确认点 → 销号，异常计数 %ld → 0",
              (long)before);
        SMGAppendHistory([NSString stringWithFormat:@"%@ ✅ 存活确认通过，计数清零（此前 %ld 次）",
                          [NSDate date], (long)before]);
    } @catch (__unused NSException *e) { }
}

void SMGResetAllState(void) {
    @try {
        SMGClearPending();
        SMGSetFailCount(0);
        SMGSetBootTotal(0);
        SMGClearBootHistory();
        SMGLog(@"[重置] 已清空全部启动状态（计数/历史/待定标记）");
    } @catch (__unused NSException *e) { }
}

#pragma mark - 跨进程通知

void SMGPostPrefsChanged(void) {
    @try {
        CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
        if (c) CFNotificationCenterPostNotification(c,
                    CFSTR("com.blr.safemodeguard/prefsChanged"), NULL, NULL, true);
    } @catch (__unused NSException *e) { }
}
