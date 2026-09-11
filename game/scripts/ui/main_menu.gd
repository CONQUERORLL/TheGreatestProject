extends Control
## 主菜单 + 开局向导（分步）：开始游戏 → ① 角色 → ② 初始武器 → ③ 初始道具 → ④ 难度 → ⑤ 模式 → 进入游戏
## 选项全部来自 Registry 注册表（创意工坊内容自动出现）；鼠标 + 手柄均可操作
## Esc / 手柄 B：向导内返回上一步，首页退出；首页含无尽炼积分排行榜入口

var _g_diff := ButtonGroup.new()
var _g_char := ButtonGroup.new()
var _g_weapon := ButtonGroup.new()
var _g_item := ButtonGroup.new()
var _g_mode := ButtonGroup.new()

# 缓存向导每步选中 id（ButtonGroup 按钮跨步骤被释放后 get_pressed_button 返回 null）
var _sel_char := "potato"
var _sel_weapon := "pistol"
var _sel_item := ""
var _sel_diff := "normal"
var _sel_endless := false   # 第 5 步：标准模式 / 无尽炼狱

var _home: Control
var _wizard: Control
var _step_label: Label
var _options: GridContainer
var _back_btn: Button
var _next_btn: Button
var _step := 0
var _slots_panel: Control     # 选槽弹窗（开始新局 / 继续共用）
var _slots_title: Label
var _slots_tip: Label
var _slot_btns: Array = []    # 3 个槽位 Button（下标 0~2 = 槽 1~3）
var _slots_mode := "new"      # "new" = 开始新局（有档需覆盖确认）| "continue" = 读取
var _confirm_slot := 0        # 覆盖确认态的槽号（0 = 无）
var _lb_panel: Control        # 无尽炼狱排行榜弹窗
var _lb_rows: VBoxContainer
var _lb_mode := "endless"     # 排行榜标签：endless 无尽总榜 / daily 今日榜
var _lb_title: Label
var _lb_btn_endless: Button
var _lb_btn_daily: Button
var _talent_panel: Control    # 天赋树弹窗
var _talent_essence: Label    # 精华余额
var _talent_rows: VBoxContainer
var _daily_panel: Control     # 每日挑战详情弹窗
var _codex                   # 图鉴（scripts/ui/codex.gd，动态引用避免跨脚本静态类型）

# ---- 自定义开局规则面板 ----
var _rules_panel: Control
var _rules_rows: VBoxContainer
var _rules_rating: Label
var _rules_code_edit: LineEdit
var _rules_preset_edit: LineEdit
var _rules_preset_box: VBoxContainer
var _rules_enable_btn: Button
var _rules_warn: Label
var _rules_base_group := ButtonGroup.new()
var _rules_base_btns: Array = []
var _rules_preview: Label

const TOTAL_STEPS := 5
const STEP_TITLES := ["选择角色", "选择初始武器", "选择初始道具", "选择难度", "选择模式"]

## 向导面板尺寸（与 _build_wizard 里的 PanelContainer 一致）
const WIZARD_W := 1000.0
const WIZARD_H := 620.0
## 网格实际可用宽度 = 面板宽 - 面板内边距 - 滚动条余量 - 网格包壳左右 margin(8+8)
const GRID_BOX_W := WIZARD_W - 32.0
## 网格间距（与 _options 的 h_separation / v_separation 一致）
const GRID_GAP := 10.0
## 选项区可用高度 = 面板高 - 步骤标题 - 底部按钮行 - VBox 间距 - 面板内边距（保守 12）
const GRID_BOX_H := WIZARD_H - 60.0 - 44.0 - 28.0 - 12.0
## 卡片尺寸上下限：下限保证内容不被裁切（卡面含图标/标题/两三行描述），
## 上限避免张数很少时卡片被拉成巨块。宽度上限放到 ~500，
## 好让"2 张 ÷ 2 列"（模式步）也能横向铺满；普通张数仍由判据选到更窄的列宽
const CARD_W_MIN := 176.0
const CARD_W_MAX := 500.0
## 高度上限放宽到接近一整屏可用高度：张数少时（如难度 3~4 张、模式 2 张）
## 单行能撑满纵向，避免上下大片留白；内容仍靠 VBox 居中，不会显得空
const CARD_H_MIN := 150.0
const CARD_H_MAX := 420.0
## 卡片宽高比上限：卡片过扁（宽 ≫ 高）会很空，超过则回退到更多列/行的排布
const CARD_ASPECT_MAX := 1.9

func _ready() -> void:
	SaveRun.migrate_legacy_if_needed()
	Music.play_track("menu", 0.5)
	var bg := ColorRect.new()
	bg.color = Color("101218")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_build_home()
	_build_wizard()
	_build_slots_panel()
	_build_leaderboard_panel()
	_build_talent_panel()
	_build_daily_panel()
	_build_codex()
	_build_rules_panel()

# ---------------- 存档槽选择弹窗 ----------------

func _build_slots_panel() -> void:
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.visible = false
	add_child(overlay)
	_slots_panel = overlay
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.65)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	center.add_child(box)
	_slots_title = Label.new()
	_slots_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_slots_title.add_theme_font_size_override("font_size", 24)
	_slots_title.add_theme_color_override("font_color", Color("e8b84b"))
	box.add_child(_slots_title)
	_slots_tip = Label.new()
	_slots_tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_slots_tip.add_theme_font_size_override("font_size", 13)
	_slots_tip.add_theme_color_override("font_color", Color("9aa3b2"))
	box.add_child(_slots_tip)
	for i in range(1, SaveRun.SLOT_COUNT + 1):
		var b := Button.new()
		b.custom_minimum_size = Vector2(460, 76)
		b.add_theme_font_size_override("font_size", 16)
		b.pressed.connect(_on_slot_pressed.bind(i))
		box.add_child(b)
		_slot_btns.append(b)
	var cancel := Button.new()
	cancel.text = "取　消"
	cancel.custom_minimum_size = Vector2(460, 46)
	cancel.pressed.connect(_close_slots)
	box.add_child(cancel)

## 打开选槽：mode = "new"（开始新局，有档覆盖需确认）| "continue"（读取有档槽）
func _open_slots(mode: String) -> void:
	Haptics.rumble(0.2, 0.0, 0.08)
	_slots_mode = mode
	_confirm_slot = 0
	_slots_panel.visible = true
	_home.visible = false
	if mode == "new":
		_slots_title.text = "选 择 存 档 槽"
		_slots_tip.text = "选空槽直接开始 · 点已有进度槽并再次点击确认覆盖"
	else:
		_slots_title.text = "继 续 游 戏"
		_slots_tip.text = "选择要继续的存档槽（空槽不可用）"
	_refresh_slots()
	# 焦点给第一个可用槽
	for b in _slot_btns:
		if not b.disabled:
			b.grab_focus()
			break

func _close_slots() -> void:
	_slots_panel.visible = false
	_home.visible = true
	for c in _home.get_child(0).get_children():
		if c is Button:
			c.grab_focus()   # 焦点回首页第一个按钮
			break

func _refresh_slots() -> void:
	for i in range(1, SaveRun.SLOT_COUNT + 1):
		var b: Button = _slot_btns[i - 1]
		var has := SaveRun.exists(i)
		if _slots_mode == "continue":
			b.disabled = not has
			b.text = _slot_label(i) if has else "第 %d 槽 · 空（不可用）" % i
			continue
		b.disabled = false
		if _confirm_slot == i:
			b.text = "⚠ 覆盖第 %d 槽？再点一次确认" % i
			b.add_theme_color_override("font_color", Color("e0644f"))
		else:
			var info := _slot_label(i)
			b.text = info + "\n（开始新局将覆盖此进度）" if has else info
			b.remove_theme_color_override("font_color")

