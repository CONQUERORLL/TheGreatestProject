extends Control
## 创意工坊：浏览 Registry 内容 + 内置编辑器（新建内容 → 校验 → 持久化到 user://mods/workshop_user）
## 数据源即 Registry：register_xxx 即时生效，save_content 写 manifest.json，重启后自动加载

const CATS := [
	["characters", "角色"], ["weapons", "武器"], ["items", "道具"],
	["upgrades", "升级"], ["enemies", "敌人"], ["difficulties", "难度"],
]

## effects/stats 属性组（键 = player.stats 键；SpinBox 步长/默认 0）
const EFFECT_FIELDS := [
	["max_hp", "最大生命", 1.0], ["dmg_mult", "伤害倍率(+0.1=+10%)", 0.01],
	["as_mult", "攻速倍率", 0.01], ["speed_mult", "移速倍率", 0.01],
	["crit_ch", "暴击率", 0.01], ["crit_mult", "暴击伤害倍率", 0.05],
	["armor", "护甲", 1.0], ["dodge", "闪避率", 0.01],
	["pickup_range", "拾取范围", 5.0], ["regen", "生命回复/秒", 0.1],
	["harvesting", "材料获取倍率", 0.01], ["lifesteal", "击杀回血", 1.0],
]

## 编辑器字段表：[键, 标签, 类型, 默认, 最小, 最大, 步长(choice 时为选项数组)]
const FIELD_DEFS := {
	"weapons": [
		["id", "ID（英文唯一，如 my_gun）", "text", "my_weapon"],
		["name", "名称", "text", "新武器"], ["ico", "图标（emoji）", "text", "🔧"],
		["cd", "冷却（秒）", "f", 0.5, 0.05, 5.0, 0.05],
		["dmg", "伤害", "f", 10.0, 1.0, 500.0, 1.0],
		["bspeed", "弹速", "f", 540.0, 0.0, 1200.0, 20.0],
		["price", "商店售价", "i", 30, 5, 300, 5],
		["shop_weight", "商店出现权重", "f", 1.0, 0.0, 5.0, 0.1],
		["rarity", "稀有度", "choice", "common", ["common", "rare", "epic"]],
		["desc", "描述", "text", "自定义武器"],
	],
	"items": [
		["id", "ID（英文唯一）", "text", "my_item"],
		["name", "名称", "text", "新道具"], ["ico", "图标（emoji）", "text", "🧩"],
		["price", "商店售价", "i", 30, 5, 300, 5],
		["rarity", "稀有度", "choice", "common", ["common", "rare", "epic"]],
		["desc", "描述", "text", "自定义道具"],
	],
	"upgrades": [
		["id", "ID（英文唯一）", "text", "my_upgrade"],
		["name", "名称", "text", "新升级"], ["ico", "图标（emoji）", "text", "✨"],
		["desc", "描述（升级池随机出现）", "text", "自定义升级"],
	],
	"enemies": [
		["id", "ID（英文唯一）", "text", "my_enemy"],
		["name", "名称", "text", "新怪物"],
		["hp", "生命", "f", 14.0, 1.0, 5000.0, 1.0],
		["speed", "速度", "f", 88.0, 0.0, 400.0, 4.0],
		["dmg", "接触伤害", "f", 8.0, 0.0, 200.0, 1.0],
		["r", "碰撞半径", "f", 14.0, 5.0, 120.0, 1.0],
		["xp", "掉落经验", "i", 1, 0, 100, 1],
		["mat", "掉落材料", "i", 1, 0, 100, 1],
		["color", "颜色（#RRGGBB）", "text", "#d9534f"],
		["shape", "形状", "choice", "circle", ["circle", "square", "diamond"]],
		["ai", "行为 AI", "choice", "chaser", ["chaser", "runner", "shooter", "boss"]],
		["bspeed", "弹速（射手/BOSS，0=不用）", "f", 0.0, 0.0, 800.0, 20.0],
		["keep_dist", "保持距离（射手风筝距离）", "f", 0.0, 0.0, 600.0, 10.0],
		["shoot_cd", "射击间隔（射手秒）", "f", 0.0, 0.0, 10.0, 0.1],
		["ring_count", "环形弹数（BOSS）", "i", 0, 0, 40, 2],
		["ring_cd", "环形弹幕间隔（BOSS 秒）", "f", 0.0, 0.0, 10.0, 0.1],
	],
	"characters": [
		["id", "ID（英文唯一）", "text", "my_character"],
		["name", "名称", "text", "新角色"], ["ico", "图标（emoji）", "text", "🧑"],
		["color", "主题色（#RRGGBB）", "text", "#e8b84b"],
		["start_weapon", "初始武器 ID", "text", "pistol"],
		["desc", "描述", "text", "自定义角色"],
	],
	"difficulties": [
		["id", "ID（英文唯一）", "text", "my_difficulty"],
		["name", "名称", "text", "新难度"],
		["desc", "描述", "text", "自定义难度"],
		["hp_mult", "敌人血量倍率", "f", 1.0, 0.2, 10.0, 0.1],
		["dmg_mult", "敌人伤害倍率", "f", 1.0, 0.2, 10.0, 0.1],
		["spawn_mult", "刷怪密度倍率", "f", 1.0, 0.2, 5.0, 0.05],
	],
}

