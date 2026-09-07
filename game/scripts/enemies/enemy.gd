class_name Enemy
extends Node2D
## 敌人 AI（移植自原型 updateEnemies）：
## - grunt / tank：直线追击；runner 带冲刺抖动
## - shooter：保持距离 + 正弦侧移，周期射击（d<620 才开火）
## - boss：追击 + 环形弹幕（d<760），半血狂暴：提速 35%、弹幕间隔 2.4→1.6
## - 敌间分离（与原型成对互推等价，各自自推半重叠）
## - flee > 0：波末退场，0.55s 淡出后移除，期间不受击/不被索敌

const EnemyBulletScene := preload("res://scenes/weapons/enemy_bullet.tscn")
const LootScene := preload("res://scenes/loot/loot.tscn")

var type := ""
var cfg: Dictionary = {}
var hp := 0.0
var max_hp := 0.0
var speed := 0.0
var touch_dmg := 0.0
var radius := 14.0
var color := Color.WHITE
var shape := "circle"
var touch_cd := 0.0
var flash_t := 0.0
var bar_t := 0.0
var player  # 不定型引用 characters/player.gd，避免循环依赖
var wob := 0.0
var shoot_cd := 0.0
var ring_cd := 0.0
var enraged := false
var flee := 0.0

func setup(type_name: String, wave: int = 1) -> void:
	type = type_name
	cfg = Registry.enemies[type_name]
	var diff: Dictionary = Registry.get_difficulty(GameState.difficulty_id)
	var boss_flag := type_name == "boss" or bool(cfg.get("is_boss", false)) \
		or String(cfg.get("ai", "")) == "boss"
	var hp_s := 1.0 if boss_flag else Config.wave_hp_scale(wave)
	var dmg_s := (1.0 + 0.18 * (wave - 1)) if boss_flag else Config.wave_dmg_scale(wave)
	hp = cfg.hp * hp_s * float(diff.hp_mult)
	max_hp = hp
	speed = cfg.speed * Config.wave_spd_scale(wave)
	touch_dmg = cfg.dmg * dmg_s * float(diff.dmg_mult)
	radius = cfg.r
	color = Color(cfg.color)
	shape = cfg.shape
	wob = GameRng.next() * TAU
	shoot_cd = GameRng.range_f(1.0, 2.0)   # 原型 rand(1,2)：首发时机错开
	ring_cd = float(cfg.get("ring_cd", 0.0))

## 是否 BOSS（内置 boss / 自定义 is_boss=true / ai="boss"）
func is_boss() -> bool:
	return type == "boss" or bool(cfg.get("is_boss", false)) or String(cfg.get("ai", "")) == "boss"

## AI 行为类型（chaser 追击 / runner 抖动冲刺 / shooter 风筝射击 / boss 环形弹幕）
func ai_type() -> String:
	return String(cfg.get("ai", "chaser"))

## 波末退场（波次管理器在收波时调用）
func start_flee() -> void:
	flee = 0.55

func _ready() -> void:
	add_to_group("enemies")

