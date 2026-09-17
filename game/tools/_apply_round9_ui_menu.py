# -*- coding: utf-8 -*-
"""第 9 轮 · 需求 1（菜单首页部分）：一列装不下 → 平均分两列。

单独成脚本的原因：`main_menu.gd` 是 **CRLF** 文件，而初次写的 `\\n` 锚点命中 0 次
（安全失败，文件未被改动）—— 拆出来用 `_edit_util` 的换行自适应重跑。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path   # noqa: E402

MENU = game_path("scripts", "ui", "main_menu.gd")

edits = []

# (1) 首页按钮区排版常量（与按钮实际尺寸共用同一批常量）
edits.append((
    "## 开局向导步数（S4.5 §10.2）：**3 步**，与沧溟的流程一致 —— 角色 → 初始武器 → 难度。\n",
    "## ---- 首页按钮区排版（第 9 轮）----\n"
    "## 这三个常量是「首页能不能一列装下」与「按钮实际排布」的**同一份真值** ——\n"
    "## 第 9 轮之前，判据与布局各写一套（都硬编 46/10），任何一处改了都会让分列判断静默失真。\n"
    "const HOME_BTN_H := 46.0        # 桌面按钮高（10 个 × 46 + 9 × 10 = 550，720 画布刚好装下）\n"
    "const HOME_BTN_GAP := 10.0      # 桌面按钮间距\n"
    "const HOME_RESERVE_H := 140.0   # 标题 + 副标题 + 间隔 + 上下边距 + 底部保险\n"
    "\n"
    "## 开局向导步数（S4.5 §10.2）：**3 步**，与沧溟的流程一致 —— 角色 → 初始武器 → 难度。\n",
))

# (2) 按钮宿主：桌面装不下就平均分两列
edits.append((
    "	# 按钮宿主：桌面单列 VBox（保持原样），小屏按可用宽度自适应多列网格 ——\n"
    "	# 单列在 925×400 的单位空间里会拉成又长又窄的一条，双列更接近手机原生观感\n"
    "	var host: Container = box\n"
    "	var btn_w := 220.0\n"
    "	if full:\n"
    "		var avail := UiMetrics.available().x\n"
    "		var min_w := UiMetrics.dp(140.0)\n"
    "		var gap := UiMetrics.dp(8.0)\n"
    "		var cols := UiMetrics.grid_columns(avail, min_w, specs.size(), gap)\n"
    "		btn_w = (avail - gap * float(cols - 1)) / float(cols)\n"
    "		var grid := GridContainer.new()\n"
    "		grid.columns = cols\n"
    "		grid.add_theme_constant_override(\"h_separation\", int(gap))\n"
    "		grid.add_theme_constant_override(\"v_separation\", int(UiMetrics.dp(6.0)))\n"
    "		box.add_child(grid)\n"
    "		host = grid\n",
    "	# 按钮宿主（第 9 轮重做）——三档，判据全部来自 HOME_* 常量，不再硬编码：\n"
    "	#   ① 桌面且一列装得下 → 单列 VBox（现状不变，垂直居中）\n"
    "	#   ② 桌面但一列装不下 → **平均分两列**（用户明确要求）\n"
    "	#      为什么不是「继续往下滚」：滚动条要玩家自己「意识到下面还有按钮」，\n"
    "	#      而这正是第 7 轮「全屏看不到退出」的成因；分列是把信息一次摆完。\n"
    "	#   ③ 小屏 → 按可用宽度自适应多列（原逻辑不变）\n"
    "	var host: Container = box\n"
    "	var btn_w := 220.0\n"
    "	if full:\n"
    "		var avail := UiMetrics.available().x\n"
    "		var min_w := UiMetrics.dp(140.0)\n"
    "		var gap := UiMetrics.dp(8.0)\n"
    "		var cols := UiMetrics.grid_columns(avail, min_w, specs.size(), gap)\n"
    "		btn_w = (avail - gap * float(cols - 1)) / float(cols)\n"
    "		var grid := GridContainer.new()\n"
    "		grid.columns = cols\n"
    "		grid.add_theme_constant_override(\"h_separation\", int(gap))\n"
    "		grid.add_theme_constant_override(\"v_separation\", int(UiMetrics.dp(6.0)))\n"
    "		box.add_child(grid)\n"
    "		host = grid\n"
    "	elif not _home_one_column_fits(specs.size()):\n"
    "		var grid2 := GridContainer.new()\n"
    "		grid2.columns = 2   # 平均分两列：10 个按钮 → 5 + 5\n"
    "		grid2.add_theme_constant_override(\"h_separation\", int(HOME_BTN_GAP))\n"
    "		grid2.add_theme_constant_override(\"v_separation\", int(HOME_BTN_GAP))\n"
    "		box.add_child(grid2)\n"
    "		host = grid2\n",
))

# (3) 桌面按钮尺寸改读常量
edits.append((
    "			b.custom_minimum_size = Vector2(spec[1], 46.0)\n",
    "			# 第 9 轮：改读 HOME_BTN_H —— 与「一列装不下吗」的判据共用同一份真值\n"
    "			b.custom_minimum_size = Vector2(spec[1], HOME_BTN_H)\n",
))

# (4) 两个辅助函数
edits.append((
    "## 首页按钮清单（S4.5 §10.2）：\n",
    "## 首页按钮区「一列装得下吗」：判据与 HOME_BTN_H / HOME_BTN_GAP 同源。\n"
    "## ⚠️ 刻意保守：宁可早一点分成两列，也不要出现「最后一行被切一半还点不到」。\n"
    "func _home_one_column_fits(n: int) -> bool:\n"
    "	if n <= 0:\n"
    "		return true\n"
    "	var need := HOME_BTN_H * float(n) + HOME_BTN_GAP * float(maxf(0.0, float(n - 1)))\n"
    "	return need <= _home_avail_h()\n"
    "\n"
    "## 按钮区可用高度 = 可见视口高度 − HOME_RESERVE_H（标题/副标题/边距/底部保险）。\n"
    "## 用 `viewport_units()` 而不是 `available()`：后者已扣安全区，而首页的标题与边距\n"
    "## 是自己排的，再扣一次安全区会把可用高度算短、提前分列。\n"
    "func _home_avail_h() -> float:\n"
    "	return maxf(UiMetrics.viewport_units().y - HOME_RESERVE_H, 200.0)\n"
    "\n"
    "## 首页按钮清单（S4.5 §10.2）：\n",
))

sys.exit(0 if apply_file(MENU, edits, "menu") else 1)
