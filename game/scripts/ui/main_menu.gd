extends Control
## 主菜单 + 开局向导（分步）：开始游戏 → ① 角色 → ② 初始武器 → ③ 初始道具 → ④ 难度 → 进入游戏
## 选项全部来自 Registry 注册表（创意工坊内容自动出现）；鼠标 + 手柄均可操作
## Esc / 手柄 B：向导内返回上一步，首页退出

var _g_diff := ButtonGroup.new()
var _g_char := ButtonGroup.new()
var _g_weapon := ButtonGroup.new()
var _g_item := ButtonGroup.new()

# 缓存向导每步选中 id（ButtonGroup 按钮跨步骤被释放后 get_pressed_button 返回 null）
var _sel_char := "potato"
var _sel_weapon := "pistol"
var _sel_item := ""
var _sel_diff := "normal"

var _home: Control
var _wizard: Control
var _step_label: Label
var _options: GridContainer
var _back_btn: Button
var _next_btn: Button
var _step := 0

const TOTAL_STEPS := 4
const STEP_TITLES := ["选择角色", "选择初始武器", "选择初始道具", "选择难度"]

func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color("101218")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_build_home()
	_build_wizard()

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
	for spec in [
		["开 始 游 戏", 220.0, _open_wizard],
		["设　　　置", 220.0, func() -> void: get_tree().change_scene_to_file("res://scenes/ui/settings.tscn")],
		["创 意 工 坊", 220.0, func() -> void: get_tree().change_scene_to_file("res://scenes/ui/workshop.tscn")],
		["退　　出", 220.0, func() -> void: get_tree().quit()],
	]:
		var b := Button.new()
		b.text = spec[0]
		b.custom_minimum_size = Vector2(spec[1], 52.0)
		b.add_theme_font_size_override("font_size", 19)
		b.pressed.connect(spec[2])
		box.add_child(b)
	box.get_child(3).grab_focus()   # “开始游戏”默认焦点（手柄直达）

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
	_home.get_child(0).get_child(3).grab_focus()

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
					c.get("ico", "?"), c.name, c.get("desc", ""),
					c.id == _sel_char, Color(c.get("color", "#e8b84b"))))
		1:
			_options.columns = 4
			for w: Dictionary in Registry.weapons.values():
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

## 选项卡片：暗底 + 稀有度/角色/难度色描边，大图标 + 色名 + 描述；选中即确认
## 前三步自动进入下一步，最后一步聚焦"开始游戏"防误触
func _make_card(group: ButtonGroup, id: String, ico: String, title_text: String, desc: String, pressed: bool, accent: Color) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.button_group = group
	b.button_pressed = pressed
	b.set_meta("id", id)
	b.custom_minimum_size = Vector2(218.0, 208.0)
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
	b.toggled.connect(func(on: bool) -> void:
		if not on:
			return
		# 缓存选中 id（防止跨步骤按钮释放后丢失选择）
		match _step:
			0: _sel_char = id
			1: _sel_weapon = id
			2: _sel_item = id
			3: _sel_diff = id
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
	# Esc / 手柄 B：向导内回上一步
	if _wizard.visible and event.is_action_pressed("ui_cancel"):
		_prev()
		get_viewport().set_input_as_handled()
		return
	# 手柄 A / Enter：确认选中焦点卡片
	if _wizard.visible and event.is_action_pressed("ui_accept"):
		var focus := get_viewport().gui_get_focus_owner()
		if focus is Button and focus.toggle_mode and not focus.disabled:
			focus.button_pressed = true   # 触发 toggled 回调 → 缓存 id + 自动进下一步
			get_viewport().set_input_as_handled()
		return

func _start() -> void:
	GameState.difficulty_id = _sel_diff
	GameState.character_id = _sel_char
	GameState.loadout_weapon = _sel_weapon
	GameState.loadout_item = _sel_item
	Haptics.rumble(0.3, 0.0, 0.1)
	get_tree().change_scene_to_file("res://scenes/main.tscn")
