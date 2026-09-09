class_name Burst
extends Node2D
## 一次性粒子迸发（命中/死亡表现；纯视觉，用全局随机即可）
## 大规模战斗护栏：全场存活超过上限时丢弃新迸发，保帧率

const MAX_LIVE := 60

var parts: Array = []

static var _live := 0   # 当前存活迸发数（护栏计数）

func _ready() -> void:
	add_to_group("fx")
	_live += 1

static func spawn(parent: Node, pos: Vector2, color: Color, count: int, speed: float) -> void:
	if _live >= MAX_LIVE:
		return   # 特效护栏
	var b := Burst.new()
	b.position = pos
	b.z_index = 20
	b.modulate = color
	for i in count:
		var a := randf() * TAU
		var v := randf_range(speed * 0.3, speed)
		b.parts.append({
			"pos": Vector2.ZERO, "vel": Vector2.from_angle(a) * v,
			"life": randf_range(0.2, 0.5), "max_life": 0.5, "r": randf_range(2.0, 4.0),
		})
	parent.add_child(b)

func _process(delta: float) -> void:
	var alive := false
	for p in parts:
		p.life -= delta
		if p.life > 0.0:
			alive = true
			p.pos += p.vel * delta
			p.vel *= exp(-6.32 * delta)
	if not alive:
		_live -= 1
		queue_free()
		return
	queue_redraw()

func _draw() -> void:
	for p in parts:
		if p.life <= 0.0:
			continue
		var a := clampf(p.life / p.max_life, 0.0, 1.0)
		draw_rect(Rect2(p.pos - Vector2(p.r / 2.0, p.r / 2.0), Vector2(p.r, p.r)), Color(1, 1, 1, a))
