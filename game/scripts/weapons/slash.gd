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

## 月牙刀身多边形：外缘取弧（刃口），内缘用 sin 包络收窄 ——
## 两端自然收成刀尖、中段最厚，这才是一把刀划过去的形状
func _blade_poly(a0: float, span: float, r_outer: float, max_thickness: float, c: Color) -> void:
	var steps := maxi(10, int(span * 16.0))
	var pts := PackedVector2Array()
	for i in steps + 1:                        # 外缘：从起始角扫到结束角
		pts.append(Vector2.from_angle(a0 + span * float(i) / float(steps)) * r_outer)
	for i in steps + 1:                        # 内缘：反向回程，半径按 sin 收窄
		var u := 1.0 - float(i) / float(steps)
		var thin := sin(u * PI)
		pts.append(Vector2.from_angle(a0 + span * u) * (r_outer - max_thickness * thin))
	draw_colored_polygon(pts, c)

## 刀光：画成月牙刀身而不是等宽弧线 ——
## 等宽弧读起来是「一个扇形亮了一下」，月牙才像「一把刀划过去」。
## 扫过前线额外点一道短亮痕表示刀锋指向。
func _draw_slash(t: float) -> void:
	var a0 := dir - arc / 2.0
	var fade := maxf(0.0, 1.0 - t * 1.15)
	if fade <= 0.0:
		return
	# ① 刀风残影：整弧极淡铺底，交代挥砍覆盖范围
	_arc_poly(a0, arc, range_r * 0.92, Color(col.r, col.g, col.b, 0.07 * fade))
	# ② 已扫过区域（前 60% 时间扫完整弧）
	var sweep := arc * clampf(t / 0.6, 0.0, 1.0)
	if sweep <= 0.001:
		return
	var reach := range_r * (0.9 + 0.1 * (1.0 - t))
	# ③ 刀身
	_blade_poly(a0, sweep, reach, range_r * 0.20, Color(col.r, col.g, col.b, 0.42 * fade))
	# ④ 刃口：外缘一条更亮的细弧
	var steps := maxi(8, int(sweep * 24.0))
	draw_arc(Vector2.ZERO, reach, a0, a0 + sweep, steps,
		Color(1.0, 1.0, 0.96, 0.85 * fade), 2.2, true)
	# ⑤ 刀锋：扫过前线的一道短亮痕
	var edge_a := a0 + sweep
	draw_line(Vector2.from_angle(edge_a) * range_r * 0.72,
		Vector2.from_angle(edge_a) * range_r * 1.02,
		Color(1.0, 1.0, 1.0, 0.9 * fade), 3.2, true)

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
