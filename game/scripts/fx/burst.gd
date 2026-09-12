class_name Burst
extends Node2D
## 一次性粒子迸发（命中/死亡表现；纯视觉，用全局随机即可）
## 大规模战斗护栏：全场存活超过上限时丢弃新迸发，保帧率

## 存活上限：真值在 Config.FX_BURST_MAX_LIVE（与其他性能护栏同一处）。
## 刻意用函数而非 const —— Config 是 autoload，不能出现在 const 初始化器里
## （那时 autoload 尚未就绪）。运行时读取，开销可忽略（仅在准入判定时调一次）。
static func max_live() -> int:
	return Config.FX_BURST_MAX_LIVE

var parts: Array = []
var _counted := false   # 本实例是否已计入 _live（保证 +1/-1 严格配对）

static var _live := 0   # 当前存活迸发数（护栏计数）

func _ready() -> void:
	add_to_group("fx")
	_live += 1
	_counted = true

## 计数兜底：节点若被外部提前销毁（queue_free / 场景切换 / ObjectPool.clear），
## _process 的到期分支不会执行，_live 会永久偏高。上限仅几十，
## 泄漏几十次就会让特效彻底不再生成（表现是「打击感突然消失」且无任何报错）。
## 用 _exit_tree 统一回正，无论从哪条路径离开场景树都能配平。
func _exit_tree() -> void:
	if _counted:
		_counted = false
		_live -= 1

static func spawn(parent: Node, pos: Vector2, color: Color, count: int, speed: float) -> void:
	if _live >= max_live():
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
		# 正常到期：交给 queue_free → _exit_tree 统一回正计数（此处不再手动 -1，避免双减）
		queue_free()
		return
	queue_redraw()

func _draw() -> void:
	for p in parts:
		if p.life <= 0.0:
			continue
		var a := clampf(p.life / p.max_life, 0.0, 1.0)
		draw_rect(Rect2(p.pos - Vector2(p.r / 2.0, p.r / 2.0), Vector2(p.r, p.r)), Color(1, 1, 1, a))
