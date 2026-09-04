class_name Explosion
extends Node2D
## 爆炸 AOE：生成瞬间对范围内敌人一次性结算伤害，0.28s 扩散消散

var max_r := 88.0
var dmg := 0.0
var crit := false
var life := 0.28
var max_life := 0.28
var applied := false

static func spawn(parent: Node, pos: Vector2, radius: float, damage: float, is_crit: bool) -> void:
	var ex := Explosion.new()
	ex.position = pos
	ex.z_index = 12
	ex.max_r = radius
	ex.dmg = damage
	ex.crit = is_crit
	parent.add_child(ex)

func _ready() -> void:
	add_to_group("fx")

func _process(delta: float) -> void:
	life -= delta
	if not applied:
		applied = true
		if GameState.is_running():
			for e in get_tree().get_nodes_in_group("enemies"):
				if e.flee > 0.0:
					continue
				if global_position.distance_to(e.global_position) < max_r + e.radius:
					e.take_damage(dmg, crit)
		# 原型 explode：橙色粒子迸发 14 粒 / 速度 200
		Burst.spawn(get_parent(), global_position, Color("ff9a3c"), 14, 200.0)
		EventBus.screen_shake.emit(5.0)
		queue_redraw()
	if life <= 0.0:
		queue_free()

func _draw() -> void:
	var r := max_r * (1.0 - life / max_life)
	var alpha := clampf(life / max_life, 0.0, 1.0)
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 48, Color(1.0, 0.702, 0.278, alpha), 4.0, true)
	draw_circle(Vector2.ZERO, r, Color(1.0, 0.549, 0.157, 0.25 * alpha))
