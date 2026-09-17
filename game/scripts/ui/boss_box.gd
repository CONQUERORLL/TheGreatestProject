extends Control
## 法宝盒子（第 9 轮 · 用户需求 4）：中间 BOSS 击破必得，波末开盒**三选一**。
##
## 与 `event_card` / `evolve_choose` 用同一套卡片布局（全屏遮罩 + 标题 + 副标题 + 卡阵），
## 但**刻意独立成一份**而不是复用它们：那两份的契约绑死在"事件卡效果"与"武器进化分支"上，
## 把法宝塞进去会让 `chosen(...)` 的签名变成三重含义，改一个必伤另两个。
##
## 输入：键盘 1~N、鼠标点击、手柄焦点导航（ui_accept）。**强制选择**（不提供取消）——
## 盒子是战利品结算的一环，允许取消就要在流程里多养一条"盒子一直挂着"的分支。

signal picked(artifact_id: String)

## 卡阵参数（桌面设计尺寸；小屏由 UiMetrics.card_grid 压缩/换行，见 open）
const CARD_WANT := Vector2(210.0, 224.0)
const CARD_MIN_W := 150.0
const CARD_MIN_H := 150.0
const CARD_GAP := 14.0
## 卡阵上方「标题 + 副标题 + 说明 + 段间距」占掉的高度（dp）
const BOX_RESERVE_H := 140.0

var player  # characters/player.gd 引用，由 main 注入（与其它 UI 同款）

var _ids: Array = []

@onready var _title: Label = $Center/Box/Title
@onready var _sub: Label = $Center/Box/Sub
@onready var _desc: Label = $Center/Box/Desc
@onready var _cards: GridContainer = $Center/Box/Cards

func _ready() -> void:
	visible = false

## 当前候选法宝 id（测试观测用）
func choices() -> Array:
	return _ids.duplicate()

## 打开盒子。`ids` 为候选法宝 id；其中**未注册**的会被静默剔除（悬空 id 不该让整个界面空转）。
func open(ids: Array) -> void:
	var valid: Array = []
	for raw in ids:
		var aid := String(raw)
		if Registry.get_artifact(aid).is_empty():
			push_warning("[boss_box] 未知法宝 id，已从候选中剔除：" + aid)
			continue
		valid.append(aid)
	_ids = valid
	_title.text = "🎁 法宝盒子"
	var how := "点按卡片选择" if UiMetrics.is_touch \
		else "按 1~%d · 手柄方向键 + A · 鼠标点击" % _ids.size()
	_sub.text = "三选一 · %s" % how
	_desc.text = "BOSS 的战利品 · 选一件带走"
	if UiMetrics.prefers_full_page():
		_desc.custom_minimum_size = Vector2(minf(520.0, UiMetrics.available().x), UiMetrics.dp(48.0))
	for c in _cards.get_children():
		_cards.remove_child(c)
		c.free()   # 立即删除：queue_free 会让本帧 get_children 返回旧+新混合
	var grid := UiMetrics.card_grid(_ids.size(), CARD_WANT,
		UiMetrics.dp(CARD_MIN_W), UiMetrics.dp(CARD_MIN_H), UiMetrics.dp(CARD_GAP),
		UiMetrics.dp(BOX_RESERVE_H))
	var card_size: Vector2 = grid.card_size
	_cards.columns = int(grid.cols)
	var idx := 0
	for raw in _ids:
		var aid := String(raw)
		idx += 1
		var a: Dictionary = Registry.get_artifact(aid)
		var btn := Button.new()
		btn.custom_minimum_size = card_size
		btn.pressed.connect(_choose.bind(aid))
		_apply_style(btn, String(a.get("rarity", "common")))
		_cards.add_child(btn)
		# 卡面（不拦截鼠标，保证按钮可点）
		var box := VBoxContainer.new()
		box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		box.alignment = BoxContainer.ALIGNMENT_CENTER
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(box)
		var key_l := Label.new()
		key_l.text = "[%d]" % idx
		key_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		key_l.add_theme_font_size_override("font_size", 13)
		key_l.add_theme_color_override("font_color", Color("9aa3b2"))
		key_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(key_l)
		var ico := Label.new()
		ico.text = String(a.get("ico", "🎁"))
		ico.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ico.add_theme_font_size_override("font_size", 34)
		ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(ico)
		var name_l := Label.new()
		name_l.text = String(a.get("name", aid))
		name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_l.add_theme_font_size_override("font_size", 19)
		name_l.add_theme_color_override("font_color",
			Config.rarity_color(String(a.get("rarity", "common"))).lightened(0.1))
		name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(name_l)
		var desc := Label.new()
		desc.text = String(a.get("desc", ""))
		desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.custom_minimum_size = Vector2(maxf(card_size.x - 20.0, 60.0), 0.0)
		desc.add_theme_font_size_override("font_size", 12)
		desc.add_theme_color_override("font_color", Color("9aa3b2"))
		desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(desc)
	visible = true
	modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, 0.12)
	_grab_first()

func _grab_first() -> void:
	var bs := _cards.get_children()
	if not bs.is_empty():
		bs[0].grab_focus()

## 卡面样式：稀有度描边 + 微底色（与 event_card 同口径，保证两个界面的手感一致）
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

func _choose(aid: String) -> void:
	if not visible:
		return
	visible = false
	Haptics.rumble(0.3, 0.0, 0.1)
	picked.emit(aid)

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_accept"):
		var focus := get_viewport().gui_get_focus_owner()
		if focus is Button and focus.get_parent() == _cards:
			_choose(String(_ids[focus.get_index()]))
		elif not _ids.is_empty():
			# 焦点丢失时落到第一张，避免卡死（与 event_card 的兜底一致）
			_choose(String(_ids[0]))
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var idx := -1
		match event.physical_keycode:
			KEY_1: idx = 0
			KEY_2: idx = 1
			KEY_3: idx = 2
			KEY_4: idx = 3
		if idx >= 0 and idx < _ids.size():
			_choose(String(_ids[idx]))
			get_viewport().set_input_as_handled()