## 槽位显示文本：槽号 · 波次 · 角色名 · 保存时间（无尽档带 🔥 与积分）
func _slot_label(i: int) -> String:
	var s := SaveRun.summary(i)
	if s.is_empty():
		return "第 %d 槽 · 空" % i
	var ch: Dictionary = Registry.get_character(String(s.get("character_id", "potato")))
	if ch.is_empty():
		ch = Registry.get_character("potato")
	var when := String(s.get("saved_at", ""))
	if when != "":
		when = "\n" + when
	if bool(s.get("endless", false)):
		return "第 %d 槽 · 🔥 第 %d 波 %s · 积分 %d%s" % [i, int(s.get("wave", 1)),
			String(ch.get("name", "")), int(s.get("score", 0)), when]
	return "第 %d 槽 · 第 %d 波 %s%s" % [i, int(s.get("wave", 1)), String(ch.get("name", "")), when]

func _on_slot_pressed(i: int) -> void:
	if _slots_mode == "continue":
		_do_continue(i)
		return
	# 开始新局：已有进度的槽需要一次覆盖确认（再点一次）
	if SaveRun.exists(i) and _confirm_slot != i:
		_confirm_slot = i
		_refresh_slots()
		return
	_do_new(i)

## 开新局先绑定槽位并进入向导；最终确认前不清旧档，允许安全取消
func _do_new(slot: int) -> void:
	GameState.slot_id = slot
	GameState.continue_pending = false
	SaveRun.current_run_owns_slot = false
	_slots_panel.visible = false
	_open_wizard()

## 读取指定槽继续：置标志 → main._ready 消费并恢复
func _do_continue(slot: int) -> void:
	GameState.slot_id = slot
	GameState.continue_pending = true
	SaveRun.current_run_owns_slot = false
	Haptics.rumble(0.3, 0.0, 0.1)
	get_tree().change_scene_to_file("res://scenes/main.tscn")

# ---------------- 首页 ----------------

func _build_home() -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	_home = center
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	center.add_child(box)
	var title := Label.new()
	title.text = "🥔 土豆兄弟 LITE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 46)
	title.add_theme_color_override("font_color", Color("e8b84b"))
	box.add_child(title)
	var sub := Label.new()
	sub.text = "俯视角生存射击 Roguelite · PC / 移动端 / 手柄"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 13)
	sub.add_theme_color_override("font_color", Color("9aa3b2"))
	box.add_child(sub)
	box.add_child(Control.new())   # 间隔
	var start_btn: Button = null
	for spec in _home_specs():
		var b := Button.new()
		b.text = spec[0]
		b.custom_minimum_size = Vector2(spec[1], 52.0)
		b.add_theme_font_size_override("font_size", 19)
		b.pressed.connect(spec[2])
		box.add_child(b)
		if spec[0] == "开 始 游 戏":
			start_btn = b
	start_btn.grab_focus()   # “开始游戏”默认焦点（手柄直达）

## 首页按钮清单：任一槽有档时头部插入"继续游戏"（进选槽弹窗）
func _home_specs() -> Array:
	var specs: Array = []
	if SaveRun.any_exists():
		specs.append(["继 续 游 戏", 220.0, func() -> void: _open_slots("continue")])
	specs.append(["开 始 游 戏", 220.0, func() -> void: _open_slots("new")])
	specs.append(["自 定 义 规 则", 220.0, func() -> void: _open_rules()])
	specs.append(["每 日 挑 战", 220.0, func() -> void: _open_daily()])
	specs.append(["排 行 榜", 220.0, func() -> void: _open_leaderboard()])
	specs.append(["天 赋 树", 220.0, func() -> void: _open_talents()])
	specs.append(["图　　鉴", 220.0, func() -> void: _open_codex()])
	specs.append(["设　　　置", 220.0, func() -> void: get_tree().change_scene_to_file("res://scenes/ui/settings.tscn")])
	specs.append(["创 意 工 坊", 220.0, func() -> void: get_tree().change_scene_to_file("res://scenes/ui/workshop.tscn")])
	specs.append(["退　　出", 220.0, func() -> void: get_tree().quit()])
	return specs

# ---------------- 开局向导 ----------------

func _build_wizard() -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.visible = false
	add_child(center)
	_wizard = center
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(WIZARD_W, WIZARD_H)
	center.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	panel.add_child(vbox)
	_step_label = Label.new()
	_step_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_step_label.add_theme_font_size_override("font_size", 24)
	_step_label.add_theme_color_override("font_color", Color("e8b84b"))
	vbox.add_child(_step_label)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)
	# 中间垫一层 CenterContainer + MarginContainer：内容不满一屏时垂直居中（消除底部留白），
	# 超出时正常滚动。GridContainer 自身无法在滚动容器里居中，故用外层包壳实现。
	var grid_wrap := CenterContainer.new()
	grid_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid_wrap)
	var grid_pad := MarginContainer.new()
	grid_pad.add_theme_constant_override("margin_left", 8)
	grid_pad.add_theme_constant_override("margin_right", 8)
	grid_wrap.add_child(grid_pad)
	_options = GridContainer.new()
	_options.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_options.add_theme_constant_override("h_separation", 10)
	_options.add_theme_constant_override("v_separation", 10)
	grid_pad.add_child(_options)
	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.add_theme_constant_override("separation", 24)
	vbox.add_child(hb)
	_back_btn = Button.new()
	_back_btn.text = "上一步（Esc）"
	_back_btn.custom_minimum_size = Vector2(160.0, 44.0)
	_back_btn.pressed.connect(_prev)
	hb.add_child(_back_btn)
	_next_btn = Button.new()
	_next_btn.custom_minimum_size = Vector2(200.0, 44.0)
	_next_btn.add_theme_font_size_override("font_size", 17)
	_next_btn.pressed.connect(_next)
	hb.add_child(_next_btn)

func _open_wizard() -> void:
	Haptics.rumble(0.2, 0.0, 0.08)
	_home.visible = false
	_wizard.visible = true
	_step = 0
	_build_step()

func _close_wizard() -> void:
	_wizard.visible = false
	_home.visible = true
	for c in _home.get_child(0).get_children():
		if c is Button:
			c.grab_focus()   # 回首页聚焦第一个按钮（继续/开始游戏）
			break

## 自适应网格：给定选项张数，算出「列数 + 卡片尺寸」，让网格尽量铺满面板。
##
## 动机：固定列数会在内容少时四周留白（武器步 6 张 ÷ 3 列 = 2 行，横向只占 674/1000）。
## 这里反其道而行 —— 先挑一个"最优列数"，再把卡片撑到该列宽、行高撑满可用高度，
## 于是无论 6 张还是 12 张都填满面板（与角色步同款观感）。
## 最优判据（依次比较）：① 网格空槽最少（避免末行残缺导致留白）② 行数更少（纵向更舒展）
## ③ 卡片更宽（横向更饱满）。返回 { "cols": int, "size": Vector2 }。
##
## min_h：本步卡片的内容高度下限（角色卡描述长需要更高）。行高不足时优先保证它，
## 由调用方决定是否因此允许纵向留白（宁可滚动，也不要把文字挤出卡外）。
func _fit_grid(n: int, min_h: float = CARD_H_MIN) -> Dictionary:
	if n <= 0:
		return { "cols": 1, "size": Vector2(CARD_W_MIN, min_h) }
	# 候选列数上限：卡片不低于 CARD_W_MIN 时可容纳的列数
	var max_cols := maxi(1, int(floor((GRID_BOX_W + GRID_GAP) / (CARD_W_MIN + GRID_GAP))))
	max_cols = mini(max_cols, n)
	# 两轮筛选：第一轮带全部约束；若一张列数都没通过（典型是 2 张卡 ——
	# 单列/双列都会超出宽度上限），第二轮放宽宽度上限只保留宽高比护栏，
	# 宁可卡片宽一点，也不要退化成"单列 + 右侧大片空白"。
	var picked := _pick_grid(n, max_cols, CARD_W_MAX, CARD_ASPECT_MAX, min_h)
	if picked.is_empty():
		picked = _pick_grid(n, max_cols, 1.0e9, CARD_ASPECT_MAX, min_h)
	if picked.is_empty():
		picked = _pick_grid(n, max_cols, 1.0e9, 1.0e9, min_h)
	if picked.is_empty():
		picked = { "cols": 1, "rows": n }
	var best_cols := int(picked.cols)
	var best_rows := int(picked.rows)
	var card_w := (GRID_BOX_W - float(best_cols - 1) * GRID_GAP) / float(best_cols)
	card_w = clampf(card_w, CARD_W_MIN, CARD_W_MAX)
	# 纵向：行高撑满可用高度（上限封顶，避免一两行被拉成巨块）
	var card_h := (GRID_BOX_H - float(best_rows - 1) * GRID_GAP) / float(best_rows)
	card_h = clampf(card_h, min_h, CARD_H_MAX)
	return { "cols": best_cols, "size": Vector2(card_w, card_h) }

