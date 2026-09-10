class_name BambooLeaf
extends Node2D
## 竹林主题氛围粒子（Phase 5）：斜向飘落的竹叶。
## 纯视觉，不参与任何判定。z_index 高于敌人（0）、低于弹丸（5~6）与玩家（10），
## 叶片因此有「从镜头前飘过」的纵深，而不会盖住关键战斗信息。

const COUNT := 40

var area := Vector2(1600.0, 1600.0)
var _leaf: Array = []

static func spawn(parent: Node, world: Vector2) -> Node2D:
	var n := BambooLeaf.new()
	n.area = world
	n.z_index = 4
	parent.add_child(n)
	return n

func _ready() -> void:
	# 刻意不进 "fx" 组：那一组是「打击感特效」的预算与统计口径
	# （Burst.MAX_LIVE 护栏、冒烟测试的 fx 计数），常驻氛围粒子混进去会污染两者
	add_to_group("ambient_fx")
	for _i in COUNT:
		_leaf.append(_make(Vector2(randf() * area.x, randf() * area.y)))

func _make(pos: Vector2) -> Dictionary:
	return { "pos": pos,
		"vx": randf_range(26.0, 58.0), "vy": randf_range(22.0, 46.0),
		"phase": randf() * TAU, "sway": randf_range(14.0, 34.0),
		"spin": randf_range(-1.6, 1.6), "size": randf_range(5.0, 9.0),
		"tone": randf() }

func _process(delta: float) -> void:
	for l in _leaf:
		var phase: float = float(l.phase) + delta * 1.7
		var drift := float(l.sway) * sin(phase)
		var p: Vector2 = l.pos
		var nx := fmod(p.x + (float(l.vx) + drift) * delta + area.x, area.x)
		var ny := fmod(p.y + float(l.vy) * delta + area.y, area.y)
		l.pos = Vector2(nx, ny)
		l.phase = phase
		l.spin = float(l.spin) + delta * 0.9
	queue_redraw()

func _draw() -> void:
	for l in _leaf:
		var s := float(l.size)
		var ang := float(l.spin)
		var p: Vector2 = l.pos
		var col: Color = Color("5d9153").lerp(Color("8ec46f"), float(l.tone))
		# 一片竹叶 = 旋转后的菱形（细长两端尖）
		draw_colored_polygon(PackedVector2Array([
			p + Vector2(s, 0.0).rotated(ang),
			p + Vector2(0.0, s * 0.42).rotated(ang),
			p + Vector2(-s, 0.0).rotated(ang),
			p + Vector2(0.0, -s * 0.42).rotated(ang)]), col)
