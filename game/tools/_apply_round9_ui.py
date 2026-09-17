# -*- coding: utf-8 -*-
"""第 9 轮 · 需求 1：UI 浮动布局（非幂等）。

改动：
  main_menu.gd  —— 首页按钮区：一列装不下 → 平均分两列（新增 3 个常量 + 2 个辅助函数）
  shop_ui.gd    —— 商品区 HBox → Grid（放不下就 3+3 平均换行）；属性栏加滚动条
  main.gd       —— 暂停页属性栏加滚动条
  hint_bubble.gd—— 点击详情改「固定视图 + 滚动条」（悬浮仍是跟随鼠标）

规则：每处 (old, new) 断言 old 在全文命中恰好 1 次，全部通过才写盘。
"""
import io
import os
import sys

ROOT = r"D:\code\firstProject-ai\TheGreatestProject"
FILES = {
    "menu": os.path.join(ROOT, "game", "scripts", "ui", "main_menu.gd"),
    "shop": os.path.join(ROOT, "game", "scripts", "ui", "shop_ui.gd"),
    "main": os.path.join(ROOT, "game", "scripts", "main.gd"),
    "hint": os.path.join(ROOT, "game", "scripts", "ui", "hint_bubble.gd"),
}


def rd(p):
    with io.open(p, encoding="utf-8", newline="") as f:
        return f.read()


def wr(p, s):
    with io.open(p, "w", encoding="utf-8", newline="") as f:
        f.write(s)


def apply(text, edits, tag):
    for i, (old, new) in enumerate(edits):
        n = text.count(old)
        if n != 1:
            print("FAIL %s #%d 命中 %d 次（要求 1）" % (tag, i, n))
            print("   old[:200]=%r" % (old[:200],))
            return None
        text = text.replace(old, new, 1)
        print("  ok %s #%d" % (tag, i))
    return text


# ============================================================ main_menu.gd
mn_edits = []

# (1) 首页排版常量（与按钮实际尺寸共用同一批常量，避免「检查用一套、布局用另一套」）
mn_edits.append((
    "## 开局向导步数（S4.5 §10.2）：**3 步**，与沧溟的流程一致 —— 角色 → 初始武器 → 难度。\n",
    "## ---- 首页按钮区排版（第 9 轮）----\n"
    "## 这三个常量是「首页能不能一列装下」与「按钮实际排布」的**同一份真值** ——\n"
    "## 第 9 轮之前，判据与布局各写一套（判据拿 46/10 硬算、布局也硬编 46/10），\n"
    "## 任何一处改了都会让分列判断静默失真。\n"
    "const HOME_BTN_H := 46.0        # 桌面按钮高（10 个 × 46 + 9 × 10 = 550，720 画布刚好装下）\n"
    "const HOME_BTN_GAP := 10.0      # 桌面按钮间距\n"
    "const HOME_RESERVE_H := 140.0   # 标题 + 副标题 + 间隔 + 上下边距 + 底部保险\n"
    "\n"
    "## 开局向导步数（S4.5 §10.2）：**3 步**，与沧溟的流程一致 —— 角色 → 初始武器 → 难度。\n",
))

# (2) 按钮宿主选择：桌面装不下就平均分两列
mn_edits.append((
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
    "	# 按钮宿主（第 9 轮重做）——三档，判据全部来自 HOME_* 常量，不再是硬编码：\n"
    "	#   ① 桌面且一列装得下 → 单列 VBox（现状不变，垂直居中）\n"
    "	#   ② 桌面但一列装不下 → **平均分两列**（用户明确要求）\n"
    "	#      为什么不是「继续滚动」：滚动条要玩家自己发现「下面还有按钮」，\n"
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
    "		grid2.columns = 2   # 平均分两列：10 个按钮 → 5 + 5（ceil 向上取整，不会少排）\n"
    "		grid2.add_theme_constant_override(\"h_separation\", int(HOME_BTN_GAP))\n"
    "		grid2.add_theme_constant_override(\"v_separation\", int(HOME_BTN_GAP))\n"
    "		box.add_child(grid2)\n"
    "		host = grid2\n",
))

