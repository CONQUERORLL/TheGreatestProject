extends Control
## 开发者调试面板（F1 呼出/收起）
## 功能：属性调整、添加武器/道具、材料/经验/等级、刷怪、God Mode、秒杀全场

var player: CharacterBody2D
var wave_manager: Node

var _panel: ScrollContainer
var _god := false

const STAT_FIELDS := [
	{ "k": "max_hp", "n": "最大生命", "min": 1.0, "max": 99999.0, "step": 1.0 },
	{ "k": "dmg_mult", "n": "伤害倍率", "min": 0.1, "max": 100.0, "step": 0.1 },
	{ "k": "as_mult", "n": "攻速倍率", "min": 0.1, "max": 100.0, "step": 0.1 },
	{ "k": "speed_mult", "n": "移速倍率", "min": 0.1, "max": 10.0, "step": 0.1 },
	{ "k": "crit_ch", "n": "暴击率", "min": 0.0, "max": 1.0, "step": 0.05 },
	{ "k": "crit_mult", "n": "暴击倍率", "min": 1.0, "max": 100.0, "step": 0.1 },
	{ "k": "armor", "n": "护甲", "min": 0.0, "max": 999.0, "step": 1.0 },
	{ "k": "dodge", "n": "闪避率", "min": 0.0, "max": 0.95, "step": 0.05 },
	{ "k": "pickup_range", "n": "拾取范围", "min": 0.0, "max": 999.0, "step": 5.0 },
	{ "k": "regen", "n": "回复/秒", "min": 0.0, "max": 999.0, "step": 0.5 },
	{ "k": "harvesting", "n": "收获加成", "min": 0.0, "max": 99.0, "step": 0.1 },
	{ "k": "lifesteal", "n": "吸血", "min": 0.0, "max": 99.0, "step": 0.1 },
]

func _ready() -> void:
	visible = false
	_build()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_F1:
			visible = not visible
			if visible:
				_sync_values()
			get_viewport().set_input_as_handled()
		elif event.physical_keycode == KEY_F2:
			_god = not _god
			if _god:
				player.hp = 99999.0
				player.stats.max_hp = 99999.0
			print("DEV: God mode = ", _god)
			get_viewport().set_input_as_handled()
		elif event.physical_keycode == KEY_F3:
			_kill_all()
			get_viewport().set_input_as_handled()

func _process(_delta: float) -> void:
	if _god and is_instance_valid(player):
		player.hp = player.stats.max_hp

# ---------------- 构建 ----------------

func _build() -> void:
	# 右侧半透明面板
	var bg := PanelContainer.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	_panel = ScrollContainer.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.offset_left = 460.0
	_panel.offset_top = 10.0
	_panel.offset_right = -10.0
	_panel.offset_bottom = -10.0
	_panel.modulate = Color(1.0, 1.0, 1.0, 0.96)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.add_child(_panel)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 6)
	_panel.add_child(box)
	# 标题
	var title := Label.new()
	title.text = "🔧 开发者面板（F1 开关 · F2 上帝 · F3 清场）"
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color("e8b84b"))
	box.add_child(title)
	# 属性区
	box.add_child(_section("属性调整（实时生效）"))
	for f in STAT_FIELDS:
		box.add_child(_stat_row(f))
	# 武器
	box.add_child(_section("添加武器"))
	box.add_child(_weapon_row())
	# 道具
	box.add_child(_section("添加道具（效果叠加）"))
	box.add_child(_item_row())
	# 资源
	box.add_child(_section("资源 / 等级"))
	box.add_child(_resource_row())
	# 刷怪
	box.add_child(_section("刷怪调试"))
	box.add_child(_spawn_row())
	# 天神
	box.add_child(_section("快捷"))
	box.add_child(_shortcut_row())

