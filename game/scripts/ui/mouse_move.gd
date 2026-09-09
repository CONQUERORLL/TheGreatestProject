extends Control
## 桌面鼠标点触移动：
## - 单击地面 → 朝点击点移动，到达后自动停下（点击角色脚下 = 停下）
## - 按住拖动 → 目标持续跟随光标轨迹
## - 键盘 / 虚拟摇杆输入立即接管；点击按钮/toast 等可交互 UI 不会误触发
## 输出写入 GameState.mouse_move（模拟量 0~1，靠近目标减速），player 移动读取

const STOP_RADIUS := 14.0        # 到达判定（世界像素）
const FULL_SPEED_RADIUS := 110.0 # 距离超过此值全速，靠近时线性减速
const MIN_SPEED_SCALE := 0.25

var player: Node2D = null
var _active := false
var _holding := false
var _target := Vector2.ZERO

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	GameState.phase_changed.connect(_on_phase_changed)
	set_process(GameState.phase == GameState.Phase.PLAYING)

func _on_phase_changed(p: int) -> void:
	var on := p == GameState.Phase.PLAYING
	set_process(on)
	if not on:
		_cancel()

func _unhandled_input(event: InputEvent) -> void:
	if not is_processing() or player == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_start(player.get_global_mouse_position())
		else:
			_holding = false
	elif event is InputEventMouseMotion and _holding:
		_target = player.get_global_mouse_position()
		queue_redraw()

func _process(_delta: float) -> void:
	# 鼠标在窗口外松开时收不到 release：兜底清除拖动状态
	if _holding and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_holding = false
	if not _active or player == null:
		GameState.mouse_move = Vector2.ZERO
		return
	# 键盘 / 虚拟摇杆优先：任一方向输入立刻取消鼠标移动
	if Input.get_vector("move_left", "move_right", "move_up", "move_down") != Vector2.ZERO \
			or GameState.touch_move != Vector2.ZERO:
		_cancel()
		return
	var to_target := _target - player.global_position
	var dist := to_target.length()
	if dist <= STOP_RADIUS:
		_cancel()
		return
	GameState.mouse_move = to_target / dist \
		* clampf(dist / FULL_SPEED_RADIUS, MIN_SPEED_SCALE, 1.0)
	queue_redraw()

## 设置移动目标（单击 / 拖动均走这里，便于测试与后续接入其他点触来源）
func _start(world_pos: Vector2) -> void:
	if player == null:
		return
	if world_pos.distance_to(player.global_position) <= STOP_RADIUS:
		_cancel()
		return
	_holding = true
	_active = true
	_target = world_pos
	queue_redraw()

func _cancel() -> void:
	_active = false
	_holding = false
	GameState.mouse_move = Vector2.ZERO
	queue_redraw()

## 目标点屏幕标记（金色圆环 + 圆点）
func _draw() -> void:
	if not _active:
		return
	var screen := get_viewport().get_canvas_transform() * _target
	var col := Color(0.91, 0.72, 0.29, 0.6)
	draw_arc(screen, 11.0, 0.0, TAU, 24, col, 2.0, true)
	draw_circle(screen, 3.0, col)
