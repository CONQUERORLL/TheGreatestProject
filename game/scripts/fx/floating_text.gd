class_name FloatingText
extends Node2D
## 飘字（伤害数字/闪避/回血），0.7s 上浮消散；描边与原型一致
## 大规模战斗护栏：全场存活超过上限时丢弃新飘字（老的最快 0.7s 后腾出名额）

## 存活上限：真值在 Config.FX_FLOAT_TEXT_MAX_LIVE（与其他性能护栏同一处）。
## 刻意用函数而非 const —— Config 是 autoload，不能出现在 const 初始化器里
## （那时 autoload 尚未就绪）。运行时读取，开销可忽略（仅在准入判定时调一次）。
static func max_live() -> int:
	return Config.FX_FLOAT_TEXT_MAX_LIVE

var text := ""
var color := Color.WHITE
var size_f := 13
var life := 0.7
var max_life := 0.7
var _counted := false   # 本实例是否已计入 _live（保证 +1/-1 严格配对）

static var _cached_font: Font = null   # 避免每帧每实例取 ThemeDB
static var _live := 0                  # 当前存活飘字数（护栏计数）

func _ready() -> void:
	add_to_group("fx")
	_live += 1
	_counted = true

## 计数兜底：节点若被外部提前销毁（queue_free / 场景切换 / ObjectPool.clear），
## _process 的到期分支不会执行，_live 会永久偏高。上限仅几十，
## 泄漏几十次就会让飘字彻底不再生成（表现是「伤害数字突然消失」且无任何报错）。
## 用 _exit_tree 统一回正，无论从哪条路径离开场景树都能配平。
func _exit_tree() -> void:
	if _counted:
		_counted = false
		_live -= 1

static func spawn(parent: Node, pos: Vector2, text_str: String, color_c: Color, size_i: int = 13) -> void:
	if _live >= max_live():
		return   # 特效护栏：海量命中时丢弃多余飘字，保帧率
	var ft := FloatingText.new()
	ft.position = pos
	ft.z_index = 20
	ft.text = text_str
	ft.color = color_c
	ft.size_f = size_i
	parent.add_child(ft)

func _process(delta: float) -> void:
	life -= delta
	position.y -= 34.0 * delta
	modulate.a = clampf(life / max_life, 0.0, 1.0)
	if life <= 0.0:
		# 正常到期：交给 queue_free → _exit_tree 统一回正计数（此处不再手动 -1，避免双减）
		queue_free()

func _draw() -> void:
	if _cached_font == null:
		_cached_font = ThemeDB.fallback_font
	draw_string_outline(_cached_font, Vector2(-200, 0), text, HORIZONTAL_ALIGNMENT_CENTER, 400.0, size_f, 3, Color(0, 0, 0, 0.6))
	draw_string(_cached_font, Vector2(-200, 0), text, HORIZONTAL_ALIGNMENT_CENTER, 400.0, size_f, color)
