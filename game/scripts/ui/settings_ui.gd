extends Control
## 设置界面：画面（分辨率/窗口模式/帧率）+ 主/音效/音乐音量 + 按键绑定（即时重绑定）+ 手柄说明
## 全部改动即时生效并写入 user://settings.cfg（Settings autoload）

var _bind_rows: Dictionary = {}   # action -> { "label": Label, "btn": Button }
var _capturing := ""
var _capture_btn: Button = null

func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color("101218")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 48)
	margin.add_theme_constant_override("margin_right", 48)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)
	# 顶栏
	var top := HBoxContainer.new()
	root.add_child(top)
	var back := Button.new()
	back.text = "← 返回主菜单"
	back.custom_minimum_size = Vector2(150.0, 38.0)
	back.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn"))
	top.add_child(back)
	var title := Label.new()
	title.text = "设置"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color("e8b84b"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top.add_child(title)
	var top_spacer := Control.new()
	top_spacer.custom_minimum_size = Vector2(150.0, 0.0)
	top_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(top_spacer)
	# 滚动内容
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)
	scroll.add_child(box)
	_build_display(box)
	_build_audio(box)
	_build_binds(box)
	_build_gamepad_help(box)
	back.grab_focus()

# ---------------- 画面 ----------------

func _build_display(box: VBoxContainer) -> void:
	box.add_child(_section("画面"))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 8)
	box.add_child(grid)
	# 分辨率
	grid.add_child(_field_label("分辨率（窗口模式）"))
	var res_opt := OptionButton.new()
	for r in Settings.RESOLUTIONS:
		res_opt.add_item("%d × %d" % [r.x, r.y])
	var cur_res := Vector2i(Settings.res_w, Settings.res_h)
	var idx := 0
	for i in Settings.RESOLUTIONS.size():
		if Settings.RESOLUTIONS[i] == cur_res:
			idx = i
			break
	res_opt.select(idx)
	res_opt.item_selected.connect(func(i: int) -> void:
		Settings.set_resolution(i)
		Haptics.rumble(0.15, 0.0, 0.05))
	grid.add_child(res_opt)
	# 窗口模式
	grid.add_child(_field_label("窗口模式"))
	var mode_opt := OptionButton.new()
	mode_opt.add_item("窗口")
	mode_opt.add_item("无边框窗口")
	mode_opt.add_item("全屏")
	mode_opt.select(clampi(Settings.mode, 0, 2))
	mode_opt.item_selected.connect(func(i: int) -> void:
		Settings.set_mode(i)
		Haptics.rumble(0.15, 0.0, 0.05))
	grid.add_child(mode_opt)
	# 帧率
	grid.add_child(_field_label("帧率上限"))
	var fps_opt := OptionButton.new()
	for f in Settings.FPS_OPTIONS:
		fps_opt.add_item("不限帧率" if f == 0 else "%d FPS" % f)
	var fidx := 0
	for i in Settings.FPS_OPTIONS.size():
		if Settings.FPS_OPTIONS[i] == Settings.fps:
			fidx = i
			break
	fps_opt.select(fidx)
	fps_opt.item_selected.connect(func(i: int) -> void:
		Settings.set_fps(Settings.FPS_OPTIONS[i])
		Haptics.rumble(0.15, 0.0, 0.05))
	grid.add_child(fps_opt)

# ---------------- 音量 ----------------

func _build_audio(box: VBoxContainer) -> void:
	box.add_child(_section("音量"))
	_volume_row(box, "主音量", Settings.master_vol, Settings.set_master)
	_volume_row(box, "音效", Settings.sfx_vol, Settings.set_sfx)
	_volume_row(box, "音乐", Settings.music_vol, Settings.set_music)

