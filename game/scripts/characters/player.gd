extends CharacterBody2D
## 玩家控制器：八方向移动 + 武器自动攻击（移植自 Web 原型 tryFire / damagePlayer）
## 输入：Input Map move_*（WASD / 方向键 / 手柄左摇杆）

const BulletScene := preload("res://scenes/weapons/bullet.tscn")

var hp: float = 100.0
var stats: Dictionary = {}
var weapons: Array = []   # [{ "type": String, "cd": float }]，上限 Config.WEAPON_SLOTS
var items_owned: Dictionary = {}   # 已购道具 id -> 数量（暂停/商店展示与出售用）
var facing := 0.0
var iframes := 0.0

@onready var camera: Camera2D = $Camera

func _ready() -> void:
	var c: Dictionary = Config.PLAYER
	stats = {
		"max_hp": c.max_hp, "regen": c.regen, "armor": c.armor, "dodge": c.dodge,
		"dmg_mult": c.dmg_mult, "as_mult": c.as_mult, "crit_ch": c.crit_ch,
		"crit_mult": c.crit_mult, "speed_mult": c.speed_mult,
		"base_speed": c.base_speed,
		"pickup_range": c.pickup_range, "harvesting": c.harvesting, "lifesteal": c.lifesteal,
		"status_chance": 0.0, "status_dmg_mult": 0.0, "status_dur_mult": 0.0, "status_spread": 0.0,
		"on_hit_burn": 0.0, "on_hit_poison": 0.0, "on_hit_freeze": 0.0,
		"on_hit_slow": 0.0, "on_hit_stun": 0.0, "on_hit_bleed": 0.0,
	}
	# 角色（Registry 注册表）：stats 可只覆盖部分字段（创意工坊自定义角色）
	var ch: Dictionary = Registry.get_character(GameState.character_id)
	for k in ch.get("stats", {}):
		stats[k] = ch.stats[k]
	_sanitize_stats()
	hp = stats.max_hp
	var wt: String = GameState.loadout_weapon
	if wt == "":
		wt = ch.get("start_weapon", "pistol")
	weapons = [{ "type": wt, "cd": 0.3 }]
	queue_redraw()

func _physics_process(delta: float) -> void:
	if not GameState.is_running():
		return
	var c: Dictionary = Config.PLAYER
	# ---- 移动：加速度 + 指数阻尼（与原型手感一致） ----
	var input_dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if GameState.touch_move != Vector2.ZERO:
		input_dir = GameState.touch_move   # 移动端虚拟摇杆（模拟量：轻推慢走）
	var max_speed: float = stats.base_speed * stats.speed_mult
	velocity += input_dir * c.accel * delta
	velocity *= exp(-9.0 * delta)
	if velocity.length() > max_speed:
		velocity = velocity.normalized() * max_speed
	var world := Vector2(Config.WORLD.w, Config.WORLD.h)
	var r: float = c.radius
	global_position = (global_position + velocity * delta).clamp(Vector2(r, r), world - Vector2(r, r))
	if input_dir != Vector2.ZERO:
		facing = input_dir.angle()
	# ---- 回复 / 无敌帧 ----
	hp = minf(stats.max_hp, hp + stats.regen * delta)
	iframes = maxf(0.0, iframes - delta)
	# ---- 武器自动攻击 ----
	for w in weapons:
		w.cd -= delta
		if w.cd <= 0.0:
			try_fire(w)

func _process(_delta: float) -> void:
	# 受击无敌帧闪烁（原型 80ms 间隔）
	modulate.a = 0.45 if (iframes > 0.0 and int(Time.get_ticks_msec() / 80.0) % 2 == 0) else 1.0