## 在给定宽度上限 + 宽高比上限下挑最优列数；无可选列数返回空字典。
## 判据依次为：空槽最少 → 行数最少 → 卡片最宽。
## 只挑列数，不决定最终高度 —— 高度由 _fit_grid 统一 clamp（低于 min_h 会撑高并可滚动）。
func _pick_grid(n: int, max_cols: int, w_cap: float, aspect_cap: float, min_h: float) -> Dictionary:
	var best_cols := 0
	var best_waste := 0x7fffffff
	var best_rows := n
	var best_w := 0.0
	for cols in range(1, max_cols + 1):
		var rows := int(ceil(float(n) / float(cols)))
		var w := (GRID_BOX_W - float(cols - 1) * GRID_GAP) / float(cols)
		if w > w_cap:
			continue   # 该列数会把卡片撑得过宽，跳过
		# 宽高比护栏：卡片按此列数撑开后若过扁（宽 ≫ 高），观感很差，跳过
		var h_at := clampf((GRID_BOX_H - float(rows - 1) * GRID_GAP) / float(rows),
			min_h, CARD_H_MAX)
		if w / h_at > aspect_cap:
			continue
		var waste := cols * rows - n   # 末行空槽数：0 表示刚好填满
		var better := false
		if waste < best_waste:
			better = true
		elif waste == best_waste and rows < best_rows:
			better = true
		elif waste == best_waste and rows == best_rows and w > best_w:
			better = true
		if better:
			best_waste = waste
			best_rows = rows
			best_cols = cols
			best_w = w
	if best_cols <= 0:
		return {}
	return { "cols": best_cols, "rows": best_rows }

func _build_step() -> void:
	for c in _options.get_children():
		_options.remove_child(c)
		c.queue_free()
	_step_label.text = "第 %d 步 / 共 %d 步 · %s" % [_step + 1, TOTAL_STEPS, STEP_TITLES[_step]]
	_back_btn.visible = _step > 0
	_next_btn.text = "开 始 游 戏" if _step == TOTAL_STEPS - 1 else "下一步 →"
	match _step:
		0:
			# 角色卡描述最长（特性 + 玩法定位两段），给足高度下限；
			# 12 张 ÷ 4 列 = 3 行若装不下就纵向滚动，绝不把文字挤出卡外
			var fit0 := _fit_grid(Registry.characters.size(), 212.0)
			_options.columns = int(fit0.cols)
			for c: Dictionary in Registry.characters.values():
				var locked := not Unlocks.is_unlocked("character", String(c.id))
				_options.add_child(_make_card(_g_char, c.id,
					c.get("ico", "?"), c.name, _character_card_desc(c),
					c.id == _sel_char, Color(c.get("color", "#e8b84b")), c.id,
					locked, Unlocks.unlock_hint("character", String(c.id)), fit0.size))
		1:
			# 开局武器：只数一遍实际可展示的张数，再算列数/尺寸，
			# 保证 Registry 缺项时列数不会算错（否则会出现空列留白）
			var wids: Array = []
			for wid in Config.LOADOUT_WEAPONS:
				if Registry.weapons.has(wid):
					wids.append(wid)
			var fit1 := _fit_grid(wids.size())
			_options.columns = int(fit1.cols)
			for wid in wids:
				var w: Dictionary = Registry.weapons[wid]
				var locked := not Unlocks.is_unlocked("weapon", String(wid))
				_options.add_child(_make_card(_g_weapon, String(wid),
					w.ico, w.name, "%s\n伤害 %.0f · CD %.2fs" % [w.desc, float(w.dmg), float(w.cd)],
					String(wid) == _sel_weapon, Config.rarity_color("common"), "",
					locked, Unlocks.unlock_hint("weapon", String(wid)), fit1.size))
		2:
			# 道具步张数多（1 空手 + 白名单），卡片走较小尺寸、按列铺满后靠滚动查看更多
			var item_count := 1
			for itid in Config.LOADOUT_ITEMS:
				if Registry.items.has(itid):
					item_count += 1
			var fit2 := _fit_grid(item_count)
			_options.columns = int(fit2.cols)
			_options.add_child(_make_card(_g_item, "", "✖", "不带道具", "空手开局",
				_sel_item == "", Color("5a6270"), "", false, "", fit2.size))
			# 开局道具只开放前期过渡档（LOADOUT_ITEMS），并按当前角色+武器的构筑亲和排序，
			# 相关道具优先展示 —— 不全部开放，避免开局就拿到神器直接降低难度
			var aff: Array = Config.affinity_tags(_sel_char, [_sel_weapon], {})
			var sorted_items: Array = []
			for itid in Config.LOADOUT_ITEMS:
				if not Registry.items.has(itid):
					continue
				var it: Dictionary = Registry.items[itid]
				sorted_items.append({ "it": it,
					"aff": Config.affinity_mult(Config.entry_tags(it), aff) })
			sorted_items.sort_custom(func(a, b): return float(a["aff"]) > float(b["aff"]))
			for e in sorted_items:
				var it: Dictionary = e.it
				_options.add_child(_make_card(_g_item, it.id,
					it.ico, it.name, it.desc, it.id == _sel_item,
					Config.rarity_color(it.get("rarity", "common")), "", false, "", fit2.size))
		3:
			var fit3 := _fit_grid(Registry.difficulties.size())
			_options.columns = int(fit3.cols)
			# 自定义规则启用时，这一步选的是「基准难度」—— 规则里难度组四项
			# 是叠乘在它之上的倍率（见 RunRules 文件头「方案 A」）
			var diff_note := "\n\n⚠ 已启用自定义规则：此难度作为基准，规则倍率叠加其上" \
				if RunRules.active else ""
			for d: Dictionary in Registry.difficulties.values():
				_options.add_child(_make_card(_g_diff, d.id,
					"⚔", d.name, "%s\n敌人血量 x%.1f · 伤害 x%.1f\n刷怪密度 x%.1f%s" % [
						d.get("desc", ""), float(d.hp_mult), float(d.dmg_mult),
						float(d.spawn_mult), diff_note],
					d.id == _sel_diff,
					Config.DIFFICULTY_COLORS.get(d.id, Color("e8b84b")), "", false, "", fit3.size))
		4:
			var fit4 := _fit_grid(2)
			_options.columns = int(fit4.cols)
			_options.add_child(_make_card(_g_mode, "standard", "🥔", "标准模式",
				"10 波通关挑战\n击败最终 BOSS 即胜利",
				not _sel_endless, Color("7ec850"), "", false, "", fit4.size))
			_options.add_child(_make_card(_g_mode, "endless", "🔥", "无尽炼狱",
				"波次无上限 · 每 10 波一轮 BOSS\n击杀累计积分 · 冲击排行榜",
				_sel_endless, Color("e0564f"), "", false, "", fit4.size))
	# 焦点：已选中的卡片，否则第一张可用卡（跳过锁定/禁用卡）
	var focus_target: Button = null
	for b in _options.get_children():
		if b.button_pressed and not b.disabled:
			focus_target = b
			break
	if focus_target == null:
		for b in _options.get_children():
			if not b.disabled:
				focus_target = b
				break
	if focus_target:
		focus_target.grab_focus()

