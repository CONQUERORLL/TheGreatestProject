extends Node2D
## 主动技能冲击波特效：中心闪光 + 双层扩散冲击波环 + 沿环旋转的粒子点，
## ~0.5s 一次性表现，配合 Burst 粒子 / screen_shake / 专属音效组成技能的「释放感」。
## 纯视觉，不拦截输入。由 player.gd 通过 preload 引用（不用 class_name，避免 headless 直跑时全局类名缓存不生效）。

const MAX_LIVE := 14

var radius := 220.0
var color := Color.WHITE
var intensity := 1.0      # 1.0 满强度（伤害/状态类）；越低越柔和（增益/回复类）
var life := 0.5
var max_life := 0.5
var _seed := 0.0          # 随机相位，让每个冲击波粒子的旋转起点不同

static var _live := 0

func _ready() -> void:
	add_to_group("fx")
	_live += 1
	_seed = randf() * TAU

static func spawn(parent: Node, pos: Vector2, col: Color, rad: float, power: float = 1.0) -> void:
	if _live >= MAX_LIVE:
		return   # 特效护栏：海量同帧释放时丢弃多余冲击波，保帧率
	var script := load("res://scripts/fx/skill_fx.gd") as GDScript
	var s = script.new()
	s.position = pos
	s.z_index = 30
	s.color = col
	s.radius = maxf(1.0, rad)
	s.intensity = clampf(power, 0.0, 1.0)
	parent.add_child(s)

func _process(delta: float) -> void:
	life -= delta
	if life <= 0.0:
		_live -= 1
		queue_free()
		return
	queue_redraw()

func _draw() -> void:
	var t := 1.0 - clampf(life / max_life, 0.0, 1.0)   # 0 → 1 扩散进度
	var ease := 1.0 - pow(1.0 - t, 3.0)                # cubic ease-out：先快后慢
	var alpha := (1.0 - t) * intensity

	# 中心闪光：瞬间亮起、快速淡出，面积随之扩张
	var flash := pow(1.0 - t, 2.0) * intensity
	if flash > 0.005:
		draw_circle(Vector2.ZERO, 24.0 * (1.0 + t * 2.0), Color(color.r, color.g, color.b, flash * 0.32))

	# 双层冲击波环：外环粗、内环细，内环扩散更快
	if alpha > 0.005:
		draw_arc(Vector2.ZERO, radius * ease, 0.0, TAU, 80,
			Color(color.r, color.g, color.b, alpha * 0.9), 6.0 * (1.0 - t) + 1.5, true)
		draw_arc(Vector2.ZERO, radius * ease * 0.6, 0.0, TAU, 64,
			Color(color.r, color.g, color.b, alpha), 3.5 * (1.0 - t) + 1.0, true)

	# 沿环旋转分布的粒子点：增加「能量外放」的动感
	var seg := 16
	for i in seg:
		var ang := _seed + float(i) / seg * TAU + t * 1.6
		var ppos := Vector2.from_angle(ang) * radius * ease
		draw_circle(ppos, 3.2 * (1.0 - t) + 1.0, Color(color.r, color.g, color.b, alpha * 0.95))
