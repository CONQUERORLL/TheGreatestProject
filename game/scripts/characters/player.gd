extends CharacterBody2D
## 玩家控制器：八方向移动 + 武器自动攻击（移植自 Web 原型 tryFire / damagePlayer）
## 输入：Input Map move_*（WASD / 方向键 / 手柄左摇杆）

const BulletScene := preload("res://scenes/weapons/bullet.tscn")
const FlameJetScript := preload("res://scripts/fx/flame_jet.gd")
const SkillFXScript := preload("res://scripts/fx/skill_fx.gd")

var hp: float = 100.0
var stats: Dictionary = {}
var weapons: Array = []   # [{ "type": String, "cd": float }]，上限 Config.WEAPON_SLOTS
var _family_synergy_bonus: Dictionary = {}   # 已应用到 stats 的同族共鸣加成（key = stats 键）
var items_owned: Dictionary = {}   # 已购道具 id -> 数量（暂停/商店展示与出售用）
var artifacts_owned: Dictionary = {}   # 已持有法宝 id -> 1（每种限 1 件，值仅为与存档格式对齐）
var artifact_stacks: Dictionary = {}   # 叠层法宝 id -> 当前层数（断刃锋/玄武核）
var facing := 0.0
var iframes := 0.0
# ---- 角色专属特性（Character Trait）----
# 注意：变量名不能用 trait —— Godot 4.7 已把 trait 列为保留关键字，
# `var trait := ...` 会直接 Parse Error（"Expected variable name after var"）
var char_trait: Dictionary = {}      # 当前角色特性（开局从 Registry 读取，空 = 无特性）
var sigil := ""                      # 角色印记 id（元素 / 风格痕迹，空串 = 无印记）；开局算一次
var _aura_t := 0.0              # 光环/战意触发计时
var _trait_pulse := 1.0         # 光环视觉脉冲（每次触发重置为 1，随时间衰减）
var _momentum_base_kills := 0   # 本波开始时的累计击杀数（战意按"本波击杀"计算）
var _flame_jet: Node2D = null   # 枪口喷射锥（火焰喷射器的表现层，见 fx/flame_jet.gd）
# ---- 主动技能（按 F 释放，开局从 Registry 角色定义读取）----
var skill: Dictionary = {}        # 当前角色主动技能（空 = 无技能）
var skill_cd := 0.0               # 技能冷却剩余秒
var _skill_buff_t := 0.0          # 技能临时增益剩余秒
var _skill_buff_effects: Dictionary = {}   # 技能临时增益的效果（结束后撤销）

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
		# 角色特性 / 道具 / 升级共用的武器行为加成（加成语义：0 = 无加成）
		"bullet_speed_bonus": 0.0,   # 弹丸飞行速度
		"bullet_range_bonus": 0.0,   # 弹丸存活时长（射程）
		"melee_range_bonus": 0.0,    # 近战斩击半径
		"aoe_radius_bonus": 0.0,     # 爆炸 / 溅射半径
		"low_hp_dmg_bonus": 0.0,     # 残血增伤上限（按缺失生命比例发挥）
		"momentum_dmg_bonus": 0.0,   # 战意当前增伤（特性运行时写入，每波清零）
	}
	# 角色（Registry 注册表）：stats 可只覆盖部分字段（创意工坊自定义角色）
	var ch: Dictionary = Registry.get_character(GameState.character_id)
	for k in ch.get("stats", {}):
		stats[k] = ch.stats[k]
	# 角色专属特性：stats 类在开局一次性注入（与升级/道具同一套加法语义）；
	# 其余 kind（aura / thorns / momentum）不属于属性，由运行时逻辑在对应时机结算
	char_trait = ch.get("trait", {})
	skill = ch.get("skill", {})   # 主动技能（按 F 释放）
	sigil = Config.sigil_for(GameState.character_id)
	if String(char_trait.get("kind", "")) == "stats":
		for tk in char_trait.get("effects", {}):
			var tv: Variant = char_trait.effects[tk]
			if typeof(tv) == TYPE_INT or typeof(tv) == TYPE_FLOAT:
				stats[String(tk)] = float(stats.get(String(tk), 0.0)) + float(tv)
	_sanitize_stats()
	hp = stats.max_hp
	# 开局武器完全由玩家在向导中选定：角色不再绑定"初始武器"，
	# 否则玩家在第 2 步改选武器时角色设定会被覆盖，绑定本身也就失去意义
	var wt: String = GameState.loadout_weapon
	if wt == "" or not Registry.weapons.has(wt):
		wt = "pistol"
	weapons = [{ "type": wt, "cd": 0.3 }]
	_momentum_base_kills = GameState.kills
	queue_redraw()