## 角色卡描述：特性置顶 + 玩法定位。
## 特性是"为什么要选这个角色"的唯一答案，必须第一眼可见 ——
## 只写属性取舍（攻速 +50%、伤害 -30%）玩家根本感受不到角色差异。
## 注意：两段都要短 —— 卡片是网格布局，长文本会把内容挤出卡外（见 _fit_grid 的高度下限）
func _character_card_desc(c: Dictionary) -> String:
	var t: Dictionary = c.get("trait", {})
	var role := String(c.get("desc", ""))
	if t.is_empty():
		return role
	return "⚡【%s】%s\n%s" % [
		String(t.get("name", "")), String(t.get("desc", "")), role]

## 选项卡片：暗底 + 稀有度/角色/难度色描边，大图标 + 色名 + 描述；选中即确认
## 前三步自动进入下一步，最后一步聚焦"开始游戏"防误触
## char_id 非空时卡面用程序化角色头像替代 emoji 图标
## locked=true 时：灰态 + 🔒 + 解锁提示，且不可选（解锁系统）
## size 为空时回落到旧默认（218×244），由 _fit_grid 统一给出自适应尺寸
func _make_card(group: ButtonGroup, id: String, ico: String, title_text: String, desc: String, pressed: bool, accent: Color, char_id: String = "", locked: bool = false, lock_hint: String = "", size: Vector2 = Vector2.ZERO) -> Button:
	var card_size := size if size != Vector2.ZERO else Vector2(218.0, 244.0)
	var b := Button.new()
	b.toggle_mode = true
	b.button_group = group
	b.button_pressed = pressed and not locked
	b.set_meta("id", id)
	b.disabled = locked
	# 卡面高度容纳「特性描述 + 玩法定位」两段文本（角色步），
	# 其余步骤内容较短，靠 VBox 居中，视觉上仍然平衡
	b.custom_minimum_size = card_size
	# 卡面样式：accent 色微底 + 描边，hover/focus 金边高亮（手柄导航可见）
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(accent.r, accent.g, accent.b, 0.09)
	normal.border_color = accent
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(10)
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = Color(accent.r, accent.g, accent.b, 0.20)
	hover.border_color = Color("e8b84b")
	var dis: StyleBoxFlat = normal.duplicate()
	dis.bg_color = Color(accent.r, accent.g, accent.b, 0.04)
	dis.border_color = Color("3a414d")
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("focus", hover.duplicate())
	b.add_theme_stylebox_override("pressed", hover.duplicate())
	b.add_theme_stylebox_override("disabled", dis)
	# 卡面内容（不拦截鼠标，保证按钮可点）
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(box)
	# 卡内元素随卡宽缩放：窄卡（如 4 列的难度/模式步）用小一号图标与文字，
	# 宽卡（如 2 列的武器步）用大一号，避免小卡拥挤 / 大卡空洞
	var scale := clampf(card_size.x / 218.0, 0.82, 1.35)
	var icon_px := roundi(36.0 * scale)
	var name_px := roundi(17.0 * scale)
	var desc_px := maxi(11, roundi(11.0 * scale))
	var desc_w := maxf(120.0, card_size.x - 26.0)
	if char_id != "":
		# 角色专属人物头像（程序化绘制）。角色卡文字最长（特性 + 定位两段），
		# 头像刻意比纯图标卡小一号，把纵向空间让给文字
		var av := CharacterAvatar.new()
		av.setup(char_id, round(58.0 * scale))
		box.add_child(av)
	else:
		var ico_l := Label.new()
		ico_l.text = "🔒" if locked else ico
		ico_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ico_l.add_theme_font_size_override("font_size", icon_px)
		ico_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(ico_l)
	var name_l := Label.new()
	name_l.text = title_text
	name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_l.add_theme_font_size_override("font_size", name_px)
	name_l.add_theme_color_override("font_color",
		Color("5a6270") if locked else accent.lightened(0.15))
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(name_l)
	var desc_l := Label.new()
	desc_l.text = ("未解锁\n%s" % lock_hint) if locked else desc
	desc_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc_l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	desc_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_l.custom_minimum_size = Vector2(desc_w, 0.0)
	# 硬护栏：卡面是固定尺寸的网格单元，描述文本绝不能溢出到相邻卡片上。
	# 让它吃掉剩余高度并 clip，保证极端内容最多被裁掉尾巴，而不是糊到隔壁卡上
	desc_l.size_flags_vertical = Control.SIZE_EXPAND_FILL
	desc_l.clip_text = true
	desc_l.add_theme_font_size_override("font_size", desc_px)
	desc_l.add_theme_color_override("font_color",
		Color("5a6270") if locked else Color("9aa3b2"))
	desc_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(desc_l)
	b.pressed.connect(func() -> void:
		# pressed 在已选中的单选卡上也会触发，因此默认卡可直接确认。
		b.button_pressed = true
		match _step:
			0: _sel_char = id
			1: _sel_weapon = id
			2: _sel_item = id
			3: _sel_diff = id
			4: _sel_endless = id == "endless"
		Haptics.rumble(0.15, 0.0, 0.05)
		if _step < TOTAL_STEPS - 1:
			_next()
		else:
			_next_btn.grab_focus())
	return b

func _next() -> void:
	if _step < TOTAL_STEPS - 1:
		_step += 1
		_build_step()
	else:
		_start()

func _prev() -> void:
	if _step > 0:
		_step -= 1
		_build_step()
	else:
		_close_wizard()

func _unhandled_input(event: InputEvent) -> void:
	if _codex != null and _codex.visible:
		return   # 图鉴自行处理返回键，避免重复消费
	# 自定义规则面板：Esc / 手柄 B 关闭（输入框获得焦点时让 LineEdit 先处理，
	# 否则玩家按 Esc 想撤销输入会直接把整个面板关掉）
	if _rules_panel.visible and event.is_action_pressed("ui_cancel"):
		var focus_r := get_viewport().gui_get_focus_owner()
		if focus_r is LineEdit:
			focus_r.release_focus()
			get_viewport().set_input_as_handled()
			return
		_close_rules()
		get_viewport().set_input_as_handled()
		return
	# 每日挑战弹窗：Esc / 手柄 B 关闭
	if _daily_panel.visible and event.is_action_pressed("ui_cancel"):
		_close_daily()
		get_viewport().set_input_as_handled()
		return
	# 天赋树弹窗：Esc / 手柄 B 关闭
	if _talent_panel.visible and event.is_action_pressed("ui_cancel"):
		_close_talents()
		get_viewport().set_input_as_handled()
		return
	# 排行榜弹窗：Esc / 手柄 B 关闭
	if _lb_panel.visible and event.is_action_pressed("ui_cancel"):
		_close_leaderboard()
		get_viewport().set_input_as_handled()
		return
	# 选槽弹窗：返回键退出覆盖确认态，再按关闭弹窗
	if _slots_panel.visible and event.is_action_pressed("ui_cancel"):
		if _confirm_slot != 0:
			_confirm_slot = 0
			_refresh_slots()
		else:
			_close_slots()
		get_viewport().set_input_as_handled()
		return
	# Esc / 手柄 B：向导内回上一步
	if _wizard.visible and event.is_action_pressed("ui_cancel"):
		_prev()
		get_viewport().set_input_as_handled()
		return
	# 手柄 A / Enter：确认选中焦点卡片
	if _wizard.visible and event.is_action_pressed("ui_accept"):
		var focus := get_viewport().gui_get_focus_owner()
		if focus is Button and focus.toggle_mode and not focus.disabled:
			focus.pressed.emit()
			get_viewport().set_input_as_handled()
		return