# (3) 桌面按钮尺寸改用常量（原来硬编码 46）
mn_edits.append((
    "		else:\n"
    "			# 高 52→46 / 间距 14→10：10 按钮总高 770 → 662，16:9 全屏的 720 单位画布\n"
    "			# 才装得下（详见 `_build_home` 抬头注释）。别再调回去。\n"
    "			b.custom_minimum_size = Vector2(spec[1], 46.0)\n",
    "		else:\n"
    "			# 高 52→46 / 间距 14→10：10 按钮总高 770 → 662，16:9 全屏的 720 单位画布\n"
    "			# 才装得下（详见 `_build_home` 抬头注释）。别再调回去。\n"
    "			# 第 9 轮：尺寸改读 HOME_BTN_H，与「一列装不下吗」的判据共用同一份真值\n"
    "			b.custom_minimum_size = Vector2(spec[1], HOME_BTN_H)\n",
))

# (4) 新增两个辅助函数（插在 _home_specs 之前）
mn_edits.append((
    "## 首页按钮清单（S4.5 §10.2）：\n",
    "## 首页按钮区「一列装得下吗」：判据与 HOME_BTN_H/HOME_BTN_GAP 同源。\n"
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

# ============================================================ shop_ui.gd
sh_edits = []

# (1) 成员类型：HBox → Grid
sh_edits.append((
    "var _goods_box: HBoxContainer\n",
    "var _goods_box: GridContainer   # 第 9 轮：一排放不下就平均换行（见 _goods_grid），不再是单行 HBox\n",
))

# (2) 构建：GridContainer + 两个 separation
sh_edits.append((
    "	_goods_box = HBoxContainer.new()\n"
    "	_goods_box.alignment = BoxContainer.ALIGNMENT_CENTER\n"
    "	_goods_box.add_theme_constant_override(\"separation\", 8)\n",
    "	# 商品区容器：GridContainer 而不是 HBoxContainer（第 9 轮）。\n"
    "	# `columns == 商品数` 时行为与单行 HBox 完全一致；放不下时由 `_goods_grid()`\n"
    "	# 改小 columns，就变成「平均换行」（6 格 → 3+3，而不是 5+1 留一张孤卡）。\n"
    "	# 旧版单行 HBox 的问题是硬溢出：桌面 6 × 150 宽 + 左右侧栏本来就超出 1280，\n"
    "	# 最后一张卡会被顶到屏幕外 —— 看得见、点不到，且不报错。\n"
    "	_goods_box = GridContainer.new()\n"
    "	_goods_box.columns = Config.SHOP_SLOTS\n"
    "	_goods_box.alignment = BoxContainer.ALIGNMENT_CENTER\n"
    "	_goods_box.add_theme_constant_override(\"h_separation\", 8)\n"
    "	_goods_box.add_theme_constant_override(\"v_separation\", 8)\n",
))

# (3) 属性栏加滚动条
sh_edits.append((
    "func _make_left_column() -> VBoxContainer:\n"
    "	_left_box = VBoxContainer.new()\n"
    "	_left_box.add_theme_constant_override(\"separation\", 4)\n"
    "	return _left_box\n",
    "## 左侧属性栏 = 「固定视图 + 滚动条」（第 9 轮 · 用户要求）。\n"
    "## 属性行数会随道具 / 法宝 / 同化度增长，裸 VBox 超出面板高度只会被**裁掉** ——\n"
    "## 看不到最后几行，且没有任何提示（不是报错，只是「信息悄悄少了」）。\n"
    "func _make_left_column() -> Control:\n"
    "	var scroll := ScrollContainer.new()\n"
    "	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL\n"
    "	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL\n"
    "	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED\n"
    "	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO\n"
    "	_left_box = VBoxContainer.new()\n"
    "	_left_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL\n"
    "	_left_box.add_theme_constant_override(\"separation\", 4)\n"
    "	scroll.add_child(_left_box)\n"
    "	return scroll\n",
))

# (4) 商品区尺寸：行列自适应 + 换算函数重写
sh_edits.append((
    "## 商品卡尺寸。桌面固定 150×238；小屏按「可用宽度 − 右侧出售栏 − 间距」除以张数算，\n"
    "## 保证无论 4 张还是 6 张都不会顶出屏幕（旧版写死 150 宽，5 张就超出面板）。\n"
    "## 高度同时受可用高度约束，避免在矮屏上把「下一波」按钮挤出画面。\n"
    "func _good_card_size() -> Vector2:\n"
    "	if not UiMetrics.prefers_full_page():\n"
    "		return Vector2(150.0, 238.0)\n"
    "	var n := maxi(1, goods.size())\n"
    "	var usable_w := UiMetrics.available().x - UiMetrics.dp(180.0) - 14.0 - UiMetrics.dp(24.0)\n"
    "	var w := clampf((usable_w - 8.0 * float(n - 1)) / float(n), UiMetrics.dp(96.0), UiMetrics.dp(170.0))\n"
    "	var h := clampf(UiMetrics.available().y - UiMetrics.dp(130.0), UiMetrics.dp(150.0), UiMetrics.dp(238.0))\n"
    "	return Vector2(w, h)\n",
    "## 商品区可用尺寸（第 9 轮）：扣掉左右侧栏与外边距后，留给商品阵列的那一块。\n"
    "## ⚠️ 这里是**估算**而不是实测容器尺寸：`_build_goods()` 跑在容器 settle 之前，\n"
    "##    拿不到真实 rect。宁可估保守一点（算窄），也不要让卡片溢出屏幕外点不到。\n"
    "func _goods_avail() -> Vector2:\n"
    "	var avail := UiMetrics.available()\n"
    "	if UiMetrics.prefers_full_page():\n"
    "		# 小屏：无左属性栏；扣右侧出售栏（dp(180)）+ 栏间距 + 外边距 + 标题/材料/动作区高度\n"
    "		avail.x -= UiMetrics.dp(180.0) + 14.0 + UiMetrics.dp(24.0)\n"
    "		avail.y -= UiMetrics.dp(130.0)\n"
    "	else:\n"
    "		# 桌面：左属性栏 288 + 右出售栏 288 + 两个 14 栏间距 + 24 外边距\n"
    "		avail.x -= 288.0 * 2.0 + 14.0 * 2.0 + 24.0\n"
    "		avail.y -= 150.0\n"
    "	return Vector2(maxf(avail.x, 200.0), maxf(avail.y, 200.0))\n"
    "\n"
    "func _goods_min_w() -> float:\n"
    "	return UiMetrics.dp(110.0) if UiMetrics.prefers_full_page() else 150.0\n"
    "\n"
    "func _goods_min_h() -> float:\n"
    "	return UiMetrics.dp(120.0) if UiMetrics.prefers_full_page() else 150.0\n"
    "\n"
    "func _goods_max_h() -> float:\n"
    "	return UiMetrics.dp(238.0)\n"
    "\n"
    "## 商品阵列的行列（第 9 轮）。思路与菜单首页一致：**先把最大列数按宽度算出来，\n"
    "## 再用 ceil 反推行数，最后用 ceil(n/rows) 平均分列** —— 这样 6 格在「最多 4 列」\n"
    "## 的宽度下得到 3+3，而不是 4+2（后者最后一行只有两张，视觉上不平衡，\n"
    "## 也会让该行的卡比上一行宽，玩家点起来手感不一致）。\n"
    "func _goods_grid() -> Vector2i:\n"
    "	var n := maxi(1, goods.size())\n"
    "	var gap := 8.0\n"
    "	var avail := _goods_avail()\n"
    "	var max_cols := int(floor((avail.x + gap) / (_goods_min_w() + gap)))\n"
    "	max_cols = clampi(max_cols, 1, n)\n"
    "	var rows := int(ceil(float(n) / float(max_cols)))\n"
    "	var cols := int(ceil(float(n) / float(rows)))\n"
    "	return Vector2i(cols, rows)\n"
    "\n"
    "## 商品卡尺寸：由 `_goods_grid()` 的行列与可用区域反推，宽度/高度各自 clamp 到\n"
    "## 「最小可读」与「最大舒适」之间。桌面不再固定 150×238 —— 那是旧版溢出的根源。\n"
    "func _good_card_size() -> Vector2:\n"
    "	var g := _goods_grid()\n"
    "	var avail := _goods_avail()\n"
    "	var gap := 8.0\n"
    "	var w := (avail.x - gap * float(g.x - 1)) / float(g.x)\n"
    "	var h := (avail.y - gap * float(g.y - 1)) / float(g.y)\n"
    "	return Vector2(maxf(w, _goods_min_w()), clampf(h, _goods_min_h(), _goods_max_h()))\n",
))

# (5) _build_goods 写入 columns
sh_edits.append((
    "func _build_goods() -> void:\n"
    "	for c in _goods_box.get_children():\n",
    "func _build_goods() -> void:\n"
    "	# 每次重建都重算列数：货架格数 / 屏宽 / 左右栏都可能与上次不同\n"
    "	_goods_box.columns = _goods_grid().x\n"
    "	for c in _goods_box.get_children():\n",
))

# ============================================================ main.gd（暂停页属性栏）
ma_edits = []
ma_edits.append((
    "	# 左：角色属性面板\n"
    "	_pause_left = VBoxContainer.new()\n"
    "	_pause_left.add_theme_constant_override(\"separation\", 4)\n"
    "	hb.add_child(_mk_side_panel(side_l, _pause_left))\n",
    "	# 左：角色属性面板 —— 「固定视图 + 滚动条」（第 9 轮 · 用户要求）。\n"
    "	# 属性行数随道具 / 法宝 / 同化度增长，裸 VBox 超出面板高度只会被裁掉，\n"
    "	# 而且裁掉的部分**没有任何提示**（暂停页又正是玩家想核对属性的地方）。\n"
    "	_pause_left = VBoxContainer.new()\n"
    "	_pause_left.size_flags_horizontal = Control.SIZE_EXPAND_FILL\n"
    "	_pause_left.add_theme_constant_override(\"separation\", 4)\n"
    "	var pl_scroll := ScrollContainer.new()\n"
    "	pl_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL\n"
    "	pl_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL\n"
    "	pl_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED\n"
    "	pl_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO\n"
    "	pl_scroll.add_child(_pause_left)\n"
    "	hb.add_child(_mk_side_panel(side_l, pl_scroll))\n",
))

# ============================================================ hint_bubble.gd
hb_edits = []

hb_edits.append((
    "## 尺寸上限（超出则内部滚动）—— 屏幕小的时候防止气泡长到出屏\n"
    "const MAX_H := 260.0\n",
    "## 尺寸上限（超出则内部滚动）—— 屏幕小的时候防止气泡长到出屏\n"
    "const MAX_H := 260.0\n"
    "## ---- 点击详情的「固定视图」（第 9 轮 · 用户要求）----\n"
    "## 用户原话：「属性和道具查看的时候就是固定视图 + 滚动条」。\n"
    "## 跟随鼠标的气泡读长描述时很别扭：同一个属性在商店不同格点开、位置都不同，\n"
    "## 视线每次都要重新找位置。所以**点击详情**改成钉在右侧固定位、内部滚动；\n"
    "## **悬浮仍然跟随鼠标**（那是一眼扫过的短提示，贴着指针才对）。\n"
    "const DOCK_W := 360.0       # 固定视图宽度（位置稳定比「刚好包住文字」重要）\n"
    "const DOCK_MAX_H := 340.0   # 固定视图高度上限，超出则内部滚动\n"
    "const DOCK_MARGIN := 12.0   # 距屏幕右缘的边距（与安全区取较大者）\n",
))

hb_edits.append((
    "var _last_title := \"\"\n",
    "var _last_title := \"\"\n"
    "var _docked := false   # 本气泡当前是不是「固定视图」（点击详情）——悬浮提示不受影响\n",
))

hb_edits.append((
    "	var bb := for_host(host)\n"
    "	target.gui_input.connect(func(e: InputEvent) -> void:\n"
    "		var pressed := (e is InputEventMouseButton and (e as InputEventMouseButton).pressed\n"
    "				and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT) \\\n"
    "			or (e is InputEventScreenTouch and (e as InputEventScreenTouch).pressed)\n"
    "		if not pressed:\n"
    "			return\n"
    "		var res: Dictionary = provider.call()\n"
    "		bb.show_at(String(res.get(\"title\", \"\")), String(res.get(\"body\", \"\")))\n"
    "		target.accept_event()      # 消费掉，别再传给底下的按钮\n"
    "	)\n",
    "	var bb := for_host(host)\n"
    "	target.gui_input.connect(func(e: InputEvent) -> void:\n"
    "		var pressed := (e is InputEventMouseButton and (e as InputEventMouseButton).pressed\n"
    "				and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT) \\\n"
    "			or (e is InputEventScreenTouch and (e as InputEventScreenTouch).pressed)\n"
    "		if not pressed:\n"
    "			return\n"
    "		var res: Dictionary = provider.call()\n"
    "		bb.show_docked(String(res.get(\"title\", \"\")), String(res.get(\"body\", \"\")))\n"
    "		target.accept_event()      # 消费掉，别再传给底下的按钮\n"
    "	)\n",
))

hb_edits.append((
    "	var vp := get_viewport().get_visible_rect().size\n"
    "	var p := get_viewport().get_mouse_position() + Vector2(18.0, 18.0)\n"
    "	p.x = clampf(p.x, 4.0, maxf(4.0, vp.x - size.x - 4.0))\n"
    "	p.y = clampf(p.y, 4.0, maxf(4.0, vp.y - size.y - 4.0))\n"
    "	position = p\n"
    "\n"
    "func hide_now() -> void:\n"
    "	visible = false\n"
    "	_last_title = \"\"\n",
    "	var vp := get_viewport().get_visible_rect().size\n"
    "	var p := get_viewport().get_mouse_position() + Vector2(18.0, 18.0)\n"
    "	p.x = clampf(p.x, 4.0, maxf(4.0, vp.x - size.x - 4.0))\n"
    "	p.y = clampf(p.y, 4.0, maxf(4.0, vp.y - size.y - 4.0))\n"
    "	_docked = false\n"
    "	position = p\n"
    "\n"
    "## ---- 点击详情：固定视图 + 滚动条 ----\n"
    "## 与 `show_at` 的差别只有两处：① 宽度固定成 DOCK_W（不随文字长短抖）\n"
    "## ② 位置固定成「右侧、垂直居中」（不跟鼠标）。滚动条两者共用（见 `_ensure`）。\n"
    "func show_docked(title_text: String, body_text: String) -> void:\n"
    "	_ensure()\n"
    "	_title.text = title_text\n"
    "	_body.text = body_text\n"
    "	_last_title = title_text\n"
    "	_docked = true\n"
    "	visible = true\n"
    "	reset_size()\n"
    "	var vp := get_viewport().get_visible_rect().size\n"
    "	var want := get_combined_minimum_size()\n"
    "	want.x = maxf(DOCK_W, minf(want.x, MAX_W))\n"
    "	if want.y > DOCK_MAX_H:\n"
    "		want.y = DOCK_MAX_H\n"
    "		_scroll.custom_minimum_size = Vector2(0.0, DOCK_MAX_H - 42.0)\n"
    "	size = want\n"
    "	var m := UiMetrics.margin()\n"
    "	var edge := maxf(m.x, DOCK_MARGIN)\n"
    "	# 右侧固定位：避开商店左侧属性栏，也不压中间的商品卡（会挡住右侧「已购道具」，\n"
    "	# 但那是可关闭的临时详情，且点别处即收 —— 比「位置到处跳」好得多）\n"
    "	var x := maxf(edge, vp.x - size.x - edge)\n"
    "	var y := clampf((vp.y - size.y) * 0.5, m.y, maxf(m.y, vp.y - size.y - m.y))\n"
    "	position = Vector2(x, y)\n"
    "\n"
    "func hide_now() -> void:\n"
    "	visible = false\n"
    "	_last_title = \"\"\n"
    "	_docked = false\n",
))

# ============================================================ 执行
ok = True
for tag, edits in [("menu", mn_edits), ("shop", sh_edits), ("main", ma_edits), ("hint", hb_edits)]:
    p = FILES[tag]
    src = rd(p)
    out = apply(src, edits, tag)
    if out is None:
        ok = False
        print("%s NOT WRITTEN" % tag)
        continue
    wr(p, out)
    print("%s: %d -> %d chars (已写盘)" % (tag, len(src), len(out)))

print("DONE" if ok else "FAILED")
sys.exit(0 if ok else 1)
