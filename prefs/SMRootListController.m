#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import "SMRootListController.h"

// ===========================================================================
// 安全模式卫士 · 设置面板（PreferenceBundle 侧）
// ===========================================================================
//
// ⚠️⚠️ 重要：本二进制**不加载插件 dylib**（见技能库 §47「跨目标符号隔离」）
//    所以这里**不能**调用 SMGCommon.h 里 FOUNDATION_EXPORT 的任何函数 ——
//    编译能过（LDFLAGS 有 dynamic_lookup），装到手机上一点就崩。
//    ⇒ 本文件自己实现一份所需的读写逻辑，与插件端共用同一个目录与文件格式。
// ===========================================================================

// ------- 与插件端保持一致的常量（改动必须两边同步） -------
static NSString * const kSMGPrefsDomain   = @"com.blr.safemodeguard";
// ⚠️ 面板侧自定的版本常量：prefs 不加载 dylib，不能引 SMG_VERSION。
//    诊断页会把它与插件端写入日志的版本比对，不一致即"插件本体没加载"。
//    ⚠️ 它必须与 SMGCommon.h 的 SMG_VERSION 保持一致（check_local.py 会校验）。
static NSString * const kSMGPrefsVersion  = @"0.1.0";

static NSString *SMGPrefsSharedDir(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *base = @"/var/mobile/Documents";
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:base]) {
            NSString *doc = NSSearchPathForDirectoriesInDomains(
                NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            base = doc.length ? doc : NSTemporaryDirectory();
        }
        dir = [base stringByAppendingPathComponent:@"安全模式卫士"];
    });
    return dir;
}

static NSString *SMGPrefsPath(NSString *name) {
    return [SMGPrefsSharedDir() stringByAppendingPathComponent:name];
}

// ------- 面板侧日志（格式与插件端一致，写同一个文件，时间线能对上） -------
static void SMPrefsLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

static void SMPrefsLog(NSString *fmt, ...) {
    @try {
        va_list ap;
        va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);

        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *d = SMGPrefsSharedDir();
        if (![fm fileExistsAtPath:d]) {
            [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
            [fm setAttributes:@{NSFilePosixPermissions: @(0777)} ofItemAtPath:d error:NULL];
        }
        NSString *line = [NSString stringWithFormat:@"[%@] 设置进程 pid=%d %@\n",
                          [NSDate date], (int)getpid(), msg ?: @""];
        NSString *path = SMGPrefsPath(@"_bootlog.txt");
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

// ------- 配置读写（与插件端同款：suite + 共享 plist 双写） -------
static id SMPrefsGet(NSString *key) {
    @try {
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kSMGPrefsDomain];
        id v = [d objectForKey:key];
        if (v) return v;
        NSDictionary *f = [NSDictionary dictionaryWithContentsOfFile:SMGPrefsPath(@"_config.plist")];
        return f[key];
    } @catch (__unused NSException *e) { return nil; }
}

static void SMPrefsSet(NSString *key, id value) {
    @try {
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kSMGPrefsDomain];
        if (value) [d setObject:value forKey:key]; else [d removeObjectForKey:key];
        [d synchronize];

        NSMutableDictionary *all = [NSMutableDictionary dictionary];
        NSDictionary *old = [NSDictionary dictionaryWithContentsOfFile:SMGPrefsPath(@"_config.plist")];
        if (old.count) [all addEntriesFromDictionary:old];
        if (value) all[key] = value; else [all removeObjectForKey:key];
        [all writeToFile:SMGPrefsPath(@"_config.plist") atomically:YES];
    } @catch (__unused NSException *e) { }
}

// ------- 状态读取（只读插件端写的文件） -------
static NSInteger SMPrefsIntFromFile(NSString *name, NSInteger def) {
    @try {
        NSString *s = [NSString stringWithContentsOfFile:SMGPrefsPath(name)
                                                encoding:NSUTF8StringEncoding error:NULL];
        return s ? (NSInteger)[s integerValue] : def;
    } @catch (__unused NSException *e) { return def; }
}

static NSString *SMPrefsSafeModeFlagPath(void) { return @"/var/mobile/.eksafemode"; }

static BOOL SMPrefsSafeModeFlagExists(void) {
    @try {
        return [[NSFileManager defaultManager] fileExistsAtPath:SMPrefsSafeModeFlagPath()];
    } @catch (__unused NSException *e) { return NO; }
}