func _start() -> void:
	GameState.difficulty_id = _sel_diff
	GameState.character_id = _sel_char
	GameState.loadout_weapon = _sel_weapon
	GameState.loadout_item = _sel_item
	GameState.endless = _sel_endless
	GameState.daily = false
	GameState.continue_pending = false
	# 自定义开局规则（方案 A：继承 + 叠加）：
	# 把向导第 4 步选的难度记为本局基准，规则里难度组四项作为倍率叠乘其上；
	# 启用时返回 "custom"（合成条目），未启用则原样返回所选难度，无副作用。
	# 注意基准由这里传入，而不是用规则面板里临时点的值 ——
	# 向导选择才是玩家最终确认的开局配置
	GameState.difficulty_id = RunRules.apply_to_run(_sel_diff)
	# Main 在玩家初始化后原子覆盖该槽；场景加载或写入失败时旧档仍保留。
	Haptics.rumble(0.3, 0.0, 0.1)
	get_tree().change_scene_to_file("res://scenes/main.tscn")

# ---------------- 每日挑战（全服同局） ----------------

## 今日配置卡片：日期种子决定角色/难度/BOSS，全部玩家一致
func _build_daily_panel() -> void:
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.visible = false
	add_child(overlay)
	_daily_panel = overlay
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.65)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	center.add_child(box)
	var title := Label.new()
	title.text = "📅 每日挑战"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color("e8b84b"))
	box.add_child(title)
	var setup: Dictionary = Config.daily_setup(Time.get_date_string_from_system())
	var ch: Dictionary = Registry.get_character(String(setup.character_id))
	var diff: Dictionary = Registry.get_difficulty(String(setup.difficulty_id))
	var boss_name: String = Registry.enemies.get(String(setup.boss_id), {}).get("name", "?")
	var info := Label.new()
	info.text = "今日阵容全服一致：\n\n%s %s ｜ %s 难度 ｜ 最终 BOSS：%s\n\n同种子同商店序列 · 死亡/通关记入今日榜" % [
		ch.get("ico", "🧑"), ch.get("name", "?"), diff.get("name", "?"), boss_name]
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.add_theme_font_size_override("font_size", 15)
	info.add_theme_color_override("font_color", Color("d8dde6"))
	info.custom_minimum_size = Vector2(480.0, 0.0)
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(info)
	var start := Button.new()
	start.text = "开始今日挑战（不占存档槽）"
	start.custom_minimum_size = Vector2(480.0, 46.0)
	start.add_theme_font_size_override("font_size", 17)
	start.pressed.connect(_start_daily)
	box.add_child(start)
	var cancel := Button.new()
	cancel.text = "关 闭（Esc）"
	cancel.custom_minimum_size = Vector2(480.0, 44.0)
	cancel.pressed.connect(_close_daily)
	box.add_child(cancel)

func _open_daily() -> void:
	Haptics.rumble(0.2, 0.0, 0.08)
	_daily_panel.visible = true
	_home.visible = false
	for c in _daily_panel.get_child(1).get_child(0).get_children():
		if c is Button:
			c.grab_focus()
			break

func _close_daily() -> void:
	_daily_panel.visible = false
	_home.visible = true
	for c in _home.get_child(0).get_children():
		if c is Button:
			c.grab_focus()
			break

# ---------------- 图鉴 ----------------

## 挂载为主菜单子节点（全屏覆盖层）；关闭时发 closed 信号，焦点回首页
func _build_codex() -> void:
	_codex = preload("res://scenes/ui/codex.tscn").instantiate()
	add_child(_codex)
	_codex.closed.connect(_on_codex_closed)

func _open_codex() -> void:
	Haptics.rumble(0.2, 0.0, 0.08)
	_home.visible = false
	_codex.open()

func _on_codex_closed() -> void:
	_home.visible = true
	for c in _home.get_child(0).get_children():
		if c is Button:
			c.grab_focus()
			break

## 开始每日挑战：日期种子 + 固定阵容，直接进局（不占存档槽）
## 每日挑战必须全服同局，因此强制关闭自定义规则（否则"同种子"失去意义）
func _start_daily() -> void:
	var today := Time.get_date_string_from_system()
	var setup: Dictionary = Config.daily_setup(today)
	RunRules.active = false
	GameState.daily = true
	GameState.daily_date = today
	GameState.endless = false
	GameState.difficulty_id = String(setup.difficulty_id)
	GameState.character_id = String(setup.character_id)
	GameState.loadout_weapon = ""
	GameState.loadout_item = ""
	GameState.slot_id = 0   # 0 = 不落盘（SaveRun 全部拒绝）
	GameState.continue_pending = false
	GameRng.seed_from(int(setup.seed))
	Haptics.rumble(0.3, 0.0, 0.1)
	get_tree().change_scene_to_file("res://scenes/main.tscn")

# ---------------- 天赋树（局外成长） ----------------

func _build_talent_panel() -> void:
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.visible = false
	add_child(overlay)
	_talent_panel = overlay
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.65)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	center.add_child(box)
	var title := Label.new()
	title.text = "🌟 天赋树 · 局外成长"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color("e8b84b"))
	box.add_child(title)
	_talent_essence = Label.new()
	_talent_essence.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_talent_essence.add_theme_font_size_override("font_size", 16)
	_talent_essence.add_theme_color_override("font_color", Color("ffd24a"))
	box.add_child(_talent_essence)
	var tip := Label.new()
	tip.text = "土豆精华：局末按积分/波次结算，永不清零 · 通用天赋全员生效，门派天赋仅对应角色生效"
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip.add_theme_font_size_override("font_size", 12)
	tip.add_theme_color_override("font_color", Color("9aa3b2"))
	box.add_child(tip)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(600.0, 360.0)
	box.add_child(scroll)
	_talent_rows = VBoxContainer.new()
	_talent_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_talent_rows.add_theme_constant_override("separation", 8)
	scroll.add_child(_talent_rows)
	var close := Button.new()
	close.text = "关 闭（Esc）"
	close.custom_minimum_size = Vector2(600.0, 44.0)
	close.pressed.connect(_close_talents)
	box.add_child(close)

func _open_talents() -> void:
	Haptics.rumble(0.2, 0.0, 0.08)
	_refresh_talents()
	_talent_panel.visible = true
	_home.visible = false
	# 焦点给第一个可购买天赋（无则关闭按钮）
	for c in _talent_rows.get_children():
		if c is Button and not c.disabled:
			c.grab_focus()
			return
	for c in _talent_panel.get_child(1).get_child(0).get_children():
		if c is Button:
			c.grab_focus()
			break

func _close_talents() -> void:
	_talent_panel.visible = false
	_home.visible = true
	for c in _home.get_child(0).get_children():
		if c is Button:
			c.grab_focus()
			break