func try_fire(w: Dictionary) -> void:
	var c: Dictionary = Registry.weapons[w.type]
	w.cd = float(c.cd) / maxf(0.01, float(stats.as_mult))
	var target := Combat.nearest_enemy(global_position)
	var ang := (target.global_position - global_position).angle() if target else facing
	facing = ang
	queue_redraw()
	var attack_type := String(c.get("attack_type", "projectile"))
	if attack_type == "melee":
		_melee_slash(c, ang)
	else:
		var pellets := maxi(1, int(c.get("pellets", 1)))
		var arc := maxf(0.0, float(c.get("arc", 0.0)))
		var spread := maxf(0.0, float(c.get("spread", 0.0)))
		for i in pellets:
			var offset := 0.0
			if pellets > 1:
				offset = -arc / 2.0 + arc * float(i) / float(pellets - 1)
			if spread > 0.0:
				offset += GameRng.range_f(-spread, spread)
			_spawn_bullet(c, ang + offset)
	var shake_amount := float(c.get("shake", 0.0))
	if shake_amount > 0.0:
		EventBus.screen_shake.emit(shake_amount)
	Sfx.play(String(c.get("sfx", "shoot_pistol")))

func _spawn_bullet(c: Dictionary, ang: float) -> void:
	var b := BulletScene.instantiate()
	b.setup(global_position + Vector2.from_angle(ang) * 18.0, ang, c, _roll_damage(c.dmg, c))
	get_parent().add_child(b)

func _melee_slash(c: Dictionary, ang: float) -> void:
	var s := Slash.new()
	s.setup(global_position, ang, c["range"], c.swing_arc)
	get_parent().add_child(s)
	# 一次性命中扇形范围内敌人（原型为 0.13s 持续检测，效果等价）
	for e in Combat.enemies_near(global_position, float(c["range"]) + Combat.MAX_ENTITY_RADIUS):
		if e.flee > 0.0:
			continue
		var d := global_position.distance_to(e.global_position)
		if d < c["range"] + e.radius:
			var da := wrapf((e.global_position - global_position).angle() - ang, -PI, PI)
			if absf(da) < c.swing_arc / 2.0:
				var roll := _roll_damage(c.dmg, c)
				e.take_damage(roll.dmg, roll.crit)
				e.apply_hit_roll(roll)

func _roll_damage(base: float, wcfg: Dictionary = {}) -> Dictionary:
	# 伤害 = 基础 × 伤害加成 × 暴击倍率（对应原型 rollDamage）
	# 同时打包状态载荷：武器自带 status + 道具 on_hit_* 概率，命中后由 Enemy.apply_hit_roll 结算
	var dmg: float = base * stats.dmg_mult
	var crit := GameRng.chance(stats.crit_ch)
	if crit:
		dmg *= stats.crit_mult
	var global_ch := float(stats.status_chance)
	var on_hit := {}
	for sid in Config.STATUS:
		var base_ch := float(stats.get("on_hit_" + String(sid), 0.0))
		if base_ch > 0.0:
			on_hit[String(sid)] = clampf(base_ch + global_ch, 0.0, 1.0)
	return {
		"dmg": dmg, "crit": crit,
		"status": String(wcfg.get("status", "")),
		"status_chance": clampf(float(wcfg.get("status_chance", 1.0)) + float(stats.status_chance), 0.0, 1.0),
		"status_stacks": int(wcfg.get("status_stacks", 1)),
		"status_dur": float(wcfg.get("status_duration", 0.0)),
		"status_power": dmg * (1.0 + float(stats.status_dmg_mult)),
		"dur_mult": 1.0 + float(stats.status_dur_mult),
		"on_hit": on_hit,
	}

## 当前构筑可施加的状态来源：{status_id: {"chance": float, "count": int}}
## 武器自带 status（与 status_chance 相加）+ 道具 on_hit_*（独立概率合并），供 HUD/暂停页图例
func status_sources() -> Dictionary:
	var out: Dictionary = {}
	var global_ch := float(stats.status_chance)
	for w in weapons:
		var cfg: Dictionary = Registry.weapons.get(w.type, {})
		var sid := String(cfg.get("status", ""))
		if sid == "" or not Config.STATUS.has(sid):
			continue
		var ch := clampf(float(cfg.get("status_chance", 1.0)) + global_ch, 0.0, 1.0)
		var e: Dictionary = out.get(sid, { "chance": 0.0, "count": 0 })
		e.chance = maxf(float(e.chance), ch)
		e.count = int(e.count) + 1
		out[sid] = e
	for sid2 in Config.STATUS:
		var base_ch := float(stats.get("on_hit_" + String(sid2), 0.0))
		if base_ch <= 0.0:
			continue
		var ch2 := clampf(base_ch + global_ch, 0.0, 1.0)
		var e2: Dictionary = out.get(String(sid2), { "chance": 0.0, "count": 0 })
		e2.chance = 1.0 - (1.0 - float(e2.chance)) * (1.0 - ch2)
		e2.count = int(e2.count) + 1
		out[String(sid2)] = e2
	return out

