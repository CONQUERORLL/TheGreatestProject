extends Node2D
## 玩家弹丸使用线段扫掠命中，避免高弹速或低帧率时穿透敌人。

var velocity := Vector2.ZERO
var life := 1.1
var dmg := 0.0
var crit := false
var radius := 4.0
var splash := 0.0
var col := Color("ffe08a")
var roll_data: Dictionary = {}

func _ready() -> void:
	add_to_group("player_bullets")

func setup(pos: Vector2, ang: float, wcfg: Dictionary, roll: Dictionary) -> void:
	position = pos
	velocity = Vector2.from_angle(ang) * float(wcfg.bspeed)
	dmg = roll.dmg
	crit = roll.crit
	roll_data = roll
	splash = float(wcfg.get("splash", 0.0))
	radius = 7.0 if splash > 0.0 else 4.0
	life = float(wcfg.get("bullet_life", 1.1))
	col = Color("ffb347") if splash > 0.0 else Color("ffe08a")

func _physics_process(delta: float) -> void:
	if not GameState.is_running():
		return
	var previous := global_position
	var next := global_position + velocity * delta
	life -= delta
	# 障碍物遮挡（Phase 5）：与敌人命中共用同一套线段几何，取更早的命中点。
	# 必须显式 is_finite 判空：block_t 用 INF 表示「没被挡住」，
	# 而 INF > 0.0 与 INF <= INF 同时为真，漏判会把「没挡住」当成「挡住」，
	# 子弹会在第一帧被全部销毁（无敌人时 enemy_t 同样是 INF，坑得更隐蔽）。
	# 只认 t > 0：贴墙开火时弹丸起点可能落在障碍物内，那种情况放它飞出去，
	# 否则贴墙射击会变成「子弹原地蒸发」
	var block_t := Obstacles.first_block_t(previous, next, radius)
	var collision := Combat.first_enemy_hit_on_segment(previous, next, radius)
	var enemy_t: float = INF
	if not collision.is_empty():
		enemy_t = float(collision.t)
	if is_finite(block_t) and block_t > 0.0 and block_t <= enemy_t:
		global_position = previous.lerp(next, block_t)
		# 溅射武器照常爆炸（打墙也有 AOE），普通弹只留一点撞击火花
		if splash > 0.0:
			Explosion.spawn(get_parent(), global_position, splash, dmg, crit, roll_data)
		else:
			Burst.spawn(get_parent(), global_position, col, 4, 90.0)
		queue_free()
		return
	if not collision.is_empty():
		var hit: Node2D = collision.enemy
		global_position = collision.position
		if splash > 0.0:
			Explosion.spawn(get_parent(), global_position, splash, dmg, crit, roll_data)
		else:
			hit.take_damage(dmg, crit)
			hit.apply_hit_roll(roll_data)
		queue_free()
		return
	global_position = next
	var world := Rect2(0.0, 0.0, Config.WORLD.w, Config.WORLD.h)
	if life <= 0.0 or not world.has_point(global_position):
		if splash > 0.0:
			Explosion.spawn(get_parent(), global_position, splash, dmg, crit, roll_data)
		queue_free()

func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, col)