func _physics_process(delta: float) -> void:
	if not GameState.is_running():
		return
	var c: Dictionary = Config.PLAYER
	# ---- 移动：加速度 + 指数阻尼（与原型手感一致） ----
	var input_dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if GameState.touch_move != Vector2.ZERO:
		input_dir = GameState.touch_move   # 移动端虚拟摇杆（模拟量：轻推慢走）
	elif input_dir == Vector2.ZERO and GameState.mouse_move != Vector2.ZERO:
		input_dir = GameState.mouse_move   # 桌面鼠标点触移动（模拟量：靠近目标减速）
	var max_speed: float = stats.base_speed * stats.speed_mult
	velocity += input_dir * c.accel * delta
	velocity *= exp(-9.0 * delta)
	if velocity.length() > max_speed:
		velocity = velocity.normalized() * max_speed
	var world := Vector2(Config.WORLD.w, Config.WORLD.h)
	var r: float = c.radius
	global_position = (global_position + velocity * delta).clamp(Vector2(r, r), world - Vector2(r, r))
	# 障碍物推出（Phase 5）：本项目没有走 Godot 物理（移动是直接写 global_position），
	# 障碍物用同一套手写判定把玩家挡在外面；推出后再钳一次边界防止被挤出世界
	global_position = Obstacles.resolve_circle(global_position, r) \
		.clamp(Vector2(r, r), world - Vector2(r, r))
	if input_dir != Vector2.ZERO:
		facing = input_dir.angle()
	# ---- 回复 / 无敌帧 ----
	hp = minf(stats.max_hp, hp + stats.regen * delta)
	iframes = maxf(0.0, iframes - delta)
	# ---- 角色特性（光环 / 战意） ----
	_trait_tick(delta)
	# ---- 主动技能冷却 / 临时增益计时 ----
	_skill_tick(delta)
	# ---- 武器自动攻击 ----
	for w in weapons:
		w.cd -= delta
		if w.cd <= 0.0:
			try_fire(w)

## 每波开始（main 在 wave_started 时调用）：战意归零，按本波击杀重新累积
func on_wave_start() -> void:
	_momentum_base_kills = GameState.kills
	stats.momentum_dmg_bonus = 0.0

## 角色特性运行时结算。
## 光环按 interval 节流（默认 0.6s）：逐帧施加状态会把 DoT 层数刷满、把五行反应
## 打成每帧连锁，同时让 Combat 空间查询从"每秒一次"变成"每物理帧一次"
func _trait_tick(delta: float) -> void:
	var before := _trait_pulse
	_trait_pulse = maxf(0.0, _trait_pulse - delta * 3.0)
	if before != _trait_pulse:
		queue_redraw()
	var kind := String(char_trait.get("kind", ""))
	if kind == "momentum":
		# 战意：本波击杀每满 per_kills 层 +per_stack 伤害，上限 max_bonus
		var per_kills := maxf(1.0, float(char_trait.get("per_kills", 8)))
		var stacks := float(GameState.kills - _momentum_base_kills) / per_kills
		var bonus := minf(float(char_trait.get("max_bonus", 0.5)),
			stacks * float(char_trait.get("per_stack", 0.04)))
		if not is_equal_approx(bonus, float(stats.momentum_dmg_bonus)):
			stats.momentum_dmg_bonus = bonus
			_trait_pulse = maxf(_trait_pulse, 0.5)
			queue_redraw()
		return
	if kind != "aura":
		return
	_aura_t += delta
	if _aura_t < maxf(0.2, float(char_trait.get("interval", 0.6))):
		return
	_aura_t = 0.0
	_trait_pulse = 1.0
	queue_redraw()
	_apply_aura()

## 光环半径：char_trait.radius > 0 用绝对值，否则按拾取范围 × radius_mult 推导
## （挂在拾取范围上 → 拾取道具/升级同时强化光环，构筑有额外收益）
func aura_radius() -> float:
	var r := float(char_trait.get("radius", 0.0))
	if r > 0.0:
		return r
	return float(stats.pickup_range) * float(char_trait.get("radius_mult", 1.0))

## 光环结算：对范围内敌人施加状态（可选附带直接伤害）。
## power 走玩家当前的状态伤害加成，让"堆异常"的构筑同样强化光环
func _apply_aura() -> void:
	var radius := aura_radius()
	var sid := String(char_trait.get("status", ""))
	var power := float(char_trait.get("power", 0.0)) * (1.0 + float(stats.status_dmg_mult))
	var dur_mult := float(char_trait.get("dur_mult", 1.0)) * (1.0 + float(stats.status_dur_mult))
	var dmg := float(char_trait.get("dmg", 0.0)) * float(stats.dmg_mult)
	var chance := clampf(float(char_trait.get("chance", 1.0)), 0.0, 1.0)
	for e in Combat.enemies_near(global_position, radius + Combat.MAX_ENTITY_RADIUS):
		if e.flee > 0.0:
			continue
		if global_position.distance_to(e.global_position) > radius + e.radius:
			continue
		if dmg > 0.0:
			e.take_damage(dmg, false, true)   # dot 通道：不触发常规打击感反馈
		if sid != "" and GameRng.chance(chance):
			e.apply_status(sid, int(char_trait.get("stacks", 1)),
				float(char_trait.get("duration", 0.0)), power, dur_mult)

## 特性主题色：优先 char_trait.color，其次取光环状态配色，最后回退角色色
func trait_color() -> Color:
	if char_trait.has("color"):
		return Color(String(char_trait.color))
	var sid := String(char_trait.get("status", ""))
	if sid != "" and Config.STATUS.has(sid):
		return Color(String(Config.STATUS[sid].get("color", "#e8b84b")))
	return Color(String(Registry.get_character(GameState.character_id).get("color", "#e8b84b")))