// 读出插件端最近一次「启动横幅」里的版本号，用于与 kSMGPrefsVersion 比对。
// 返回 nil = 日志里找不到启动横幅（插件本体没加载 / 从没跑过）。
static NSString *SMPrefsPluginVersionFromLog(void) {
    @try {
        NSString *log = [NSString stringWithContentsOfFile:SMGPrefsPath(@"_bootlog.txt")
                                                  encoding:NSUTF8StringEncoding error:NULL];
        if (!log.length) return nil;
        NSArray<NSString *> *lines = [log componentsSeparatedByString:@"\n"];
        // 从后往前找最后一条启动横幅
        for (NSInteger i = (NSInteger)lines.count - 1; i >= 0; i--) {
            NSString *l = lines[(NSUInteger)i];
            NSRange r = [l rangeOfString:@"SafeModeGuard "];
            NSRange r2 = [l rangeOfString:@" 启动"];
            if (r.location == NSNotFound || r2.location == NSNotFound) continue;
            NSInteger from = (NSInteger)(r.location + r.length);
            NSInteger to = (NSInteger)r2.location;
            if (to <= from) continue;
            NSString *ver = [l substringWithRange:NSMakeRange((NSUInteger)from,
                                                             (NSUInteger)(to - from))];
            ver = [ver stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (ver.length) return ver;
        }
        return nil;
    } @catch (__unused NSException *e) { return nil; }
}

#pragma mark - 控制器

// ⭐ C 函数必须在 @implementation **之前**声明 ——
//    （技能库 §42：类方法必须在 @implementation 里面，而 C 函数反过来要先声明）
static void SMRootListControllerPrefsChanged(CFNotificationCenterRef center,
                                             void *observer,
                                             CFStringRef name,
                                             const void *object,
                                             CFDictionaryRef userInfo);

@implementation SMRootListController

- (id)init {
    self = [super init];
    if (self) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)self,
                                        SMRootListControllerPrefsChanged,
                                        CFSTR("com.blr.safemodeguard/prefsChanged"),
                                        NULL, CFNotificationSuspensionBehaviorCoalesce);
    }
    return self;
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
    SMPrefsLog(@"[设置] ✅ 打开「安全模式卫士」面板（面板版本 %@）", kSMGPrefsVersion);
}

#pragma mark 状态摘要

- (id)readStateSummary:(PSSpecifier *)spec {
    @try {
        NSInteger fails = SMPrefsIntFromFile(@"_failcount.txt", 0);
        NSInteger total = SMPrefsIntFromFile(@"_boottotal.txt", 0);
        // ⚠️ 别套两层 integerValue：SMGPrefsGet 返回 id，
        //    `SMPrefsGet(...) ?: @3` 已是 id，再发一次 integerValue 到 NSInteger 上就类型错乱。
        id rawMax = SMPrefsGet(@"maxFailCount");
        NSInteger maxN = rawMax ? [rawMax integerValue] : 3;
        BOOL sm = SMPrefsSafeModeFlagExists();

        NSString *state = sm ? @"🔴 已写入安全模式标记" : @"🟢 正常";
        return [NSString stringWithFormat:@"状态：%@\n连续异常启动：%ld / %ld\n累计启动次数：%ld",
                state, (long)fails, (long)maxN, (long)total];
    } @catch (__unused NSException *e) { return @"（读取失败）"; }
}

- (id)readVersionDiag:(PSSpecifier *)spec {
    @try {
        NSString *pluginVer = SMPrefsPluginVersionFromLog();
        if (!pluginVer) {
            return [NSString stringWithFormat:
                @"面板版本：%@\n插件版本：（日志里找不到启动横幅）\n\n⚠️ 这说明插件本体没有在 SpringBoard 里加载过。\n请确认：① 已安装主插件包；② 已重启桌面。",
                kSMGPrefsVersion];
        }
        BOOL same = [pluginVer isEqualToString:kSMGPrefsVersion];
        return [NSString stringWithFormat:
            @"面板版本：%@\n插件版本：%@\n\n%@",
            kSMGPrefsVersion, pluginVer,
            same ? @"✅ 版本一致，插件本体已正常加载。"
                 : @"⚠️ 版本不一致 → 插件本体没加载（你看到的面板是旧的，或主包没装上）。"];
    } @catch (__unused NSException *e) { return @"（读取失败）"; }
}

- (id)readBootHistory:(PSSpecifier *)spec {
    @try {
        NSString *p = SMGPrefsPath(@"_history.plist");
        NSArray *a = [NSArray arrayWithContentsOfFile:p];
        if (!a.count) return @"（暂无启动记录）";
        NSMutableString *out = [NSMutableString string];
        // 倒序：最新在前
        NSInteger shown = 0;
        for (NSInteger i = (NSInteger)a.count - 1; i >= 0 && shown < 12; i--, shown++) {
            [out appendFormat:@"%@\n", a[(NSUInteger)i]];
        }
        return out.length ? out : @"（暂无启动记录）";
    } @catch (__unused NSException *e) { return @"（读取失败）"; }
}

#pragma mark 动作（全部无参，与已验证可用的兄弟同款形态）

