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
var _back_press_ms := 0   # 首页返回键上次按下时刻（双击退出防误触）
var _back_hint: Label
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

const TOTAL_STEPS := 5
const STEP_TITLES := ["选择角色", "选择初始武器", "选择初始道具", "选择难度", "选择模式"]

func _ready() -> void:
	SaveRun.migrate_legacy_if_needed()
	Music.play_track("menu", 0.5)
	var bg := ColorRect.new()
	bg.color = Color("101218")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_build_home()
	_build_wizard()
	_build_back_hint()
	_build_slots_panel()
	_build_leaderboard_panel()
	_build_talent_panel()
	_build_daily_panel()
	_build_codex()

## 底部居中提示（返回键双击退出用）
func _build_back_hint() -> void:
	_back_hint = Label.new()
	_back_hint.text = "再按一次返回键退出"
	_back_hint.add_theme_font_size_override("font_size", 16)
	_back_hint.add_theme_color_override("font_color", Color("e8b84b"))
	_back_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_back_hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_back_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_back_hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_back_hint.offset_bottom = -22.0
	_back_hint.visible = false
	add_child(_back_hint)

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
	panel.custom_minimum_size = Vector2(1000.0, 620.0)
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

	vbox.add_child(scroll)
	_options = GridContainer.new()
	_options.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_options.add_theme_constant_override("h_separation", 10)
	_options.add_theme_constant_override("v_separation", 10)
	scroll.add_child(_options)
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

func _build_step() -> void:
	for c in _options.get_children():
		_options.remove_child(c)
		c.queue_free()
	_step_label.text = "第 %d 步 / 共 %d 步 · %s" % [_step + 1, TOTAL_STEPS, STEP_TITLES[_step]]
	_back_btn.visible = _step > 0
	_next_btn.text = "开 始 游 戏" if _step == TOTAL_STEPS - 1 else "下一步 →"
	match _step:
		0:
			_options.columns = 3
			for c: Dictionary in Registry.characters.values():
				_options.add_child(_make_card(_g_char, c.id,
					c.get("ico", "?"), c.name, _character_card_desc(c),
					c.id == _sel_char, Color(c.get("color", "#e8b84b")), c.id))
		1:
			_options.columns = 4
			# 开局武器完全由玩家决定：角色不再绑定"初始武器"，
			# 否则玩家改选武器时角色设定会被覆盖，绑定本身也就失去意义
			for w: Dictionary in Registry.weapons.values():
				if float(w.get("shop_weight", 1.0)) <= 0.0:
					continue   # 进化形态不进开局池（只能靠波末同名武器合成获得）
				_options.add_child(_make_card(_g_weapon, w.id,
					w.ico, w.name, "%s\n伤害 %.0f · CD %.2fs" % [w.desc, float(w.dmg), float(w.cd)],
					w.id == _sel_weapon, Config.rarity_color(w.get("rarity", "common"))))
		2:
			_options.columns = 4
			_options.add_child(_make_card(_g_item, "", "✖", "不带道具", "空手开局",
				_sel_item == "", Color("5a6270")))
			for it: Dictionary in Registry.items.values():
				_options.add_child(_make_card(_g_item, it.id,
					it.ico, it.name, it.desc, it.id == _sel_item,
					Config.rarity_color(it.get("rarity", "common"))))
		3:
			_options.columns = 3
			for d: Dictionary in Registry.difficulties.values():
				_options.add_child(_make_card(_g_diff, d.id,
					"⚔", d.name, "%s\n敌人血量 x%.1f · 伤害 x%.1f\n刷怪密度 x%.1f" % [
						d.get("desc", ""), float(d.hp_mult), float(d.dmg_mult), float(d.spawn_mult)],
					d.id == _sel_diff,
					Config.DIFFICULTY_COLORS.get(d.id, Color("e8b84b"))))
		4:
			_options.columns = 2
			_options.add_child(_make_card(_g_mode, "standard", "🥔", "标准模式",
				"10 波通关挑战\n击败最终 BOSS 即胜利",
				not _sel_endless, Color("7ec850")))
			_options.add_child(_make_card(_g_mode, "endless", "🔥", "无尽炼狱",
				"波次无上限 · 每 10 波一轮 BOSS\n击杀累计积分 · 冲击排行榜",
				_sel_endless, Color("e0564f")))
	# 焦点：已选中的卡片，否则第一张
	var focus_target: Button = null
	for b in _options.get_children():
		if b.button_pressed:
			focus_target = b
			break
	if focus_target == null and _options.get_child_count() > 0:
		focus_target = _options.get_child(0)
	if focus_target:
		focus_target.grab_focus()