## 特性：荆棘反击（受击瞬间对周围敌人结算一次伤害）
func _trait_on_hurt() -> void:
	if String(char_trait.get("kind", "")) != "thorns":
		return
	var dmg := float(char_trait.get("dmg", 0.0)) * float(stats.dmg_mult)
	if dmg <= 0.0:
		return
	var radius := maxf(1.0, float(char_trait.get("radius", 150.0)))
	_trait_pulse = 1.0
	for e in Combat.enemies_near(global_position, radius + Combat.MAX_ENTITY_RADIUS):
		if e.flee > 0.0:
			continue
		if global_position.distance_to(e.global_position) <= radius + e.radius:
			e.take_damage(dmg, false, true)
	Burst.spawn(get_parent(), global_position, Color("ffd24a"), 10, 180.0)
	queue_redraw()


func _process(_delta: float) -> void:
	# 受击无敌帧闪烁（原型 80ms 间隔）
	modulate.a = 0.45 if (iframes > 0.0 and int(Time.get_ticks_msec() / 80.0) % 2 == 0) else 1.0

func try_fire(w: Dictionary) -> void:
	var c: Dictionary = Registry.weapons[w.type]
	w.cd = float(c.cd) / maxf(0.01, float(stats.as_mult))
	# 索敌优先选视线未被障碍物挡住的敌人（Phase 5）：障碍物会拦住弹丸，
	# 若还死盯最近的目标，玩家会被迫对着柱子倾泻全部输出
	var target := Combat.nearest_enemy_visible(global_position, 4.0)
	var ang := (target.global_position - global_position).angle() if target else facing
	facing = ang
	queue_redraw()
	# 火焰喷射器：火焰的主体是枪口喷射锥（FlameJet，不跟弹丸走），
	# 每次开火刷新它的朝向与喷射长度
	if String(c.get("fx", "")) == "flame":
		_ignite_flame_jet(c, ang)
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

## 点燃枪口喷射锥。长度按「实际射程」推算（含角色特性与道具的射程加成）——
## 于是「铳匠长管 / 加长枪管」这类道具会让火焰肉眼可见地喷得更远
func _ignite_flame_jet(c: Dictionary, ang: float) -> void:
	var wc := _weapon_runtime_cfg(c)
	var reach := float(wc.get("bspeed", 300.0)) * float(wc.get("bullet_life", 0.3)) + 26.0
	_ensure_flame_jet().ignite(ang, reach, 26.0)

## 惰性创建喷射锥并挂在自身（成为子节点后位置自动跟随玩家，无需每帧同步）
func _ensure_flame_jet() -> Node2D:
	if _flame_jet == null or not is_instance_valid(_flame_jet):
		_flame_jet = FlameJetScript.new()
		_flame_jet.z_index = -1   # 相对玩家（z_as_relative 默认开）→ 火焰压在人物下层
		add_child(_flame_jet)
	return _flame_jet

func _spawn_bullet(c: Dictionary, ang: float) -> void:
	var b = ObjectPool.acquire("bullet", BulletScene, get_parent())
	b.setup(global_position + Vector2.from_angle(ang) * 18.0, ang,
		_weapon_runtime_cfg(c), _roll_damage(c.dmg, c), _trait_tint_for(c))

## 武器配色：状态色优先（火焰长剑橙 / 毒牙匕首绿 / 霜冻法杖冰蓝），
## 没有状态的纯物理武器用象牙白刀光
func _weapon_color(wcfg: Dictionary) -> Color:
	var sid := String(wcfg.get("status", ""))
	if sid != "" and Config.STATUS.has(sid):
		return Color(String(Config.STATUS[sid].get("color", "#e9e4b0")))
	return Color(1.0, 0.914, 0.69)

## 该武器是否真的吃到「角色专属特性」的加成：吃到则返回特性主题色，否则透明。
## 弹丸 / 刀光上的强调光环就靠它 —— 让增幅「看得见」，且只对真正受益的武器生效：
##   近战：仅在 melee_range_bonus > 0 时亮（太白剑客拿太刀会亮、拿手枪不亮）
##   投射：需要弹速 / 射程加成，或「该武器有溅射 且 角色有爆炸半径加成」
## 一律发光等于没有信息量，精准匹配才能让玩家读懂自己的构筑
func _trait_tint_for(wcfg: Dictionary) -> Color:
	if char_trait.is_empty():
		return Color(0, 0, 0, 0)
	if String(wcfg.get("attack_type", "projectile")) == "melee":
		return trait_color() if float(stats.melee_range_bonus) > 0.0 else Color(0, 0, 0, 0)
	if float(stats.bullet_speed_bonus) > 0.0 or float(stats.bullet_range_bonus) > 0.0:
		return trait_color()
	if float(stats.aoe_radius_bonus) > 0.0 and float(wcfg.get("splash", 0.0)) > 0.0:
		return trait_color()
	return Color(0, 0, 0, 0)

