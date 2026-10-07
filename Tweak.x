#import <UIKit/UIKit.h>
#import <unistd.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import "SMGCommon.h"

// ===========================================================================
// 安全模式卫士 · SpringBoard 侧
// ===========================================================================
//
// 本文件只做两件事：
//   ① %ctor 里尽早「记账」（判定上一轮 + 写下本轮 pending）
//   ② 延迟 N 秒后确认 SpringBoard 真的活着 → 「销号」
//
// ⚠️ 严禁事项（来自 DecoyLock 的血泪，见技能库 §48）：
//   - 禁止 makeKeyAndVisible / 抢 key window（会让锁屏点不动）
//   - 禁止自建窗口、禁止碰视图树
//   - 本插件是纯后台逻辑，绝不在界面上留任何痕迹
//
// ⚠️ 存活确认的设计要点：
//   不能只用「延迟 N 秒然后销号」—— 那样如果 SpringBoard 在 N-1 秒被杀，
//   我们就销号了，反而漏判。必须**先验证界面真的在了**再销号。
//
//   判定「SpringBoard 活着」的证据（分级，任一成立即可）：
//     a) 能取到 keyWindow 且 windowScene 已连接
//     b) 能取到 UIApplication 且 applicationState 不是后台
//     c) 兜底：连续多轮重试都失败才认为没活
//   并且重试机制：每 2 秒试一次，直到超过 N 秒才放弃。
// ===========================================================================

static NSString * const kSMGBundleID = @"com.apple.springboard";

static BOOL SMGIsSpringBoard(void) {
    static BOOL isSB = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bid = [NSBundle mainBundle].bundleIdentifier;
        isSB = [bid isEqualToString:kSMGBundleID];
    });
    return isSB;
}

#pragma mark - 存活判定

// 判定当前 SpringBoard 是否「真的起来了」。
// 返回 YES = 有充分证据说明界面已经可用。
static BOOL SMGSystemLooksAlive(void) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        if (!app) return NO;

        // 证据 a：能拿到 keyWindow / 任一已连接 scene 的窗口
        BOOL hasWindow = NO;
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in app.connectedScenes) {
                if (![s isKindOfClass:[UIWindowScene class]]) continue;
                UIWindowScene *ws = (UIWindowScene *)s;
                if (ws.activationState == UISceneActivationStateUnattached) continue;
                if (ws.windows.count > 0) { hasWindow = YES; break; }
            }
        }
        if (!hasWindow) {
            // 老接口兜底
            NSArray *wins = app.windows;
            if (wins.count > 0) hasWindow = YES;
        }
        if (!hasWindow) return NO;

        // 证据 b：应用状态不是「正在后台」
        //   注意：SpringBoard 的 applicationState 与普通 App 不同，
        //   这里只排除 Active 之外的极端情况，不做强约束。
        UIApplicationState st = app.applicationState;
        if (st == UIApplicationStateBackground) {
            // 有可能是启动瞬间的过渡态，不据此判死 —— 交给重试机制
            // 但也不被认为是"活着"，让下一轮重试
            return NO;
        }

        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

#pragma mark - 存活确认轮次

static int  gSMGAliveRounds = 0;
static BOOL gSMGConfirmed = NO;

static void SMGAliveRound(void) {
    @try {
        if (gSMGConfirmed) return;
        if (!SMGIsSpringBoard()) return;

        gSMGAliveRounds++;
        BOOL alive = SMGSystemLooksAlive();

        if (alive) {
            gSMGConfirmed = YES;
            SMGLog(@"[存活] 第 %d 轮确认 SpringBoard 界面已就绪 → 销号", gSMGAliveRounds);
            SMGBootConfirmAlive();
            return;
        }

        // 还没就绪 → 再等 2 秒重试，直到超过配置的超时时间
        double elapsed = (double)gSMGAliveRounds * 2.0;
        double limit = SMGAliveDelay();

        if (elapsed >= limit) {
            // ⭐ 超时仍未确认 → 不再重试。
            //    ⚠️ 关键：这里**故意不销号**（pending 保持存在）。
            //    下一轮启动时会因此判为异常 → 计数 +1 → 最终触发安全模式。
            //    这正是"黑屏超过 N 秒"的落地方式。
            SMGLog(@"[存活] ⏱️ 已等待 %.0f 秒仍未确认界面就绪（上限 %.0f 秒）→ 保持未销号",
                  elapsed, limit);
            gSMGConfirmed = YES;   // 停掉重试（不是"确认存活"，是"结束等待"）
            return;
        }

        SMGLog(@"[存活] 第 %d 轮：界面尚未就绪（已等 %.0f 秒 / 上限 %.0f 秒），2 秒后重试",
              gSMGAliveRounds, elapsed, limit);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ SMGAliveRound(); });
    } @catch (__unused NSException *e) { }
}

#pragma mark - 启动

static void SMGBoot(void) {
    @try {
        if (!SMGIsSpringBoard()) return;

        // —— ① 记账（必须最先做，越早越好） ——
        BOOL lastAbnormal = SMGBootBegin();

        // ⭐ 启动横幅：一眼看出插件是否加载、版本是否对、上一轮是否异常
        SMGLog(@"========== SafeModeGuard %@ 启动（上一轮%@）==========",
               SMG_VERSION, lastAbnormal ? @"异常 ⚠️" : @"正常");

        // 若已处于安全模式（标记存在），说明上一轮已经触发过 —— 提示用户
        if (SMGSafeModeFlagExists()) {
            SMGLog(@"[状态] ⚠️ 安全模式标记存在：%@", SMGSafeModeFlagPath());
            SMGLog(@"[状态] 说明上一次已判定为无限注销循环 → 进系统后请打开 Sileo 卸载问题插件，"
                   @"再到「设置 → 安全模式卫士」点「退出安全模式」。");
        }

        // —— ② 安排存活确认 ——
        double delay = SMGAliveDelay();
        SMGLog(@"[存活] 将在 %.0f 秒后开始确认 SpringBoard 是否存活", delay);

        // 首次确认：等 delay 秒后开始（这段窗口就是"观察期"）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            gSMGAliveRounds = 0;
            SMGAliveRound();
        });
    } @catch (__unused NSException *e) { }
}

#pragma mark - 构造器

%ctor {
    @autoreleasepool {
        // ⭐ 尽早执行：%ctor 在任何 UI 之前，这是"记账"的最佳时机。
        //    ⚠️ 不要把记账放到 dispatch_after 里 —— 那样如果 SpringBoard
        //       在延迟期间就被杀了，这一轮的 pending 根本没写下来。
        if (SMGIsSpringBoard()) {
            SMGBoot();
        }
    }
}
