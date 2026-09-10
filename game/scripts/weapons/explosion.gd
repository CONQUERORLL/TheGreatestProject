class_name Explosion
extends Node2D
## 爆炸 AOE：生成瞬间对范围内敌人一次性结算伤害，0.28s 扩散消散。
##
## 外观按武器的 fx 外观族区分（从 roll.fx 读，见 Registry.WEAPON_FX）：
##   震雷法锣/鎏金权杖 → 向外辐射的锯齿闪电 + 环形电波 + 白闪
##   霜冻法杖/玄冰新星 → 冰蓝爆裂 + 向外飞散的碎晶
##   火箭筒/火焰系     → 火球 + 外圈黑烟
##   青藤缠索         → 绿雾 + 孢子
## 其余（含 mod 武器）保留默认橙色冲击波

var max_r := 88.0
var dmg := 0.0
var crit := false
var life := 0.28
var max_life := 0.28
var applied := false
var status_roll: Dictionary = {}
var fx := ""
var col := Color("ff9a3c")
var sigil := ""                  # 角色印记 id（元素 / 风格痕迹，空 = 无印记）

static func spawn(parent: Node, pos: Vector2, radius: float, damage: float, is_crit: bool,
		roll: Dictionary = {}) -> void:
	var ex := Explosion.new()
	ex.position = pos
	ex.z_index = 12
	ex.max_r = radius
	ex.dmg = damage
	ex.crit = is_crit
	ex.status_roll = roll
	ex.fx = String(roll.get("fx", ""))
	ex.sigil = String(roll.get("sigil", ""))
	# 配色：武器状态色优先（火=橙红 / 冰=冰蓝 / 雷=金 / 毒=绿），否则按外观族兜底
	var sid := String(roll.get("status", ""))
	if sid != "" and Config.STATUS.has(sid):
		ex.col = Color(String(Config.STATUS[sid].get("color", "#ff9a3c")))
	elif ex.fx == "thunder":
		ex.col = Color("ffe066")
	elif ex.fx == "frost":
		ex.col = Color("a8e4ff")
	parent.add_child(ex)

func _ready() -> void:
	add_to_group("fx")

func _process(delta: float) -> void:
	life -= delta
	if not applied:
		applied = true
		if GameState.is_running():
			for e in Combat.enemies_near(global_position, max_r + Combat.MAX_ENTITY_RADIUS):
				if e.flee > 0.0:
					continue
				if global_position.distance_to(e.global_position) < max_r + e.radius:
					e.take_damage(dmg, crit)
					e.apply_hit_roll(status_roll)
		# 迸发粒子与震屏按外观族区分：雷击明显更重，冰爆更"碎"
		match fx:
			"thunder":
				Burst.spawn(get_parent(), global_position, Color("fff2b0"), 18, 260.0)
				EventBus.screen_shake.emit(7.0)
			"frost":
				Burst.spawn(get_parent(), global_position, Color("bfe9ff"), 16, 170.0)
				EventBus.screen_shake.emit(4.0)
			"vine":
				Burst.spawn(get_parent(), global_position, Color("8fe07a"), 14, 150.0)
				EventBus.screen_shake.emit(3.5)
			_:   # 原型 explode：橙色粒子迸发 14 粒 / 速度 200
				Burst.spawn(get_parent(), global_position, col, 14, 200.0)
				EventBus.screen_shake.emit(5.0)
		queue_redraw()
	if life <= 0.0:
		queue_free()
		return
	queue_redraw()

func _draw() -> void:
	var t := 1.0 - life / max_life   # 0 → 1 扩散进度
	var alpha := clampf(life / max_life, 0.0, 1.0)
	match fx:
		"thunder":
			_draw_thunder(t, alpha)
		"frost":
			_draw_frost(t, alpha)
		"vine":
			_draw_vine(t, alpha)
		"flame", "rocket":
			_draw_flame(t, alpha)
		_:
			_draw_default(t, alpha)
	# 角色印记：爆点上再叠一层「谁打出来的」痕迹
	if sigil != "":
		_draw_sigil(t, alpha)

## ---------------- 角色印记 ----------------
## 叠加在爆炸外观之上：印记色外环 + 按 glyph 分布的痕迹。
## 半径随扩散进度推进，但比主爆环略小 —— 让它读起来是「附着在爆点上」而非另一个爆炸
func _draw_sigil(t: float, alpha: float) -> void:
	var c := Config.sigil_color(sigil)
	if c.a <= 0.0:
		return
	var r := max_r * (0.72 + 0.28 * t)
	match Config.sigil_glyph(sigil):
		"spark":
			# 火 / 爆 / 血：向外飞散的火星
			for i in 8:
				var d := Vector2.from_angle(TAU * float(i) / 8.0 + t * 0.6)
				draw_circle(d * r * (0.85 + float(i % 3) * 0.08),
					2.0, Color(c.r, c.g, c.b, 0.60 * alpha))
		"ring":
			# 守 / 运：双环
			draw_arc(Vector2.ZERO, r * 0.92, 0.0, TAU, 40,
				Color(c.r, c.g, c.b, 0.50 * alpha), 2.0, true)
			draw_arc(Vector2.ZERO, r * 0.68, 0.0, TAU, 32,
				Color(c.r, c.g, c.b, 0.32 * alpha), 1.4, true)
		"edge":
			# 剑 / 疾：径向向外的锋线
			for i2 in 6:
				var d2 := Vector2.from_angle(TAU * float(i2) / 6.0 + 0.5)
				draw_line(d2 * r * 0.45, d2 * r * 1.02,
					Color(c.r, c.g, c.b, 0.48 * alpha), 1.6, true)
		_:
			# mote（水 / 木 / 土 / 生）：外圈漂浮微粒
			for i3 in 10:
				var d3 := Vector2.from_angle(TAU * float(i3) / 10.0 + t * 0.4)
				draw_circle(d3 * r * (0.9 + float(i3 % 3) * 0.06),
					1.6, Color(c.r, c.g, c.b, 0.50 * alpha))