## 单条音量滑杆：label + 滑杆 + 百分比；拖动即时应用并持久化
func _volume_row(box: VBoxContainer, label_text: String, value: float, setter: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	box.add_child(row)
	var name_l := _field_label(label_text)
	name_l.custom_minimum_size = Vector2(72.0, 0.0)
	row.add_child(name_l)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 5.0
	slider.value = value * 100.0
	slider.custom_minimum_size = Vector2(300.0, 30.0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var val_l := Label.new()
	val_l.text = "%d%%" % int(slider.value)
	val_l.custom_minimum_size = Vector2(56.0, 0.0)
	slider.value_changed.connect(func(v: float) -> void:
		setter.call(v / 100.0)
		val_l.text = "%d%%" % int(v))
	row.add_child(slider)
	row.add_child(val_l)

# ---------------- 按键绑定 ----------------

func _build_binds(box: VBoxContainer) -> void:
	box.add_child(_section("按键绑定（点击“重绑定”后按下新按键；Esc 取消）"))
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 6)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(grid)
	for action in Settings.ACTION_ORDER:
		var name_l := _field_label(String(Settings.ACTION_LABELS.get(action, action)))
		name_l.custom_minimum_size = Vector2(120.0, 0.0)
		grid.add_child(name_l)
		var bind_l := Label.new()
		bind_l.text = Settings.binding_text(action)
		bind_l.add_theme_font_size_override("font_size", 13)
		bind_l.add_theme_color_override("font_color", Color("cfd6e4"))
		bind_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bind_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		grid.add_child(bind_l)
		var btn := Button.new()
		btn.text = "重绑定"
		btn.custom_minimum_size = Vector2(100.0, 32.0)
		btn.set_meta("action", action)
		btn.pressed.connect(_start_capture.bind(action, btn))
		grid.add_child(btn)
		_bind_rows[action] = { "label": bind_l, "btn": btn }
	var reset_all := Button.new()
	reset_all.text = "全部恢复默认按键"
	reset_all.custom_minimum_size = Vector2(180.0, 34.0)
	reset_all.pressed.connect(_reset_all_binds)
	box.add_child(reset_all)

func _start_capture(action: String, btn: Button) -> void:
	_cancel_capture()
	_capturing = action
	_capture_btn = btn
	btn.text = "按下按键…"
	btn.disabled = true
	Haptics.rumble(0.15, 0.0, 0.05)

func _cancel_capture() -> void:
	if _capturing != "" and _capture_btn != null:
		_capture_btn.text = "重绑定"
		_capture_btn.disabled = false
	_capturing = ""
	_capture_btn = null

func _finish_capture(ev: InputEvent) -> void:
	var action := _capturing
	Settings.bind_action(action, ev)
	var row: Dictionary = _bind_rows.get(action, {})
	if row.has("label"):
		row.label.text = Settings.binding_text(action)
	Haptics.rumble(0.3, 0.0, 0.1)
	_cancel_capture()

func _reset_all_binds() -> void:
	for action in Settings.ACTION_ORDER:
		Settings.reset_action(action)
		var row: Dictionary = _bind_rows.get(action, {})
		if row.has("label"):
			row.label.text = Settings.binding_text(action)
	Haptics.rumble(0.3, 0.0, 0.1)

func _unhandled_input(event: InputEvent) -> void:
	# 未在捕获按键时：Android 返回键 / Esc / 手柄 B → 回主菜单（并消费事件，杜绝误退出）
	if _capturing == "":
		if event.is_action_pressed("ui_cancel"):
			get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
			get_viewport().set_input_as_handled()
		return
	# Esc 取消捕获（不绑定）
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ESCAPE:
			_cancel_capture()
			get_viewport().set_input_as_handled()
			return
		_finish_capture(event)
		get_viewport().set_input_as_handled()
	elif event is InputEventJoypadButton and event.pressed:
		_finish_capture(event)
		get_viewport().set_input_as_handled()
	elif event is InputEventJoypadMotion and absf(event.axis_value) > 0.6:
		_finish_capture(event)
		get_viewport().set_input_as_handled()

# ---------------- 手柄说明 ----------------

func _build_gamepad_help(box: VBoxContainer) -> void:
	box.add_child(_section("手柄按键说明（Xbox 布局）"))
	var help := Label.new()
	help.text = "A（右下键）= 确认　　B（右下侧）= 返回 / 取消\n" \
		+ "Start(Menu) = 暂停　　Back(View) = 静音切换\n" \
		+ "十字键 / 左摇杆 = 菜单导航 + 游戏内移动\n" \
		+ "游戏内武器自动攻击，只需专心走位；手柄震动随战斗反馈自动触发"
	help.add_theme_font_size_override("font_size", 13)
	help.add_theme_color_override("font_color", Color("9aa3b2"))
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(help)

# ---------------- 小部件 ----------------

func _section(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 16)
	l.add_theme_color_override("font_color", Color("e8b84b"))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _field_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 14)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l
