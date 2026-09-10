extends Control
## 江湖奇遇事件卡 UI（Phase 4）
## 全屏遮罩 + 标题 + 描述 + 三选一按钮。
## 代价类选项（cost_materials / hp_pct_cost）在资源不足时置灰，但仍占位显示——
## 玩家需要看见「自己付不起什么」才能理解取舍。
## 本界面为强制选择：不提供 Esc 取消（奇遇必须做个决定）。
## 输入：键盘 1/2/3、鼠标点击、手柄焦点导航（←/→ + A）

signal chosen(card_id: String, choice_index: int)

var player  # characters/player.gd 引用，由 main 注入

var _card: Dictionary = {}
var _buttons: Array = []
var _key_labels: Array = []

@onready var _title: Label = $Center/Box/Title
@onready var _sub: Label = $Center/Box/Sub
@onready var _desc: Label = $Center/Box/Desc
@onready var _cards: HBoxContainer = $Center/Box/Cards

func _ready() -> void:
	visible = false

## 当前展示的卡 id（测试/调试观测用）
func card_id() -> String:
	return String(_card.get("id", ""))

func choice_count() -> int:
	return _buttons.size()

func is_choice_enabled(i: int) -> bool:
	return i >= 0 and i < _buttons.size() and not _buttons[i].disabled

## 打开事件卡：card 为 Config.EVENT_CARDS 的条目
func open(card: Dictionary) -> void:
	if card.is_empty():
		return
	_card = card
	_buttons = []
	_key_labels = []
	_title.text = "%s %s" % [String(card.get("ico", "❓")), String(card.get("title", "奇遇"))]
	_desc.text = String(card.get("desc", ""))
	_build_choices()
	visible = true
	modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, 0.12)
	_grab_default()

## 默认焦点：第一张可选项（不可选的禁用按钮拿不到焦点）
func _grab_default() -> void:
	for b in _buttons:
		if not b.disabled:
			b.grab_focus()
			return
	if not _buttons.is_empty():
		_buttons[0].grab_focus()

func _build_choices() -> void:
	for c in _cards.get_children():
		_cards.remove_child(c)
		c.free()   # 立即删除：queue_free 会让本帧 get_children 返回旧+新混合
	var choices: Array = _card.get("choices", [])
	for i in choices.size():
		var ch: Dictionary = choices[i]
		var effect: Dictionary = ch.get("effect", {})
		var afford := _affordable(effect)
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(200.0, 208.0)
		btn.disabled = not bool(afford.get("ok", true))
		btn.pressed.connect(_choose.bind(i))
		_apply_card_style(btn, String(_card.get("rarity", "common")), btn.disabled)
		_cards.add_child(btn)
		_buttons.append(btn)
		# 卡面（不拦截鼠标，保证按钮可点）
		var box := VBoxContainer.new()
		box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		box.alignment = BoxContainer.ALIGNMENT_CENTER
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(box)
		var key_l := Label.new()
		key_l.text = "[%d]" % (i + 1)
		key_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		key_l.add_theme_font_size_override("font_size", 15)
		key_l.add_theme_color_override("font_color", Color("9aa3b2"))
		key_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(key_l)
		_key_labels.append(key_l)
		var name_l := Label.new()
		name_l.text = String(ch.get("text", ""))
		name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_l.add_theme_font_size_override("font_size", 19)
		name_l.add_theme_color_override("font_color",
			Config.rarity_color(String(_card.get("rarity", "common"))).lightened(0.1))
		name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(name_l)
		var hint_l := Label.new()
		hint_l.text = String(ch.get("hint", ""))
		hint_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint_l.custom_minimum_size = Vector2(180.0, 0.0)
		hint_l.add_theme_font_size_override("font_size", 12)
		hint_l.add_theme_color_override("font_color", Color("9aa3b2"))
		hint_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(hint_l)
		# 付不起的选项把原因写在卡面底部，避免玩家以为是 bug
		if not bool(afford.get("ok", true)):
			var why := Label.new()
			why.text = String(afford.get("reason", "资源不足"))
			why.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			why.custom_minimum_size = Vector2(180.0, 0.0)
			why.add_theme_font_size_override("font_size", 11)
			why.add_theme_color_override("font_color", Color("e0564f"))
			why.mouse_filter = Control.MOUSE_FILTER_IGNORE
			box.add_child(why)

## 选项可负担性：只认「前置消耗」两个键；奖励类键一律无条件可负担
func _affordable(effect: Dictionary) -> Dictionary:
	var cost := int(effect.get("cost_materials", 0))
	if cost > 0 and GameState.materials < cost:
		return { "ok": false, "reason": "材料不足（需 %d ◆）" % cost }
	var pct := float(effect.get("hp_pct_cost", 0.0))
	if pct > 0.0 and player != null:
		var max_hp: float = float(player.stats.get("max_hp", 0.0))
		# 必须留 1 点血，否则这个选项就是自杀键
		if float(player.hp) - max_hp * pct < 1.0:
			return { "ok": false, "reason": "生命不足（需 %d%% 生命）" % roundi(pct * 100.0) }
	return { "ok": true, "reason": "" }

## 卡面样式：稀有度描边 + 微底色；禁用态整体压暗以示不可选
func _apply_card_style(btn: Button, rarity: String, disabled: bool) -> void:
	var rc: Color = Config.rarity_color(rarity) if not disabled else Color("5a6270")
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(rc.r, rc.g, rc.b, 0.08)
	normal.border_color = rc
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(10)
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = Color(rc.r, rc.g, rc.b, 0.16)
	hover.border_color = Color("e8b84b")
	var dis: StyleBoxFlat = normal.duplicate()
	dis.bg_color = Color(0.10, 0.11, 0.13, 0.5)
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("focus", hover.duplicate())
	btn.add_theme_stylebox_override("pressed", hover.duplicate())
	btn.add_theme_stylebox_override("disabled", dis)

func _choose(i: int) -> void:
	if not visible or i < 0 or i >= _buttons.size():
		return
	if _buttons[i].disabled:
		return
	var cid := card_id()
	var choices: Array = _card.get("choices", [])
	if i >= choices.size():
		return
	Haptics.rumble(0.3, 0.0, 0.1)
	visible = false
	_buttons = []
	_key_labels = []
	chosen.emit(cid, i)

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_accept"):
		var focus := get_viewport().gui_get_focus_owner()
		if focus is Button and not focus.disabled and focus.get_parent() == _cards:
			_choose(focus.get_index())
		else:
			# 焦点丢失时落到第一张可选项，避免卡死
			for i in _buttons.size():
				if not _buttons[i].disabled:
					_choose(i)
					break
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_1: _choose(0); get_viewport().set_input_as_handled()
			KEY_2: _choose(1); get_viewport().set_input_as_handled()
			KEY_3: _choose(2); get_viewport().set_input_as_handled()
