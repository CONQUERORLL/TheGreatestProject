extends Node2D
## 玩家弹丸使用线段扫掠命中，避免高弹速或低帧率时穿透敌人。

var velocity := Vector2.ZERO
var life := 1.1
var dmg := 0.0
var crit := false
var radius := 4.0
var splash := 0.0
var col := Color("ffe08a")

func _ready() -> void:
	add_to_group("player_bullets")

func setup(pos: Vector2, ang: float, wcfg: Dictionary, roll: Dictionary) -> void:
	position = pos
	velocity = Vector2.from_angle(ang) * float(wcfg.bspeed)
	dmg = roll.dmg
	crit = roll.crit
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
	var collision := Combat.first_enemy_hit_on_segment(previous, next, radius)
	if not collision.is_empty():
		var hit: Node2D = collision.enemy
		global_position = collision.position
		if splash > 0.0:
			Explosion.spawn(get_parent(), global_position, splash, dmg, crit)
		else:
			hit.take_damage(dmg, crit)
		queue_free()
		return
	global_position = next
	var world := Rect2(0.0, 0.0, Config.WORLD.w, Config.WORLD.h)
	if life <= 0.0 or not world.has_point(global_position):
		if splash > 0.0:
			Explosion.spawn(get_parent(), global_position, splash, dmg, crit)
		queue_free()

func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, col)
