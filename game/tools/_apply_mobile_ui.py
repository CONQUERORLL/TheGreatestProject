# -*- coding: utf-8 -*-
"""第 10 轮（迁移到移动端）：补齐第 7~9 轮新 UI 的移动端适配 + 补 UiMetrics 断言。

审计结论（先取证再动手）：
  · 第 7~9 轮新增脚本里，`entry_text.gd`（纯文案表）/ `menu_element_loop.gd`（半径由外部 set_radius 给）
    / `boss_box.gd`（card_grid + dp + prefers_full_page 全用了）/ `terrain_zone.gd`（非 UI）都**不是**缺口。
  · 用 git 取「4ff3794 新增行 ∩ 硬编码高度 <48」交集，只命中 6 处，去掉无害的（h=0.0 / 分隔线）
    后剩三处真缺口，即本脚本要改的三处。

改动（三处都必须【桌面逐像素不变】）：
  1. hint_bubble.gd —— 唯一完全绕过 UiMetrics 的布局代码。四个上限（MAX_W/MAX_H/DOCK_W/DOCK_MAX_H）
     是桌面绝对尺寸，不看视口；且 `_body.custom_minimum_size.x` 写死 MAX_W 会让气泡最小宽恒 ≥368，
     视口更窄时 `show_at` 的落点夹取上界跌到 4 以下 → 气泡被钉在左上角、右侧文字看不见（不报错）。
     改：窄屏按 available() 比例收缩 + 新增纯函数 `clamp_to_viewport()` 把尺寸夹进视口。
  2. main.gd::_build_end_menus —— 死亡/通关页 7 个按钮高 38/46 写死。38 单元 ≈ 38dp，
     够不着 Material 的 48dp 最小可点尺寸。改：走 touch_at_least，且**必须 gate 在
     prefers_full_page()** —— 桌面 units_per_inch≈96，直接 dp(38) 会变成 22.8（按钮变矮）。
  3. shop_ui.gd —— 两处「出售」按钮 56×24。手机端左侧属性栏已按 compact 隐藏、右侧栏是**唯一**
     的出售入口（第 9 轮特意保留就为了「手机上能卖东西」），24dp 的按钮等于白保留。改：走 dp + touch_at_least。

另补 `_check_mobile_ui()` 冒烟用例 —— 改动前冒烟对 UiMetrics **零覆盖**：
  纯函数三条（夹进视口 / 不放大 / 极小视口不出 0）+ 反向对照（不是恒等函数）+
  桌面契约（card_grid 桌面恒返回 want 原值、touch_at_least 非触屏返回原值、
  HintBubble 桌面四个上限 == 原常量）。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path  # noqa: E402

OK = True


def run(rel, edits, tag):
    global OK
    p = game_path(*rel.split("/"))
    if not os.path.exists(p):
        print("MISSING %s" % p)
        OK = False
        return
    if not apply_file(p, edits, tag):
        OK = False


# ============================================================
# 1. hint_bubble.gd
# ============================================================
run("scripts/ui/hint_bubble.gd", [
    # 1a. 常量区：窄屏收缩比例
    (
        """## 尺寸上限（超出则内部滚动）—— 屏幕小的时候防止气泡长到出屏
const MAX_H := 260.0
""",
        """## 尺寸上限（超出则内部滚动）—— 屏幕小的时候防止气泡长到出屏
const MAX_H := 260.0
## ---- 窄屏（移动端 / 紧凑档）收缩（移动端适配补齐）----
## 上面几个常量是**桌面绝对尺寸**，不含视口概念：手机横屏可用区只有约 700×380 单位，
## DOCK_MAX_H=340 会吃掉八成屏高、DOCK_W=360 会占掉近半屏宽 —— 一张临时详情把战场全盖住。
## 所以窄屏按 `UiMetrics.available()` 的比例收缩；桌面走原常量，排布逐像素不变。
## ⚠️ 比「太大」更要紧的是**溢出**：`show_at` 的落点夹取是 `clampf(p, 4, vp - size - 4)`，
##    size 一旦超过视口，上界就跌到 4 以下（被 maxf 兜成 4）→ 气泡被钉在左上角，
##    右/下侧文字**直接看不见**，且不报任何错。
const NARROW_W_RATIO := 0.92       # 跟随气泡最大宽 / 可用区宽
const NARROW_H_RATIO := 0.62       # 跟随气泡最大高 / 可用区高
const NARROW_DOCK_W_RATIO := 0.80  # 固定视图宽 / 可用区宽
const NARROW_DOCK_H_RATIO := 0.78  # 固定视图高 / 可用区高
## 窄屏收缩后的绝对下限：再小就读不成句，宁可让外层换行
const NARROW_MIN_W := 168.0
const NARROW_MIN_H := 140.0
""",
    ),
    # 1b. 纯函数 + 四个上限 helper（插在成员变量之前）
    (
        """var _title: Label = null
