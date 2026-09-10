extends Node2D
## 玩家弹丸使用线段扫掠命中，避免高弹速或低帧率时穿透敌人。
##
## 外观按武器的 fx 外观族绘制（表见 Registry.WEAPON_FX）：
## 火焰喷射器画的是沿运动方向拉长的火舌而不是圆点，磁轨炮/狙击枪是细长穿甲弹，
## 震雷法锣带锯齿电弧，冰系是六角冰晶……
## 拖尾长度正比于**实际**弹速，所以角色的「弹道精通 / 鹰眼」加成会直接变成更长的光带，
## 不再只是数值上快一点、看起来毫无区别。

var velocity := Vector2.ZERO
var life := 1.1
var base_life := 1.1
var dmg := 0.0
var crit := false
var radius := 4.0
var splash := 0.0
var col := Color("ffe08a")
var roll_data: Dictionary = {}
var fx := "bolt"                 # 外观族（Registry.WEAPON_FX）
var tint := Color(0, 0, 0, 0)    # 角色特性强调色（透明 = 该武器未吃到特性加成）

func _ready() -> void:
	add_to_group("player_bullets")

func setup(pos: Vector2, ang: float, wcfg: Dictionary, roll: Dictionary,
		trait_tint: Color = Color(0, 0, 0, 0)) -> void:
	position = pos
	velocity = Vector2.from_angle(ang) * float(wcfg.bspeed)
	dmg = roll.dmg
	crit = roll.crit
	roll_data = roll
	splash = float(wcfg.get("splash", 0.0))
	radius = 7.0 if splash > 0.0 else 4.0
	life = float(wcfg.get("bullet_life", 1.1))
	base_life = life
	tint = trait_tint
	fx = String(wcfg.get("fx", ""))
	if fx == "":
		# 缺省兜底：多弹丸当霰弹、其余当普通弹（mod 武器不写 fx 也能看）
		fx = "pellet" if int(wcfg.get("pellets", 1)) > 1 else "bolt"
	col = _pick_color(wcfg)

## 配色优先级：武器状态色 > 外观族默认色。
## 于是「火焰长剑的斩击」「疫病连弩的箭」不额外配置也能各自带火色 / 毒色
func _pick_color(wcfg: Dictionary) -> Color:
	var sid := String(wcfg.get("status", ""))
	if sid != "" and Config.STATUS.has(sid):
		return Color(String(Config.STATUS[sid].get("color", "#ffe08a")))
	match String(wcfg.get("fx", "")):
		"flame":
			return Color("ff8a3c")
		"thunder":
			return Color("ffe066")
		"frost":
			return Color("a8e4ff")
		"vine":
			return Color("7ec850")
		"bell":
			return Color("ffd24a")
		"lance":
			return Color("dff2ff")
		"rocket":
			return Color("ffb347")
		"pellet":
			return Color("ffd98a")
	if splash > 0.0:
		return Color("ffb347")
	return Color("ffe08a")

func _physics_process(delta: float) -> void:
	if not GameState.is_running():
		return
	var previous := global_position
	var next := global_position + velocity * delta
	life -= delta
	# 障碍物遮挡（Phase 5）：与敌人命中共用同一套线段几何，取更早的命中点。
	# 必须显式 is_finite 判空：block_t 用 INF 表示「没被挡住」，
	# 而 INF > 0.0 与 INF <= INF 同时为真，漏判会把「没挡住」当成「挡住」，
	# 子弹会在第一帧被全部销毁（无敌人时 enemy_t 同样是 INF，坑得更隐蔽）。
	# 只认 t > 0：贴墙开火时弹丸起点可能落在障碍物内，那种情况放它飞出去，
	# 否则贴墙射击会变成「子弹原地蒸发」
	var block_t := Obstacles.first_block_t(previous, next, radius)
	var collision := Combat.first_enemy_hit_on_segment(previous, next, radius)
	var enemy_t: float = INF
	if not collision.is_empty():
		enemy_t = float(collision.t)
	if is_finite(block_t) and block_t > 0.0 and block_t <= enemy_t:
		global_position = previous.lerp(next, block_t)
		# 溅射武器照常爆炸（打墙也有 AOE），普通弹只留一点撞击火花
		if splash > 0.0:
			Explosion.spawn(get_parent(), global_position, splash, dmg, crit, roll_data)
		else:
			Burst.spawn(get_parent(), global_position, col, 4, 90.0)
		queue_free()
		return
	if not collision.is_empty():
		var hit: Node2D = collision.enemy
		global_position = collision.position
		if splash > 0.0:
			Explosion.spawn(get_parent(), global_position, splash, dmg, crit, roll_data)
		else:
			hit.take_damage(dmg, crit)
			hit.apply_hit_roll(roll_data)
		queue_free()
		return
	global_position = next
	var world := Rect2(0.0, 0.0, Config.WORLD.w, Config.WORLD.h)
	if life <= 0.0 or not world.has_point(global_position):
		if splash > 0.0:
			Explosion.spawn(get_parent(), global_position, splash, dmg, crit, roll_data)
		queue_free()
		return
	# 火焰 / 电弧 / 尾焰是随时间变化的形态，需要逐帧重绘；
	# 其余外观相对节点自身静止（位移由引擎变换处理），画一次即可
	if fx == "flame" or fx == "thunder" or fx == "rocket":
		queue_redraw()