func _refresh_talents() -> void:
	for c in _talent_rows.get_children():
		_talent_rows.remove_child(c)
		c.queue_free()
	_talent_essence.text = "◆ 土豆精华 %d（累计获得 %d）" % [MetaProgress.essence, MetaProgress.total_earned]
	for id in MetaProgress.TALENTS:
		var t: Dictionary = MetaProgress.TALENTS[id]
		var lv := MetaProgress.talent_level(id)
		var max_lv := int(t.max_lv)
		var cost := MetaProgress.talent_cost(id)
		var row := Button.new()
		row.custom_minimum_size = Vector2(580.0, 64.0)
		var full := lv >= max_lv
		if full:
			row.text = "%s %s　Lv %d/%d　已满级" % [t.ico, t.name, lv, max_lv]
			row.disabled = true
		else:
			row.text = "%s %s　Lv %d/%d　升级：%d 精华\n%s" % [t.ico, t.name, lv, max_lv, cost, t.desc]
			row.disabled = MetaProgress.essence < cost
		row.pressed.connect(_on_talent_buy.bind(id))
		_talent_rows.add_child(row)
	# ---- 门派专属分隔 ----
	var divider := Label.new()
	divider.text = "— 门派专属（仅对应角色生效）—"
	divider.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	divider.add_theme_font_size_override("font_size", 14)
	divider.add_theme_color_override("font_color", Color("c39bf5"))
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_talent_rows.add_child(divider)
	for sid in MetaProgress.SECT_TALENTS:
		var t: Dictionary = MetaProgress.SECT_TALENTS[sid]
		var lv := MetaProgress.sect_level(sid)
		var max_lv := int(t.max_lv)
		var cost := MetaProgress.sect_cost(sid)
		var ch: Dictionary = Registry.get_character(String(t.get("character", "")))
		var ch_name := String(ch.get("name", ""))
		var row := Button.new()
		row.custom_minimum_size = Vector2(580.0, 64.0)
		var full := lv >= max_lv
		if full:
			row.text = "%s %s　Lv %d/%d　已满级\n仅「%s」生效" % [t.ico, t.name, lv, max_lv, ch_name]
			row.disabled = true
		else:
			row.text = "%s %s　Lv %d/%d　升级：%d 精华\n%s（仅「%s」生效）" % [
				t.ico, t.name, lv, max_lv, cost, t.desc, ch_name]
			row.disabled = MetaProgress.essence < cost
		row.pressed.connect(_on_sect_buy.bind(sid))
		_talent_rows.add_child(row)

func _on_talent_buy(id: String) -> void:
	if MetaProgress.buy_talent(id):
		Haptics.rumble(0.25, 0.0, 0.08)
		Sfx.play("buy")
		_refresh_talents()
		# 重新抓焦首个可购买项，保持手柄导航连续
		for c in _talent_rows.get_children():
			if c is Button and not c.disabled:
				c.grab_focus()
				return

func _on_sect_buy(id: String) -> void:
	if MetaProgress.buy_sect(id):
		Haptics.rumble(0.25, 0.0, 0.08)
		Sfx.play("buy")
		_refresh_talents()
		for c in _talent_rows.get_children():
			if c is Button and not c.disabled:
				c.grab_focus()
				return

func _build_leaderboard_panel() -> void:
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.visible = false
	add_child(overlay)
	_lb_panel = overlay
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.65)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	center.add_child(box)
	_lb_title = Label.new()
	_lb_title.text = "🔥 无尽炼狱 · 排行榜"
	_lb_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lb_title.add_theme_font_size_override("font_size", 26)
	_lb_title.add_theme_color_override("font_color", Color("e8b84b"))
	box.add_child(_lb_title)
	# 标签行：无尽总榜 / 今日榜
	var tabs := HBoxContainer.new()
	tabs.alignment = BoxContainer.ALIGNMENT_CENTER
	tabs.add_theme_constant_override("separation", 10)
	box.add_child(tabs)
	_lb_btn_endless = Button.new()
	_lb_btn_endless.text = "无尽总榜"
	_lb_btn_endless.custom_minimum_size = Vector2(160.0, 38.0)
	_lb_btn_endless.toggle_mode = true
	_lb_btn_endless.pressed.connect(func() -> void:
		_switch_lb_tab("endless"))
	tabs.add_child(_lb_btn_endless)
	_lb_btn_daily = Button.new()
	_lb_btn_daily.text = "📅 今日榜"
	_lb_btn_daily.custom_minimum_size = Vector2(160.0, 38.0)
	_lb_btn_daily.toggle_mode = true
	_lb_btn_daily.pressed.connect(func() -> void:
		_switch_lb_tab("daily"))
	tabs.add_child(_lb_btn_daily)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(560.0, 370.0)
	box.add_child(scroll)
	_lb_rows = VBoxContainer.new()
	_lb_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lb_rows.add_theme_constant_override("separation", 6)
	scroll.add_child(_lb_rows)
	var close := Button.new()
	close.text = "关 闭（Esc）"
	close.custom_minimum_size = Vector2(560.0, 44.0)
	close.pressed.connect(_close_leaderboard)
	box.add_child(close)

func _switch_lb_tab(tab: String) -> void:
	_lb_mode = tab
	_lb_btn_endless.button_pressed = tab == "endless"
	_lb_btn_daily.button_pressed = tab == "daily"
	Haptics.rumble(0.15, 0.0, 0.05)
	_refresh_leaderboard()

func _open_leaderboard() -> void:
	Haptics.rumble(0.2, 0.0, 0.08)
	_lb_btn_endless.button_pressed = _lb_mode == "endless"
	_lb_btn_daily.button_pressed = _lb_mode == "daily"
	_refresh_leaderboard()
	_lb_panel.visible = true
	_home.visible = false
	for c in _lb_panel.get_child(1).get_child(0).get_children():
		if c is Button:
			c.grab_focus()   # 焦点给关闭按钮（手柄直达）
			break

func _close_leaderboard() -> void:
	_lb_panel.visible = false
	_home.visible = true
	for c in _home.get_child(0).get_children():
		if c is Button:
			c.grab_focus()   # 焦点回首页第一个按钮
			break

func _refresh_leaderboard() -> void:
	for c in _lb_rows.get_children():
		_lb_rows.remove_child(c)
		c.queue_free()
	var list: Array = Leaderboard.get_list()
	var empty_hint := "去无尽炼狱模式创造第一个纪录吧！"
	if _lb_mode == "daily":
		var today := Time.get_date_string_from_system()
		list = Leaderboard.get_daily_list(today)
		_lb_title.text = "📅 每日挑战 · 今日榜（%s）" % today
		empty_hint = "今天的挑战还没人完成，去「每日挑战」打个样！"
	else:
		_lb_title.text = "🔥 无尽炼狱 · 排行榜"
	if list.is_empty():
		var empty := Label.new()
		empty.text = "暂无记录\n\n" + empty_hint
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_font_size_override("font_size", 15)
		empty.add_theme_color_override("font_color", Color("5a6270"))
		empty.custom_minimum_size = Vector2(540.0, 200.0)
		empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_lb_rows.add_child(empty)
		return
	var medals := ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩"]
	for i in list.size():
		var e: Dictionary = list[i]
		var row := Label.new()
		row.text = "%s  %d 分 · 第 %d 波 · %s · 击杀 %d · %s" % [medals[i],
			int(e.score), int(e.wave), String(e.char_name), int(e.kills), String(e.date)]
		row.add_theme_font_size_override("font_size", 15)
		row.add_theme_color_override("font_color",
			Color("ffd24a") if i == 0 else Color("d8dde6"))
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_lb_rows.add_child(row)

# ---------------- 自定义开局规则 ----------------