var _body: Label = null
var _scroll: ScrollContainer = null
""",
        """## 把「想要的尺寸」夹进视口（**纯函数** —— 冒烟 `_check_mobile_ui()` 直接断言它）。
## 气泡自算的宽高一旦超过视口，落点夹取就会失效并把气泡钉在左上角（见上面常量区的说明）。
static func clamp_to_viewport(want: Vector2, vp: Vector2, pad := 4.0) -> Vector2:
	return Vector2(
		clampf(want.x, 1.0, maxf(1.0, vp.x - pad * 2.0)),
		clampf(want.y, 1.0, maxf(1.0, vp.y - pad * 2.0)))

## 四个尺寸上限：桌面恒为原常量，窄屏按可用区比例收缩。
## 统一 gate 在 `UiMetrics.prefers_full_page()` 上 —— 桌面不能走 `dp()`：
## 桌面 units_per_inch≈96，`dp(340)` 会算成 204，气泡反而缩水。
func _max_w() -> float:
	if not UiMetrics.prefers_full_page():
		return MAX_W
	return clampf(UiMetrics.available().x * NARROW_W_RATIO, NARROW_MIN_W, MAX_W)

func _max_h() -> float:
	if not UiMetrics.prefers_full_page():
		return MAX_H
	return clampf(UiMetrics.available().y * NARROW_H_RATIO, NARROW_MIN_H, MAX_H)

func _dock_w() -> float:
	if not UiMetrics.prefers_full_page():
		return DOCK_W
	return clampf(UiMetrics.available().x * NARROW_DOCK_W_RATIO, NARROW_MIN_W, DOCK_W)

func _dock_max_h() -> float:
	if not UiMetrics.prefers_full_page():
		return DOCK_MAX_H
	return clampf(UiMetrics.available().y * NARROW_DOCK_H_RATIO, NARROW_MIN_H, DOCK_MAX_H)

var _title: Label = null
var _body: Label = null
var _scroll: ScrollContainer = null
""",
    ),
    # 1c. _ensure 里的初始值加注释（真正生效值由每次 show_* 重算）
    (
        """	_body.custom_minimum_size = Vector2(MAX_W, 0.0)
	_body.add_theme_font_size_override("font_size", 12)
""",
        """	# 初始值；每次 show_* 都会按当前视口重算（旋转 / 布局变化后 _max_w 会变）
	_body.custom_minimum_size = Vector2(MAX_W, 0.0)
	_body.add_theme_font_size_override("font_size", 12)
""",
    ),
    # 1d. show_at：换行宽先按视口定 + 尺寸夹进视口
    (
        """	reset_size()
	var want := get_combined_minimum_size()
	if want.y > MAX_H:
		want.y = MAX_H
		_scroll.custom_minimum_size = Vector2(0.0, MAX_H - 42.0)
	else:
		# ⚠️ 必须显式复位：`_scroll` 是**复用**节点，上一次长文把最小高度顶上去之后
		#    不复位，下一条短提示也会撑出同样一大片空白（现象是"气泡突然变得很高"，
		#    不是报错，纯视觉）。
		_scroll.custom_minimum_size = Vector2.ZERO
	size = want
	var vp := get_viewport().get_visible_rect().size