func _draw() -> void:
	var d := velocity.normalized()
	if d == Vector2.ZERO:
		d = Vector2.RIGHT
	_draw_trail(d, velocity.length())
	match fx:
		"flame":
			_draw_flame(d)
		"rocket":
			_draw_rocket(d)
		"lance":
			_draw_lance(d)
		"frost":
			_draw_frost(d)
		"thunder":
			_draw_thunder(d)
		"vine":
			_draw_vine(d)
		"bell":
			_draw_bell(d)
		"pellet":
			_draw_pellet()
		_:
			_draw_bolt()
	# 特性强调环：只有这把武器真的吃到角色特性加成时才会画（见 player._trait_tint_for）
	if tint.a > 0.0:
		draw_arc(Vector2.ZERO, radius + 4.5, 0.0, TAU, 24,
			Color(tint.r, tint.g, tint.b, 0.55), 1.8, true)

## 速度拖尾：长度正比于实际弹速。
## 540 与 864 的弹速差会直接变成约一倍长的光带 —— 弹速类角色特性的可视化就靠这里
func _draw_trail(d: Vector2, spd: float) -> void:
	var tl := clampf(spd * 0.055, 9.0, 130.0)
	var tail := -d * tl
	draw_line(tail, Vector2.ZERO, Color(col.r, col.g, col.b, 0.20), radius * 1.1, true)
	draw_line(tail * 0.5, Vector2.ZERO, Color(col.r, col.g, col.b, 0.42), radius * 0.65, true)

func _draw_bolt() -> void:
	draw_circle(Vector2.ZERO, radius, col)
	draw_circle(Vector2.ZERO, radius * 0.45, Color(1.0, 1.0, 1.0, 0.85))

func _draw_pellet() -> void:
	# 霰弹小丸：比普通弹更小更亮，一次五发铺开
	draw_circle(Vector2.ZERO, radius * 0.8, col)
	draw_circle(Vector2.ZERO, radius * 0.35, Color(1.0, 1.0, 1.0, 0.7))

## 火舌：沿运动方向拉长的水滴形，外焰暗红 → 内焰橙 → 芯部亮黄白；
## 长度随存活时间收缩，模拟火焰在空中消散（这才是「喷射」该有的样子）
func _draw_flame(d: Vector2) -> void:
	var t := clampf(life / maxf(0.01, base_life), 0.0, 1.0)
	var perp := Vector2(-d.y, d.x)
	var half := 3.0 + 3.8 * t
	var tail := -d * (8.0 + 14.0 * t)
	var tip := d * (5.0 + 7.0 * t)
	draw_colored_polygon(PackedVector2Array([
		tail, tail + perp * half * 0.62, tip, tail - perp * half * 0.62]),
		Color(0.93, 0.29, 0.08, 0.40))
	draw_colored_polygon(PackedVector2Array([
		tail * 0.55, tip * 0.78 + perp * half * 0.34, tip, tip * 0.78 - perp * half * 0.34]),
		Color(1.0, 0.62, 0.15, 0.70))
	draw_circle(d * 1.5, 1.7 + 1.6 * t, Color(1.0, 0.95, 0.72, 0.92))

