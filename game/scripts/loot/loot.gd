class_name Loot
extends Node2D
## 掉落物（移植自原型 pickups / updatePickups / settlePickup / drawPickup）
## kind: "xp" 经验晶体 / "mat" 材料 / "heart" 红心（+val HP）
## 行为：弹出减速（摩擦 exp(-6dt)）→ 进入拾取范围被磁吸 → 接触结算

var kind := "xp"
var val := 1
var vel := Vector2.ZERO
var player  # characters/player.gd 引用，由生成方注入
var _t := 0.0
var _phase := 0.0
var _collected := false

func setup(kind_name: String, value: int, pos: Vector2, velocity: Vector2) -> void:
	kind = kind_name
	val = value
	position = pos
	vel = velocity

func _ready() -> void:
	add_to_group("loot")
	z_index = -1   # 原型中掉落物绘制在敌人/玩家之下
	scale = Vector2(0.2, 0.2)   # 弹出缩放动画
	_phase = position.x   # 原型浮动相位取自 x 坐标

func _physics_process(delta: float) -> void:
	_t += delta
	scale = scale.lerp(Vector2.ONE, minf(1.0, delta * 14.0))
	if not GameState.is_running() or player == null or not is_instance_valid(player):
		queue_redraw()
		return
	vel *= exp(-6.0 * delta)
	var d: float = player.global_position.distance_to(global_position)
	var pr: float = player.stats.pickup_range
	if d < pr:   # 磁吸：f = 1800 * (1 - d/R + 0.2)，越近吸力越强（原 900 翻倍）
		var f: float = 1800.0 * (1.0 - d / pr + 0.2)
		vel += (player.global_position - global_position).normalized() * f * delta
	global_position += vel * delta
	if d < float(Config.PLAYER.radius) + 12.0:
		settle()
		return
	queue_redraw()

## 结算拾取（原型 settlePickup）；波末全场回收也走这里
func settle() -> void:
	if _collected:
		return
	_collected = true
	remove_from_group("loot")   # 立即出组，避免同帧统计/二次回收
	match kind:
		"xp":
			GameState.gain_xp(val)
		"mat":
			GameState.add_materials(val)
		"heart":
			if player and is_instance_valid(player):
				player.hp = minf(player.stats.max_hp, player.hp + float(val))
				FloatingText.spawn(get_parent(), player.global_position + Vector2(0.0, -24.0),
					"+" + str(val), Color("7ec850"))
	queue_free()

func _draw() -> void:
	var bob := sin(_t * 3.33 + _phase) * 2.0   # 原型 sin(now/300 + x) * 2
	draw_set_transform(Vector2(0.0, bob), 0.0, Vector2.ONE)
	match kind:
		"xp":
			# 绿色菱形晶体（旋转 45° 的 8×8 方块）
			draw_set_transform(Vector2(0.0, bob), PI / 4.0, Vector2.ONE)
			draw_rect(Rect2(-4.0, -4.0, 8.0, 8.0), Color("7ec850"))
		"mat":
			# 琥珀圆 + 高光
			draw_circle(Vector2.ZERO, 5.0, Color("e8b84b"))
			draw_circle(Vector2(-1.5, -1.5), 1.6, Color("fff3d0"))
		"heart":
			# 红心：两圆 + 三角近似贝塞尔心形
			draw_circle(Vector2(-2.8, -2.2), 3.4, Color("ef6b5e"))
			draw_circle(Vector2(2.8, -2.2), 3.4, Color("ef6b5e"))
			draw_colored_polygon(PackedVector2Array([
				Vector2(-5.6, -0.5), Vector2(5.6, -0.5), Vector2(0.0, 6.0)]), Color("ef6b5e"))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
