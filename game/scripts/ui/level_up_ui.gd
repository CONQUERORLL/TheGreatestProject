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
	# 波末掉落自动回收等场景会在非 PLAYING 阶段积压 level_queue，
	# 回到战斗阶段时补弹升级卡，确保不吞升级选择
	GameState.phase_changed.connect(_on_phase_changed)

func _on_leveled_up(_new_level: int) -> void:
	if GameState.phase == GameState.Phase.PLAYING and GameState.level_queue > 0:
		open()

func _on_phase_changed(new_phase: int) -> void:
	if new_phase == GameState.Phase.PLAYING and GameState.level_queue > 0 and not visible:
		open()

## 打开升级选择（原型 openLevelUp：随机抽 3 张不重复，可跨次重复；
## 按稀有度加权，等级越高越容易出高品阶卡）
func open() -> void:
	GameState.set_phase(GameState.Phase.LEVEL_UP)
	_choices = []
	# 构筑亲和：与当前角色 / 武器相关的升级更容易出现（近战角色更容易刷到开刃等）
	var wps: Array = []
	var arts: Dictionary = {}
	if player != null and is_instance_valid(player):
		wps = player.weapons
		arts = player.artifacts_owned
	var aff := Config.affinity_tags(GameState.character_id, wps, arts)
	var weighted: Array = []
	for u in Registry.upgrade_list():
		var w: float = Config.rarity_weight(String(u.get("rarity", "common")), GameState.level) \
			* Config.affinity_mult(Config.entry_tags(u), aff)
		weighted.append({ "item": u, "w": w })
	for _i in 3:
		if weighted.is_empty():
			break
		var chosen: Dictionary = GameRng.weighted_pick(weighted)
		_choices.append(chosen)
		for k in range(weighted.size()):
			if weighted[k].item == chosen:
				weighted.remove_at(k)
				break
	_ensure_affinity_choice(aff)
	_title.text = "升级！Lv %d" % GameState.level
	_build_cards()
	visible = true
	# 轻淡入过渡（0.1s，不阻塞选择）
	modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, 0.1)
	_grab_first_card()   # 旧按钮已 free，直接抓焦第一张

## 亲和保底：三张全都不契合构筑时，把最后一张换成契合项。
## 单靠加权只能让契合项「更常出现」，玩家仍可能连着几级看不到任何与构筑相关的东西 ——
## 保底把「关联性」从概率变成承诺，这是构筑感能否成立的关键一步。
## 只换最后一张：保留前两张的随机性，避免每次升级都是同一类卡，那会让 build 变窄而非变丰富。
func _ensure_affinity_choice(aff: Array) -> void:
	if aff.is_empty() or _choices.is_empty():
		return
	for c in _choices:
		if Config.affinity_mult(Config.entry_tags(c), aff) > 1.0:
			return   # 已有契合项，不必干预
	var taken := {}
	for c2 in _choices:
		taken[String(c2.get("id", ""))] = true
	var pool: Array = []
	for u in Registry.upgrade_list():
		if taken.has(String(u.get("id", ""))):
			continue
		var m := Config.affinity_mult(Config.entry_tags(u), aff)
		if m <= 1.0:
			continue
		pool.append({ "item": u,
			"w": Config.rarity_weight(String(u.get("rarity", "common")), GameState.level) * m })
	if pool.is_empty():
		return
	_choices[_choices.size() - 1] = GameRng.weighted_pick(pool)

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
		var rarity := String(u.get("rarity", "common"))
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(200.0, 220.0)
		btn.pressed.connect(_choose.bind(i))
		_apply_card_style(btn, rarity)
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
		name_l.add_theme_color_override("font_color", Config.rarity_color(rarity).lightened(0.1))
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

## 卡面样式：稀有度描边 + 微底色（normal/hover/focus/pressed，focus 金边高亮供手柄导航）
func _apply_card_style(btn: Button, rarity: String = "common") -> void:
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

func _choose(i: int) -> void:
	if not visible or i < 0 or i >= _choices.size():
		return
	if player:
		player.apply_upgrade(_choices[i].id)
	Haptics.rumble(0.25, 0.0, 0.08)   # 手柄确认轻震
	GameState.level_queue = maxi(0, GameState.level_queue - 1)
	_choices = []
	if GameState.level_queue > 0:
		# 连升：为下一次升级重新抽取三张，避免空卡片锁死
		open()
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
			# 必须 set_input_as_handled：否则同一个按键会继续冒泡到 main 的调试后门
			# （1/2/3 在调试构建里是"换武器"键）。升级选中后 phase 已切回 PLAYING，
			# 若不标记已处理，main._unhandled_input 会按"调试换武器"把玩家武器整体换掉
			KEY_1: _choose(0); get_viewport().set_input_as_handled()
			KEY_2: _choose(1); get_viewport().set_input_as_handled()
			KEY_3: _choose(2); get_viewport().set_input_as_handled()