""",
        """	reset_size()
	# 换行宽度必须先按当前视口定：`custom_minimum_size.x` 既是 Label 的换行宽，
	# 也决定气泡的最小宽度 —— 窄屏不收这一项，下面的 clamp 就永远夹不动（恒 ≥ MAX_W+内边距）。
	var max_w := _max_w()
	var max_h := _max_h()
	_body.custom_minimum_size = Vector2(max_w, 0.0)
	var want := get_combined_minimum_size()
	if want.y > max_h:
		want.y = max_h
		_scroll.custom_minimum_size = Vector2(0.0, max_h - 42.0)
	else:
		# ⚠️ 必须显式复位：`_scroll` 是**复用**节点，上一次长文把最小高度顶上去之后
		#    不复位，下一条短提示也会撑出同样一大片空白（现象是"气泡突然变得很高"，
		#    不是报错，纯视觉）。
		_scroll.custom_minimum_size = Vector2.ZERO
	var vp := get_viewport().get_visible_rect().size
	size = clamp_to_viewport(want, vp)
""",
    ),
    # 1e. show_docked：同上
    (
        """	reset_size()
	var vp := get_viewport().get_visible_rect().size
	var want := get_combined_minimum_size()
	want.x = maxf(DOCK_W, minf(want.x, MAX_W))
	if want.y > DOCK_MAX_H:
		want.y = DOCK_MAX_H
		_scroll.custom_minimum_size = Vector2(0.0, DOCK_MAX_H - 42.0)
	else:
		# 同 `show_at`：固定视图与跟随视图共用同一个滚动节点，短内容必须把最小高度收回
		_scroll.custom_minimum_size = Vector2.ZERO
	size = want
""",
        """	reset_size()
	# 与 show_at 同源：换行宽先按当前视口定（否则最小宽恒 ≥ MAX_W+内边距，clamp 夹不动）
	var max_w := _max_w()
	var dock_w := _dock_w()
	var dock_max_h := _dock_max_h()
	_body.custom_minimum_size = Vector2(max_w, 0.0)
	var vp := get_viewport().get_visible_rect().size
	var want := get_combined_minimum_size()
	# 固定视图「位置稳定比刚好包住文字重要」→ 宽度取固定值，但必须 ≥ 换行宽且不超上限。
	# 桌面（dock_w=360 / max_w=340）结果恒为 360，与改动前逐像素一致。
	want.x = maxf(dock_w, minf(want.x, max_w))
	if want.y > dock_max_h:
		want.y = dock_max_h
		_scroll.custom_minimum_size = Vector2(0.0, dock_max_h - 42.0)
	else:
		# 同 `show_at`：固定视图与跟随视图共用同一个滚动节点，短内容必须把最小高度收回
		_scroll.custom_minimum_size = Vector2.ZERO
	size = clamp_to_viewport(want, vp)
""",
    ),
], "hint_bubble")

# ============================================================
# 2. main.gd —— 结算页按钮触控尺寸
# ============================================================
run("scripts/main.gd", [
    (
        """func _build_end_menus() -> void:
	# 死亡界面按钮
	dead_label.text = "你倒下了"
""",
        """func _build_end_menus() -> void:
	# 结算页按钮高度（移动端适配补齐）：38 单元 ≈ 38dp，够不着 Material 的 48dp 最小可点尺寸，
	# 手机上「再来一局 / 返回主菜单 / 退出游戏」会点空。触摸设备按触控下限抬到 48dp。
	# ⚠️ 必须 gate 在 `prefers_full_page()` 上：桌面 units_per_inch≈96，`dp(38)` 只有 22.8，
	#    直接套 dp 会让桌面按钮**变矮**（与 `_build_pause_panel` 同样的写法与理由）。
	var full := UiMetrics.prefers_full_page()
	var h_btn := UiMetrics.touch_at_least(UiMetrics.dp(38.0)) if full else 38.0
	var h_btn_big := UiMetrics.touch_at_least(UiMetrics.dp(46.0)) if full else 46.0
	# 死亡界面按钮
	dead_label.text = "你倒下了"
""",
    ),
    (
        """	retry_btn.custom_minimum_size = Vector2(200.0, 38.0)
""",
        """	retry_btn.custom_minimum_size = Vector2(200.0, h_btn)
""",
    ),
    (
        """	back_btn.custom_minimum_size = Vector2(200.0, 38.0)
""",
        """	back_btn.custom_minimum_size = Vector2(200.0, h_btn)
""",
    ),
    (
        """	dead_quit.custom_minimum_size = Vector2(200.0, 38.0)
