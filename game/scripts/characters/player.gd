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
	}
	# 角色（Registry 注册表）：stats 可只覆盖部分字段（创意工坊自定义角色）
	var ch: Dictionary = Registry.get_character(GameState.character_id)
	for k in ch.get("stats", {}):
		stats[k] = ch.stats[k]
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
	w.cd = c.cd / stats.as_mult
	var target := Combat.nearest_enemy(global_position)
	var ang := (target.global_position - global_position).angle() if target else facing
	facing = ang   # 角色+枪朝向射击方向
	queue_redraw()
	match w.type:
		"knife":
			_melee_slash(c, ang)
			Sfx.play("shoot_knife")
		"shotgun":
			for i in int(c.pellets):
				var a: float = ang - c.arc / 2.0 + c.arc * (float(i) / (float(c.pellets) - 1.0)) \
					+ GameRng.range_f(-0.03, 0.03)
				_spawn_bullet(c, a)
			EventBus.screen_shake.emit(2.0)
			Sfx.play("shoot_shotgun")
		_:
			var spread: float = c.get("spread", 0.0)
			var a2 := ang + (GameRng.range_f(-spread, spread) if spread > 0.0 else 0.0)
			_spawn_bullet(c, a2)
			if w.type == "rocket":
				EventBus.screen_shake.emit(2.5)
				Sfx.play("shoot_rocket")
			elif w.type == "smg":
				Sfx.play("shoot_smg")
			else:
				Sfx.play("shoot_pistol")

func _spawn_bullet(c: Dictionary, ang: float) -> void:
	var b := BulletScene.instantiate()
	b.setup(global_position + Vector2.from_angle(ang) * 18.0, ang, c, _roll_damage(c.dmg))
	get_parent().add_child(b)

func _melee_slash(c: Dictionary, ang: float) -> void:
	var s := Slash.new()
	s.setup(global_position, ang, c["range"], c.swing_arc)
	get_parent().add_child(s)
	# 一次性命中扇形范围内敌人（原型为 0.13s 持续检测，效果等价）
	for e in get_tree().get_nodes_in_group("enemies"):
		if e.flee > 0.0:
			continue
		var d := global_position.distance_to(e.global_position)
		if d < c["range"] + e.radius:
			var da := wrapf((e.global_position - global_position).angle() - ang, -PI, PI)
			if absf(da) < c.swing_arc / 2.0:
				var roll := _roll_damage(c.dmg)
				e.take_damage(roll.dmg, roll.crit)

func _roll_damage(base: float) -> Dictionary:
	# 伤害 = 基础 × 伤害加成 × 暴击倍率（对应原型 rollDamage）
	var dmg: float = base * stats.dmg_mult
	var crit := GameRng.chance(stats.crit_ch)
	if crit:
		dmg *= stats.crit_mult
	return { "dmg": dmg, "crit": crit }

## 应用升级效果（数据驱动：effects 键 = stats 键，创意工坊自定义升级直接生效）
## 特例：heal_flat = 最大生命+立即回复同值；heal_pct = 立即回复最大生命百分比
func apply_upgrade(id: String) -> void:
	var u: Dictionary = Registry.upgrades.get(id, {})
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
	queue_redraw()   # 拾取范围圈等自绘跟随刷新

## 应用商店道具被动效果（数据驱动：effects 键 = stats 键，可叠加；i-hp 只加上限不回血，与原型一致）
func apply_item(id: String) -> void:
	if not Registry.items.has(id):
		return
	items_owned[id] = int(items_owned.get(id, 0)) + 1
	var it: Dictionary = Registry.items[id]
	for k in it.get("effects", {}):
		stats[k] = stats.get(k, 0.0) + float(it.effects[k])
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
	hp = minf(hp, stats.max_hp)
	queue_redraw()
	return price

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

func _draw() -> void:
	# 角色+枪整体朝向 facing（射击时更新，移动时跟随输入方向）
	var r: float = Config.PLAYER.radius
	draw_circle(Vector2.ZERO, stats.pickup_range, Color(0.494, 0.784, 0.31, 0.05))
	# 身体
	draw_circle(Vector2.ZERO, r, Color("e8b84b"))
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 40, Color("b98a2e"), 2.0, true)
	# 旋转坐标系：眼睛+枪一起朝向 facing
	draw_set_transform(Vector2.ZERO, facing, Vector2.ONE)
	# 眼睛（朝前 = +X 方向）
	draw_circle(Vector2(2.0, -5.0), 2.6, Color("2b2110"))
	draw_circle(Vector2(2.0, 5.0), 2.6, Color("2b2110"))
	# 枪管
	draw_rect(Rect2(r - 2.0, -3.0, 14.0, 6.0), Color("454b59"))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