## 武器运行参数：叠加角色的弹道类特性（弹速 / 射程 / 爆炸半径）。
## 无加成时直接复用原字典 —— 高攻速武器每秒开火十余次，没必要每次都 duplicate
func _weapon_runtime_cfg(c: Dictionary) -> Dictionary:
	var sb := float(stats.bullet_speed_bonus)
	var rb := float(stats.bullet_range_bonus)
	var ab := float(stats.aoe_radius_bonus)
	if sb <= 0.0 and rb <= 0.0 and ab <= 0.0:
		return c
	var wc := c.duplicate()
	if sb > 0.0:
		wc["bspeed"] = float(c.get("bspeed", 0.0)) * (1.0 + sb)
	if rb > 0.0:
		wc["bullet_life"] = float(c.get("bullet_life", 1.1)) * (1.0 + rb)
	if ab > 0.0 and c.has("splash"):
		wc["splash"] = float(c.get("splash", 0.0)) * (1.0 + ab)
	return wc

func _melee_slash(c: Dictionary, ang: float) -> void:
	# 斩击范围受角色的近战范围特性加成（视觉与判定用同一个 reach）
	var reach := float(c["range"]) * (1.0 + float(stats.melee_range_bonus))
	var s := Slash.new()
	# 外观族 / 特性强调色 / 状态配色一起给到刀光：太刀是月牙、长鞭会甩、重锤推冲击波
	s.setup(global_position, ang, reach, c.swing_arc,
		String(c.get("fx", "")), _trait_tint_for(c), _weapon_color(c), sigil)
	get_parent().add_child(s)
	# 一次性命中扇形范围内敌人（原型为 0.13s 持续检测，效果等价）
	for e in Combat.enemies_near(global_position, reach + Combat.MAX_ENTITY_RADIUS):
		if e.flee > 0.0:
			continue
		var d := global_position.distance_to(e.global_position)
		if d < reach + e.radius:
			var da := wrapf((e.global_position - global_position).angle() - ang, -PI, PI)
			if absf(da) < c.swing_arc / 2.0:
				var roll := _roll_damage(c.dmg, c)
				e.take_damage(roll.dmg, roll.crit)
				e.apply_hit_roll(roll)

func _roll_damage(base: float, wcfg: Dictionary = {}) -> Dictionary:
	# 伤害 = 基础 × 伤害加成 × 暴击倍率（对应原型 rollDamage）
	# 同时打包状态载荷：武器自带 status + 道具 on_hit_* 概率，命中后由 Enemy.apply_hit_roll 结算
	var dmg: float = base * stats.dmg_mult
	# 特性增伤：残血增伤按缺失生命比例线性发挥（满血 0%、濒死 100%）；
	# 战意由 _trait_tick 逐波累积后写入 stats，这里只做读取
	var lhb := float(stats.low_hp_dmg_bonus)
	if lhb > 0.0:
		dmg *= 1.0 + lhb * (1.0 - clampf(hp / maxf(1.0, float(stats.max_hp)), 0.0, 1.0))
	dmg *= 1.0 + float(stats.momentum_dmg_bonus)
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
		"fx": String(wcfg.get("fx", "")),   # 外观族：弹丸命中后的爆炸也按武器区分形态
		"sigil": sigil,                     # 角色印记：弹丸 / 刀光 / 爆炸按「谁在用」叠加痕迹
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
func apply_upgrade(id: String) -> void:
	var u: Dictionary = Registry.upgrades.get(id, {})
	if u.is_empty():
		return
	CodexData.unlock("upgrade", id)
	apply_effects(u.get("effects", {}))

## 应用一组属性效果（数据驱动：键 = stats 键）
## 特例：heal_flat = 最大生命 + 立即回复同值；heal_pct = 立即回复最大生命百分比
## 升级 / 事件卡奖励共用此入口，新增效果只需扩字典，不必改调用方
func apply_effects(effects: Dictionary) -> void:
	if effects.is_empty():
		return
	for k in effects:
		var raw: Variant = effects[k]
		if typeof(raw) != TYPE_INT and typeof(raw) != TYPE_FLOAT:
			continue
		var v := float(raw)
		match String(k):
			"heal_flat":
				stats.max_hp += v
				hp = minf(stats.max_hp, hp + v)
			"heal_pct":
				hp = minf(stats.max_hp, hp + stats.max_hp * v)
			_:
				stats[k] = float(stats.get(k, 0.0)) + v
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

# ------------------------------------------------------------
# 法宝（Phase 3）：触发式特效，每种限 1 件，重复获得转材料补偿
# ------------------------------------------------------------

## 获得法宝。返回 true = 新获得；false = 重复（已发放材料补偿）或 id 非法
## 掉落物/商店/BOSS 入账三条渠道统一走这里，保证补偿与图鉴解锁不会漏
func apply_artifact(id: String) -> bool:
	if not Registry.artifacts.has(id):
		return false
	CodexData.unlock("artifact", id)
	if artifacts_owned.has(id):
		GameState.add_materials(Config.ARTIFACT_DUP_MATERIALS)
		FloatingText.spawn(get_parent(), global_position + Vector2(0.0, -28.0),
			"法宝已持有 · +%d ◆" % Config.ARTIFACT_DUP_MATERIALS, Color("ffd24a"))
		return false
	artifacts_owned[id] = 1
	EventBus.artifact_acquired.emit(id)
	return true

## 出售法宝：返还 50% 购入价，并先清零它的叠层属性（否则暴击/护甲会残留）
func sell_artifact(id: String) -> int:
	if not artifacts_owned.has(id) or not Registry.artifacts.has(id):
		return 0
	var price := roundi(float(int(Registry.artifacts[id].get("price", 110))) * 0.5)
	_set_artifact_stacks(id, 0)
	artifacts_owned.erase(id)
	return price