- (void)smgEnterSafeMode {
    @try {
        NSString *content = [NSString stringWithFormat:
            @"SafeModeGuard %@\n%@\n用户从设置面板手动写入。\n",
            kSMGPrefsVersion, [NSDate date]];
        NSError *err = nil;
        // atomically:YES 时不能传 error:，用 NSData 写法
        NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
        BOOL ok = [data writeToFile:SMPrefsSafeModeFlagPath()
                            options:NSDataWritingAtomic error:&err];
        SMPrefsLog(@"[设置] 手动进入安全模式：%@（%@）", ok ? @"成功" : @"失败",
                   err.localizedDescription ?: @"无错误信息");
        [self reloadSpecifiers];

        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:(ok ? @"已写入安全模式标记" : @"写入失败")
                             message:(ok ? @"下次重启后将跳过全部插件注入（进入安全模式）。\n\n要退出安全模式，请在本面板点「退出安全模式」。"
                                         : [NSString stringWithFormat:@"%@\n\n可能是权限问题，日志已记录。", err.localizedDescription ?: @""])
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    } @catch (__unused NSException *e) { }
}

- (void)smgExitSafeMode {
    @try {
        BOOL existed = SMPrefsSafeModeFlagExists();
        NSError *err = nil;
        BOOL ok = YES;
        if (existed) {
            ok = [[NSFileManager defaultManager] removeItemAtPath:SMPrefsSafeModeFlagPath()
                                                            error:&err];
        }
        SMPrefsLog(@"[设置] 退出安全模式：%@（原本%@）",
                   ok ? @"成功" : @"失败", existed ? @"存在标记" : @"无标记");
        [self reloadSpecifiers];

        NSString *msg = nil;
        if (!existed)      msg = @"当前本来就没有安全模式标记。";
        else if (ok)       msg = @"已删除安全模式标记。\n下次重启将正常加载全部插件。";
        else               msg = [NSString stringWithFormat:@"删除失败：%@",
                                  err.localizedDescription ?: @""];
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:(ok ? @"已退出安全模式" : @"操作失败")
                             message:msg
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    } @catch (__unused NSException *e) { }
}

- (void)smgResetState {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:SMGPrefsPath(@"_pending.txt") error:NULL];
        [fm removeItemAtPath:SMGPrefsPath(@"_failcount.txt") error:NULL];
        [fm removeItemAtPath:SMGPrefsPath(@"_boottotal.txt") error:NULL];
        [fm removeItemAtPath:SMGPrefsPath(@"_history.plist") error:NULL];
        SMPrefsLog(@"[设置] 已重置全部启动状态计数");
        [self reloadSpecifiers];

        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"已重置"
                             message:@"连续异常启动计数、累计启动次数、启动历史均已清空。\n（安全模式标记不受影响）"
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    } @catch (__unused NSException *e) { }
}

- (void)smgShowLog {
    @try {
        NSString *log = [NSString stringWithContentsOfFile:SMGPrefsPath(@"_bootlog.txt")
                                                  encoding:NSUTF8StringEncoding error:NULL];
        if (!log.length) log = @"（暂无日志。插件可能还没在 SpringBoard 里跑过。）";
        // 只显示尾部，避免超长
        if (log.length > 12000) {
            log = [NSString stringWithFormat:@"…（仅显示最近部分）…\n%@",
                   [log substringFromIndex:log.length - 12000]];
        }
        UIViewController *vc = [UIViewController new];
        vc.title = @"运行日志";
        UITextView *tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
        tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tv.editable = NO;
        tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        tv.text = log;
        [vc.view addSubview:tv];
        [self.navigationController pushViewController:vc animated:YES];
    } @catch (__unused NSException *e) { }
}

- (void)smgClearLog {
    @try {
        [[NSFileManager defaultManager] removeItemAtPath:SMGPrefsPath(@"_bootlog.txt") error:NULL];
        SMPrefsLog(@"[设置] 已清空运行日志");
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"已清空" message:@"运行日志已删除。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    } @catch (__unused NSException *e) { }
}

// 开关：总开关（需要同步刷新其它行的可用状态）
- (void)setEnabledPref:(id)value specifier:(PSSpecifier *)spec {
    @try {
        SMPrefsSet(@"enabled", value);
        SMPrefsLog(@"[设置] 总开关 → %@", [value boolValue] ? @"开" : @"关");
    } @catch (__unused NSException *e) { }
}

- (id)getEnabledPref:(PSSpecifier *)spec {
    @try {
        id v = SMPrefsGet(@"enabled");
        return v ? @([v boolValue]) : @YES;
    } @catch (__unused NSException *e) { return @YES; }
}

@end

// 跨进程通知回调：插件改了状态后刷新面板
// （定义放在 @end 之后，声明已在 @implementation 之前给出）
static void SMRootListControllerPrefsChanged(CFNotificationCenterRef center,
                                             void *observer,
                                             CFStringRef name,
                                             const void *object,
                                             CFDictionaryRef userInfo) {
    @try {
        SMRootListController *ctl = (__bridge SMRootListController *)observer;
        if (!ctl) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            @try { [ctl reloadSpecifiers]; } @catch (__unused NSException *e) { }
        });
    } @catch (__unused NSException *e) { }
}
