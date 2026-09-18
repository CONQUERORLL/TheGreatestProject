# -*- coding: utf-8 -*-
"""第 11 轮 · Q5：修 HintBubble 的两处真 bug（正文区高度恒 0 / 点别处关不掉）。

探针实测（headless，复刻 _ensure 的节点树）：
    body.combined_min  = (340, 37)   ← 正文自己知道自己要 37px
    scroll.min         = (348, 0)    ← ScrollContainer 纵向 AUTO 时**最小高度恒 0**
    panel.combined_min = (376, 44)   ← 于是整只气泡只有 44px（标题+间距+内边距）
对照：v=DISABLED → panel=81；显式 scroll.cmin.y=40 → 正文显示。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path

TARGET = game_path("scripts", "ui", "hint_bubble.gd")

LAYOUT_FN = '''## 量出气泡尺寸（`show_at` / `show_docked` 共用）。
##
## ⚠️⚠️ 这是第 11 轮修掉的那个真 bug：旧写法在「没超上限」的分支里把
##    `_scroll.custom_minimum_size` **复位成 ZERO**，而 `ScrollContainer` 在
##    `vertical_scroll_mode = AUTO` 时**最小高度恒为 0**（它不把子节点高度算进自己）
##    → 气泡的正文区高度恒 0 → **只剩标题**。
##    用户原话：「点击查看详情时，只有名称，没有道具效果描述」「属性悬浮也只有名称」。
##    headless 探针实测：`body.combined_min=(340,37)` / `scroll.min=(348,0)` /
##    `panel.combined_min=(376,44)` —— 44 就是「标题 + 间距 + 内边距」，正文一点没分到。
## 修法：**先量出正文高度并显式写进 `_scroll.custom_minimum_size`**，超上限才回收；
##    回收量用「实测总高 − 实测正文高」推出来的真 chrome（标题+间距+内边距），**不硬编码 42**。
func _layout_body(wrap_w: float, cap_h: float) -> Vector2:
	reset_size()
	# 换行宽度必须先定：`custom_minimum_size.x` 既是 Label 的换行宽，也决定气泡最小宽度。
	# 窄屏不收这一项，下面的 clamp 就永远夹不动（恒 ≥ MAX_W + 内边距）。
	_body.custom_minimum_size = Vector2(wrap_w, 0.0)
	# ① 先按「完整显示正文」设高，量出真实总高
	_scroll.custom_minimum_size = Vector2(0.0, maxf(1.0, _body.get_combined_minimum_size().y))
	var full := get_combined_minimum_size()
	# ② 超上限才把正文区压回去（其余部分原样保留，不做「复位成 0」那种自毁）
	if full.y > cap_h:
		var chrome := maxf(0.0, full.y - _scroll.custom_minimum_size.y)
		_scroll.custom_minimum_size = Vector2(0.0, maxf(24.0, cap_h - chrome))
		return Vector2(full.x, cap_h)
	return full

'''

EDITS = [
    # ---- ① 新增共用测量函数（挂在 show_at 之前）----
    ('func show_at(title_text: String, body_text: String) -> void:',
     LAYOUT_FN + 'func show_at(title_text: String, body_text: String) -> void:'),

    # ---- ② show_at 改用共用测量 ----
    ('''\t# 尺寸必须「先按内容算，再夹进视口」：直接信任内容高度会在长说明时把气泡顶出屏幕，
\t# 玩家看不到上半截，还以为是渲染 bug。
\treset_size()
\t# 换行宽度必须先按当前视口定：`custom_minimum_size.x` 既是 Label 的换行宽，
\t# 也决定气泡的最小宽度 —— 窄屏不收这一项，下面的 clamp 就永远夹不动（恒 ≥ MAX_W+内边距）。
\tvar max_w := _max_w()
\tvar max_h := _max_h()
\t_body.custom_minimum_size = Vector2(max_w, 0.0)
\tvar want := get_combined_minimum_size()
\tif want.y > max_h:
\t\twant.y = max_h
\t\t_scroll.custom_minimum_size = Vector2(0.0, max_h - 42.0)
\telse:
\t\t# ⚠️ 必须显式复位：`_scroll` 是**复用**节点，上一次长文把最小高度顶上去之后
\t\t#    不复位，下一条短提示也会撑出同样一大片空白（现象是"气泡突然变得很高"，
\t\t#    不是报错，纯视觉）。
\t\t_scroll.custom_minimum_size = Vector2.ZERO
\tvar vp := get_viewport().get_visible_rect().size
\tsize = clamp_to_viewport(want, vp)''',
     '''\t# 尺寸「先按内容算，再夹进视口」—— 全部交给 `_layout_body`（见那里的长注释）
\tvar want := _layout_body(_max_w(), _max_h())
\tvar vp := get_viewport().get_visible_rect().size
\tsize = clamp_to_viewport(want, vp)'''),

    # ---- ③ show_docked 改用共用测量 ----
    ('''\treset_size()
\t# 与 show_at 同源：换行宽先按当前视口定（否则最小宽恒 ≥ MAX_W+内边距，clamp 夹不动）
\tvar max_w := _max_w()
\tvar dock_w := _dock_w()
\tvar dock_max_h := _dock_max_h()
\t_body.custom_minimum_size = Vector2(max_w, 0.0)
\tvar vp := get_viewport().get_visible_rect().size
\tvar want := get_combined_minimum_size()
\t# 固定视图「位置稳定比刚好包住文字重要」→ 宽度取固定值，但必须 ≥ 换行宽且不超上限。
\t# 桌面（dock_w=360 / max_w=340）结果恒为 360，与改动前逐像素一致。
\twant.x = maxf(dock_w, minf(want.x, max_w))
\tif want.y > dock_max_h:
\t\twant.y = dock_max_h
\t\t_scroll.custom_minimum_size = Vector2(0.0, dock_max_h - 42.0)
\telse:
\t\t# 同 `show_at`：固定视图与跟随视图共用同一个滚动节点，短内容必须把最小高度收回
\t\t_scroll.custom_minimum_size = Vector2.ZERO
\tsize = clamp_to_viewport(want, vp)''',
     '''\tvar dock_w := _dock_w()
\tvar want := _layout_body(_max_w(), _dock_max_h())
\tvar vp := get_viewport().get_visible_rect().size
\t# 固定视图「位置稳定比刚好包住文字重要」→ 宽度取固定值，但必须 ≥ 换行宽且不超上限。
\t# 桌面（dock_w=360 / max_w=340）结果恒为 360，与改动前逐像素一致。
\twant.x = maxf(dock_w, minf(want.x, _max_w()))
\tsize = clamp_to_viewport(want, vp)'''),

    # ---- ④ 关不掉：_unhandled_input → _input ----
    ('''## 点空白处收起：`gui_input` 已被目标 `accept_event()` 消费，所以钉住的气泡
## 只在点到别的地方时才会走到这里 —— 正是想要的行为。
func _unhandled_input(e: InputEvent) -> void:''',
     '''## 点任意处收起。
##
## ⚠️⚠️ 必须用 `_input` 而**不是** `_unhandled_input`（第 11 轮修）：`_unhandled_input`
##    只在「**没有任何 GUI 消费这次点击**」时才触发，而暂停面板 / 商店里到处都是
##    `MOUSE_FILTER_STOP` 的按钮与面板 —— 点哪都被它们吃掉 → 钉住的气泡**根本关不掉**。
##    （用户原话：「没法关闭」。）
##    `_input` 跑在 GUI 之前，所以语义是「先收起，再让这次点击照常落到下面的控件上」，
##    点到道具/按钮时的行为与关闭前完全一致。
func _input(e: InputEvent) -> void:'''),
]

if not apply_file(TARGET, EDITS, "hint-bubble-r11"):
    sys.exit(1)