## 已持有法宝的配置列表（按获得顺序），供触发执行器与 UI 共用
func owned_artifacts() -> Array:
	var out: Array = []
	for id in artifacts_owned:
		var a: Dictionary = Registry.get_artifact(String(id))
		if not a.is_empty():
			out.append(a)
	return out

## 把叠层法宝的层数设为 target（自动受 stack_max 上限约束）
## 层数差量增量结算到 stats，与 apply_item/sell_item 同一套叠加方式
func _set_artifact_stacks(id: String, target: int) -> void:
	var effect: Dictionary = Registry.get_artifact(id).get("effect", {})
	if not effect.has("stat"):
		return
	var stat_id := String(effect.stat)
	var next := clampi(target, 0, int(effect.get("stack_max", 1)))
	var cur := int(artifact_stacks.get(id, 0))
	if next == cur:
		return
	var per := float(effect.get("per_stack", 0.0))
	stats[stat_id] = float(stats.get(stat_id, 0.0)) + per * float(next - cur)
	if next <= 0:
		artifact_stacks.erase(id)
	else:
		artifact_stacks[id] = next
	_sanitize_stats()

## 给叠层法宝加 n 层（未持有则忽略）
func add_artifact_stacks(id: String, n: int) -> void:
	if artifacts_owned.has(id):
		_set_artifact_stacks(id, int(artifact_stacks.get(id, 0)) + n)

## 重置叠层：scope = "wave"（每波开始，断刃锋）/ "run"（局终，玄武核）
func reset_artifact_stacks(scope: String) -> void:
	# .keys() 返回副本，遍历中删改 artifact_stacks 安全
	for id in artifact_stacks.keys():
		var effect: Dictionary = Registry.get_artifact(String(id)).get("effect", {})
		if String(effect.get("stack_reset", "wave")) == scope:
			_set_artifact_stacks(String(id), 0)

## 回复生命（法宝/事件共用），返回实际回复量
func heal(amount: float) -> float:
	if amount <= 0.0 or hp <= 0.0:
		return 0.0
	var before := hp
	hp = minf(float(stats.max_hp), hp + amount)
	var gained := hp - before
	if gained > 0.5:
		FloatingText.spawn(get_parent(), global_position + Vector2(0.0, -24.0),
			"+" + str(roundi(gained)), Color("7ec850"))
	return gained

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
	# 特性 / 道具共用的武器行为加成（负值无意义，统一抬到 0）
	stats.bullet_speed_bonus = maxf(0.0, float(stats.bullet_speed_bonus))
	stats.bullet_range_bonus = maxf(0.0, float(stats.bullet_range_bonus))
	stats.melee_range_bonus = maxf(0.0, float(stats.melee_range_bonus))
	stats.aoe_radius_bonus = maxf(0.0, float(stats.aoe_radius_bonus))
	stats.low_hp_dmg_bonus = clampf(float(stats.low_hp_dmg_bonus), 0.0, 5.0)
	stats.momentum_dmg_bonus = clampf(float(stats.momentum_dmg_bonus), 0.0, 5.0)
	for sid in Config.STATUS:
		var key := "on_hit_" + String(sid)
		stats[key] = clampf(float(stats.get(key, 0.0)), 0.0, 1.0)

func take_damage(raw: float) -> void:
	if iframes > 0.0:
		return
	if GameRng.chance(stats.dodge):
		FloatingText.spawn(get_parent(), global_position + Vector2(0.0, -22.0), "闪避", Color("9ad0ff"))
		return
	# 岩肤符：受击【前】同步查询法宝的护甲加成与低血减伤
	# （player_damaged 信号在本次结算之后才发，在那里改已经太晚）
	var armor := float(stats.armor) + ArtifactSystem.armor_bonus(self)
	var dmg: float = raw * (1.0 - armor / (armor + 8.0))
	dmg *= ArtifactSystem.incoming_damage_mult(self)
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
## 只自动进化「单分支」武器；「多分支」武器由 main 弹进化选择 UI 让玩家挑方向
## （见 pending_evolve_choices / evolve_weapon_to），返回进化公告文本列表（无进化返回空）
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
		if need > 0 and int(counts[wtype]) >= need and _evolve_branches(cfg).size() == 1:
			to_process.append(wtype)
	for wtype in to_process:
		var cfg: Dictionary = Registry.weapons[wtype]
		var need := int(cfg.evolve_need)
		var target := _pick_evolve_target(cfg)
		if target == "":
			continue
		# 移除 need 把同名武器，追加 1 把进化形态
		var removed := 0
		var new_weapons: Array = []
		for w in weapons:
			if w.type == wtype and removed < need:
				removed += 1
			else:
				new_weapons.append(w)
		weapons = new_weapons
		weapons.append({ "type": target, "cd": 0.1 })
		var ex_cfg: Dictionary = Registry.weapons[target]
		results.append("%s ×%d → %s" % [cfg.name, need, ex_cfg.name])
	refresh_family_synergy()
	return results