## 应用升级效果（数据驱动：effects 键 = stats 键，创意工坊自定义升级直接生效）
## 特例：heal_flat = 最大生命+立即回复同值；heal_pct = 立即回复最大生命百分比
func apply_upgrade(id: String) -> void:
	var u: Dictionary = Registry.upgrades.get(id, {})
	if u.is_empty():
		return
	CodexData.unlock("upgrade", id)
	for k in u.get("effects", {}):
		var v: float = float(u.effects[k])
		match k:
			"heal_flat":
				stats.max_hp += v
				hp = minf(stats.max_hp, hp + v)
			"heal_pct":
				hp = minf(stats.max_hp, hp + stats.max_hp * v)
			_:
				stats[k] = stats.get(k, 0.0) + v
	_sanitize_stats()
	queue_redraw()   # 拾取范围圈等自绘跟随刷新

## 应用商店道具被动效果（数据驱动：effects 键 = stats 键，可叠加；i-hp 只加上限不回血，与原型一致）
func apply_item(id: String) -> void:
	if not Registry.items.has(id):
		return
	CodexData.unlock("item", id)
	items_owned[id] = int(items_owned.get(id, 0)) + 1
	var it: Dictionary = Registry.items[id]
	for k in it.get("effects", {}):
		stats[k] = stats.get(k, 0.0) + float(it.effects[k])
	_sanitize_stats()
	queue_redraw()

## 出售道具：返还 50% 购入价并移除效果（heal_flat/heal_pct 为一次性效果，不可逆）
func sell_item(id: String) -> int:
	var cnt := int(items_owned.get(id, 0))
	if cnt <= 0 or not Registry.items.has(id):
		return 0
	var it: Dictionary = Registry.items[id]
	var price := roundi(float(int(it.get("price", 30))) * 0.5)
	items_owned[id] = cnt - 1
	if items_owned[id] <= 0:
		items_owned.erase(id)
	for k in it.get("effects", {}):
		if k == "heal_flat" or k == "heal_pct":
			continue
		stats[k] = stats.get(k, 0.0) - float(it.effects[k])
	_sanitize_stats()
	hp = minf(hp, stats.max_hp)
	queue_redraw()
	return price

func _sanitize_stats() -> void:
	stats.max_hp = maxf(1.0, float(stats.max_hp))
	stats.base_speed = maxf(1.0, float(stats.base_speed))
	stats.dmg_mult = maxf(0.01, float(stats.dmg_mult))
	stats.as_mult = maxf(0.01, float(stats.as_mult))
	stats.speed_mult = maxf(0.01, float(stats.speed_mult))
	stats.crit_ch = clampf(float(stats.crit_ch), 0.0, 1.0)
	stats.crit_mult = maxf(1.0, float(stats.crit_mult))
	stats.armor = maxf(-7.9, float(stats.armor))
	stats.dodge = clampf(float(stats.dodge), 0.0, 0.95)
	stats.pickup_range = maxf(0.0, float(stats.pickup_range))
	stats.regen = maxf(0.0, float(stats.regen))
	stats.harvesting = maxf(-0.99, float(stats.harvesting))
	stats.lifesteal = maxf(0.0, float(stats.lifesteal))
	stats.status_chance = clampf(float(stats.status_chance), 0.0, 1.0)
	stats.status_dmg_mult = maxf(0.0, float(stats.status_dmg_mult))
	stats.status_dur_mult = maxf(0.0, float(stats.status_dur_mult))
	stats.status_spread = clampf(float(stats.status_spread), 0.0, 1.0)
	for sid in Config.STATUS:
		var key := "on_hit_" + String(sid)
		stats[key] = clampf(float(stats.get(key, 0.0)), 0.0, 1.0)