var _cat := "characters"
var _list_box: VBoxContainer
var _browser: Control
var _editor: Control
var _editor_cat := "weapons"
var _form_box: VBoxContainer
var _form_fields: Array = []     # [{key, ctrl, type}]
var _form_effects: Array = []    # [{key, spin}]
var _editor_status: Label

func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color("101218")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_build_browser()
	_build_editor()

# ================= 浏览面板 =================

func _build_browser() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right"]:
		margin.add_theme_constant_override(side, 40)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	add_child(margin)
	_browser = margin
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)
	var top := HBoxContainer.new()
	box.add_child(top)
	var back := Button.new()
	back.text = "← 返回主菜单"
	back.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn"))
	top.add_child(back)
	var title := Label.new()
	title.text = "创意工坊"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color("e8b84b"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top.add_child(title)
	var new_btn := Button.new()
	new_btn.text = "✚ 新建内容"
	new_btn.pressed.connect(_open_editor)
	top.add_child(new_btn)
	var open_btn := Button.new()
	open_btn.text = "mods 文件夹"
	open_btn.pressed.connect(_open_mods_dir)
	top.add_child(open_btn)
	var reload_btn := Button.new()
	reload_btn.text = "重新加载"
	reload_btn.pressed.connect(func() -> void:
		Registry.reload_content()
		_rebuild_list())
	top.add_child(reload_btn)
	var cats := HBoxContainer.new()
	cats.add_theme_constant_override("separation", 6)
	box.add_child(cats)
	var group := ButtonGroup.new()
	for i in CATS.size():
		var b := Button.new()
		b.text = CATS[i][1]
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = CATS[i][0] == _cat
		b.set_meta("cat", CATS[i][0])
		b.custom_minimum_size = Vector2(84.0, 34.0)
		b.toggled.connect(_on_cat_toggled.bind(CATS[i][0]))
		cats.add_child(b)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(scroll)
	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_theme_constant_override("separation", 6)
	scroll.add_child(_list_box)
	var help := Label.new()
	help.text = "内置内容来自游戏本体；mod 内容来自 res://mods 与 user://mods（来源标记在括号内）。\n" \
		+ "「✚ 新建内容」在游戏内编辑并保存到 user://mods/workshop_user/manifest.json，重新加载后全局生效。\n" \
		+ "高级 mod：manifest 顶层可加 \"boss\": \"敌人id\" 替换最终 BOSS、\"spawn_table\": {\"波次\": [{\"item\":\"敌人id\",\"w\":权重}]} 覆盖刷怪组合。"
	help.add_theme_font_size_override("font_size", 12)
	help.add_theme_color_override("font_color", Color("9aa3b2"))
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(help)
	_rebuild_list()

func _on_cat_toggled(on: bool, cat: String) -> void:
	if not on:
		return
	_cat = cat
	Haptics.rumble(0.15, 0.0, 0.05)
	_rebuild_list()

func _open_mods_dir() -> void:
	var path := ProjectSettings.globalize_path("user://mods")
	DirAccess.make_dir_recursive_absolute(path)
	OS.shell_open(path)

func _rebuild_list() -> void:
	for c in _list_box.get_children():
		_list_box.remove_child(c)
		c.queue_free()
	var data: Dictionary = {}
	match _cat:
		"characters": data = Registry.characters
		"weapons": data = Registry.weapons
		"items": data = Registry.items
		"upgrades": data = Registry.upgrades
		"enemies": data = Registry.enemies
		"difficulties": data = Registry.difficulties
	for id in data:
		_list_box.add_child(_make_row(data[id]))

func _make_row(d: Dictionary) -> Control:
	var panel := PanelContainer.new()
	var box := VBoxContainer.new()
	panel.add_child(box)
	var name_l := Label.new()
	var src: String = d.get("source", "")
	var src_tag := "　[%s]" % src if src != "" else ""
	name_l.text = "%s %s　(%s)%s" % [d.get("ico", "•"), d.get("name", "?"), d.get("id", "?"), src_tag]
	name_l.add_theme_font_size_override("font_size", 15)
	box.add_child(name_l)
	var info := Label.new()
	info.text = _summary(d)
	info.add_theme_font_size_override("font_size", 12)
	info.add_theme_color_override("font_color", Color("9aa3b2"))
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(info)
	return panel

func _summary(d: Dictionary) -> String:
	match _cat:
		"characters":
			var s: Dictionary = d.get("stats", {})
			return "生命 %.0f ｜ 移速 %.0f ｜ 初始武器 %s ｜ %s" % [
				float(s.get("max_hp", 0.0)), float(s.get("base_speed", 0.0)),
				d.get("start_weapon", "-"), d.get("desc", "")]
		"weapons":
			return "CD %.2fs ｜ 伤害 %.0f ｜ %s ｜ 售价 %d◆ ｜ %s" % [
				float(d.get("cd", 0.0)), float(d.get("dmg", 0.0)),
				d.get("rarity", "-"), int(d.get("price", 30)), d.get("desc", "")]
		"items":
			return "%s ｜ %d◆ ｜ %s ｜ effects=%s" % [
				d.get("rarity", "-"), int(d.get("price", 0)), d.get("desc", ""),
				d.get("effects", {})]
		"upgrades":
			return "%s ｜ effects=%s" % [d.get("desc", ""), d.get("effects", {})]
		"enemies":
			return "HP %.0f ｜ 速度 %.0f ｜ 伤害 %.0f ｜ AI %s ｜ 经验 %s 材料 %s%s" % [
				float(d.get("hp", 0.0)), float(d.get("speed", 0.0)), float(d.get("dmg", 0.0)),
				d.get("ai", "chaser"), str(d.get("xp", 0)), str(d.get("mat", 0)),
				" ｜ BOSS" if (bool(d.get("is_boss", false)) or String(d.get("ai", "")) == "boss") else ""]
		"difficulties":
			return "%s ｜ 血量 x%.1f ｜ 伤害 x%.1f ｜ 刷怪 x%.1f" % [
				d.get("desc", ""), float(d.get("hp_mult", 1.0)),
				float(d.get("dmg_mult", 1.0)), float(d.get("spawn_mult", 1.0))]
	return ""

# ================= 编辑器面板 =================

func _build_editor() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right"]:
		margin.add_theme_constant_override(side, 60)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	margin.visible = false
	add_child(margin)
	_editor = margin
	var panel := PanelContainer.new()
	margin.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)
	var top := HBoxContainer.new()
	vbox.add_child(top)
	var back := Button.new()
	back.text = "← 返回列表"
	back.pressed.connect(_close_editor)
	top.add_child(back)
	var title := Label.new()
	title.text = "新建内容"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color("e8b84b"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top.add_child(title)
	var save_btn := Button.new()
	save_btn.text = "💾 保存并生效"
	save_btn.custom_minimum_size = Vector2(160.0, 40.0)
	save_btn.pressed.connect(_save_entry)
	top.add_child(save_btn)
	# 类别选择
	var cats := HBoxContainer.new()
	cats.add_theme_constant_override("separation", 6)
	cats.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(cats)
	var group := ButtonGroup.new()
	for i in CATS.size():
		var b := Button.new()
		b.text = CATS[i][1]
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = CATS[i][0] == _editor_cat
		b.set_meta("cat", CATS[i][0])
		b.custom_minimum_size = Vector2(90.0, 36.0)
		b.toggled.connect(_on_editor_cat.bind(CATS[i][0]))
		cats.add_child(b)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0.0, 360.0)
	vbox.add_child(scroll)
	_form_box = VBoxContainer.new()
	_form_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_form_box.add_theme_constant_override("separation", 6)
	scroll.add_child(_form_box)
	_editor_status = Label.new()
	_editor_status.add_theme_font_size_override("font_size", 13)
	_editor_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_editor_status)
	_build_form()