## 角色卡描述：特性置顶 + 玩法定位。
## 特性是"为什么要选这个角色"的唯一答案，必须第一眼可见 ——
## 只写属性取舍（攻速 +50%、伤害 -30%）玩家根本感受不到角色差异
func _character_card_desc(c: Dictionary) -> String:
	var t: Dictionary = c.get("trait", {})
	var role := String(c.get("desc", ""))
	if t.is_empty():
		return role
	return "⚡【%s】%s\n\n%s" % [
		String(t.get("name", "")), String(t.get("desc", "")), role]

## 选项卡片：暗底 + 稀有度/角色/难度色描边，大图标 + 色名 + 描述；选中即确认
## 前三步自动进入下一步，最后一步聚焦"开始游戏"防误触
## char_id 非空时卡面用程序化角色头像替代 emoji 图标
func _make_card(group: ButtonGroup, id: String, ico: String, title_text: String, desc: String, pressed: bool, accent: Color, char_id: String = "") -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.button_group = group
	b.button_pressed = pressed
	b.set_meta("id", id)
	# 卡面高度容纳「特性描述 + 玩法定位」两段文本（角色步），
	# 其余步骤内容较短，靠 VBox 居中，视觉上仍然平衡
	b.custom_minimum_size = Vector2(218.0, 244.0)
	# 卡面样式：accent 色微底 + 描边，hover/focus 金边高亮（手柄导航可见）
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(accent.r, accent.g, accent.b, 0.09)
	normal.border_color = accent
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(10)
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = Color(accent.r, accent.g, accent.b, 0.20)
	hover.border_color = Color("e8b84b")
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("focus", hover.duplicate())
	b.add_theme_stylebox_override("pressed", hover.duplicate())
	# 卡面内容（不拦截鼠标，保证按钮可点）
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(box)
	if char_id != "":
		# 角色专属人物头像（程序化绘制）
		var av := CharacterAvatar.new()
		av.setup(char_id, 76.0)
		box.add_child(av)
	else:
		var ico_l := Label.new()
		ico_l.text = ico
		ico_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ico_l.add_theme_font_size_override("font_size", 36)
		ico_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(ico_l)
	var name_l := Label.new()
	name_l.text = title_text
	name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_l.add_theme_font_size_override("font_size", 17)
	name_l.add_theme_color_override("font_color", accent.lightened(0.15))
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(name_l)
	var desc_l := Label.new()
	desc_l.text = desc
	desc_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_l.custom_minimum_size = Vector2(192.0, 0.0)
	desc_l.add_theme_font_size_override("font_size", 11)
	desc_l.add_theme_color_override("font_color", Color("9aa3b2"))
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
	# 首页：返回键 / Esc 两秒内按两次退出（Android 返回键防误触）
	if not _wizard.visible and event.is_action_pressed("ui_cancel"):
		var now := Time.get_ticks_msec()
		if now - _back_press_ms < 2000:
			get_tree().quit()
		else:
			_back_press_ms = now
			_back_hint.visible = true
			var t := get_tree().create_timer(2.0)
			t.timeout.connect(func() -> void: _back_hint.visible = false)
		get_viewport().set_input_as_handled()

func _start() -> void:
	GameState.difficulty_id = _sel_diff
	GameState.character_id = _sel_char
	GameState.loadout_weapon = _sel_weapon
	GameState.loadout_item = _sel_item
	GameState.endless = _sel_endless
	GameState.continue_pending = false
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
func _start_daily() -> void:
	var today := Time.get_date_string_from_system()
	var setup: Dictionary = Config.daily_setup(today)
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
	tip.text = "土豆精华：局末按积分/波次结算，永不清零 · 天赋对所有新局生效"
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