func _physics_process(delta: float) -> void:
	if not GameState.is_running():
		return
	flash_t = maxf(0.0, flash_t - delta)
	bar_t = maxf(0.0, bar_t - delta)
	touch_cd = maxf(0.0, touch_cd - delta)
	# ---- 退场淡出，期间跳过一切行为 ----
	if flee > 0.0:
		flee -= delta
		modulate.a = clampf(flee / 0.55, 0.0, 1.0) * 0.6
		if flee <= 0.0:
			queue_free()
		return
	if player == null or not is_instance_valid(player):
		return
	wob += delta * 6.0
	var to_p: Vector2 = player.global_position - global_position
	var d := to_p.length()
	var ux := to_p / maxf(d, 0.001)
	var mv := Vector2.ZERO
	if ai_type() == "shooter" and cfg.has("keep_dist"):
		# 保持距离 + 正弦侧移
		var kd: float = cfg.keep_dist
		if d > kd + 40.0:
			mv = ux
		elif d < kd - 50.0:
			mv = -ux
		var side := sin(wob) * 0.6
		mv = (mv + Vector2(-ux.y, ux.x) * side) * speed
		shoot_cd -= delta
		if shoot_cd <= 0.0 and d < 620.0:
			shoot_cd = float(cfg.shoot_cd)
			_fire_shooter(ux.angle())
	elif is_boss():
		mv = ux * speed
		ring_cd -= delta
		if not enraged and hp < max_hp * 0.5:
			enraged = true
			speed *= 1.35
		if ring_cd <= 0.0 and d < 760.0:
			ring_cd = 1.6 if enraged else float(cfg.ring_cd)
			_fire_ring()
			EventBus.screen_shake.emit(3.0)
	else:
		# 追击型；runner（ai="runner"）带轻微抖动冲刺感
		var wobble := (1.0 + 0.12 * sin(wob * 2.0)) if ai_type() == "runner" else 1.0
		mv = ux * speed * wobble
	global_position += mv * delta
	var world := Vector2(Config.WORLD.w, Config.WORLD.h)
	global_position = global_position.clamp(
		Vector2(radius, radius), world - Vector2(radius, radius))
	# 移动后重新计算接触，避免使用上一位置的距离和方向。
	var contact_vec: Vector2 = player.global_position - global_position
	var contact_d := contact_vec.length()
	if contact_d < radius + float(Config.PLAYER.radius) and touch_cd <= 0.0:
		touch_cd = Config.PLAYER.touch_tick
		player.take_damage(touch_dmg)
		var contact_dir := contact_vec.normalized() if contact_d > 0.001 else Vector2.from_angle(wob)
		var push: float = (radius + float(Config.PLAYER.radius) + 10.0) - contact_d
		if push > 0.0:
			global_position -= contact_dir * push
	Combat.update_enemy_position(self)
	# 空间索引只查询邻近敌人，并按实例 ID 每对只处理一次。
	for other in Combat.enemies_near(global_position, radius + Combat.MAX_ENTITY_RADIUS):
		if other == self or other.flee > 0.0 or is_queued_for_deletion() \
				or other.is_queued_for_deletion() or get_instance_id() >= other.get_instance_id():
			continue
		var separation: Vector2 = other.global_position - global_position
		var separation_d := separation.length()
		var min_d: float = radius + other.radius
		if separation_d > 0.01 and separation_d < min_d:
			var shift := separation / separation_d * (min_d - separation_d) * 0.5
			global_position -= shift
			other.global_position += shift
			other.global_position = other.global_position.clamp(
				Vector2(other.radius, other.radius), world - Vector2(other.radius, other.radius))
			Combat.update_enemy_position(other)
	global_position = global_position.clamp(
		Vector2(radius, radius), world - Vector2(radius, radius))
	Combat.update_enemy_position(self)
	queue_redraw()

func _fire_shooter(ang: float) -> void:
	_fire_enemy_bullet(ang, float(cfg.bspeed), 6.0, 3.0, touch_dmg)

func _fire_ring() -> void:
	var n: int = cfg.ring_count
	var off := GameRng.next() * TAU
	for i in n:
		var a := off + TAU * float(i) / float(n)
		_fire_enemy_bullet(a, float(cfg.bspeed), 7.0, 4.5, touch_dmg * 0.7)

func _fire_enemy_bullet(ang: float, bspeed: float, r: float, life_t: float, dmg: float) -> void:
	var b := EnemyBulletScene.instantiate()
	b.setup(global_position, ang, bspeed, dmg, r, life_t)
	b.player = player
	get_parent().add_child(b)

func take_damage(dmg: float, crit: bool) -> void:
	if hp <= 0.0 or flee > 0.0:
		return
	hp -= dmg
	flash_t = 0.09
	bar_t = 0.9
	Sfx.play("enemy_hit")
	FloatingText.spawn(get_parent(), global_position + Vector2(0.0, -radius - 4.0),
		str(roundi(dmg)) + ("!" if crit else ""), Color("ffd24a") if crit else Color.WHITE,
		16 if crit else 12)
	Burst.spawn(get_parent(), global_position, color, 3, 90.0)
	if hp <= 0.0:
		die()