func _open_editor() -> void:
	Haptics.rumble(0.2, 0.0, 0.08)
	_browser.visible = false
	_editor.visible = true
	_editor_status.text = ""
	_build_form()

func _close_editor() -> void:
	_editor.visible = false
	_browser.visible = true
	_rebuild_list()

func _on_editor_cat(on: bool, cat: String) -> void:
	if not on:
		return
	_editor_cat = cat
	Haptics.rumble(0.15, 0.0, 0.05)
	_editor_status.text = ""
	_build_form()

## 按类别动态构建字段表单（+ items/upgrades/characters 的 effects 属性组）
func _build_form() -> void:
	for c in _form_box.get_children():
		_form_box.remove_child(c)
		c.queue_free()
	_form_fields = []
	_form_effects = []
	for def in FIELD_DEFS[_editor_cat]:
		_form_box.add_child(_make_field(def))
	if _editor_cat == "items" or _editor_cat == "upgrades" or _editor_cat == "characters":
		_form_box.add_child(_make_section("属性效果（0 = 不加成；倍率类 0.1 = +10%）"))
		var grid := GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", 12)
		grid.add_theme_constant_override("v_separation", 4)
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_form_box.add_child(grid)
		for ef in EFFECT_FIELDS:
			grid.add_child(_make_effect_field(ef))
		if _editor_cat == "characters":
			# 角色基础移速（stats.base_speed，区别于 speed_mult 加成）
			grid.add_child(_make_effect_field(["base_speed", "基础移速", 10.0]))

