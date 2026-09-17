# -*- coding: utf-8 -*-
"""第 9 轮 · 冒烟前的自查修正（2/2）：hint_bubble 的滚动最小高度未复位。

`_scroll` 是复用节点：上一次长文把 `custom_minimum_size.y` 顶到 ~300 之后不复位，
下一条**短**提示也会撑出一大片空白（现象是"气泡忽然变很高"，不是报错）。

跑法：
    python.exe game/tools/_apply_round9_redfix_b.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path  # noqa: E402

HB = game_path("scripts", "ui", "hint_bubble.gd")

AT_OLD = """	if want.y > MAX_H:
		want.y = MAX_H
		_scroll.custom_minimum_size = Vector2(0.0, MAX_H - 42.0)
	size = want
"""

AT_NEW = """	if want.y > MAX_H:
		want.y = MAX_H
		_scroll.custom_minimum_size = Vector2(0.0, MAX_H - 42.0)
	else:
		# ⚠️ 必须显式复位：`_scroll` 是**复用**节点，上一次长文把最小高度顶上去之后
		#    不复位，下一条短提示也会撑出同样一大片空白（现象是"气泡突然变得很高"，
		#    不是报错，纯视觉）。
		_scroll.custom_minimum_size = Vector2.ZERO
	size = want
"""

DOCK_OLD = """	if want.y > DOCK_MAX_H:
		want.y = DOCK_MAX_H
		_scroll.custom_minimum_size = Vector2(0.0, DOCK_MAX_H - 42.0)
	size = want
"""

DOCK_NEW = """	if want.y > DOCK_MAX_H:
		want.y = DOCK_MAX_H
		_scroll.custom_minimum_size = Vector2(0.0, DOCK_MAX_H - 42.0)
	else:
		# 同 `show_at`：固定视图与跟随视图共用同一个滚动节点，短内容必须把最小高度收回
		_scroll.custom_minimum_size = Vector2.ZERO
	size = want
"""


def main():
    ok = apply_file(HB, [(AT_OLD, AT_NEW), (DOCK_OLD, DOCK_NEW)], "r9-redfix-hint")
    if not ok:
        sys.exit(1)
    print("ALL OK")


if __name__ == "__main__":
    main()
