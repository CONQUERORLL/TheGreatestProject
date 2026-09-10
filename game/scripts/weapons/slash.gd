class_name Slash
extends Node2D
## 近战挥砍视觉。伤害由玩家开火时一次性结算，这里只负责表现。
##
## 按武器的 fx 外观族绘制（表见 Registry.WEAPON_FX）：
##   太刀/砍刀/长剑 → 月牙刀光，且会**沿挥砍方向扫过**（不是整片扇形一起闪现）
##   沥青长鞭       → 甩出去的鞭影
##   重锤           → 推出去的冲击波 + 向外辐射的碎裂
## 配色取武器的状态色：火焰长剑是橙红刀光、毒牙匕首是绿刃。

var dir := 0.0
var arc := 1.5
var range_r := 82.0
var life := 0.22
var max_life := 0.22
var fx := "slash"
var col := Color(1.0, 0.914, 0.69)
var tint := Color(0, 0, 0, 0)   # 角色特性强调色（透明 = 该武器未吃到特性加成）

func setup(pos: Vector2, direction: float, slash_range: float, swing_arc: float,
		fx_id: String = "", tint_col: Color = Color(0, 0, 0, 0),
		slash_col: Color = Color(1.0, 0.914, 0.69)) -> void:
	position = pos
	dir = direction
	range_r = slash_range
	arc = swing_arc
	fx = fx_id if fx_id != "" else "slash"
	tint = tint_col
	col = slash_col
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
	var t := 1.0 - life / max_life   # 0 → 1
	match fx:
		"whip":
			_draw_whip(t)
		"smash":
			_draw_smash(t)
		_:
			_draw_slash(t)
	# 特性强调弧：只有该武器的近战范围确实被角色特性放大时才画
	if tint.a > 0.0:
		draw_arc(Vector2.ZERO, range_r * 0.96, dir - arc / 2.0, dir + arc / 2.0,
			maxi(8, int(arc * 18.0)), Color(tint.r, tint.g, tint.b, 0.45 * (1.0 - t)), 2.0, true)

## 扇形填充（含圆心）
func _arc_poly(a0: float, span: float, r: float, c: Color) -> void:
	var steps := maxi(6, int(span * 20.0))
	var pts := PackedVector2Array([Vector2.ZERO])
	for i in steps + 1:
		pts.append(Vector2.from_angle(a0 + span * float(i) / float(steps)) * r)
	draw_colored_polygon(pts, c)

## 月牙刀光：残影铺满整弧 + 刀光沿弧扫过 + 扫过前线的高亮刀锋
func _draw_slash(t: float) -> void:
	var a0 := dir - arc / 2.0
	var fade := maxf(0.0, 1.0 - t * 1.15)
	if fade <= 0.0:
		return
	# ① 刀风残影：整弧低透明，快速淡出（让「大开大合」的宽度可见）
	_arc_poly(a0, arc, range_r * 0.95, Color(col.r, col.g, col.b, 0.11 * fade))
	# ② 已扫过区域的刀光（前 60% 时间扫完整弧）
	var sweep := arc * clampf(t / 0.6, 0.0, 1.0)
	if sweep <= 0.001:
		return
	var steps := maxi(6, int(sweep * 22.0))
	draw_arc(Vector2.ZERO, range_r, a0, a0 + sweep, steps,
		Color(col.r, col.g, col.b, 0.72 * fade), 4.0, true)
	draw_arc(Vector2.ZERO, range_r * 0.78, a0, a0 + sweep, steps,
		Color(1.0, 1.0, 0.95, 0.45 * fade), 2.0, true)
	# ③ 刀锋：扫过前线的一道径向亮线
	var edge_a := a0 + sweep
	draw_line(Vector2.from_angle(edge_a) * range_r * 0.22,
		Vector2.from_angle(edge_a) * range_r,
		Color(1.0, 1.0, 1.0, 0.8 * fade), 2.4, true)

## 鞭影：一条从近到远、角度滞后的曲线（末端甩出去），像真的抽了一鞭
func _draw_whip(t: float) -> void:
	var fade := maxf(0.0, 1.0 - t * 1.1)
	if fade <= 0.0:
		return
	var a0 := dir - arc / 2.0
	var sweep := arc * clampf(t / 0.55, 0.0, 1.0)
	var pts := PackedVector2Array()
	var seg := 14
	for i in seg + 1:
		var u := float(i) / float(seg)
		var a := a0 + sweep * (1.0 - u)        # 越靠鞭梢角度越滞后 → 甩鞭感
		pts.append(Vector2.from_angle(a) * (range_r * (0.35 + 0.65 * u)))
	draw_polyline(pts, Color(col.r, col.g, col.b, 0.8 * fade), 3.0, true)
	draw_polyline(pts, Color(0.05, 0.05, 0.06, 0.55 * fade), 1.2, true)
	draw_circle(pts[pts.size() - 1], 3.0, Color(col.r, col.g, col.b, fade))

## 重砸：向外推的粗冲击波 + 内外双弧 + 沿弧辐射的裂纹
func _draw_smash(t: float) -> void:
	var fade := maxf(0.0, 1.0 - t * 0.95)
	if fade <= 0.0:
		return
	var a0 := dir - arc / 2.0
	var steps := maxi(8, int(arc * 20.0))
	var rr := range_r * (0.45 + 0.6 * t)
	draw_arc(Vector2.ZERO, rr, a0, a0 + arc, steps,
		Color(col.r, col.g, col.b, 0.85 * fade), 9.0, true)
	draw_arc(Vector2.ZERO, rr * 0.72, a0, a0 + arc, steps,
		Color(1.0, 1.0, 1.0, 0.42 * fade), 3.0, true)
	for i in 9:
		var a := a0 + arc * (float(i) + 0.5) / 9.0
		draw_line(Vector2.from_angle(a) * rr * 0.8,
			Vector2.from_angle(a) * rr * 1.18,
			Color(1.0, 0.95, 0.8, 0.6 * fade), 2.0, true)
