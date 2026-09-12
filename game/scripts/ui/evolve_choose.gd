extends Control
## 武器进化方向选择弹窗：波末多分支进化时让玩家挑方向。
## 复用 event_card 的全屏遮罩 + 卡片布局；setup(choice) 传入单个待选选项
## { weapon, need, branches:[id...] }，玩家点选 / 按 1-4 后发 evolved 信号。
## 输入：键盘 1~N、鼠标点击、手柄焦点导航（ui_accept）

signal evolved(weapon: String, target: String)

var _choice: Dictionary = {}

@onready var _title: Label = $Center/Box/Title
@onready var _sub: Label = $Center/Box/Sub
@onready var _cards: HBoxContainer = $Center/Box/Cards

func _ready() -> void:
	visible = false

func setup(choice: Dictionary) -> void:
	_choice = choice
	var cfg: Dictionary = Registry.weapons.get(String(choice.get("weapon", "")), {})
	var branches: Array = choice.get("branches", [])
	_title.text = "⚔ %s 进化方向" % String(cfg.get("name", "武器"))
	_sub.text = "持有 %d 把 %s · 选择进化分支" % [int(choice.get("need", 0)), String(cfg.get("name", ""))]
	for c in _cards.get_children():
		_cards.remove_child(c)
		c.free()
	var idx := 0
	for bid in branches:
		if not Registry.weapons.has(String(bid)):
			continue
		idx += 1
		var bcfg: Dictionary = Registry.weapons[String(bid)]
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(200.0, 220.0)
		btn.pressed.connect(_choose.bind(String(bid)))
		_apply_style(btn, String(bcfg.get("rarity", "common")))
		_cards.add_child(btn)
		# 卡面内容（不拦截鼠标）
		var box := VBoxContainer.new()
		box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		box.alignment = BoxContainer.ALIGNMENT_CENTER
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(box)
		var ico := Label.new()
		ico.text = String(bcfg.get("ico", "🔧"))
		ico.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ico.add_theme_font_size_override("font_size", 36)
		ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(ico)
		var name_l := Label.new()
		name_l.text = String(bcfg.get("name", ""))
		name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_l.add_theme_font_size_override("font_size", 20)
		name_l.add_theme_color_override("font_color",
			Config.rarity_color(String(bcfg.get("rarity", "common"))).lightened(0.1))
		name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(name_l)
		var key_l := Label.new()
		key_l.text = "[%d]" % idx
		key_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		key_l.add_theme_font_size_override("font_size", 12)
		key_l.add_theme_color_override("font_color", Color("9aa3b2"))
		key_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(key_l)
		var desc := Label.new()
		desc.text = String(bcfg.get("desc", ""))
		desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.custom_minimum_size = Vector2(180.0, 0.0)
		desc.add_theme_font_size_override("font_size", 12)
		desc.add_theme_color_override("font_color", Color("9aa3b2"))
		desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(desc)
	visible = true
	modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, 0.1)
	_grab_first()

func _grab_first() -> void:
	var buttons := _cards.get_children()
	if not buttons.is_empty():
		buttons[0].grab_focus()

func _apply_style(btn: Button, rarity: String) -> void:
	var rc: Color = Config.rarity_color(rarity)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(rc.r, rc.g, rc.b, 0.08)
	normal.border_color = rc
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(10)
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = Color(rc.r, rc.g, rc.b, 0.16)
	hover.border_color = Color("e8b84b")
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("focus", hover.duplicate())
	btn.add_theme_stylebox_override("pressed", hover.duplicate())

func _choose(target: String) -> void:
	if not visible:
		return
	visible = false
	Haptics.rumble(0.3, 0.0, 0.1)
	evolved.emit(String(_choice.get("weapon", "")), target)

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var idx := -1
		match event.physical_keycode:
			KEY_1: idx = 0
			KEY_2: idx = 1
			KEY_3: idx = 2
			KEY_4: idx = 3
		var branches: Array = _choice.get("branches", [])
		if idx >= 0 and idx < branches.size():
			_choose(String(branches[idx]))
			get_viewport().set_input_as_handled()