func _make_section(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color("e8b84b"))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

## def: [key, label, type, default, (min,max,step|choices)]
func _make_field(def: Array) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lab := Label.new()
	lab.text = def[1]
	lab.custom_minimum_size = Vector2(240.0, 0.0)
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lab)
	var ftype: String = def[2]
	var ctrl: Control
	match ftype:
		"text":
			var e := LineEdit.new()
			e.text = str(def[3])
			e.custom_minimum_size = Vector2(300.0, 32.0)
			ctrl = e
		"f", "i":
			var s := SpinBox.new()
			s.min_value = def[4]
			s.max_value = def[5]
			s.step = def[6]
			s.value = float(def[3])
			s.custom_minimum_size = Vector2(160.0, 32.0)
			if ftype == "i":
				s.suffix = ""
			ctrl = s
		"choice":
			var o := OptionButton.new()
			var opts: Array = def[4]
			for opt in opts:
				o.add_item(str(opt))
			o.select(maxi(0, opts.find(def[3])))
			o.custom_minimum_size = Vector2(160.0, 32.0)
			ctrl = o
		_:
			return row
	row.add_child(ctrl)
	_form_fields.append({ "key": def[0], "ctrl": ctrl, "type": ftype })
	return row

func _make_effect_field(ef: Array) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lab := Label.new()
	lab.text = ef[1]
	lab.custom_minimum_size = Vector2(170.0, 0.0)
	lab.add_theme_font_size_override("font_size", 12)
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(lab)
	var s := SpinBox.new()
	s.min_value = 0.0
	s.max_value = 999.0
	s.step = float(ef[2])
	s.custom_minimum_size = Vector2(110.0, 28.0)
	row.add_child(s)
	_form_effects.append({ "key": ef[0], "spin": s })
	return row

## 收集表单 → Registry 校验注册 → 持久化
func _save_entry() -> void:
	var entry := {}
	for f in _form_fields:
		var v: Variant
		match f.type:
			"text": v = f.ctrl.text.strip_edges()
			"f": v = float(f.ctrl.value)
			"i": v = int(round(f.ctrl.value))
			"choice": v = f.ctrl.get_item_text(f.ctrl.selected)
		entry[f.key] = v
	# effects 组：收集非零值
	var effects := {}
	for ef in _form_effects:
		var val: float = float(ef.spin.value)
		if val != 0.0:
			effects[ef.key] = val
	if not effects.is_empty():
		if _editor_cat == "characters":
			# 角色：effects 进 stats（base_speed 也是 stats 键）
			entry["stats"] = effects
		else:
			entry["effects"] = effects
	# 敌人：ai="boss" 自动标记；shooter 缺省风筝参数补默认
	if _editor_cat == "enemies":
		if String(entry.get("ai", "")) == "boss":
			entry["is_boss"] = true
			if float(entry.get("ring_cd", 0.0)) <= 0.0:
				entry["ring_cd"] = 2.4
			if int(entry.get("ring_count", 0)) <= 0:
				entry["ring_count"] = 14
			if float(entry.get("bspeed", 0.0)) <= 0.0:
				entry["bspeed"] = 240.0
		elif String(entry.get("ai", "")) == "shooter":
			if float(entry.get("keep_dist", 0.0)) <= 0.0:
				entry["keep_dist"] = 270.0
			if float(entry.get("shoot_cd", 0.0)) <= 0.0:
				entry["shoot_cd"] = 2.2
			if float(entry.get("bspeed", 0.0)) <= 0.0:
				entry["bspeed"] = 300.0
	# 武器近战可选字段不需要；校验交给 Registry
	if Registry.save_content(_editor_cat, entry):
		Haptics.rumble(0.3, 0.0, 0.1)
		_editor_status.text = "✅ 已保存：%s（%s）— 重新加载后全局生效" % [entry.get("name", ""), entry.get("id", "")]
		_editor_status.add_theme_color_override("font_color", Color("7ec850"))
	else:
		Haptics.rumble(0.4, 0.2, 0.15)
		_editor_status.text = "❌ 保存失败：检查必填字段（ID/名称/数值），ID 不能与内置内容冲突字段缺失"
		_editor_status.add_theme_color_override("font_color", Color("ff8a80"))
