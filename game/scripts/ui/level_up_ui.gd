extends Control
## 升级三选一 UI（移植自原型 ov-level / openLevelUp / chooseUpgrade）
## 触发：拾取经验结算升级且 phase==PLAYING 时弹出（原型同款判断）
## 连升：选完一张 level_queue 仍 >0 时重新抽三张
## 输入：键盘 1/2/3、鼠标点击、手柄焦点导航（ui_left/right + ui_accept）

var player  # characters/player.gd 引用，由 main 注入
var _choices: Array = []   # 当前三张升级卡（Registry.upgrades 元素）

@onready var _title: Label = $Center/Box/Title
@onready var _cards: HBoxContainer = $Center/Box/Cards

func _ready() -> void:
	visible = false
	EventBus.leveled_up.connect(_on_leveled_up)

func _on_leveled_up(_new_level: int) -> void:
	if GameState.phase == GameState.Phase.PLAYING and GameState.level_queue > 0:
		open()

## 打开升级选择（原型 openLevelUp：全量池随机抽 3 张不重复，可跨次重复）
func open() -> void:
	GameState.set_phase(GameState.Phase.LEVEL_UP)
	_choices = []
	var pool := Registry.upgrade_list().duplicate()
	for _i in 3:
		if pool.is_empty():
			break
		_choices.append(pool.pop_at(GameRng.range_i(0, pool.size() - 1)))
	_title.text = "升级！Lv %d" % GameState.level
	_build_cards()
	visible = true
	_grab_first_card()   # 旧按钮已 free，直接抓焦第一张

func _grab_first_card() -> void:
	if not visible:
		return
	var buttons := _cards.get_children()
	if not buttons.is_empty():
		buttons[0].grab_focus()

func card_count() -> int:
	return _choices.size()

func _build_cards() -> void:
	for c in _cards.get_children():
		_cards.remove_child(c)
		c.free()   # 立即删除：不用 queue_free，否则帧末 get_children 返回旧+新混合
	for i in _choices.size():
		var u: Dictionary = _choices[i]
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(200.0, 220.0)
		btn.pressed.connect(_choose.bind(i))
		_apply_card_style(btn)
		_cards.add_child(btn)
		# 卡面内容（不拦截鼠标，保证按钮可点）
		var box := VBoxContainer.new()
		box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		box.alignment = BoxContainer.ALIGNMENT_CENTER
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(box)
		var ico := Label.new()
		ico.text = u.ico
		ico.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ico.add_theme_font_size_override("font_size", 36)
		ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(ico)
		var name_l := Label.new()
		name_l.text = u.name
		name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_l.add_theme_font_size_override("font_size", 20)
		name_l.add_theme_color_override("font_color", Color("e8b84b"))
		name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(name_l)
		var key_l := Label.new()
		key_l.text = "[%d]" % (i + 1)
		key_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		key_l.add_theme_font_size_override("font_size", 12)
		key_l.add_theme_color_override("font_color", Color("9aa3b2"))
		key_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(key_l)
		var desc := Label.new()
		desc.text = u.desc
		desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.custom_minimum_size = Vector2(180.0, 0.0)
		desc.add_theme_font_size_override("font_size", 12)
		desc.add_theme_color_override("font_color", Color("9aa3b2"))
		desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(desc)

## 暗色卡面样式（normal/hover/focus/pressed，focus 金边高亮供手柄导航）
func _apply_card_style(btn: Button) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color("22262f")
	normal.border_color = Color("3a4150")
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(10)
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = Color("2b303b")
	hover.border_color = Color("e8b84b")
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("focus", hover.duplicate())
	btn.add_theme_stylebox_override("pressed", hover.duplicate())

func _choose(i: int) -> void:
	if not visible or i < 0 or i >= _choices.size():
		return
	if player:
		player.apply_upgrade(_choices[i].id)
	Haptics.rumble(0.25, 0.0, 0.08)   # 手柄确认轻震
	GameState.level_queue = maxi(0, GameState.level_queue - 1)
	_choices = []
	if GameState.level_queue > 0:
		# 连升：不隐藏 UI，直接重建卡片并抓焦
		_build_cards()
		_grab_first_card()
	else:
		visible = false
		GameState.set_phase(GameState.Phase.PLAYING)

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_accept"):
		var focus := get_viewport().gui_get_focus_owner()
		if focus and focus.get_parent() == _cards:
			_choose(focus.get_index())
		elif _choices.size() > 0:
			_choose(0)   # 焦点丢失时默认选第一张
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_1: _choose(0)
			KEY_2: _choose(1)
			KEY_3: _choose(2)