func die() -> void:
	EventBus.enemy_killed.emit(type)
	if is_boss():
		# 原型：BOSS 死亡大爆发（40 粒 / 260 速度）+ 震屏 14，直接胜利结算不掉落
		Burst.spawn(get_parent(), global_position, color, 40, 260.0)
		EventBus.screen_shake.emit(14.0)
		EventBus.boss_killed.emit()
		queue_free()
		return
	Burst.spawn(get_parent(), global_position, color, 10, 150.0)
	_drop_loot()
	# 吸血：每击杀回复 lifesteal（原型 killEnemy）
	if player and is_instance_valid(player) and player.stats.lifesteal > 0.0:
		player.hp = minf(player.stats.max_hp, player.hp + player.stats.lifesteal)
	queue_free()

## 掉落：经验晶体 + 材料（收获加成）+ 概率红心（越强掉越好，heart_chance 按怪物类型）
func _drop_loot() -> void:
	var harvest := 0.0
	if player and is_instance_valid(player):
		harvest = player.stats.harvesting
	_spawn_loot("xp", int(cfg.xp),
		Vector2(GameRng.range_f(-40.0, 40.0), GameRng.range_f(-40.0, 40.0)))
	_spawn_loot("mat", maxi(1, roundi(float(cfg.mat) * (1.0 + harvest))),
		Vector2(GameRng.range_f(-50.0, 50.0), GameRng.range_f(-50.0, 50.0)))
	var heart_ch: float = float(cfg.get("heart_chance", Config.HEAL_DROP_CHANCE))
	if heart_ch > 0.0 and GameRng.chance(heart_ch):
		_spawn_loot("heart", 8, Vector2.ZERO)

func _spawn_loot(kind_name: String, value: int, velocity: Vector2) -> void:
	var l := LootScene.instantiate()
	l.setup(kind_name, value, global_position + Vector2(GameRng.range_f(-6.0, 6.0),
		GameRng.range_f(-6.0, 6.0)), velocity)
	l.player = player
	get_parent().add_child(l)

func _draw() -> void:
	var sc := 1.0 + (0.12 if flash_t > 0.0 else 0.0)
	var rr := radius * sc
	var fill := Color.WHITE if flash_t > 0.0 else color
	var outline := Color(0.0, 0.0, 0.0, 0.35)
	match shape:
		"circle":
			draw_circle(Vector2.ZERO, rr, fill)
			draw_arc(Vector2.ZERO, rr, 0.0, TAU, 40, outline, 2.0, true)
		"square":
			draw_rect(Rect2(-rr, -rr, rr * 2.0, rr * 2.0), fill)
			draw_rect(Rect2(-rr, -rr, rr * 2.0, rr * 2.0), outline, false, 2.0)
		"diamond":
			draw_colored_polygon(PackedVector2Array([
				Vector2(0.0, -rr), Vector2(rr, 0.0), Vector2(0.0, rr), Vector2(-rr, 0.0)]), fill)
	# 眼睛
	var er := radius * 0.16
	draw_circle(Vector2(-radius * 0.3, -radius * 0.15), er, Color("241013"))
	draw_circle(Vector2(radius * 0.3, -radius * 0.15), er, Color("241013"))
	# 血条（受击后短暂显示）
	if bar_t > 0.0 and hp < max_hp:
		var bw := maxf(26.0, radius * 2.0)
		draw_rect(Rect2(-bw / 2.0, -radius - 10.0, bw, 4.0), Color(0.0, 0.0, 0.0, 0.6))
		draw_rect(Rect2(-bw / 2.0, -radius - 10.0, bw * clampf(hp / max_hp, 0.0, 1.0), 4.0), Color("e8b84b"))
