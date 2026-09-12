class_name GhostFire
extends Node2D
## 幽冥主题氛围粒子（Phase 5）：漂浮的鬼火。
## 与竹林/古庙的区别是「无方向」——鬼火原地缓慢游荡并周期性明灭，
## 让画面有不安定的呼吸感。纯视觉，不参与判定。

const COUNT := 32

var area := Vector2(1600.0, 1600.0)
var _fire: Array = []

static func spawn(parent: Node, world: Vector2) -> Node2D:
	var n := GhostFire.new()
	n.area = world
	n.z_index = 4
	parent.add_child(n)
	return n

func _ready() -> void:
	# 刻意不进 "fx" 组：那一组是「打击感特效」的预算与统计口径
	# （Burst.max_live() 护栏、冒烟测试的 fx 计数），常驻氛围粒子混进去会污染两者
	add_to_group("ambient_fx")
	for _i in COUNT:
		_fire.append(_make(Vector2(randf() * area.x, randf() * area.y)))

func _make(pos: Vector2) -> Dictionary:
	var ang := randf() * TAU
	return { "pos": pos,
		"vx": cos(ang) * randf_range(6.0, 20.0), "vy": sin(ang) * randf_range(6.0, 20.0),
		"phase": randf() * TAU, "pulse": randf_range(0.8, 1.9),
		"size": randf_range(4.0, 9.0), "hue": randf() }

func _process(delta: float) -> void:
	for f in _fire:
		var p: Vector2 = f.pos
		var nx := fmod(p.x + float(f.vx) * delta + area.x, area.x)
		var ny := fmod(p.y + float(f.vy) * delta + area.y, area.y)
		f.pos = Vector2(nx, ny)
		# 鬼火每 2~4 秒换一次游荡方向，避免全场朝同一方向漂走
		var phase: float = float(f.phase) + delta * float(f.pulse)
		if phase > TAU * 2.0:
			phase -= TAU * 2.0
			var ang := randf() * TAU
			f.vx = cos(ang) * randf_range(6.0, 20.0)
			f.vy = sin(ang) * randf_range(6.0, 20.0)
		f.phase = phase
	queue_redraw()

func _draw() -> void:
	for f in _fire:
		var p: Vector2 = f.pos
		var r := float(f.size)
		# 明灭：sin 在 [0,1] 之间呼吸，最暗时保留 30% 亮度，不完全消失
		var bright := 0.30 + 0.70 * (0.5 + 0.5 * sin(float(f.phase)))
		var col: Color = Color("5ac8e0").lerp(Color("9a7ae0"), float(f.hue))
		draw_circle(p, r * 2.1, Color(col.r, col.g, col.b, 0.09 * bright))
		draw_circle(p, r, Color(col.r, col.g, col.b, 0.42 * bright))
		draw_circle(p, r * 0.38, Color(0.90, 0.98, 1.0, 0.72 * bright))
