class_name Incense
extends Node2D
## 古庙主题氛围粒子（Phase 5）：自下而上的香火余烬。
## 与竹叶相反，香火整体向上飘并逐渐熄灭，营造「庙里有人刚上过香」的静默感。
## 纯视觉，不参与判定。

const COUNT := 36

var area := Vector2(1600.0, 1600.0)
var _ember: Array = []

static func spawn(parent: Node, world: Vector2) -> Node2D:
	var n := Incense.new()
	n.area = world
	n.z_index = 4
	parent.add_child(n)
	return n

func _ready() -> void:
	# 刻意不进 "fx" 组：那一组是「打击感特效」的预算与统计口径
	# （Burst.MAX_LIVE 护栏、冒烟测试的 fx 计数），常驻氛围粒子混进去会污染两者
	add_to_group("ambient_fx")
	for _i in COUNT:
		_ember.append(_make(randf() * area.y))

## life 从 1 递减到 0：越接近 0 越暗越小，回到满值时从底部重新升起
func _make(y: float) -> Dictionary:
	return { "pos": Vector2(randf() * area.x, y),
		"vy": randf_range(-38.0, -18.0), "phase": randf() * TAU,
		"sway": randf_range(10.0, 26.0), "life": randf(), "size": randf_range(2.2, 4.6) }

func _process(delta: float) -> void:
	for e in _ember:
		var life: float = float(e.life) - delta * 0.28
		var p: Vector2 = e.pos
		var phase: float = float(e.phase) + delta * 1.1
		var nx := fmod(p.x + float(e.sway) * sin(phase) * delta + area.x, area.x)
		var ny := p.y + float(e.vy) * delta
		if life <= 0.0 or ny < 0.0:
			life = 1.0
			nx = randf() * area.x
			ny = area.y
		e.pos = Vector2(nx, ny)
		e.life = life
		e.phase = phase
	queue_redraw()

func _draw() -> void:
	for e in _ember:
		var life := clampf(float(e.life), 0.0, 1.0)
		var p: Vector2 = e.pos
		var r := float(e.size) * (0.45 + 0.55 * life)
		# 外层暗红余烬 + 内层橙金火芯
		draw_circle(p, r * 1.9, Color(0.85, 0.42, 0.18, 0.13 * life))
		draw_circle(p, r, Color(1.0, 0.62, 0.28, 0.62 * life))
		draw_circle(p, r * 0.45, Color(1.0, 0.88, 0.55, 0.85 * life))