## 规则面板：11 项规则逐条可调 + 实时难度评级 + 预设 + 挑战码。
## 面板只改 RunRules 上的参数，真正的注入发生在 _start()（apply_to_run）。
func _build_rules_panel() -> void:
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.visible = false
	add_child(overlay)
	_rules_panel = overlay
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, 20)
	overlay.add_child(margin)
	var panel := PanelContainer.new()
	var psb := StyleBoxFlat.new()
	psb.bg_color = Color("141821")
	psb.border_color = Color("2c3340")
	psb.set_border_width_all(1)
	psb.set_corner_radius_all(10)
	psb.content_margin_left = 18.0
	psb.content_margin_right = 18.0
	psb.content_margin_top = 14.0
	psb.content_margin_bottom = 14.0
	panel.add_theme_stylebox_override("panel", psb)
	margin.add_child(panel)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	panel.add_child(root)
	# 标题 + 开关
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	root.add_child(head)
	var title := Label.new()
	title.text = "🎛 自定义开局规则"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color("e8b84b"))
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(title)
	_rules_enable_btn = Button.new()
	_rules_enable_btn.toggle_mode = true
	_rules_enable_btn.custom_minimum_size = Vector2(190.0, 40.0)
	_rules_enable_btn.add_theme_font_size_override("font_size", 16)
	_rules_enable_btn.pressed.connect(_on_rules_toggle)
	head.add_child(_rules_enable_btn)
	# 基准难度选择：规则里难度组四项叠乘在它之上（方案 A）
	var base_row := HBoxContainer.new()
	base_row.alignment = BoxContainer.ALIGNMENT_CENTER
	base_row.add_theme_constant_override("separation", 8)
	root.add_child(base_row)
	var bl := Label.new()
	bl.text = "基准难度（向导第 4 步）"
	bl.add_theme_font_size_override("font_size", 14)
	bl.add_theme_color_override("font_color", Color("9aa3b2"))
	bl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	base_row.add_child(bl)
	_rules_base_group = ButtonGroup.new()
	for did in RunRules.BUILTIN_DIFF_IDS:
		var d: Dictionary = Registry.get_difficulty(String(did))
		var b := Button.new()
		b.text = "%s x%.1f" % [String(d.get("name", did)), float(d.get("hp_mult", 1.0))]
		b.toggle_mode = true
		b.button_group = _rules_base_group
		b.set_meta("did", String(did))
		b.custom_minimum_size = Vector2(112.0, 34.0)
		b.add_theme_color_override("font_color",
			Config.DIFFICULTY_COLORS.get(String(did), Color("e8b84b")))
		b.pressed.connect(_on_base_diff_pick.bind(String(did)))
		base_row.add_child(b)
		_rules_base_btns.append(b)
	# 评级 + 提示
	_rules_rating = Label.new()
	_rules_rating.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rules_rating.add_theme_font_size_override("font_size", 17)
	_rules_rating.add_theme_color_override("font_color", Color("ffd24a"))
	_rules_rating.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_rules_rating)
	# 实算预览：让玩家直接看到「基准 × 规则」后的最终难度数值，而不是自己心算
	_rules_preview = Label.new()
	_rules_preview.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rules_preview.add_theme_font_size_override("font_size", 13)
	_rules_preview.add_theme_color_override("font_color", Color("7ec850"))
	_rules_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_rules_preview)
	_rules_warn = Label.new()
	_rules_warn.text = "自定义规则局不参与排行榜与每日挑战（参数可调低，上榜等于刷榜）· 精华照常结算"
	_rules_warn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rules_warn.add_theme_font_size_override("font_size", 12)
	_rules_warn.add_theme_color_override("font_color", Color("9aa3b2"))
	_rules_warn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_rules_warn)
	# 中部：左 = 规则列表，右 = 预设
	var mid := HBoxContainer.new()
	mid.add_theme_constant_override("separation", 16)
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(mid)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	mid.add_child(scroll)
	_rules_rows = VBoxContainer.new()
	_rules_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rules_rows.add_theme_constant_override("separation", 4)
	scroll.add_child(_rules_rows)
	mid.add_child(_build_rules_side())
	# 底部：挑战码 + 按钮
	root.add_child(_build_rules_footer())

## 右列：预设保存 / 列表（点击载入，右侧 ✕ 删除）
func _build_rules_side() -> VBoxContainer:
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(268.0, 0.0)
	col.add_theme_constant_override("separation", 6)
	var h := Label.new()
	h.text = "预设方案"
	h.add_theme_font_size_override("font_size", 15)
	h.add_theme_color_override("font_color", Color("e8b84b"))
	h.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(h)
	var save_row := HBoxContainer.new()
	save_row.add_theme_constant_override("separation", 6)
	col.add_child(save_row)
	_rules_preset_edit = LineEdit.new()
	_rules_preset_edit.placeholder_text = "预设名"
	_rules_preset_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rules_preset_edit.custom_minimum_size = Vector2(0.0, 36.0)
	save_row.add_child(_rules_preset_edit)
	var save_btn := Button.new()
	save_btn.text = "保存"
	save_btn.custom_minimum_size = Vector2(66.0, 36.0)
	save_btn.pressed.connect(_on_preset_save)
	save_row.add_child(save_btn)
	var pscroll := ScrollContainer.new()
	pscroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	pscroll.custom_minimum_size = Vector2(0.0, 240.0)
	col.add_child(pscroll)
	_rules_preset_box = VBoxContainer.new()
	_rules_preset_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rules_preset_box.add_theme_constant_override("separation", 4)
	pscroll.add_child(_rules_preset_box)
	return col

## 底部：挑战码输入 + 复制 / 导入 / 重置 / 关闭
func _build_rules_footer() -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	var code_row := HBoxContainer.new()
	code_row.add_theme_constant_override("separation", 8)
	col.add_child(code_row)
	var cl := Label.new()
	cl.text = "挑战码"
	cl.add_theme_font_size_override("font_size", 14)
	cl.add_theme_color_override("font_color", Color("9aa3b2"))
	cl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	code_row.add_child(cl)
	_rules_code_edit = LineEdit.new()
	_rules_code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rules_code_edit.custom_minimum_size = Vector2(0.0, 38.0)
	_rules_code_edit.placeholder_text = "把别人的挑战码粘到这里，点「导入」"
	_rules_code_edit.add_theme_font_size_override("font_size", 14)
	code_row.add_child(_rules_code_edit)
	var copy_btn := Button.new()
	copy_btn.text = "复制"
	copy_btn.custom_minimum_size = Vector2(76.0, 38.0)
	copy_btn.tooltip_text = "复制当前规则为挑战码，发给朋友即可复现同一局"
	copy_btn.pressed.connect(_on_code_copy)
	code_row.add_child(copy_btn)
	var import_btn := Button.new()
	import_btn.text = "导入"
	import_btn.custom_minimum_size = Vector2(76.0, 38.0)
	import_btn.pressed.connect(_on_code_import)
	code_row.add_child(import_btn)
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 12)
	col.add_child(btn_row)
	var reset_btn := Button.new()
	reset_btn.text = "重置为默认"
	reset_btn.custom_minimum_size = Vector2(150.0, 42.0)
	reset_btn.pressed.connect(_on_rules_reset)
	btn_row.add_child(reset_btn)
	var close_btn := Button.new()
	close_btn.text = "关 闭（Esc）"
	close_btn.custom_minimum_size = Vector2(180.0, 42.0)
	close_btn.pressed.connect(_close_rules)
	btn_row.add_child(close_btn)
	return col

func _open_rules() -> void:
	Haptics.rumble(0.2, 0.0, 0.08)
	_refresh_rules()
	_rules_panel.visible = true
	_home.visible = false
	_rules_enable_btn.grab_focus()

func _close_rules() -> void:
	_rules_panel.visible = false
	_home.visible = true
	for c in _home.get_child(0).get_children():
		if c is Button:
			c.grab_focus()
			break

func _on_rules_toggle() -> void:
	RunRules.active = _rules_enable_btn.button_pressed
	Haptics.rumble(0.15, 0.0, 0.05)
	_refresh_rules()

func _on_rules_reset() -> void:
	RunRules.reset_to_defaults()
	Haptics.rumble(0.2, 0.0, 0.08)
	_refresh_rules()

