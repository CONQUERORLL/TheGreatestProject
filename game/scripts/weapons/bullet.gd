extends Node2D
## 玩家子弹：直线飞行，命中敌人造成伤害；火箭弹命中/到期触发爆炸
## 数值来源 CONFIG.WEAPONS（bspeed/life/radius/splash 与原型一致）

var velocity := Vector2.ZERO
var life := 1.1
var dmg := 0.0
var crit := false
var radius := 4.0
var splash := 0.0
var col := Color("ffe08a")

func setup(pos: Vector2, ang: float, wcfg: Dictionary, roll: Dictionary) -> void:
	position = pos
	velocity = Vector2.from_angle(ang) * float(wcfg.bspeed)
	dmg = roll.dmg
	crit = roll.crit
	splash = float(wcfg.get("splash", 0.0))
	radius = 7.0 if splash > 0.0 else 4.0
	life = 0.55 if wcfg.has("pellets") else 1.1  # 霰弹枪弹丸短射程
	col = Color("ffb347") if splash > 0.0 else Color("ffe08a")

func _physics_process(delta: float) -> void:
	if not GameState.is_running():
		return
	global_position += velocity * delta
	life -= delta
	var world := Rect2(0.0, 0.0, Config.WORLD.w, Config.WORLD.h)
	if life <= 0.0 or not world.has_point(global_position):
		if splash > 0.0:
			Explosion.spawn(get_parent(), global_position, splash, dmg, crit)
		queue_free()
		return
	for e in get_tree().get_nodes_in_group("enemies"):
		if e.flee > 0.0:
			continue
		if global_position.distance_to(e.global_position) < radius + e.radius:
			if splash > 0.0:
				Explosion.spawn(get_parent(), global_position, splash, dmg, crit)
			else:
				e.take_damage(dmg, crit)
			queue_free()
			return

func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, col)