func take_damage(raw: float) -> void:
	if iframes > 0.0:
		return
	if GameRng.chance(stats.dodge):
		FloatingText.spawn(get_parent(), global_position + Vector2(0.0, -22.0), "闪避", Color("9ad0ff"))
		return
	var dmg: float = raw * (1.0 - stats.armor / (stats.armor + 8.0))
	hp -= dmg
	iframes = Config.PLAYER.iframes
	EventBus.screen_shake.emit(3.5)
	EventBus.player_damaged.emit(dmg)
	FloatingText.spawn(get_parent(), global_position + Vector2(0.0, -20.0),
		"-" + str(roundi(dmg)), Color("ff8a80"))
	Burst.spawn(get_parent(), global_position, Color("e05a4f"), 6, 120.0)
	if hp <= 0.0:
		hp = 0.0
		EventBus.player_died.emit()

## 武器进化（波末由 main 调用）：同名武器达到 evolve_need 时自动合成进化形态。
## 4 把手枪 → 1 把双管神射（腾出槽位），返回进化公告文本列表（无进化返回空）
func evolve_weapons() -> Array:
	var results: Array = []
	var counts := {}
	for w in weapons:
		counts[w.type] = counts.get(w.type, 0) + 1
	var to_process: Array = []
	for wtype in counts:
		var cfg: Dictionary = Registry.weapons.get(wtype, {})
		if cfg.is_empty():
			continue
		var need := int(cfg.get("evolve_need", 0))
		if need > 0 and int(counts[wtype]) >= need and Registry.weapons.has(cfg.evolve_to):
			to_process.append(wtype)
	for wtype in to_process:
		var cfg: Dictionary = Registry.weapons[wtype]
		var need := int(cfg.evolve_need)
		# 移除 need 把同名武器，追加 1 把进化形态
		var removed := 0
		var new_weapons: Array = []
		for w in weapons:
			if w.type == wtype and removed < need:
				removed += 1
			else:
				new_weapons.append(w)
		weapons = new_weapons
		weapons.append({ "type": cfg.evolve_to, "cd": 0.1 })
		var ex_cfg: Dictionary = Registry.weapons[cfg.evolve_to]
		results.append("%s ×%d → %s" % [cfg.name, need, ex_cfg.name])
	return results

## 进化预览：返回 [{type, name, have, need}]（商店/HUD 提示用）
func evolve_progress() -> Array:
	var counts := {}
	for w in weapons:
		counts[w.type] = counts.get(w.type, 0) + 1
	var progress: Array = []
	for wtype in counts:
		var cfg: Dictionary = Registry.weapons.get(wtype, {})
		var need := int(cfg.get("evolve_need", 0))
		if need > 0 and int(counts[wtype]) < need and Registry.weapons.has(cfg.get("evolve_to", "")):
			progress.append({ "type": wtype, "name": cfg.name,
				"have": int(counts[wtype]), "need": need })
	return progress

func _draw() -> void:
	# 角色+枪整体朝向 facing（射击时更新，移动时跟随输入方向）
	var r: float = Config.PLAYER.radius
	draw_circle(Vector2.ZERO, stats.pickup_range, Color(0.494, 0.784, 0.31, 0.05))
	# 身体：按角色主题色着色（游戏内外形象一致）
	var body_col: Color = Color(String(Registry.get_character(
		GameState.character_id).get("color", "#e8b84b")))
	draw_circle(Vector2.ZERO, r, body_col)
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 40, body_col.darkened(0.35), 2.0, true)
	# 旋转坐标系：眼睛+枪一起朝向 facing
	draw_set_transform(Vector2.ZERO, facing, Vector2.ONE)
	# 眼睛（朝前 = +X 方向）
	draw_circle(Vector2(2.0, -5.0), 2.6, Color("2b2110"))
	draw_circle(Vector2(2.0, 5.0), 2.6, Color("2b2110"))
	# 枪管
	draw_rect(Rect2(r - 2.0, -3.0, 14.0, 6.0), Color("454b59"))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