## 进化分支列表：优先 evolve_branches（多分支），否则回退单 evolve_to
func _evolve_branches(cfg: Dictionary) -> Array:
	var br: Array = cfg.get("evolve_branches", [])
	if not br.is_empty():
		return br
	if Registry.weapons.has(String(cfg.get("evolve_to", ""))):
		return [String(cfg.evolve_to)]
	return []

## 选择进化目标：优先进化到「尚未持有」的分支（按 branches 数据顺序），全部持有则回退第一个
func _pick_evolve_target(cfg: Dictionary) -> String:
	var branches: Array = _evolve_branches(cfg)
	if branches.is_empty():
		return ""
	var owned := {}
	for w in weapons:
		owned[w.type] = true
	for b in branches:
		if Registry.weapons.has(String(b)) and not owned.has(String(b)):
			return String(b)
	return String(branches[0])

## 待选择的进化选项：返回 [{weapon, need, branches:[id...]}]（仅多分支达标的武器，供进化选择 UI）
func pending_evolve_choices() -> Array:
	var counts := {}
	for w in weapons:
		counts[w.type] = counts.get(w.type, 0) + 1
	var choices: Array = []
	for wtype in counts:
		var cfg: Dictionary = Registry.weapons.get(wtype, {})
		if cfg.is_empty():
			continue
		var need := int(cfg.get("evolve_need", 0))
		if need <= 0 or int(counts[wtype]) < need:
			continue
		var branches: Array = _evolve_branches(cfg)
		if branches.size() > 1:
			choices.append({ "weapon": wtype, "need": need, "branches": branches })
	return choices

## 指定进化：把 need 把 wtype 合成 1 把 target（进化选择 UI 选定方向后调用）。
## 成功返回公告文本，数量不足或目标非法返回空串
func evolve_weapon_to(wtype: String, target: String) -> String:
	var cfg: Dictionary = Registry.weapons.get(wtype, {})
	if cfg.is_empty() or not Registry.weapons.has(target):
		return ""
	var need := int(cfg.get("evolve_need", 0))
	if need <= 0:
		return ""
	var removed := 0
	var new_weapons: Array = []
	for w in weapons:
		if w.type == wtype and removed < need:
			removed += 1
		else:
			new_weapons.append(w)
	if removed < need:
		return ""   # 数量不足（理论上不会，调用前已达标）
	weapons = new_weapons
	weapons.append({ "type": target, "cd": 0.1 })
	refresh_family_synergy()
	return "%s ×%d → %s" % [cfg.name, need, Registry.weapons[target].name]

## 进化预览：返回 [{type, name, have, need}]（商店/HUD 提示用）
func evolve_progress() -> Array:
	var counts := {}
	for w in weapons:
		counts[w.type] = counts.get(w.type, 0) + 1
	var progress: Array = []
	for wtype in counts:
		var cfg: Dictionary = Registry.weapons.get(wtype, {})
		var need := int(cfg.get("evolve_need", 0))
		if need > 0 and int(counts[wtype]) < need and not _evolve_branches(cfg).is_empty():
			progress.append({ "type": wtype, "name": cfg.name,
				"have": int(counts[wtype]), "need": need })
	return progress

## 下一个进化目标名（多分支时优先「尚未持有」的方向），供商店/图鉴提示；无进化返回空串
func next_evolve_name(wtype: String) -> String:
	var cfg: Dictionary = Registry.weapons.get(wtype, {})
	if cfg.is_empty():
		return ""
	var branches: Array = _evolve_branches(cfg)
	if branches.is_empty():
		return ""
	var owned := {}
	for w in weapons:
		owned[w.type] = true
	for b in branches:
		if Registry.weapons.has(String(b)) and not owned.has(String(b)):
			return String(Registry.weapons[String(b)].get("name", String(b)))
	return String(Registry.weapons[String(branches[0])].get("name", String(branches[0])))

## 同族武器共鸣：持有同 family 武器 ≥2 把时，每多一把叠加一次加成（Config.WEAPON_FAMILY_SYNERGY）。
## 武器列表变化（购买/出售/进化）后调用 refresh_family_synergy()；先撤销旧加成再按当前阵容重新应用，
## 保证 stats 里的共鸣永远只反映「当前」武器，不会因反复调用而叠加泄漏。
## 读档场景特殊处理见 load_family_synergy_snapshot()。
func refresh_family_synergy() -> void:
	for k in _family_synergy_bonus:
		stats[k] = stats.get(k, 0.0) - float(_family_synergy_bonus[k])
	_family_synergy_bonus = _compute_family_synergy()
	for k in _family_synergy_bonus:
		stats[k] = stats.get(k, 0.0) + float(_family_synergy_bonus[k])
	_sanitize_stats()
	queue_redraw()

## 计算当前武器阵容的同族共鸣加成（纯计算，不改 stats）
func _compute_family_synergy() -> Dictionary:
	var fam_count := {}
	for w in weapons:
		var wcfg: Dictionary = Registry.weapons.get(w.type, {})
		var fam := String(wcfg.get("family", ""))
		if fam != "":
			fam_count[fam] = int(fam_count.get(fam, 0)) + 1
	var bonus := {}
	for fam in fam_count:
		var layers: int = int(fam_count[fam]) - 1
		if layers <= 0:
			continue
		var cfg: Dictionary = Config.WEAPON_FAMILY_SYNERGY.get(fam, {})
		for k in cfg:
			bonus[k] = float(bonus.get(k, 0.0)) + float(cfg[k]) * float(layers)
	return bonus