## 按分组重建规则行；每组之间插一条分隔标题
func _refresh_rules() -> void:
	_rules_enable_btn.button_pressed = RunRules.active
	_rules_enable_btn.text = "规则已启用 ✓" if RunRules.active else "规则未启用（点此开启）"
	_rules_enable_btn.add_theme_color_override("font_color",
		Color("7ec850") if RunRules.active else Color("9aa3b2"))
	# 基准难度按钮同步（RunRules.base_difficulty_id 是唯一真值来源）
	# 未启用规则时整体灰掉：那时难度完全由向导决定，这里的按钮无意义
	for b in _rules_base_btns:
		b.button_pressed = String(b.get_meta("did")) == RunRules.base_difficulty_id
		b.disabled = not RunRules.active
	_rules_rating.text = _rating_text()
	_rules_preview.text = _preview_text()
	_rules_code_edit.text = RunRules.encode()
	# 规则行也随启用状态灰化，避免"改了却不生效"的困惑
	for row in _rules_rows.get_children():
		for c in row.get_children():
			if c is Button:
				c.disabled = not RunRules.active
	for c in _rules_rows.get_children():
		_rules_rows.remove_child(c)
		c.queue_free()
	var shown_group := ""
	for r in RunRules.RULES:
		var g := String(r.group)
		if g != shown_group:
			shown_group = g
			var gl := Label.new()
			gl.text = "— %s —" % g
			gl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			gl.add_theme_font_size_override("font_size", 13)
			gl.add_theme_color_override("font_color", Color("c39bf5"))
			gl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_rules_rows.add_child(gl)
		_rules_rows.add_child(_make_rule_row(r))
	_refresh_presets()

## 单条规则行：名称 ｜ [－] 值 [＋] ｜ 默认值（已是默认时弱化显示）
func _make_rule_row(r: Dictionary) -> Control:
	var key := String(r.key)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.custom_minimum_size = Vector2(0.0, 38.0)
	var nm := Label.new()
	nm.text = String(r.name)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.add_theme_font_size_override("font_size", 14)
	nm.add_theme_color_override("font_color", Color("d8dde6"))
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(nm)
	var minus := Button.new()
	minus.text = "−"
	minus.custom_minimum_size = Vector2(40.0, 34.0)
	minus.pressed.connect(_on_rule_step.bind(key, -1.0))
	row.add_child(minus)
	var val := Label.new()
	val.text = _rule_value_text(r)
	val.custom_minimum_size = Vector2(88.0, 0.0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val.add_theme_font_size_override("font_size", 15)
	# 非默认值高亮：一眼看出"这局跟标准难度不一样的地方"
	val.add_theme_color_override("font_color",
		Color("9aa3b2") if is_equal_approx(RunRules.get_value(key), float(r.default))
		else Color("ffd24a"))
	val.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(val)
	var plus := Button.new()
	plus.text = "＋"
	plus.custom_minimum_size = Vector2(40.0, 34.0)
	plus.pressed.connect(_on_rule_step.bind(key, 1.0))
	row.add_child(plus)
	return row

## 值的显示文本：按 fmt 分支（pct 百分比 / mul x倍率 / int 整数 / bool 开关）
func _rule_value_text(r: Dictionary) -> String:
	var v := RunRules.get_value(String(r.key))
	match String(r.fmt):
		"pct":
			return "%d%%" % roundi(v * 100.0)
		"int":
			return "%d" % roundi(v)
		"bool":
			return "开启" if v >= 0.5 else "关闭"
		_:
			return "x%.1f" % v

func _on_rule_step(key: String, dir: float) -> void:
	var d := RunRules.rule_def(key)
	if d.is_empty():
		return
	var step := float(d.step) * dir
	var before := RunRules.get_value(key)
	RunRules.set_value(key, before + step)
	if is_equal_approx(before, RunRules.get_value(key)):
		return   # 已到边界：不响反馈，避免"按了没反应还响"的困惑
	Haptics.rumble(0.1, 0.0, 0.04)
	Sfx.play("ui_select")
	_refresh_rules()

## 实算预览：走 inject_difficulty() 的真实合成逻辑，展示「基准 × 规则」的最终数值。
## 关键：不是把规则值和基准各写一遍（那样会和真实算法脱节），而是直接算合成结果
func _preview_text() -> String:
	if not RunRules.active:
		return ""
	var d := RunRules.inject_difficulty()
	return "最终 → 血量 x%.2f ｜ 伤害 x%.2f ｜ 密度 x%.2f ｜ 精英 %d%%" % [
		float(d.hp_mult), float(d.dmg_mult), float(d.spawn_mult),
		roundi(float(d.elite_chance) * 100.0)]

func _on_base_diff_pick(id: String) -> void:
	if RunRules.base_difficulty_id == id:
		return
	RunRules.base_difficulty_id = id
	Haptics.rumble(0.15, 0.0, 0.05)
	Sfx.play("ui_select")
	_refresh_rules()

## 评级文案：1~5 星 + 数值；与基准难度持平时给出提示
func _rating_text() -> String:
	if not RunRules.active:
		return "未启用 —— 使用向导里选择的难度"
	var stars := ""
	for i in 5:
		stars += "★" if i < RunRules.rating_stars() else "☆"
	var r := RunRules.difficulty_rating()
	var base_name := RunRules.base_difficulty_name()
	if RunRules.is_default():
		return "%s  x%.2f ｜ 基准「%s」，规则未改动难度" % [stars, r, base_name]
	return "%s  x%.2f ｜ 基准「%s」+ 规则叠加" % [stars, r, base_name]

## 预设列表：每行「载入」按钮 + 「✕」删除
func _refresh_presets() -> void:
	for c in _rules_preset_box.get_children():
		_rules_preset_box.remove_child(c)
		c.queue_free()
	var names := RunRules.preset_names()
	if names.is_empty():
		var empty := Label.new()
		empty.text = "暂无预设"
		empty.add_theme_font_size_override("font_size", 12)
		empty.add_theme_color_override("font_color", Color("5a6270"))
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_rules_preset_box.add_child(empty)
		return
	for n in names:
		var name := String(n)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		var load_btn := Button.new()
		load_btn.text = name
		load_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		load_btn.custom_minimum_size = Vector2(0.0, 32.0)
		load_btn.tooltip_text = "载入预设 %s" % name
		load_btn.pressed.connect(_on_preset_load.bind(name))
		row.add_child(load_btn)
		var del := Button.new()
		del.text = "✕"
		del.custom_minimum_size = Vector2(32.0, 32.0)
		del.tooltip_text = "删除预设 %s" % name
		del.pressed.connect(_on_preset_delete.bind(name))
		row.add_child(del)
		_rules_preset_box.add_child(row)

func _on_preset_save() -> void:
	var name := _rules_preset_edit.text.strip_edges()
	if name.is_empty():
		EventBus.banner_requested.emit("预设", "先给这套规则起个名字", 1.6)
		return
	if RunRules.save_preset(name):
		_rules_preset_edit.text = ""
		Haptics.rumble(0.2, 0.0, 0.08)
		Sfx.play("ui_select")
		_refresh_presets()

func _on_preset_load(name: String) -> void:
	if RunRules.load_preset(name):
		RunRules.active = true   # 载入预设的意图就是用它，顺手开启
		Haptics.rumble(0.2, 0.0, 0.08)
		_refresh_rules()

func _on_preset_delete(name: String) -> void:
	if RunRules.delete_preset(name):
		Haptics.rumble(0.15, 0.0, 0.05)
		_refresh_presets()

## 复制挑战码到剪贴板（Web/桌面均可用；失败时兜底提示手动复制）
func _on_code_copy() -> void:
	var code := RunRules.encode()
	DisplayServer.clipboard_set(code)
	_rules_code_edit.text = code
	EventBus.banner_requested.emit("已复制挑战码", code, 2.4)

## 从输入框导入挑战码；格式不合法时保留原参数并提示
func _on_code_import() -> void:
	var code := _rules_code_edit.text.strip_edges()
	if code.is_empty():
		EventBus.banner_requested.emit("导入", "先粘贴一串挑战码", 1.8)
		return
	if RunRules.decode(code):
		RunRules.active = true
		Haptics.rumble(0.25, 0.0, 0.08)
		Sfx.play("ui_select")
		_refresh_rules()
		EventBus.banner_requested.emit("挑战码已导入", _rating_text(), 2.4)
	else:
		EventBus.banner_requested.emit("挑战码无效",
			"格式应为 BTL2- 开头（含基准难度 + %d 段规则）" % RunRules.RULES.size(), 2.6)