## 火箭弹：尖头弹体 + 尾翼 + 摆动尾焰（火箭筒打的是「弹」不是「球」）
func _draw_rocket(d: Vector2) -> void:
	var perp := Vector2(-d.y, d.x)
	var fl := 13.0 + sin(life * 46.0) * 3.5
	draw_colored_polygon(PackedVector2Array([
		-d * 5.0 + perp * 3.6, -d * (5.0 + fl), -d * 5.0 - perp * 3.6]),
		Color(1.0, 0.62, 0.20, 0.72))
	draw_colored_polygon(PackedVector2Array([
		d * 9.0, -d * 5.0 + perp * 4.0, -d * 4.0, -d * 5.0 - perp * 4.0]),
		Color(0.36, 0.38, 0.43))
	draw_circle(Vector2.ZERO, 2.2, Color(1.0, 0.9, 0.6, 0.9))

## 穿甲弹：极细长的尖锥 + 长速度线，强调「一发贯穿」
func _draw_lance(d: Vector2) -> void:
	var perp := Vector2(-d.y, d.x)
	draw_colored_polygon(PackedVector2Array([
		d * 17.0, -d * 9.0 + perp * 2.4, -d * 9.0 - perp * 2.4]),
		Color(col.r, col.g, col.b, 0.95))
	draw_line(-d * 26.0, -d * 8.0, Color(col.r, col.g, col.b, 0.5), 1.6, true)
	draw_circle(Vector2.ZERO, 2.4, Color(1.0, 1.0, 1.0, 0.9))

## 六角冰晶 + 冷雾环
func _draw_frost(d: Vector2) -> void:
	for i in 3:
		var a := TAU * float(i) / 3.0 + 0.45
		draw_line(Vector2.from_angle(a) * radius, Vector2.from_angle(a + PI) * radius,
			Color(col.r, col.g, col.b, 0.9), 2.0, true)
	draw_circle(Vector2.ZERO, radius * 0.6, Color(0.85, 0.96, 1.0, 0.85))
	draw_arc(Vector2.ZERO, radius + 2.5, 0.0, TAU, 16,
		Color(col.r, col.g, col.b, 0.35), 1.2, true)

## 雷霆：沿飞行方向的三股锯齿电弧（震雷法锣 / 鎏金权杖的核心识别特征）
## 抖动用固定的伪随机相位（i/s 的三角函数），避免逐帧随机导致电弧乱抖
func _draw_thunder(d: Vector2) -> void:
	var perp := Vector2(-d.y, d.x)
	for i in 3:
		var off := (float(i) - 1.0) * 5.5
		var pts := PackedVector2Array()
		for s in 6:
			var t := float(s) / 5.0
			var jitter := sin(float(i * 7 + s * 11) * 1.7) * 4.4 * (1.0 - absf(t - 0.5) * 2.0)
			pts.append(d * (-11.0 + 27.0 * t) + perp * (off + jitter))
		draw_polyline(pts, Color(1.0, 0.94, 0.62, 0.55), 1.8, true)
	draw_circle(Vector2.ZERO, radius * 0.85, col)
	draw_circle(Vector2.ZERO, radius * 0.4, Color(1.0, 1.0, 1.0, 0.95))

## 藤蔓：一条扭动的绿线缠着小苞
func _draw_vine(d: Vector2) -> void:
	var perp := Vector2(-d.y, d.x)
	var pts := PackedVector2Array()
	for s in 7:
		var t := float(s) / 6.0
		pts.append(d * (-10.0 + 20.0 * t) + perp * sin(t * 7.0) * 3.6)
	draw_polyline(pts, Color(0.45, 0.78, 0.32, 0.9), 3.0, true)
	draw_circle(Vector2.ZERO, radius * 0.75, col)

## 金铃：本体 + 垂直于飞行方向的两道音波弧
func _draw_bell(d: Vector2) -> void:
	var perp := Vector2(-d.y, d.x)
	draw_circle(Vector2.ZERO, radius * 0.85, col)
	draw_circle(Vector2.ZERO, radius * 0.4, Color(1.0, 1.0, 1.0, 0.85))
	var base := perp.angle()
	for k in 2:
		draw_arc(-d * 3.0, 10.0 + float(k) * 6.0, base - 0.9, base + 0.9, 12,
			Color(1.0, 0.88, 0.45, 0.5 - float(k) * 0.18), 1.6, true)