## 读档后调用：存档的 stats 已包含存档时刻的共鸣（无需重新应用），
## 这里只记录当前共鸣量，保证后续 refresh 撤销时不会重复扣减
func load_family_synergy_snapshot() -> void:
	_family_synergy_bonus = _compute_family_synergy()

# ------------------------------------------------------------
# 主动技能（按 F 释放）：每个角色一个专属技能，冷却 + 临时增益
# ------------------------------------------------------------

## 技能冷却 / 临时增益计时（_physics_process 每帧调用）
func _skill_tick(delta: float) -> void:
	if skill_cd > 0.0:
		skill_cd = maxf(0.0, skill_cd - delta)
	if _skill_buff_t > 0.0:
		_skill_buff_t -= delta
		if _skill_buff_t <= 0.0:
			_clear_skill_buff()

## 释放主动技能。返回 true = 成功释放（进入冷却）；false = 冷却中 / 无技能 / 非战斗阶段
func cast_skill() -> bool:
	if skill.is_empty() or skill_cd > 0.0 or not GameState.is_running():
		return false
	var ok := false
	match String(skill.get("kind", "")):
		"nova_status": ok = _skill_nova_status()
		"self_heal": ok = _skill_self_heal()
		"buff": ok = _skill_buff()
		"burst_damage": ok = _skill_burst_damage()
		"grant_materials": ok = _skill_grant_materials()
	if ok:
		skill_cd = float(skill.get("cd", 12.0))
		_trait_pulse = 1.0
		_play_skill_vfx()
		queue_redraw()
		EventBus.banner_requested.emit("%s %s" % [String(skill.get("ico", "✨")),
			String(skill.get("name", "技能"))], String(skill.get("desc", "")), 2.0)
	return ok

## 技能：范围状态（焚天烈焰 / 毒雾爆发 / 寒潮）
func _skill_nova_status() -> bool:
	var radius := float(skill.get("radius", 220.0))
	var sid := String(skill.get("status", ""))
	var power := float(skill.get("power", 0.0)) * (1.0 + float(stats.status_dmg_mult))
	var dur_mult := 1.0 + float(stats.status_dur_mult)
	var dmg := float(skill.get("dmg", 0.0)) * float(stats.dmg_mult)
	var hit := 0
	for e in Combat.enemies_near(global_position, radius + Combat.MAX_ENTITY_RADIUS):
		if e.flee > 0.0:
			continue
		if global_position.distance_to(e.global_position) > radius + e.radius:
			continue
		hit += 1
		if dmg > 0.0:
			e.take_damage(dmg, false, true)
		if sid != "":
			e.apply_status(sid, int(skill.get("stacks", 1)), 0.0, power, dur_mult)
	return hit > 0

## 技能：回复 + 眩晕周围敌人（血宴）
func _skill_self_heal() -> bool:
	var heal: float = float(stats.max_hp) * float(skill.get("heal_pct", 0.35))
	hp = minf(float(stats.max_hp), hp + heal)
	var stun_radius := float(skill.get("stun_radius", 0.0))
	if stun_radius > 0.0:
		for e in Combat.enemies_near(global_position, stun_radius + Combat.MAX_ENTITY_RADIUS):
			if e.flee <= 0.0 and global_position.distance_to(e.global_position) <= stun_radius + e.radius:
				e.apply_status("stun", 1, float(skill.get("stun_dur", 1.0)), 0.0, 1.0)
	return true

## 技能：临时增益（丰收鼓舞 / 铁壁 / 弹幕风暴 / 疾风步 / 战吼）
func _skill_buff() -> bool:
	_clear_skill_buff()
	var effects: Dictionary = skill.get("effects", {})
	_skill_buff_effects = {}
	for k in effects:
		var v := float(effects[k])
		_skill_buff_effects[k] = v
		stats[k] = stats.get(k, 0.0) + v
	# 战吼：立即注入战意层数（减少基础击杀数，让战意计算多出对应层）
	var mstacks := int(skill.get("momentum_stacks", 0))
	if mstacks > 0:
		var per_kills := maxf(1.0, float(char_trait.get("per_kills", 8)))
		_momentum_base_kills -= int(mstacks * per_kills)
	_skill_buff_t = float(skill.get("duration", 6.0))
	_sanitize_stats()
	queue_redraw()
	return true

func _clear_skill_buff() -> void:
	for k in _skill_buff_effects:
		stats[k] = stats.get(k, 0.0) - float(_skill_buff_effects[k])
	_skill_buff_effects = {}
	_sanitize_stats()
	queue_redraw()

## 技能：范围爆发伤害（血怒斩 / 剑气纵横）
func _skill_burst_damage() -> bool:
	var radius := float(skill.get("radius", 220.0))
	var dmg := float(skill.get("mult", 3.0)) * 20.0 * float(stats.dmg_mult)
	# 血怒斩：生命越低伤害越高
	if String(skill.get("name", "")) == "血怒斩" and stats.max_hp > 0.0:
		dmg *= 1.0 + (1.0 - hp / stats.max_hp)
	var hit := 0
	for e in Combat.enemies_near(global_position, radius + Combat.MAX_ENTITY_RADIUS):
		if e.flee > 0.0:
			continue
		if global_position.distance_to(e.global_position) > radius + e.radius:
			continue
		hit += 1
		e.take_damage(dmg, false, false)
	return hit > 0

