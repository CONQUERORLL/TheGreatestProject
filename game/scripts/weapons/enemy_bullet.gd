extends Node2D
## 敌方弹丸使用线段扫掠命中玩家，避免高弹速或低帧率穿透。

var velocity := Vector2.ZERO
var life := 3.0
var dmg := 10.0
var radius := 6.0
var player

const COL := Color("ff6b5e")

func _ready() -> void:
	add_to_group("enemy_bullets")

func setup(pos: Vector2, ang: float, bspeed: float, damage: float, r: float, life_t: float) -> void:
	position = pos
	velocity = Vector2.from_angle(ang) * bspeed
	dmg = damage
	radius = r
	life = life_t
	z_index = 6

func _physics_process(delta: float) -> void:
	if not GameState.is_running():
		return
	var previous := global_position
	var next := global_position + velocity * delta
	life -= delta
	if player != null and is_instance_valid(player) and Combat.segment_hits_circle(
			previous, next, player.global_position, radius + float(Config.PLAYER.radius)):
		global_position = next
		player.take_damage(dmg)
		queue_free()
		return
	global_position = next
	var world := Rect2(0.0, 0.0, Config.WORLD.w, Config.WORLD.h)
	if life <= 0.0 or not world.has_point(global_position):
		queue_free()

func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, COL)
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 20, Color(0.0, 0.0, 0.0, 0.35), 2.0, true)
