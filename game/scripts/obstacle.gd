class_name Obstacle
extends RefCounted
## 地图障碍物外观（Phase 5）：3 种主题装饰物 —— 竹子 / 庙柱 / 石碑。
##
## 为什么不是 StaticBody2D + CollisionShape2D：
## 本项目的移动与弹丸命中全是手写判定（player 直接写 global_position、敌人是 Node2D、
## 子弹走 Combat 线段扫掠），没有任何实体调用 move_and_slide / move_and_collide。
## 因此 StaticBody2D 放进场里既不会挡住移动，也不会挡住子弹——只有物理体才会互相作用。
## 障碍物因此实现为「纯数据 + 统一绘制 + 手写推出/遮挡判定」，见 systems/obstacles.gd。
##
## 本文件只负责「长什么样」和「碰撞半径」，不持有位置，也不做任何查询。

## 每种外观的碰撞半径与配色；碰撞统一按圆处理（推出与线段遮挡都有解析解，
## 比矩形快且不会有角落卡顿）
const SHAPES := {
	"bamboo": { "r": 22.0, "body": "#4a7350", "accent": "#7fb884", "shadow": "#1b2a1e" },
	"pillar": { "r": 26.0, "body": "#6b5346", "accent": "#a28268", "shadow": "#2a1f1a" },
	"stele": { "r": 30.0, "body": "#565b6d", "accent": "#8a90a5", "shadow": "#191c26" },
}

static func radius(kind: String) -> float:
	var cfg: Dictionary = SHAPES.get(kind, SHAPES["bamboo"])
	return float(cfg.get("r", 24.0))

static func kinds() -> Array:
	return SHAPES.keys()

## 在 canvas 的本地坐标系里画一个障碍物（pos 为世界坐标，main 的 _draw 原点即世界原点）
static func draw_one(canvas: CanvasItem, pos: Vector2, kind: String) -> void:
	var cfg: Dictionary = SHAPES.get(kind, SHAPES["bamboo"])
	var r := float(cfg.get("r", 24.0))
	var body := Color(String(cfg.get("body", "#4a7350")))
	var accent := Color(String(cfg.get("accent", "#7fb884")))
	var shadow := Color(String(cfg.get("shadow", "#1b2a1e")))
	# 统一的落地阴影：让俯视角有分量感，也提示「这是实体不是背景装饰」
	canvas.draw_circle(pos + Vector2(0.0, r * 0.42), r * 0.86, Color(shadow.r, shadow.g, shadow.b, 0.55))
	match kind:
		"pillar":
			_draw_pillar(canvas, pos, r, body, accent)
		"stele":
			_draw_stele(canvas, pos, r, body, accent)
		_:
			_draw_bamboo(canvas, pos, r, body, accent)

## 竹子：细长竿身 + 两道竹节 + 顶部斜出的两片叶子
static func _draw_bamboo(canvas: CanvasItem, pos: Vector2, r: float, body: Color, accent: Color) -> void:
	var half_w := r * 0.34
	var half_h := r * 1.15
	canvas.draw_rect(Rect2(pos.x - half_w, pos.y - half_h, half_w * 2.0, half_h * 2.0), body)
	# 竹节
	for i in 2:
		var ny := pos.y - half_h * 0.45 + float(i) * half_h * 0.72
		canvas.draw_line(Vector2(pos.x - half_w, ny), Vector2(pos.x + half_w, ny), accent, 2.0)
	# 竹叶（两片，朝左上和右上斜出）
	canvas.draw_colored_polygon(PackedVector2Array([
		Vector2(pos.x - half_w * 0.2, pos.y - half_h * 0.86),
		Vector2(pos.x - r * 1.16, pos.y - half_h * 1.30),
		Vector2(pos.x - half_w * 0.2, pos.y - half_h * 1.02)]), accent)
	canvas.draw_colored_polygon(PackedVector2Array([
		Vector2(pos.x + half_w * 0.2, pos.y - half_h * 0.92),
		Vector2(pos.x + r * 1.10, pos.y - half_h * 1.42),
		Vector2(pos.x + half_w * 0.2, pos.y - half_h * 1.06)]), accent.darkened(0.15))

## 庙柱：方形柱身 + 上下柱头（俯视看是方墩，比圆墩更「建筑」）
static func _draw_pillar(canvas: CanvasItem, pos: Vector2, r: float, body: Color, accent: Color) -> void:
	var half := r * 0.78
	canvas.draw_rect(Rect2(pos.x - half, pos.y - half, half * 2.0, half * 2.0), body)
	canvas.draw_rect(Rect2(pos.x - half, pos.y - half, half * 2.0, half * 0.42), accent)
	canvas.draw_rect(Rect2(pos.x - half, pos.y + half - half * 0.42, half * 2.0, half * 0.42), accent.darkened(0.2))
	canvas.draw_rect(Rect2(pos.x - half * 0.34, pos.y - half * 0.30, half * 0.68, half * 0.60),
		Color(0.0, 0.0, 0.0, 0.22))

## 石碑：圆顶方碑 + 碑面刻痕
static func _draw_stele(canvas: CanvasItem, pos: Vector2, r: float, body: Color, accent: Color) -> void:
	var half := r * 0.72
	canvas.draw_rect(Rect2(pos.x - half, pos.y - half * 0.86, half * 2.0, half * 1.86), body)
	canvas.draw_circle(pos + Vector2(0.0, -half * 0.86), half, body)
	# 碑面刻痕：三条短横线，暗示有铭文
	for i in 3:
		var ly := pos.y - half * 0.30 + float(i) * half * 0.46
		canvas.draw_line(Vector2(pos.x - half * 0.52, ly), Vector2(pos.x + half * 0.52, ly),
			Color(accent.r, accent.g, accent.b, 0.55), 1.5)