""",
        """	dead_quit.custom_minimum_size = Vector2(200.0, h_btn)
""",
    ),
    (
        """	_victory_continue.custom_minimum_size = Vector2(270.0, 46.0)
""",
        """	_victory_continue.custom_minimum_size = Vector2(270.0, h_btn_big)
""",
    ),
    (
        """	vic_retry.custom_minimum_size = Vector2(270.0, 38.0)
""",
        """	vic_retry.custom_minimum_size = Vector2(270.0, h_btn)
""",
    ),
    (
        """	vic_back.custom_minimum_size = Vector2(270.0, 38.0)
""",
        """	vic_back.custom_minimum_size = Vector2(270.0, h_btn)
""",
    ),
    (
        """	vic_quit.custom_minimum_size = Vector2(270.0, 38.0)
""",
        """	vic_quit.custom_minimum_size = Vector2(270.0, h_btn)
""",
    ),
], "main.gd")

# ============================================================
# 3. shop_ui.gd —— 出售按钮触控尺寸
# ============================================================
run("scripts/ui/shop_ui.gd", [
    (
        """func _goods_max_h() -> float:
	return UiMetrics.dp(238.0)
""",
        """func _goods_max_h() -> float:
	return UiMetrics.dp(238.0)

## 出售按钮尺寸（移动端适配补齐）。桌面 56×24 —— 右侧栏是纯列表，24 够用。
## 但手机上左侧属性栏已按 compact 隐藏，右侧栏成了**唯一**的出售入口
## （第 9 轮特意保留它就是为了「手机上也能卖东西」），24 单元 ≈ 24dp、
## 只有 Material 最小触控目标（48dp）的一半，手指根本按不准 —— 那这一栏就白保留了。
func _sell_btn_size() -> Vector2:
	if not UiMetrics.prefers_full_page():
		return Vector2(56.0, 24.0)
	return Vector2(UiMetrics.dp(56.0), UiMetrics.touch_at_least(UiMetrics.dp(24.0)))
""",
    ),
    (
        """			asell.custom_minimum_size = Vector2(56.0, 24.0)
""",
        """			asell.custom_minimum_size = _sell_btn_size()
""",
    ),
    (
        """		sell.custom_minimum_size = Vector2(56.0, 24.0)
""",
        """		sell.custom_minimum_size = _sell_btn_size()
""",
    ),
], "shop_ui")

# ============================================================
# 4. smoke_test.gd —— 新增 _check_mobile_ui() + 注册
# ============================================================
run("tests/smoke_test.gd", [
    (
        """	_check_round9_boss_terrain()
""",
        """	_check_round9_boss_terrain()
	_check_mobile_ui()
""",
    ),
    (
        """func _check_reach_safety() -> void:
""",
        """## 移动端 UI 度量（第 10 轮补）。改动前冒烟对 UiMetrics **零覆盖** ——
