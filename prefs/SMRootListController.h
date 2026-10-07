#ifndef SMRootListController_h
#define SMRootListController_h

#import <UIKit/UIKit.h>

// ---------------------------------------------------------------------------
// PSListController 的私有声明（用 dynamic_lookup，不链接 Preferences.framework）
//
// ⚠️⚠️ `_specifiers` ivar 必须声明在**基类接口**里 —— 这是本项目踩过的坑：
//     PSListController 的表格数据源直接访问自己的 `_specifiers` ivar（编译期绑定），
//     子类若在别处声明，基类永远看到 nil，
//     现象就是「能点进面板，但整页空白」—— 而且不报任何错，极难排查。
//
// ⚠️ 另一个坑：`detail` 键会让 Preferences 框架自己实例化控制器，
//     框架假设 detail 是 PSListController 体系，给纯原生 UITableViewController
//     会「实例化即闪退」（无 OC 异常可捕获）。→ 本项目 plist 里全部用 action:。
// ---------------------------------------------------------------------------
@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
@end

@interface PSListController : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    @protected
    NSArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)reloadSpecifiers;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (UITableView *)table;
@end

// 主面板：保留 PSListController（Root.plist 驱动，最稳）
@interface SMRootListController : PSListController
@end

#endif /* SMRootListController_h */