## 技能：获得材料（丰收）
func _skill_grant_materials() -> bool:
	GameState.add_materials(int(skill.get("materials", 60)))
	return true

## 技能视觉主题色：状态类取状态配色，伤害/增益类取角色主题色
func _skill_color() -> Color:
	var sid := String(skill.get("status", ""))
	if sid != "" and Config.STATUS.has(sid):
		return Color(String(Config.STATUS[sid].get("color", "#e8b84b")))
	return Color(String(Registry.get_character(GameState.character_id).get("color", "#e8b84b")))

## 技能释放的视觉 / 震动 / 音效：冲击波环 + 粒子迸发 + 震屏 + 专属音效，
## 不同 kind 强度与配色不同，让「技能放出去了」肉眼可辨
func _play_skill_vfx() -> void:
	var col := _skill_color()
	var kind := String(skill.get("kind", ""))
	var parent := get_parent()
	match kind:
		"nova_status", "burst_damage":
			# 范围伤害/状态：满强度冲击波 + 双层粒子 + 强震屏
			var rad := float(skill.get("radius", 220.0))
			SkillFXScript.spawn(parent, global_position, col, rad, 1.0)
			Burst.spawn(parent, global_position, col, 26, 300.0)
			Burst.spawn(parent, global_position, col.lightened(0.45), 14, 150.0)
			EventBus.screen_shake.emit(6.0)
		"self_heal":
			# 血宴：血红冲击波（吸血）+ 绿色粒子（回复）点缀
			var heal_col := Color("e05a4f")
			var srad := float(skill.get("stun_radius", 200.0))
			SkillFXScript.spawn(parent, global_position, heal_col, maxf(srad, 160.0), 0.85)
			Burst.spawn(parent, global_position, heal_col, 16, 200.0)
			Burst.spawn(parent, global_position, Color("5ef27e"), 10, 140.0)
			EventBus.screen_shake.emit(3.0)
		"buff":
			# 增益：柔和冲击波（后续光环由 _draw_skill_buff_aura 持续表现）
			SkillFXScript.spawn(parent, global_position, col, 170.0, 0.8)
			Burst.spawn(parent, global_position, col, 14, 180.0)
			EventBus.screen_shake.emit(2.5)
		"grant_materials":
			# 丰收：金色粒子喷涌
			var gold := Color("ffd24a")
			SkillFXScript.spawn(parent, global_position, gold, 150.0, 0.7)
			Burst.spawn(parent, global_position, gold, 20, 240.0)
			EventBus.screen_shake.emit(1.5)
	Sfx.play("skill_cast")
	Haptics.rumble(0.45, 0.12, 0.3)

func _draw() -> void:
	# 角色+枪整体朝向 facing（射击时更新，移动时跟随输入方向）
	var r: float = Config.PLAYER.radius
	_draw_trait_aura()
	_draw_skill_buff_aura()
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

## 技能增益持续光环：buff 类技能持续期间（_skill_buff_t > 0）随玩家移动的呼吸光环，
## 让「增益还在生效」肉眼可辨，透明度随剩余时间衰减
func _draw_skill_buff_aura() -> void:
	if _skill_buff_t <= 0.0:
		return
	var dur := maxf(0.001, float(skill.get("duration", 6.0)))
	var remain := clampf(_skill_buff_t / dur, 0.0, 1.0)
	var pulse := 0.55 + 0.45 * sin(Time.get_ticks_msec() * 0.006)
	var sc := _skill_color()
	var rr := float(Config.PLAYER.radius) + 9.0
	draw_circle(Vector2.ZERO, rr + 4.0, Color(sc.r, sc.g, sc.b, 0.10 * pulse * remain))
	draw_arc(Vector2.ZERO, rr, 0.0, TAU, 48, Color(sc.r, sc.g, sc.b, 0.5 * remain), 3.0, true)

## 特性视觉：光环范围圈 + 触发脉冲，让「范围多大 / 何时生效」肉眼可辨
func _draw_trait_aura() -> void:
	var kind := String(char_trait.get("kind", ""))
	if kind == "aura":
		var ar := aura_radius()
		var tc := trait_color()
		draw_circle(Vector2.ZERO, ar, Color(tc.r, tc.g, tc.b, 0.040 + 0.05 * _trait_pulse))
		draw_arc(Vector2.ZERO, ar, 0.0, TAU, 64,
			Color(tc.r, tc.g, tc.b, 0.14 + 0.30 * _trait_pulse), 2.0, true)
	elif kind == "thorns" and _trait_pulse > 0.0:
		draw_arc(Vector2.ZERO, maxf(1.0, float(char_trait.get("radius", 150.0))),
			0.0, TAU, 64, Color(1.0, 0.82, 0.29, 0.32 * _trait_pulse), 3.0, true)
	elif kind == "momentum" and _trait_pulse > 0.0:
		draw_arc(Vector2.ZERO, Config.PLAYER.radius + 7.0, 0.0, TAU, 32,
			Color(1.0, 0.51, 0.31, 0.5 * _trait_pulse), 2.5, true)
