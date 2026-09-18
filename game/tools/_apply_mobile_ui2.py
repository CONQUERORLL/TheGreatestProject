# -*- coding: utf-8 -*-
"""第 10 轮补丁：把 HintBubble 的四个尺寸上限改成 `static`，并让冒烟不再实例化它。

起因：`_check_mobile_ui()` 里 `HintBubble.new()` 只是为了读四个上限，
却往 ObjectDB 塞了个 Control —— 冒烟退出时本来就有泄漏噪音（`N ObjectDB instances were leaked`），
测试自己再分配对象会把那个数字**搅浑**，反而遮住真正的泄漏。
先试过用 `--script` 单独跑探针，但 `--script` 不加载 autoload →
`hint_bubble.gd` 直接 `Identifier not found: UiMetrics` 编译失败，路子不通。
所以改成从设计上消除：四个上限只读 UiMetrics（autoload）与常量，本来就不需要实例状态。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path  # noqa: E402

OK = True


def run(rel, edits, tag):
    global OK
    p = game_path(*rel.split("/"))
    if not apply_file(p, edits, tag):
        OK = False


run("scripts/ui/hint_bubble.gd", [
    (
        """## 四个尺寸上限：桌面恒为原常量，窄屏按可用区比例收缩。
## 统一 gate 在 `UiMetrics.prefers_full_page()` 上 —— 桌面不能走 `dp()`：
## 桌面 units_per_inch≈96，`dp(340)` 会算成 204，气泡反而缩水。
func _max_w() -> float:
""",
        """## 四个尺寸上限：桌面恒为原常量，窄屏按可用区比例收缩。
## 统一 gate 在 `UiMetrics.prefers_full_page()` 上 —— 桌面不能走 `dp()`：
## 桌面 units_per_inch≈96，`dp(340)` 会算成 204，气泡反而缩水。
##
## ⚠️ 这四个必须是 `static`：它们只读 UiMetrics（autoload）与常量，**没有任何实例状态**。
##    写成实例方法会逼着测试 `HintBubble.new()` 才能断言 —— 而冒烟退出时本来就有
##    `N ObjectDB instances were leaked` 的引擎侧噪音，测试再塞对象进去就把那个数字搅浑了，
##    真正新引入的泄漏会被淹没（本次正是先踩了这个坑）。纯函数就该是 static 的。
static func _max_w() -> float:
""",
    ),
    (
        """func _max_h() -> float:
""",
        """static func _max_h() -> float:
""",
    ),
    (
        """func _dock_w() -> float:
""",
        """static func _dock_w() -> float:
""",
    ),
    (
        """func _dock_max_h() -> float:
""",
        """static func _dock_max_h() -> float:
""",
    ),
], "hint_bubble-static")

run("tests/smoke_test.gd", [
    (
        """	# 气泡四个上限：桌面必须等于原常量（窄屏收缩绝不能漏到桌面）
	var bb := HintBubble.new()
	var caps_ok: bool = is_equal_approx(bb._max_w(), HintBubble.MAX_W) \\
		and is_equal_approx(bb._max_h(), HintBubble.MAX_H) \\
		and is_equal_approx(bb._dock_w(), HintBubble.DOCK_W) \\
		and is_equal_approx(bb._dock_max_h(), HintBubble.DOCK_MAX_H)
	var caps_txt := "max_w=%.1f max_h=%.1f dock_w=%.1f dock_max_h=%.1f" % [
		bb._max_w(), bb._max_h(), bb._dock_w(), bb._dock_max_h()]
	bb.free()
	if not caps_ok:
""",
        """	# 气泡四个上限：桌面必须等于原常量（窄屏收缩绝不能漏到桌面）。
	# 它们是 static，所以这里**不实例化** —— 测试里 new 一个 Control 会往 ObjectDB 塞对象，
	# 把退出时的泄漏计数搅浑，真正的新增泄漏反而看不见。
	var mw: float = HintBubble._max_w()
	var mh: float = HintBubble._max_h()
	var dw: float = HintBubble._dock_w()
	var dh: float = HintBubble._dock_max_h()
	var caps_ok: bool = is_equal_approx(mw, HintBubble.MAX_W) and is_equal_approx(mh, HintBubble.MAX_H)
	caps_ok = caps_ok and is_equal_approx(dw, HintBubble.DOCK_W) and is_equal_approx(dh, HintBubble.DOCK_MAX_H)
	var caps_txt := "max_w=%.1f max_h=%.1f dock_w=%.1f dock_max_h=%.1f" % [mw, mh, dw, dh]
	if not caps_ok:
""",
    ),
], "smoke-static")

print("\n== %s ==" % ("ALL WRITTEN" if OK else "有失败，见上（失败的文件保持原样）"))
sys.exit(0 if OK else 1)
