extends Node2D
## 敌方弹丸使用线段扫掠命中玩家，避免高弹速或低帧率穿透。
## 视觉：沿飞行方向的镖形弹体（深色外廓 + 红色弹身 + 白热弹芯），
## 与圆形的掉落物（经验晶体/材料珠）形成强区分，一眼可辨敌我。

var velocity := Vector2.ZERO
var life := 3.0
var dmg := 10.0
var radius := 6.0
var player

const COL := Color("ff6b5e")
const OUTLINE := Color(0.16, 0.05, 0.05, 0.95)
const CORE := Color("fff3ec")

func _ready() -> void:
	add_to_group("enemy_bullets")

func setup(pos: Vector2, ang: float, bspeed: float, damage: float, r: float, life_t: float) -> void:
	position = pos
	rotation = ang
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
	# 镖形（箭头朝 +X = 飞行方向）：外廓 > 弹身 > 弹芯，轮廓感强
	var half_len := radius * 1.35
	var half_wid := radius * 0.58
	var tip := Vector2(half_len, 0.0)
	var side := Vector2(-half_len * 0.35, half_wid)
	var tail := Vector2(-half_len, 0.0)
	var outline_pts := PackedVector2Array([
		tip, Vector2(side.x, side.y), tail, Vector2(side.x, -side.y)])
	draw_colored_polygon(outline_pts, OUTLINE)
	var body_pts := PackedVector2Array([
		tip * 0.78, Vector2(side.x, side.y * 0.62), tail * 0.80,
		Vector2(side.x, -side.y * 0.62)])
	draw_colored_polygon(body_pts, COL)
	draw_circle(Vector2(radius * 0.30, 0.0), radius * 0.32, CORE)
