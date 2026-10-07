#ifndef SMGCommon_h
#define SMGCommon_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <unistd.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define SMG_VERSION      @"0.1.0"
#define SMG_PREFS_DOMAIN @"com.blr.safemodeguard"

// ---------------------------------------------------------------------------
// 设计说明（写给自己和未来的维护者）
// ---------------------------------------------------------------------------
//
// 【要解决的问题】
//   某个插件导致设备「无限注销 / 黑屏」，SpringBoard 反复被杀重启，
//   用户进不了系统，也就没法打开 Sileo 卸载问题插件 —— 设备事实上变砖。
//
// 【为什么不能「在黑屏时计时 30 秒然后动手」】
//   本插件跑在 SpringBoard 进程里。无限注销时 SpringBoard 正在被反复杀死，
//   任何留在内存中的计时器都会随着进程一起消失，永远数不满 30 秒。
//   ⇒ 唯一活得过「反复重启」的地方是**磁盘**。
//
// 【本插件的机制（记账 + 销号）】
//   把「黑屏超过 N 秒」翻译成磁盘上可判定的等价物：
//
//   ① %ctor（进程刚起来，比任何 UI 都早）
//        读磁盘 pending 标记：如果上一轮留下的「进行中」标记还在，
//        说明上一轮没能走到销号那一步 → 上一轮 = 异常启动 → failCount++
//        然后写下本轮的「进行中」标记。
//
//   ② 启动后延迟 N 秒（默认 30 秒，可调）
//        确认 SpringBoard 真的活着（拿到 keyWindow / 界面已呈现）
//        → 删除「进行中」标记 = 销号，说明本轮是**正常启动**。
//
//   ③ 下一轮启动时若发现 pending 标记仍在
//        → 上一轮没活过 N 秒 → failCount++
//        failCount >= 阈值（默认 3）→ 判定设备已陷入无限注销循环
//        → 创建 /var/mobile/.eksafemode（ElleKit 官方安全模式标记）
//        → 下次重启时 ElleKit 跳过全部插件注入 = 进入安全模式
//        → 用户得以进入系统，打开 Sileo 卸载问题插件。
//
// 【这个机制的关键优点】
//   **不需要知道是哪个插件搞的鬼，也不需要赶在崩溃前写完磁盘。**
//   只要「起来了又死掉」这个事实在磁盘上留下痕迹就够了。
//   而且它是 fail-safe 的：本插件自己崩了也不会让情况变坏
//   （pending 标记还在 → 只会让计数继续涨，更快触发保护）。
//
// 【安全约束】
//   - 所有磁盘 IO 包 @try，任何失败都静默跳过，绝不因 IO 问题影响 SpringBoard
//   - 正常启动一定销号，绝不因误判把用户送进安全模式
//   - 提供「一键退出安全模式」，用户误判后能自救
//   - 存活确认失败时 fail-open（宁可不清计数，也不要错误地留下 pending
//     —— 注意：留下 pending 会让计数涨，是"更保守"的方向，这是安全的）
//
// ---------------------------------------------------------------------------

// 共享配置目录（SpringBoard 进程与「设置」进程都能写的位置）
FOUNDATION_EXPORT NSString *SMGSharedDir(void);
FOUNDATION_EXPORT NSString *SMGConfigPath(void);
FOUNDATION_EXPORT NSString *SMGBootLogPath(void);
FOUNDATION_EXPORT NSString *SMGPendingPath(void);

// ElleKit 官方安全模式标记
//   依据（ElleKit 源码 libinjector）：safe mode 在下列任一条件成立时启用
//     ① 环境变量 _MSSafeMode == "1"
//     ② 环境变量 _SafeMode   == "1"
//     ③ 文件 /var/mobile/.eksafemode 存在   ← 我们用的就是这条
//   效果：libinjector 不再注入任何常规插件（只加载安全模块）
//   另：ElleKit 自带「SpringBoard 启动失败自动进安全模式」，是第二道保险。
FOUNDATION_EXPORT NSString *SMGSafeModeFlagPath(void);

// 读写配置（NSUserDefaults suite + 共享 plist 双写，与 DecoyLock 同款做法）
FOUNDATION_EXPORT id   SMGConfigGet(NSString *key);
FOUNDATION_EXPORT void SMGConfigSet(NSString *key, id value);
FOUNDATION_EXPORT NSDictionary *SMGConfigAll(void);

// 便捷读取（带默认值，保证配置面板没打开过也能跑）
FOUNDATION_EXPORT BOOL     SMGEnabled(void);          // 总开关，默认 YES
FOUNDATION_EXPORT NSInteger SMGMaxFailCount(void);    // 连续异常启动阈值，默认 3
FOUNDATION_EXPORT double   SMGAliveDelay(void);       // 存活确认延迟秒数，默认 30
FOUNDATION_EXPORT BOOL     SMGAutoSafeMode(void);     // 达阈值是否自动进安全模式，默认 YES

// ------------------------------ 核心状态机 ------------------------------

// ① 启动时调用（%ctor 里，越早越好）。
//    返回：上一轮是否被判定为「异常启动」。
//    副作用：pending 标记的检查 / failCount 累加 / 本轮 pending 落盘。
FOUNDATION_EXPORT BOOL SMGBootBegin(void);

// ② 存活确认通过时调用 —— 销号。
//    副作用：删除 pending 标记、failCount 清零、写正常启动记录。
FOUNDATION_EXPORT void SMGBootConfirmAlive(void);

// ③ 查询 / 修改计数（供设置面板使用）
FOUNDATION_EXPORT NSInteger SMGFailCount(void);
FOUNDATION_EXPORT void      SMGSetFailCount(NSInteger n);
FOUNDATION_EXPORT NSInteger SMGBootTotal(void);        // 累计启动轮次（仅供展示）

// ④ 安全模式标记的读写
FOUNDATION_EXPORT BOOL SMGSafeModeFlagExists(void);
FOUNDATION_EXPORT BOOL SMGEnterSafeMode(NSString *reason);   // 写入标记，返回是否成功
FOUNDATION_EXPORT BOOL SMGExitSafeMode(void);                // 删除标记

// ⑤ 手动清空所有状态（设置面板「重置」用）
FOUNDATION_EXPORT void SMGResetAllState(void);

// ⑥ 启动历史（追加式，最新在后），供面板展示
FOUNDATION_EXPORT NSArray<NSString *> *SMGBootHistory(void);
FOUNDATION_EXPORT void SMGClearBootHistory(void);

// 探针（诊断日志，Filza 友好，追加式）
FOUNDATION_EXPORT void SMGLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
FOUNDATION_EXPORT NSString *SMGLogRead(void);
FOUNDATION_EXPORT void SMGLogClear(void);

// 调用「设置」进程刷新面板（跨进程通知）
FOUNDATION_EXPORT void SMGPostPrefsChanged(void);

#endif /* SMGCommon_h */