func _draw_default(_t: float, alpha: float) -> void:
	var r := max_r * (1.0 - alpha)
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 48, Color(col.r, col.g, col.b, alpha), 4.0, true)
	draw_circle(Vector2.ZERO, r, Color(col.r, col.g, col.b, 0.25 * alpha))

## 雷霆：白闪 + 八向锯齿闪电 + 双环电波。
## 抖动相位用 i/s 的确定性三角函数，保证电弧形状稳定不乱跳
func _draw_thunder(t: float, alpha: float) -> void:
	var flash := maxf(0.0, 1.0 - t * 3.5)
	if flash > 0.0:
		draw_circle(Vector2.ZERO, max_r * 0.55, Color(1.0, 1.0, 0.94, 0.42 * flash))
	for i in 8:
		var ang := TAU * float(i) / 8.0 + 0.38
		var pts := PackedVector2Array()
		for s in 5:
			var u := float(s) / 4.0
			var r := max_r * (0.25 + 0.75 * u) * (1.0 - t * 0.12)
			var jitter := sin(float(i * 13 + s * 7) * 2.1) * 0.16 * u
			pts.append(Vector2.from_angle(ang + jitter) * r)
		draw_polyline(pts, Color(1.0, 0.96, 0.66, 0.85 * alpha), 2.2, true)
	var rr := max_r * (0.2 + 0.85 * t)
	draw_arc(Vector2.ZERO, rr, 0.0, TAU, 48, Color(col.r, col.g, col.b, 0.7 * alpha), 3.0, true)
	draw_arc(Vector2.ZERO, rr * 1.18, 0.0, TAU, 48, Color(0.85, 0.9, 1.0, 0.3 * alpha), 1.5, true)

## 冰爆：冰蓝填充 + 外环 + 向外飞散的碎晶
func _draw_frost(t: float, alpha: float) -> void:
	var rr := max_r * (1.0 - alpha)
	draw_circle(Vector2.ZERO, rr, Color(0.62, 0.86, 1.0, 0.16 * alpha))
	draw_arc(Vector2.ZERO, rr, 0.0, TAU, 48, Color(col.r, col.g, col.b, 0.8 * alpha), 3.5, true)
	for i in 10:
		var dirv := Vector2.from_angle(TAU * float(i) / 10.0 + 0.3)
		var d1 := rr * (0.95 + 0.25 * sin(float(i) * 2.0))
		draw_line(dirv * rr * 0.7, dirv * d1, Color(0.88, 0.97, 1.0, 0.8 * alpha), 2.5, true)

## 毒雾：半透明绿云 + 孢子点
func _draw_vine(t: float, alpha: float) -> void:
	var rr := max_r * (1.0 - alpha)
	draw_circle(Vector2.ZERO, rr, Color(0.45, 0.78, 0.32, 0.15 * alpha))
	draw_arc(Vector2.ZERO, rr, 0.0, TAU, 48, Color(col.r, col.g, col.b, 0.7 * alpha), 3.0, true)
	for i in 12:
		var p := Vector2.from_angle(TAU * float(i) / 12.0 + 0.2) * rr * (0.5 + 0.4 * sin(float(i) * 3.0))
		draw_circle(p, 2.0, Color(0.7, 0.95, 0.5, 0.7 * alpha))

## 火球：核心亮橙 + 外圈黑烟（火箭筒与火焰系共用）
func _draw_flame(t: float, alpha: float) -> void:
	var rr := max_r * (1.0 - alpha)
	draw_circle(Vector2.ZERO, rr * 0.72, Color(1.0, 0.45, 0.12, 0.30 * alpha))
	draw_circle(Vector2.ZERO, rr * 0.42, Color(1.0, 0.78, 0.30, 0.34 * alpha))
	draw_arc(Vector2.ZERO, rr, 0.0, TAU, 48, Color(1.0, 0.62, 0.20, 0.72 * alpha), 4.0, true)
	draw_arc(Vector2.ZERO, rr * 1.12, 0.0, TAU, 40, Color(0.15, 0.13, 0.12, 0.32 * alpha), 6.0, true)
