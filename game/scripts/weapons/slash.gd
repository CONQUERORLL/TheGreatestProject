class_name Slash
extends Node2D
## 近战挥砍视觉（扇形弧光，0.13s 消散）；伤害由玩家开火时一次性结算

var dir := 0.0
var arc := 1.5
var range_r := 82.0
var life := 0.13
var max_life := 0.13

func setup(pos: Vector2, direction: float, slash_range: float, swing_arc: float) -> void:
	position = pos
	dir = direction
	range_r = slash_range
	arc = swing_arc
	z_index = 15

func _ready() -> void:
	add_to_group("fx")

func _process(delta: float) -> void:
	life -= delta
	if life <= 0.0:
		queue_free()
		return
	queue_redraw()

func _draw() -> void:
	var a := 1.0 - life / max_life
	var alpha := (1.0 - a) * 0.8
	var rr := range_r * (0.5 + a * 0.6)
	var points := PackedVector2Array([Vector2.ZERO])
	var steps := 16
	for i in steps + 1:
		var t := -arc / 2.0 + arc * float(i) / float(steps)
		points.append(Vector2.from_angle(dir + t) * rr)
	draw_colored_polygon(points, Color(1.0, 0.914, 0.69, alpha))
