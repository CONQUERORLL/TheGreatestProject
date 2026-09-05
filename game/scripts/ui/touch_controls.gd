extends Control
## 移动端虚拟摇杆（触屏设备自动显示）：左半屏浮动摇杆控制移动 + 右上角暂停按钮
## 摇杆输出写入 GameState.touch_move（模拟量 0~1），player 移动优先读取
## 桌面/headless 无触屏自动隐藏；UI 全程 mouse_filter=IGNORE，不挡任何点击

signal pause_requested

const RADIUS := 72.0     # 摇杆基座半径（拖满 = 全速）
const KNOB := 30.0       # 摇杆头半径

var _touch_idx := -1        # 占用的触点 index（-1 = 空闲；多点触控时摇杆独占一个手指）
var _base := Vector2.ZERO   # 基座屏幕坐标（按下的位置）
var _knob := Vector2.ZERO   # 摇杆头位置
var _pause_btn: Button = null

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	GameState.phase_changed.connect(_on_phase_changed)
	_build_pause_btn()

## 只在触屏设备的战斗/开场阶段显示（商店/升级/暂停等走原生按钮交互，不需要摇杆）
func _on_phase_changed(p: int) -> void:
	visible = DisplayServer.is_touchscreen_available() \
		and (p == GameState.Phase.PLAYING or p == GameState.Phase.INTRO)
	if not visible:
		_reset()

func _build_pause_btn() -> void:
	_pause_btn = Button.new()
	_pause_btn.text = "⏸"
	_pause_btn.flat = true
	_pause_btn.focus_mode = Control.FOCUS_NONE   # 不参与手柄焦点链
	_pause_btn.add_theme_font_size_override("font_size", 24)
	_pause_btn.add_theme_color_override("font_color", Color(0.95, 0.91, 0.78, 0.7))
	_pause_btn.add_theme_color_override("font_pressed_color", Color("e8b84b"))
	_pause_btn.anchor_left = 1.0
	_pause_btn.anchor_right = 1.0
	_pause_btn.offset_left = -66.0
	_pause_btn.offset_top = 8.0
	_pause_btn.offset_right = -10.0
	_pause_btn.offset_bottom = 62.0
	_pause_btn.pressed.connect(func() -> void: pause_requested.emit())
	add_child(_pause_btn)

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventScreenTouch:
		if event.pressed and _touch_idx == -1 \
				and event.position.x < get_viewport_rect().size.x * 0.55:
			# 空闲手指按在左半屏 → 在按下处生成摇杆
			_touch_idx = event.index
			_base = event.position
			_knob = _base
			queue_redraw()
		elif not event.pressed and event.index == _touch_idx:
			_reset()
	elif event is InputEventScreenDrag and event.index == _touch_idx:
		var v: Vector2 = event.position - _base
		if v.length() > RADIUS:
			v = v.normalized() * RADIUS   # 拖出基座按边缘方向全速
		_knob = _base + v
		GameState.touch_move = v / RADIUS   # 模拟量：轻推慢走
		queue_redraw()

func _draw() -> void:
	if _touch_idx == -1:
		return
	draw_circle(_base, RADIUS, Color(1.0, 1.0, 1.0, 0.08))
	draw_arc(_base, RADIUS, 0.0, TAU, 48, Color(1.0, 1.0, 1.0, 0.3), 2.0, true)
	draw_circle(_knob, KNOB, Color(0.91, 0.72, 0.29, 0.55))

func _reset() -> void:
	_touch_idx = -1
	GameState.touch_move = Vector2.ZERO
	queue_redraw()
