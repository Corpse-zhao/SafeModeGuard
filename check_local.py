#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SafeModeGuard 本地预检 —— 把 CI 里的静态检查搬到本地跑，省 CI 轮次。

用法：  python check_local.py
（在工程根目录执行）

⚠️ 本脚本的检查项必须与 .github/workflows/build.yml 的 Preflight 保持一致。
   两边不同步 = 本地绿而 CI 红，白等一轮。
"""
import io
import os
import re
import glob
import sys

FAIL = 0
HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)


def read(path):
    try:
        return io.open(path, encoding="utf-8", errors="replace").read()
    except IOError:
        return ""


def strip_comments(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    s = re.sub(r"//[^\n]*", "", s)
    return s


def fail(msg):
    global FAIL
    print("   " + msg)
    FAIL = 1


# ---------------------------------------------------------------------------
print("--- 检查 1：%hook 类必须真实存在（本项目应无 %hook）---")
tw = read("Tweak.x")
hits = [l for l in tw.splitlines() if re.match(r"^%hook\s", l)]
if hits:
    fail("❌ Tweak.x 出现了 %hook：%s" % hits)
    fail("   本插件不需要 hook 任何方法（纯记账逻辑）")
else:
    print("   ✅ 无 %hook")

# ---------------------------------------------------------------------------
print("--- 检查 2：主插件禁止自建窗口 / 抢 key window ---")
bad = []
for f in ["Tweak.x", "SMGCommon.m"]:
    for i, line in enumerate(read(f).splitlines(), 1):
        s = line.strip()
        if s.startswith("//") or s.startswith("*") or s.startswith("/*"):
            continue
        if re.search(r"makeKeyAndVisible|UIWindow\s*\*|addSubview", line):
            bad.append("%s:%d %s" % (f, i, s))
if bad:
    fail("❌ 检测到窗口操作：")
    for b in bad:
        fail("     " + b)
    fail("   本插件是纯后台逻辑，绝不允许碰界面")
else:
    print("   ✅ 无界面操作")

# ---------------------------------------------------------------------------
print("--- 检查 3：记账必须在 %ctor 顶层，不能藏在延迟回调里 ---")
m = re.search(r"%ctor\s*\{(.*?)\n\}", tw, re.S)
if not m:
    fail("❌ 找不到 %ctor 块")
else:
    body = strip_comments(m.group(1))
    if "SMGBoot()" not in body:
        fail("❌ %ctor 里没有调用 SMGBoot()")
    else:
        # 剥掉 dispatch_after 整块，再看 SMGBoot 是否还在
        stripped = re.sub(r"dispatch_after\s*\((?:[^()]|\([^()]*\))*\)\s*;", "", body)
        if "SMGBoot()" not in stripped:
            fail("❌ SMGBoot() 只出现在 dispatch_after 里 → 记账被延迟，会漏判")
        else:
            print("   ✅ 记账在 %ctor 顶层同步执行")

# ---------------------------------------------------------------------------
print("--- 检查 4：记账（写 pending）必须先于任何延迟 ---")
m = re.search(r"static void SMGBoot\(void\)\s*\{(.*?)\n\}", tw, re.S)
if not m:
    fail("❌ 找不到 SMGBoot 函数体")
else:
    body = strip_comments(m.group(1))
    i_begin = body.find("SMGBootBegin()")
    i_delay = body.find("dispatch_after")
    if i_begin < 0:
        fail("❌ SMGBoot 里没有 SMGBootBegin()")
    elif i_delay >= 0 and i_begin > i_delay:
        fail("❌ SMGBootBegin() 排在 dispatch_after 之后 → 记账被延迟")
    else:
        print("   ✅ 记账先于延迟")

# ---------------------------------------------------------------------------
print("--- 检查 5：存活确认必须「先验证界面再销号」---")
t = strip_comments(tw)
if "SMGSystemLooksAlive" not in t:
    fail("❌ 缺少 SMGSystemLooksAlive")
m = re.search(r"static void SMGAliveRound\(void\)\s*\{(.*?)\n\}", t, re.S)
if not m:
    fail("❌ 找不到 SMGAliveRound")
else:
    body = m.group(1)
    if "SMGSystemLooksAlive()" not in body:
        fail("❌ SMGAliveRound 未调用 SMGSystemLooksAlive()")
    if not re.search(r"if\s*\(\s*alive\s*\)\s*\{[^}]*SMGBootConfirmAlive\(\)", body, re.S):
        fail("❌ SMGBootConfirmAlive() 不在 if (alive) 分支里 → 会裸销号")
    # 超时分支必须不销号
    m2 = re.search(r"elapsed\s*>=\s*limit\s*\)?\s*\{(.*?)\n\s*\}", body, re.S)
    if m2 and "SMGBootConfirmAlive" in m2.group(1):
        fail("❌ 超时分支里调用了 SMGBootConfirmAlive() → 保护彻底失效")
    else:
        print("   ✅ 存活确认=先验证；超时不销号")

# ---------------------------------------------------------------------------
print("--- 检查 6：磁盘 IO 必须全部包 @try ---")
src = read("SMGCommon.m")
bad = []
for mm in re.finditer(r"\n(?:static\s+)?[\w\s\*<>]*?(\w+)\s*\([^;{]*\)\s*\{(.*?)\n\}", src, re.S):
    name, body = mm.group(1), mm.group(2)
    if not re.search(r"writeToFile|removeItemAtPath|contentsOfFile|createDirectoryAtPath"
                     r"|fileHandleForWriting|setAttributes", body):
        continue
    if "@try" not in body:
        bad.append(name)
if bad:
    fail("❌ 以下含磁盘操作的函数缺 @try：%s" % sorted(set(bad)))
else:
    print("   ✅ 含磁盘操作的函数都有 @try")

# ---------------------------------------------------------------------------
print("--- 检查 7：写入必须原子 ---")
if re.search(r"writeToFile:[^;]*atomically:YES", src):
    print("   ✅ 使用原子写")
else:
    fail("❌ 未检测到原子写")

# ---------------------------------------------------------------------------
print("--- 检查 8：必须使用 ElleKit 官方安全模式标记路径 ---")
if re.search(r'"/var/mobile/\.eksafemode"', read("SMGCommon.h") + src):
    print("   ✅ /var/mobile/.eksafemode")
else:
    fail("❌ 找不到 ElleKit 官方标记路径")

# ---------------------------------------------------------------------------
print("--- 检查 9：prefs 侧禁止调用插件端符号 ---")
h = read("SMGCommon.h")
exported = set(re.findall(r"FOUNDATION_EXPORT\s+[\w\s\*<>]*?\b(\w+)\s*\(", h))
bad = []
for p in sorted(glob.glob("prefs/*.m") + glob.glob("prefs/*.h")):
    s = strip_comments(read(p))
    for sym in sorted(exported):
        if re.search(r"(?<![\w])" + re.escape(sym) + r"\s*\(", s):
            bad.append((p, sym))
if bad:
    fail("❌ prefs 侧调用了插件端符号（装机即崩）：")
    for p, s in bad:
        fail("     %s → %s" % (p, s))
else:
    print("   ✅ 符号隔离正确（导出 %d 个符号，prefs 无引用）" % len(exported))

# ---------------------------------------------------------------------------
print("--- 检查 10/11：Root.plist 的 action / get / set 必须有实现 ---")
p = read("prefs/Resources/Root.plist")
pm = strip_comments(read("prefs/SMRootListController.m"))
methods = set(re.findall(r"^\s*-\s*\([^)]*\)\s*([A-Za-z_][A-Za-z0-9_]*)", pm, re.M))
bad = []
for a in sorted(set(re.findall(r'"action"\s*:\s*"([^"]+)"', p))):
    if a.split(":")[0] not in methods:
        bad.append(("action", a))
for g in sorted(set(re.findall(r'"get"\s*:\s*"([^"]+)"', p))):
    if g.split(":")[0] not in methods:
        bad.append(("get", g))
for s in sorted(set(re.findall(r'"set"\s*:\s*"([^"]+)"', p))):
    if s.split(":")[0] not in methods:
        bad.append(("set", s))
if bad:
    fail("❌ Root.plist 里以下键没有实现：")
    for k, v in bad:
        fail("     %s → %s" % (k, v))
else:
    print("   ✅ action / get / set 全部有实现")

# ---------------------------------------------------------------------------
print("--- 检查 12：日志格式串 % 转义 ---")
files = ["Tweak.x", "SMGCommon.m"] + sorted(glob.glob("prefs/*.m"))
call = re.compile(r'(?:SMGLog|SMPrefsLog)\s*\(\s*@"((?:[^"\\]|\\.)*)"')
conv = re.compile(r"%[-+ #0-9.*]*[lhqzjt]*[diouxXeEfgGaAcspn@]")
bad = []
for f in files:
    for i, line in enumerate(read(f).splitlines(), 1):
        m = call.search(line)
        if not m:
            continue
        s = m.group(1).replace("%%", "\x00")
        for mm in conv.finditer(s):
            nxt = s[mm.end():mm.end() + 2]
            if len(nxt) == 2 and all(c.isascii() and c.isalpha() for c in nxt):
                bad.append((f, i, m.group(1)))
                break
        else:
            if "%" in conv.sub("", s):
                bad.append((f, i, m.group(1)))
if bad:
    fail("❌ 以下日志格式串的 %% 未转义：")
    for f, i, s in bad:
        fail("   %s:%d  %s" % (f, i, s))
else:
    print("   ✅ 格式串检查通过")

# ---------------------------------------------------------------------------
print("--- 检查 13：重复 %hook 类 ---")
dup = [x for x in set(re.findall(r"^%hook\s+([A-Za-z_]\w*)", tw, re.M))
       if len(re.findall(r"^%hook\s+" + re.escape(x) + r"\s*$", tw, re.M)) > 1]
if dup:
    fail("❌ 重复 %hook 类：%s" % dup)
else:
    print("   ✅ 无重复")

# ---------------------------------------------------------------------------
print("--- 检查 14：static 变量声明了没用（-Werror）---")
bad = 0
for path in sorted(glob.glob("*.m") + glob.glob("prefs/*.m")):
    raw = read(path)
    t = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
    t = re.sub(r"//[^\n]*", "", t)
    t = re.sub(r'"(?:\\.|[^"\\])*"', '""', t)
    lines = t.splitlines()
    for i, l in enumerate(lines, 1):
        if not l or l[0].isspace():
            continue
        mm = re.match(r"static\s+(?:const\s+)?.*?\b(\w+)\s*(?:=[^;]*)?;\s*$", l)
        if not mm:
            continue
        if "(" in l and "=" not in l:
            continue
        name = mm.group(1)
        pat = re.compile(r"(?<![\w])" + re.escape(name) + r"(?![\w])")
        if not any(j != i and pat.search(o) for j, o in enumerate(lines, 1)):
            fail("❌ %s 第 %d 行 static 变量 `%s` 未使用" % (path, i, name))
            bad = 1
if not bad:
    print("   ✅ 无未使用 static 变量")

# ---------------------------------------------------------------------------
print("--- 检查 15：ARC 桥接 ---")
bad = 0
for path in sorted(glob.glob("*.m") + glob.glob("*.x") + glob.glob("prefs/*.m")):
    for i, line in enumerate(read(path).splitlines(), 1):
        if "__bridge" in line:
            continue
        s = line.strip()
        if s.startswith("//") or s.startswith("*") or s.startswith("/*"):
            continue
        for mm in re.finditer(r"\(\s*void\s*\*\s*\)\s*([A-Za-z_]\w*)", line):
            t = mm.group(1)
            if t.startswith("&") or re.match(r"^(old|orig|imp)$", t, re.I):
                continue
            fail("❌ %s 第 %d 行 `(void *)%s` 需 __bridge" % (path, i, t))
            bad = 1
if not bad:
    print("   ✅ ARC 桥接正确")

# ---------------------------------------------------------------------------
print("--- 检查 16：版本号四处一致 ---")
mm = re.search(r'#define\s+SMG_VERSION\s+@"([^"]+)"', h)
if not mm:
    fail("❌ 找不到 SMG_VERSION")
    ver = None
else:
    ver = mm.group(1)
    print("   插件版本 = %s" % ver)
    checks = [
        ("prefs/SMRootListController.m", r'kSMGPrefsVersion\s*=\s*@"([^"]+)"', "面板版本常量"),
        ("control", r"^Version:\s*(\S+)", "主包 control"),
        ("prefs/control", r"^Version:\s*(\S+)", "面板 control"),
        ("prefs/Resources/Info.plist", r'CFBundleShortVersionString\s*=\s*"([^"]+)"', "面板 Info.plist"),
    ]
    for path, pat, label in checks:
        txt = read(path)
        m2 = re.search(pat, txt, re.M)
        if not m2:
            fail("❌ %s 找不到版本号" % label)
        elif m2.group(1) != ver:
            fail("❌ %s 版本(%s) ≠ %s" % (label, m2.group(1), ver))
        else:
            print("   ✅ %s = %s" % (label, m2.group(1)))

# ---------------------------------------------------------------------------
print("--- 检查 17：启动横幅格式 ---")
if re.search(r"SafeModeGuard %@ 启动", tw):
    print("   ✅ 启动横幅用 SMG_VERSION 单一来源")
else:
    fail('❌ 启动横幅不是 "SafeModeGuard %@ 启动" 形式（面板版本自检靠它解析）')

# ---------------------------------------------------------------------------
print("--- 检查 18：括号平衡（粗检，确认没有截断的代码）---")
for f in ["Tweak.x", "SMGCommon.m", "SMGCommon.h", "prefs/SMRootListController.m"]:
    s = read(f)
    # 去掉字符串与注释再数
    s2 = re.sub(r'"(?:\\.|[^"\\])*"', '""', s)
    s2 = re.sub(r"//[^\n]*", "", s2)
    s2 = re.sub(r"/\*.*?\*/", "", s2, flags=re.S)
    for ch, name in [("{", "大括号"), ("(", "小括号")]:
        pair = {"{": "}", "(": ")"}[ch]
        a, b = s2.count(ch), s2.count(pair)
        if a != b:
            fail("❌ %s 的%s不平衡：%d 个 %s vs %d 个 %s" % (f, name, a, ch, b, pair))
print("   ✅ 括号平衡检查完成")

# ---------------------------------------------------------------------------
print("--- 检查 19：plist 结构（老式 ASCII plist，不用 plistlib）---")
# ⚠️ Theos 工程里的 plist 是 NeXTSTEP/ASCII 老式格式（`key = value;` + 花括号），
#    plistlib 只认 XML / 二进制 → 用它校验会全部误报 "Invalid file"。
#    正确做法：查「花括号/圆括号配平」+「必需键存在」+「没有明显的语法残缺」。
def check_ascii_plist(path, required_keys):
    s = read(path)
    if not s.strip():
        fail("❌ %s 是空文件" % path)
        return
    # 剥掉字符串字面量再数括号（字符串里可能含括号）
    t = re.sub(r'"(?:\\.|[^"\\])*"', '""', s)
    for op, cl, name in [("{", "}", "花括号"), ("(", ")", "圆括号")]:
        if t.count(op) != t.count(cl):
            fail("❌ %s 的%s不平衡：%d vs %d" % (path, name, t.count(op), t.count(cl)))
            return
    for k in required_keys:
        if not re.search(r"(?<![\w])" + re.escape(k) + r"(?![\w])", s):
            fail("❌ %s 缺少必需键 %s" % (path, k))
            return

check_ascii_plist("prefs/Resources/Root.plist", ["items", "cell", "label"])
check_ascii_plist("prefs/Resources/Info.plist",
                  ["CFBundleExecutable", "CFBundleIdentifier", "NSPrincipalClass"])
check_ascii_plist("SafeModeGuard.plist", ["Filter", "Bundles"])
check_ascii_plist("layout/Library/PreferenceLoader/Preferences/SafeModeGuard.plist",
                  ["entry", "bundle", "cell", "detail", "isController", "label"])
print("   ✅ 全部 plist 结构检查通过（ASCII 格式，括号配平 + 必需键齐全）")

# ---------------------------------------------------------------------------
print("--- 检查 19b：Info.plist 的 NSPrincipalClass 必须与实现类同名 ---")
ip = read("prefs/Resources/Info.plist")
mm = re.search(r"NSPrincipalClass\s*=\s*\"?([A-Za-z_]\w*)", ip)
if not mm:
    fail("❌ Info.plist 找不到 NSPrincipalClass")
else:
    cls = mm.group(1)
    if "@implementation " + cls not in read("prefs/SMRootListController.m"):
        fail("❌ NSPrincipalClass=%s 但 %s.m 里没有 @implementation %s" % (cls, cls, cls))
    else:
        print("   ✅ NSPrincipalClass=%s 与实现类一致" % cls)

# ---------------------------------------------------------------------------
print("--- 检查 20：入口 plist 必须是 entry 包裹 ---")
entry = read("layout/Library/PreferenceLoader/Preferences/SafeModeGuard.plist")
if "entry" in entry and "isController" in entry and "detail" in entry:
    print("   ✅ 入口 plist 用 entry 包裹 + detail 键")
else:
    fail("❌ 入口 plist 格式不对（必须是 { entry = { bundle/cell/detail/isController }; }）")

# ---------------------------------------------------------------------------
print("--- 检查 21：⭐ prefs 侧必须声明 PSListController（否则 19 连错）---")
# 血泪（2026-10-07 首轮 CI）：prefs 的 .m 只 import UIKit 是不够的 ——
# PSListController 是私有类，必须自己声明。漏了会级联出：
#   use of undeclared identifier '_specifiers'
#   no visible @interface ... declares the selector 'reloadSpecifiers'
# 共 19 个错误。而 Theos 只报第一个文件，看起来像"prefs 全烂了"。
#
# ⚠️⚠️ 本检查第一版是**无效的**（靠注入测试发现）：
#    写的是 `"_specifiers" in pm_hdr` —— 子串匹配，而头文件**注释里**也提到
#    _specifiers，于是恒为真、永远不报错。这正是 §54「子串匹配认错对象」。
#    ✅ 正解：剥掉注释后，在 **@interface PSListController { ... } 块内**精确查找。
pm_src = read("prefs/SMRootListController.m")
pm_hdr = read("prefs/SMRootListController.h")
hdr_nc = strip_comments(pm_hdr)          # ⭐ 必须先剥注释！

bad = []
if "@interface PSListController" not in hdr_nc:
    bad.append("prefs/SMRootListController.h 缺少 @interface PSListController 声明")
else:
    # 精确取 PSListController 的 ivar 块（花括号内）
    blk = re.search(r"@interface\s+PSListController\b[^{]*\{(.*?)\}", hdr_nc, re.S)
    if not blk:
        bad.append("PSListController 没有声明 ivar 块（{ ... }）")
    elif not re.search(r"(?<![\w])_specifiers(?![\w])", blk.group(1)):
        bad.append("PSListController 的 ivar 块里缺少 _specifiers"
                   "（缺了会「能进面板但整页空白」，且不报错）")
if "@interface PSSpecifier" not in hdr_nc:
    bad.append("缺少 @interface PSSpecifier 声明")
# .m 必须 import 自己那个头
if '#import "SMRootListController.h"' not in pm_src:
    bad.append('prefs/SMRootListController.m 没有 #import "SMRootListController.h"')
# .m 用了这些符号 → 头文件里必须有声明
#
# ⚠️⚠️ 变量名血泪（2026-10-07）：这里原本写的是 `src_nc = strip_comments(pm_src)`，
#     而 `src_nc` 在下面「v0.2.0 新增检查」里被当作 **SMGCommon.m 的剥注释正文**使用。
#     于是检查 21 悄悄把 src_nc 改成了 **prefs** 的内容，
#     导致检查 25~31 全部在找 prefs 里不可能存在的插件端函数
#     → 报了一堆「找不到 SMGNoteBootTimeAndCheckRapid / SMGRebootEnabled」，
#     看起来像"新代码没写进去"，实际是**检查脚本自己把变量覆盖了**。
#     ⇒ 教训：跨大段代码复用「剥注释正文」这种通用名变量，必然踩变量覆盖的坑。
#       各检查用各自带前缀的名字（pm_* = prefs，smg_* = 插件端）。
pm_nc_body = strip_comments(pm_src)
for sym in ["_specifiers", "reloadSpecifiers", "loadSpecifiersFromPlistName"]:
    if re.search(r"(?<![\w])" + re.escape(sym) + r"(?![\w])", pm_nc_body) and \
       not re.search(r"(?<![\w])" + re.escape(sym) + r"(?![\w])", hdr_nc):
        bad.append("prefs/.m 用了 %s 但头文件里没有声明" % sym)
if bad:
    for b in bad:
        fail("❌ " + b)
else:
    print("   ✅ PSListController 私有声明齐全（含 _specifiers ivar，已剥注释精确匹配）")

# ---------------------------------------------------------------------------
print("--- 检查 22：⭐ 调用的函数名必须真实存在（防「名字打错」隐式声明）---")
# 血泪：我把 SMPrefsPluginVersionFromLog() 写成了 SMGPrefsPluginVersionFromLog()
# （SMPrefs- vs SMG-），Clang 在 C99 下只报 warning + 隐式声明 int
# → 配合 ARC 变成 4 个 error，全在别人看着莫名其妙的行上。
# 做法：收集文件内所有函数定义名，再检查所有 `标识符(` 调用是否都有定义或外部声明。
#
# ⚠️⚠️ 变量名血泪（2026-10-07）：这里原本写的是 `src = strip_comments(read(path))`，
#     在循环里反复覆盖全局的 `src`（本应是 SMGCommon.m 的完整正文，见上方检查 6）。
#     循环最后一个文件是 Tweak.x → 循环结束后 `src` 变成了 **Tweak.x** 的内容！
#     于是后面检查 25~31 全在 Tweak.x 里找插件端函数 → 全部「找不到」。
#     ⇒ 这是同一次踩的**第二个变量覆盖坑**（第一个是 src_nc 被 prefs 覆盖）。
#       修法：循环内用局部名 `f_nc`，绝不复用外部通用名。
for path in ["prefs/SMRootListController.m", "SMGCommon.m", "Tweak.x"]:
    f_nc = strip_comments(read(path))
    defined = set(re.findall(r"\n\s*(?:static\s+)?[\w\s\*<>]*?\b(\w+)\s*\([^;{]*\)\s*\{", f_nc))
    defined |= set(re.findall(r"@implementation\s+(\w+)", f_nc))
    # 本项目自定义前缀：SMG(插件端) / SMPrefs(面板端)
    called = set(re.findall(r"(?<![\w.])(SMG|SMPrefs)([A-Z]\w*)\s*\(", f_nc))
    bad = []
    for pre, rest in sorted(called):
        name = pre + rest
        if name in defined:
            continue
        # 允许：已在头文件里声明的导出符号（插件端）
        if ("FOUNDATION_EXPORT" in read("SMGCommon.h")
                and re.search(r"FOUNDATION_EXPORT[^;]*\b" + re.escape(name) + r"\s*\(", read("SMGCommon.h"))):
            continue
        # 面板端不得引用插件端符号（检查 9 已管），这里只报「谁都没定义」
        bad.append(name)
    if bad:
        fail("❌ %s 里调用了未定义的函数（名字打错？）：" % path)
        for b in sorted(set(bad)):
            fail("     %s" % b)
if not FAIL or True:
    pass

# ---------------------------------------------------------------------------
print("--- 检查 23：⭐ 别把 integerValue 套两层 ---")
# 血泪：`[[SMPrefsGet(k) ?: @3 integerValue] integerValue]`
# 内层已返回 NSInteger，外层再发消息 → bad receiver type 'NSInteger'。
for path in sorted(glob.glob("prefs/*.m")):
    for i, line in enumerate(read(path).splitlines(), 1):
        s = strip_comments(line)
        if re.search(r"\?\:\s*@[\d.]+\s+integerValue\]\s*integerValue\]", s) or \
           re.search(r"integerValue\]\s*integerValue\]", s):
            fail("❌ %s 第 %d 行 integerValue 套了两层：%s" % (path, i, line.strip()))
print("   ✅ 无 double-integerValue")

# ---------------------------------------------------------------------------
print("--- 检查 24：⭐ DEBIAN 维护脚本必须可执行（否则打包阶段才失败）---")
# 血泪（2026-10-07 第二轮 CI）：编译全部通过（双切片链接签名正常），
# 却倒在最后打包：
#   ERROR: maintainer script 'postinst' has bad permissions 644
#   (must be >=0555 and <=0775)
# 根因：Windows 上 git 不记录可执行位，CI 克隆下来是 644。
# ⚠️ 只 chmod 本地文件**不够** —— 必须更新 **git 索引**里的权限位
#    （`git update-index --chmod=+x`），否则推上去还是 644。
#
# ⚠️⚠️ 另一个坑（本检查第一版就踩了）：**在 Windows 上 os.stat() 报的权限位不可信**。
#    Git Bash / MSYS 下新建文件恒被报成 666，`mode & 0o111` 永远为 0
#    → 会误报「没有可执行位」，即使文件在本机是 755。
#    ✅ 所以本地判据只能是 **git 索引里的 100755**（那才是 CI 实际拿到的东西）。
#    文件系统权限只做参考，不作判据（在本条 24b 里查）。
debian_dir = "layout/DEBIAN"
is_windows = (os.name == "nt")
if os.path.isdir(debian_dir):
    for name in sorted(os.listdir(debian_dir)):
        if name in ("postinst", "preinst", "postrm", "prerm"):
            p = os.path.join(debian_dir, name)
            st = os.stat(p)
            if is_windows:
                mode = st.st_mode & 0o777
                print("   ℹ️  %s 本机权限 %o（Windows 下不可信，不作为判据）" % (p, mode))
            else:
                mode = st.st_mode & 0o777
                if not (0o555 <= mode <= 0o775) or not (mode & 0o111):
                    fail("❌ %s 权限 %o 不合法（须 0555~0775 且含可执行位）" % (p, mode))
                else:
                    print("   ✅ %s 权限 %o" % (p, mode))
else:
    print("   （无 layout/DEBIAN 目录，跳过）")

print("--- 检查 24b：⭐ 维护脚本的 git 索引权限位必须是 100755（真正判据）---")
# ⚠️ 光看文件系统权限会漏 —— git 只存 100644 / 100755 两种。
#    Windows 上新建文件恒为 100644，必须显式 update-index --chmod=+x。
try:
    import subprocess
    out = subprocess.run(["git", "ls-files", "-s", debian_dir],
                         capture_output=True, text=True).stdout
    checked = 0
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 4:
            mode, path = parts[0], parts[3]
            if path.rsplit("/", 1)[-1] in ("postinst", "preinst", "postrm", "prerm"):
                checked += 1
                if mode != "100755":
                    fail("❌ git 索引里 %s 权限是 %s（应为 100755）" % (path, mode))
                    fail("   修复：git update-index --chmod=+x %s" % path)
                else:
                    print("   ✅ git 索引 %s = 100755" % path)
    if checked == 0:
        print("   （git 索引里没有维护脚本）")
except Exception as e:
    print("   （git 不可用，跳过索引检查：%s）" % e)

# ---------------------------------------------------------------------------
# 仅供「函数体提取」用的宽松花括号计数器。
# ⚠️ 不能用 `\{(.*?)\n\}` 非贪婪匹配 —— 只要函数体里有嵌套块（if/for/@try），
#    第一个 `\n}` 可能是内层块的收尾，会截出半截函数体 → 断言莫名其妙地失败。
#    （§63.7 的同款陷阱：校验工具自己出错，却看起来像代码有问题）
def find_body(src, header_regex):
    """在 src 里找匹配 header 的函数，返回其函数体字符串（不含最外层大括号）。"""
    m = re.search(header_regex, src)
    if not m:
        return None, None
    i = m.end() - 1                     # 指向 '{'
    if src[i] != "{":
        return None, None
    depth = 0
    for j in range(i, len(src)):
        c = src[j]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return src[i + 1:j], m.group(0)
    return None, None


print("--- 检查 24c：⭐ 用到的 C 库符号必须有对应 #import ---")
# 血泪（2026-10-07 v0.2.0）：SMGProbeRebootSymbol 用了 dlsym/RTLD_DEFAULT，
# 但 SMGCommon.h 没 import <dlfcn.h> → 编译报一串看着莫名的错（其实都是同一处）：
#   call to undeclared function 'dlsym'
#   declaration of 'dlsym' must be imported from module 'Darwin.POSIX.dlfcn'
#   conflicting types for 'dlsym'
#   use of undeclared identifier 'RTLD_DEFAULT'
# ⚠️ 而 Preflight 全绿 —— 静态检查有盲区：「符号用没用」查了，「头文件导没导」没查。
#    本检查补上：把「常见 C 库符号 → 必需头文件」做成表，双向核对。
#
# ⚠️ 不能用「有没有 include 这个头」单边判断 —— 很多头是 Foundation 间接拉进来的。
#    必须**先确认符号真的被用了**，再要求显式 import
#    （显式 import 无害，且不依赖传递包含的偶然性）。
C_SYMBOL_HEADERS = {
    "dlsym": "dlfcn.h", "dlopen": "dlfcn.h", "dlclose": "dlfcn.h",
    "RTLD_DEFAULT": "dlfcn.h", "RTLD_NOW": "dlfcn.h",
    "getpid": "unistd.h", "reboot": "unistd.h",
    "kill": "signal.h", "signal": "signal.h",
    "sysctl": "sys/sysctl.h", "sysctlbyname": "sys/sysctl.h",
    "posix_spawn": "spawn.h",
    "mmap": "sys/mman.h",
    "malloc": "stdlib.h", "free": "stdlib.h",
    "printf": "stdio.h",
    "strlen": "string.h", "memcpy": "string.h",
    "dispatch_after": "dispatch/dispatch.h",
}
_c_hdr_files = sorted(glob.glob("*.m") + glob.glob("*.x") + glob.glob("*.h") + glob.glob("prefs/*.m"))
_c_hdr_any_use = False
# ⚠️⚠️ 必须用**剥掉注释后**的正文来找 #import ——
#    否则被注释掉的 `// #import <dlfcn.h>` 也会被当成"已导入"
#    → 检查恒为绿（假阴性）。这正是 §54「子串匹配认错对象」的变体：
#    匹配到了字面文本，但那行根本不是有效代码。
#    （本检查第一版就踩了这个坑，靠注入测试发现。）
for path in _c_hdr_files:
    _raw = read(path)
    _imports = set(re.findall(r'#import\s*[<"]([^>"]+)[>"]', strip_comments(_raw)))
    # 本文件 + 其 import 的本地头，合并检查「符号是否被使用」
    # ⚠️ 同时要把本地头自己的 import 也算进来 ——
    #    SMGCommon.m 自己只 import "SMGCommon.h"，而 <dlfcn.h> 在后者里。
    #    只看本文件的 import 会误报「用了 dlsym 但没导 dlfcn.h」。
    _merged = strip_comments(_raw)
    for _lh in re.findall(r'#import\s+"([^"]+)"', strip_comments(_raw)):
        for _cand in [_lh, os.path.join(os.path.dirname(path), _lh)]:
            if os.path.exists(_cand):
                _lraw = read(_cand)
                _merged += "\n" + strip_comments(_lraw)
                _imports |= set(re.findall(r'#import\s*[<"]([^>"]+)[>"]', strip_comments(_lraw)))
                break
    _miss = []
    for _sym, _hdr in C_SYMBOL_HEADERS.items():
        if re.search(r"(?<![\w>])" + re.escape(_sym) + r"\s*\(", _merged):
            _c_hdr_any_use = True
            if not any(i.endswith(_hdr) for i in _imports):
                _miss.append((_sym, _hdr))
    # 非函数式常量单独处理
    if re.search(r"(?<![\w])RTLD_DEFAULT(?![\w])", _merged):
        _c_hdr_any_use = True
        if not any(i.endswith("dlfcn.h") for i in _imports):
            _miss.append(("RTLD_DEFAULT", "dlfcn.h"))
    for _sym, _hdr in sorted(set(_miss)):
        fail("❌ %s 用了 %s 但没 #import <%s>" % (path, _sym, _hdr))
if not FAIL:
    print("   ✅ C 库符号的 import 检查通过（有使用的文件均已显式 import）")

print("--- 检查 25：⭐ 频率判定必须「先记本次再判定」---")
# 逻辑陷阱：如果先数窗口再记本次，第 2 次注销时窗口里只有 1 条 → 永远判不出来，
# 永远慢一拍。所以要断言：addObject:@(now) 出现在统计循环之前。
smg_nc = strip_comments(src)   # src = SMGCommon.m（变量名带前缀，避免覆盖）
body, _ = find_body(smg_nc, r"SMGNoteBootTimeAndCheckRapid\s*\(void\)\s*\{")
if body is None:
    fail("❌ 找不到 SMGNoteBootTimeAndCheckRapid")
else:
    i_add = body.find("addObject:@(now)")
    # 统计循环：for (... in times) ... inWindow++
    m_cnt = re.search(r"for\s*\([^)]*in\s+times\s*\)", body)
    i_cnt = m_cnt.start() if m_cnt else -1
    if i_add < 0:
        fail("❌ 没有把「本次」时间戳加入序列（addObject:@(now)）")
    elif i_cnt < 0:
        fail("❌ 找不到窗口内统计循环")
    elif i_add > i_cnt:
        fail("❌ 顺序错了：先统计后才记录本次 → 永远慢一拍，第 2 次注销判不出来")
    else:
        print("   ✅ 先记本次、再统计（不会慢一拍）")

# ---------------------------------------------------------------------------
print("--- 检查 26：⭐ 主动重启必须有「只尝试一次」硬闸 ---")
# 主动重启是本插件唯一的危险操作。它在失控循环里发出重启指令，
# 必须保证「同一进程内绝不重复发」—— 否则会变成新的循环源。
if "sSMGRebootAttempted" not in smg_nc:
    fail("❌ SMGCommon.m 里找不到 sSMGRebootAttempted（只试一次的硬闸）")
else:
    body, _ = find_body(smg_nc, r"SMGPerformRebootOnce\s*\(void\)\s*\{")
    if body is None:
        fail("❌ 找不到 SMGPerformRebootOnce")
    else:
        i_guard = body.find("if (sSMGRebootAttempted)")
        i_set = body.find("sSMGRebootAttempted = YES")
        if i_guard < 0 or i_set < 0:
            fail("❌ SMGPerformRebootOnce 里没有读/写 sSMGRebootAttempted")
        elif i_guard > i_set:
            fail("❌ 先赋值后判断 → 硬闸失效（判断永远为真）")
        else:
            print("   ✅ 有「只尝试一次」硬闸，且判断先于赋值")

# ---------------------------------------------------------------------------
print("--- 检查 27：⭐ 主动重启的默认值必须是关闭 ---")
# 默认开启 = 把危险操作强加给不知情的用户。必须默认关。
body, _ = find_body(smg_nc, r"BOOL\s+SMGRebootEnabled\s*\(void\)\s*\{")
if body is None:
    fail("❌ 找不到 SMGRebootEnabled")
else:
    if re.search(r"\?\s*\[v\s+boolValue\]\s*:\s*NO", body):
        print("   ✅ 插件端 SMGRebootEnabled 默认 NO")
    else:
        fail("❌ 插件端 SMGRebootEnabled 默认不是 NO（危险操作必须默认关闭）")

# 面板侧也必须默认关，否则面板显示"开"而插件实际"关"，用户会困惑
pm_nc = strip_comments(read("prefs/SMRootListController.m"))
body, _ = find_body(pm_nc, r"getRebootEnabledPref\s*:\([^)]*\)\s*\w+\s*\{")
if body is None:
    fail("❌ 找不到 getRebootEnabledPref")
elif re.search(r":\s*@NO", body):
    print("   ✅ 面板端 getRebootEnabledPref 默认 @NO")
else:
    fail("❌ 面板端 getRebootEnabledPref 默认不是 @NO（会与插件端显示不一致）")

# ---------------------------------------------------------------------------
print("--- 检查 28：⭐ 主动重启只能在「写标记成功」之后调用 ---")
# 标记是保底主路径。标记都没写成还去重启 = 纯添乱。
body, _ = find_body(smg_nc, r"BOOL\s+SMGBootBegin\s*\(void\)\s*\{")
if body is None:
    fail("❌ 找不到 SMGBootBegin")
else:
    i_call = body.find("SMGPerformRebootOnce()")
    if i_call < 0:
        fail("❌ SMGBootBegin 里没有调用 SMGPerformRebootOnce()")
    else:
        # 必须处于 if (ok) { ... } 里，其中 ok = SMGEnterSafeMode(...)
        pre = body[:i_call]
        if re.search(r"if\s*\(\s*ok\s*\)\s*\{", pre) and "SMGEnterSafeMode" in pre:
            print("   ✅ 重启调用被包在「写标记成功（if (ok)）」分支内")
        else:
            fail("❌ SMGPerformRebootOnce() 不在 if (ok) 分支里 → 标记没写成也会重启，纯添乱")

# ---------------------------------------------------------------------------
print("--- 检查 29：⭐ 不允许 shell 调用来做重启 ---")
# sandbox 下的 fork/exec 行为不可控，且 system() 系列在 SpringBoard 里会失败。
# 必须走 dlsym 探测 + 直接函数调用。
for pat, why in [(r"\bsystem\s*\(", "system()"), (r"\bpopen\s*\(", "popen()"),
                 (r"\bposix_spawn\b", "posix_spawn"), (r"\bfork\s*\(", "fork()")]:
    if re.search(pat, smg_nc):
        fail("❌ SMGCommon.m 出现 %s —— sandbox 下不可控，重启只能走 dlsym 探测" % why)
print("   ✅ 无 shell/spawn 类重启手段")

# ---------------------------------------------------------------------------
print("--- 检查 30：⭐ 启动时间戳文件必须在重置时一并清空 ---")
# 否则用户点「重置」后，下一次启动可能立刻因为残留时间戳被判为「频率突增」。
body, _ = find_body(smg_nc, r"void\s+SMGResetAllState\s*\(void\)\s*\{")
if body is None:
    fail("❌ 找不到 SMGResetAllState")
elif "SMGBootTimesPath()" in body:
    print("   ✅ 重置会清空启动时间戳")
else:
    fail("❌ SMGResetAllState 没清 _boottimes.plist → 重置后可能立刻误判")

# 面板侧重置同理
body, _ = find_body(pm_nc, r"-\s*\(void\)\s*smgResetState\s*\{")
if body is None:
    fail("❌ 找不到面板 smgResetState")
elif "_boottimes.plist" in body:
    print("   ✅ 面板重置也会清空启动时间戳")
else:
    fail("❌ 面板 smgResetState 没清 _boottimes.plist")

# ---------------------------------------------------------------------------
print("--- 检查 31：⭐ 新配置项默认值两侧必须一致 ---")
# 面板显示"开"而插件实际"关"（或反之）是最难查的一类 bug。
pairs = [
    ("rapidExitEnabled", "SMGRapidExitEnabled", "getRapidEnabledPref", "YES"),
    ("rebootEnabled",    "SMGRebootEnabled",    "getRebootEnabledPref", "NO"),
]
for key, fn, getter, default in pairs:
    sb, _ = find_body(smg_nc, re.escape(fn) + r"\s*\(void\)\s*\{")
    pb, _ = find_body(pm_nc, re.escape(getter) + r"\s*:\([^)]*\)\s*\w+\s*\{")
    s_ok = bool(sb is not None and re.search(r":\s*" + default + r"\b", sb))
    p_ok = bool(pb is not None and re.search(r":\s*@" + default + r"\b", pb))
    if s_ok and p_ok:
        print("   ✅ %s 两侧默认一致（%s）" % (key, default))
    else:
        fail("❌ %s 默认值不一致或缺失（插件端默认 %s：%s，面板端：%s）"
             % (key, default, "OK" if s_ok else "缺失/不符", "OK" if p_ok else "缺失/不符"))

# ---------------------------------------------------------------------------
print()
if FAIL:
    print("🛑 本地预检未通过，修完再推 CI")
    sys.exit(1)
print("🎉 本地预检全部通过，可以推 CI 了")