func _section(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color("e8b84b"))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _stat_row(f: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var l := Label.new()
	l.text = f.n
	l.custom_minimum_size = Vector2(90.0, 0.0)
	l.add_theme_font_size_override("font_size", 12)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(l)
	var sb := SpinBox.new()
	sb.min_value = f.min
	sb.max_value = f.max
	sb.step = f.step
	sb.suffix = ""
	sb.custom_minimum_size = Vector2(120.0, 28.0)
	sb.set_meta("key", f.k)
	sb.value_changed.connect(func(v: float) -> void:
		if is_instance_valid(player):
			player.stats[f.k] = v
			if f.k == "max_hp":
				player.hp = minf(player.hp, v)
			player.queue_redraw())
	row.add_child(sb)
	var reset := Button.new()
	reset.text = "R"
	reset.custom_minimum_size = Vector2(28.0, 28.0)
	reset.tooltip_text = "恢复默认"
	reset.set_meta("field", f)
	reset.pressed.connect(func() -> void:
		var sb2: SpinBox = row.get_child(1)
		var cfg_val: float = float(Config.PLAYER.get(f.k, 0.0))
		sb2.value = cfg_val)
	row.add_child(reset)
	return row

func _weapon_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.custom_minimum_size = Vector2(160.0, 28.0)
	for w: Dictionary in Registry.weapons.values():
		opt.add_item("%s (%s)" % [w.name, w.id])
	row.add_child(opt)
	var add := Button.new()
	add.text = "+ 添加"
	add.pressed.connect(func() -> void:
		if not is_instance_valid(player):
			return
		var idx: int = opt.selected
		var wkeys: Array = Registry.weapons.keys()
		if idx >= 0 and idx < wkeys.size():
			var wid: String = wkeys[idx]
			if player.weapons.size() < Config.WEAPON_SLOTS:
				player.weapons.append({ "type": wid, "cd": 0.1 })
				print("DEV: 添加武器 %s (%d/%d)" % [wid, player.weapons.size(), Config.WEAPON_SLOTS])
			else:
				print("DEV: 武器槽已满 %d/%d" % [player.weapons.size(), Config.WEAPON_SLOTS]))
	row.add_child(add)
	return row

func _item_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.custom_minimum_size = Vector2(160.0, 28.0)
	for it: Dictionary in Registry.items.values():
		opt.add_item("%s (%s)" % [it.name, it.id])
	row.add_child(opt)
	var add := Button.new()
	add.text = "+ 使用"
	add.pressed.connect(func() -> void:
		if not is_instance_valid(player):
			return
		var idx: int = opt.selected
		var ikeys: Array = Registry.items.keys()
		if idx >= 0 and idx < ikeys.size():
			var iid: String = ikeys[idx]
			player.apply_item(iid)
			print("DEV: 使用道具 %s" % iid))
	row.add_child(add)
	return row

func _resource_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	# 材料
	row.add_child(_label("材料"))
	var mat_sb := SpinBox.new()
	mat_sb.min_value = 0
	mat_sb.max_value = 99999
	mat_sb.value = 0
	mat_sb.custom_minimum_size = Vector2(100.0, 28.0)
	row.add_child(mat_sb)
	var mat_btn := Button.new()
	mat_btn.text = "设为"
	mat_btn.pressed.connect(func() -> void:
		GameState.materials = int(mat_sb.value))
	row.add_child(mat_btn)
	row.add_child(_label("  经验"))
	var xp_sb := SpinBox.new()
	xp_sb.min_value = 0
	xp_sb.max_value = 99999
	xp_sb.value = 0
	xp_sb.custom_minimum_size = Vector2(100.0, 28.0)
	row.add_child(xp_sb)
	var xp_btn := Button.new()
	xp_btn.text = "加经验"
	xp_btn.pressed.connect(func() -> void:
		GameState.gain_xp(int(xp_sb.value)))
	row.add_child(xp_btn)
	# 等级
	row.add_child(_label("  升级"))
	var lv_btn := Button.new()
	lv_btn.text = "+1 级"
	lv_btn.pressed.connect(func() -> void:
		GameState.gain_xp(Config.xp_need(GameState.level)))
	row.add_child(lv_btn)
	return row

func _spawn_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var opt := OptionButton.new()
	opt.custom_minimum_size = Vector2(120.0, 28.0)
	for et: String in ["grunt", "runner", "tank", "shooter", "boss"]:
		var e: Dictionary = Registry.enemies.get(et, {})
		opt.add_item("%s (%s)" % [e.get("name", et), et])
	row.add_child(opt)
	var spawn := Button.new()
	spawn.text = "在玩家旁生成"
	spawn.pressed.connect(func() -> void:
		if not is_instance_valid(player) or wave_manager == null:
			return
		var idx: int = opt.selected
		var types: Array = ["grunt", "runner", "tank", "shooter", "boss"]
		if idx >= 0 and idx < types.size():
			wave_manager.spawn(types[idx])
			print("DEV: 生成 %s" % types[idx]))
	row.add_child(spawn)
	return row

func _shortcut_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var god := Button.new()
	god.text = "God Mode (F2)"
	god.pressed.connect(func() -> void:
		_god = not _god
		if _god and is_instance_valid(player):
			player.hp = 99999.0
			player.stats.max_hp = 99999.0
		print("DEV: God mode = ", _god))
	row.add_child(god)
	var kill := Button.new()
	kill.text = "秒杀全场 (F3)"
	kill.pressed.connect(_kill_all)
	row.add_child(kill)
	var heal := Button.new()
	heal.text = "满血"
	heal.pressed.connect(func() -> void:
		if is_instance_valid(player):
			player.hp = player.stats.max_hp)
	row.add_child(heal)
	return row

# ---------------- 工具 ----------------

func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 12)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _sync_values() -> void:
	if not is_instance_valid(player):
		return
	for child in _panel.get_child(0).get_children():
		if child is HBoxContainer and child.get_child_count() >= 2:
			var sb = child.get_child(1)
			if sb is SpinBox and sb.has_meta("key"):
				var k: String = sb.get_meta("key")
				sb.value = float(player.stats.get(k, 0.0))

func _kill_all() -> void:
	var count := 0
	for e in get_tree().get_nodes_in_group("enemies"):
		if e.flee > 0.0:
			continue
		e.die()
		count += 1
	print("DEV: 秒杀 %d 个敌人" % count)
