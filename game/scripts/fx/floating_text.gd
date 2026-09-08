class_name FloatingText
extends Node2D
## 飘字（伤害数字/闪避/回血），0.7s 上浮消散；描边与原型一致
## 大规模战斗护栏：全场存活超过上限时丢弃新飘字（老的最快 0.7s 后腾出名额）

const MAX_LIVE := 70

var text := ""
var color := Color.WHITE
var size_f := 13
var life := 0.7
var max_life := 0.7

static var _cached_font: Font = null   # 避免每帧每实例取 ThemeDB
static var _live := 0                  # 当前存活飘字数（护栏计数）

func _ready() -> void:
	add_to_group("fx")
	_live += 1

static func spawn(parent: Node, pos: Vector2, text_str: String, color_c: Color, size_i: int = 13) -> void:
	if _live >= MAX_LIVE:
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
		_live -= 1
		queue_free()

func _draw() -> void:
	if _cached_font == null:
		_cached_font = ThemeDB.fallback_font
	draw_string_outline(_cached_font, Vector2(-200, 0), text, HORIZONTAL_ALIGNMENT_CENTER, 400.0, size_f, 3, Color(0, 0, 0, 0.6))
	draw_string(_cached_font, Vector2(-200, 0), text, HORIZONTAL_ALIGNMENT_CENTER, 400.0, size_f, color)