## 它同时被桌面与移动端读，一旦改坏，桌面排布会「静默变形」（不报错、只是位置变了）。
## 所以这里钉三件事：① 纯函数真的会收缩（不是恒等）② 收缩有下限（不出 0/负数）
## ③ 桌面端契约：card_grid / touch_at_least / 气泡四个上限**一律返回原值**。
func _check_mobile_ui() -> void:
	# ① 夹进视口：超出部分被裁到 vp - pad*2
	var vp := Vector2(200.0, 100.0)
	var c1: Vector2 = HintBubble.clamp_to_viewport(Vector2(9999.0, 9999.0), vp)
	if not c1.is_equal_approx(Vector2(192.0, 92.0)):
		_fail("clamp_to_viewport 未把尺寸夹进视口：%s（期望 192,92）" % c1)
		return
	# 反向对照：它必须**不是恒等函数**，否则上面那条在「函数没生效」时也会绿
	if c1.is_equal_approx(Vector2(9999.0, 9999.0)):
		_fail("clamp_to_viewport 是恒等函数（没生效）")
		return
	# ② 小尺寸不被放大（只在超限时收缩）
	var c2: Vector2 = HintBubble.clamp_to_viewport(Vector2(10.0, 20.0), vp)
	if not c2.is_equal_approx(Vector2(10.0, 20.0)):
		_fail("clamp_to_viewport 把未超限的尺寸改动了：%s" % c2)
		return
	# ③ 极小视口：下界兜到 1 而不是 0/负数（0 会让气泡不可见且落点夹取反向）
	var c3: Vector2 = HintBubble.clamp_to_viewport(Vector2(80.0, 80.0), Vector2(10.0, 10.0))
	if c3.x < 1.0 or c3.y < 1.0:
		_fail("clamp_to_viewport 在极小视口下返回了 0/负数：%s" % c3)
		return
	# ④ 桌面契约：headless 无触屏、非 mobile、视口高 720 → 一定不是 full_page
	if UiMetrics.prefers_full_page():
		_fail("桌面/headless 不该判为 full_page（排布分支会整体切错）")
		return
	if UiMetrics.size_class() != "expanded":
		_fail("桌面 720 高应为 expanded，实为 %s" % UiMetrics.size_class())
		return
	# card_grid 在非 full_page 时必须**原样返回 want**，否则桌面卡阵尺寸会变
	var g: Dictionary = UiMetrics.card_grid(3, Vector2(210.0, 224.0), 150.0, 150.0, 14.0, 140.0)
	if not Vector2(g.card_size).is_equal_approx(Vector2(210.0, 224.0)) or int(g.cols) != 3:
		_fail("card_grid 桌面端未原样返回设计尺寸：%s cols=%s" % [g.card_size, g.cols])
		return
	# touch_at_least：非触屏恒返回原值（这是「桌面不被改」的总闸门）
	if not is_equal_approx(UiMetrics.touch_at_least(30.0), 30.0):
		_fail("非触屏设备 touch_at_least 改动了原值")
		return
	# 气泡四个上限：桌面必须等于原常量（窄屏收缩绝不能漏到桌面）
	var bb := HintBubble.new()
	var caps_ok: bool = is_equal_approx(bb._max_w(), HintBubble.MAX_W) \\
		and is_equal_approx(bb._max_h(), HintBubble.MAX_H) \\
		and is_equal_approx(bb._dock_w(), HintBubble.DOCK_W) \\
		and is_equal_approx(bb._dock_max_h(), HintBubble.DOCK_MAX_H)
	var caps_txt := "max_w=%.1f max_h=%.1f dock_w=%.1f dock_max_h=%.1f" % [
		bb._max_w(), bb._max_h(), bb._dock_w(), bb._dock_max_h()]
	bb.free()
	if not caps_ok:
		_fail("气泡尺寸上限在桌面端被改动了：%s" % caps_txt)
		return
	# ⑤ 安全区兜底：四边都不小于 SAFE_MIN_DP（刘海 API 不可用时也不能是 0）
	var ins: Dictionary = UiMetrics.safe_insets()
	var min_side: float = UiMetrics.dp(UiMetrics.SAFE_MIN_DP) - 0.01
	for k in ["left", "right", "top", "bottom"]:
		if float(ins[k]) < min_side:
			_fail("安全区 %s 低于兜底值：%.2f < %.2f" % [k, float(ins[k]), min_side])
			return
	# available() 必须真的扣掉了边距（否则各界面的「自适应」都在按全屏算）
	var avail: Vector2 = UiMetrics.available()
	var vu: Vector2 = UiMetrics.viewport_units()
	if avail.x <= 0.0 or avail.y <= 0.0 or avail.x >= vu.x or avail.y >= vu.y:
		_fail("available() 未扣除边距：avail=%s viewport=%s" % [avail, vu])
		return
	# ⑥ grid_columns 纯函数：宽了才多列、窄了只 1 列（反向对照，防「恒返回 1」或「恒返回 n」）
	if UiMetrics.grid_columns(2000.0, 150.0, 3, 10.0) != 3:
		_fail("grid_columns 在宽区未放满 3 列")
		return
	if UiMetrics.grid_columns(200.0, 150.0, 3, 10.0) != 1:
		_fail("grid_columns 在窄区未退化成 1 列")
		return
	print("SMOKE: mobile ui metrics OK（%s / caps %s）" % [UiMetrics.size_class(), caps_txt])

func _check_reach_safety() -> void:
""",
    ),
], "smoke_test")

print("\n== %s ==" % ("ALL WRITTEN" if OK else "有失败，见上（失败的文件保持原样）"))
sys.exit(0 if OK else 1)
