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
var _vis_state := -1   # 0 常态 / 1 受击闪白 / 2 血条显示；变化才重绘
var _spiral_angle := 0.0   # 螺旋织网者：当前螺旋弹幕相位
var _summon_cd := 0.0      # 腐土孵化者：召唤倒计时
var _reborn := false       # 焚天凤凰：涅槃重生标记（第一次死亡回血复活，仅一次）
var spawn_wave := 1        # 生成时波次（召唤物继承）
var elite := false         # 精英实例标志（由 wave_manager.spawn 注入；掉法宝只认这个）
var statuses: Dictionary = {}   # 状态 id -> { stacks, remaining, tick_t, power }
var status_resist := 0.0        # 状态时长减免（BOSS 0.55）
var reaction_debuffs: Array = []   # 五行反应 debuff：{dmg_taken_mult, dot_mult, remaining}
var _reaction_active: Dictionary = {}   # 本敌正在执行的反应 id（禁止自我递归）
var _status_sig := 0            # 状态签名（层数/集合变化才重绘）
var _status_flash_t := 0.0      # 状态触发彩色扩散环剩余时间
var _status_flash_color := Color.WHITE

## 敌间分离查询余量：普通敌最大组合 30+30=60；大体型（BOSS 56+卫兵 30=86）用 90，
## 含 BOSS 的配对由 BOSS 自身的大余量查询覆盖，普通敌海保持小余量省开销
const SEPARATION_PAD_NORMAL := 60.0
const SEPARATION_PAD_LARGE := 90.0

## 五行反应默认参数（Config.REACTIONS 未显式给出时的兜底值）
const REACTION_AOE_RADIUS := 100.0
const REACTION_DEBUFF_DURATION := 3.0
const REACTION_CONVERT_DURATION := 0.5

func setup(type_name: String, wave: int = 1) -> void:
	type = type_name
	spawn_wave = wave
	cfg = Registry.enemies[type_name]
	var diff: Dictionary = Registry.get_difficulty(GameState.difficulty_id)
	var boss_flag := type_name.begins_with("boss") or bool(cfg.get("is_boss", false)) \
			or String(cfg.get("ai", "")) == "boss"
	var hp_s := 1.0
	var dmg_s := 1.0
	if boss_flag:
		# BOSS 不吃常规波次缩放；无尽模式每深 1 波血量 +30%（再叠难度倍率），
		# 防止后期构筑对 BOSS 秒杀
		if GameState.endless and wave > 10:
			hp_s = 1.0 + 0.30 * float(wave - 10)
		dmg_s = 1.0 + 0.18 * float(wave - 1)
	else:
		hp_s = Config.wave_hp_scale(wave)
		dmg_s = Config.wave_dmg_scale(wave)
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
	status_resist = clampf(float(cfg.get("status_resist", 0.0)), 0.0, 0.95)
	CodexData.unlock("enemy", type_name)   # 图鉴：遭遇即解锁

## 是否 BOSS（内置 boss / boss_* 前缀 / 自定义 is_boss=true / ai="boss"）
func is_boss() -> bool:
	# boss / boss_spiral / boss_phoenix 等所有 boss_* 前缀都是 BOSS。
	# 之前只判 type == "boss"，导致 Phase 2 的 5 个新 BOSS 从未被识别 ——
	# 它们一直是「不会发弹幕、不触发胜利结算」的高血肉桩
	return type.begins_with("boss") or bool(cfg.get("is_boss", false)) \
		or String(cfg.get("ai", "")) == "boss"

## AI 行为类型（chaser 追击 / runner 抖动冲刺 / shooter 风筝射击 / boss 环形弹幕）
func ai_type() -> String:
	return String(cfg.get("ai", "chaser"))

## 波末退场（波次管理器在收波时调用）
func start_flee() -> void:
	flee = 0.55

# ------------------------------------------------------------
# 状态效果（异常状态）：容器 + 施加/结算 API
# ------------------------------------------------------------

func has_status(id: String) -> bool:
	return statuses.has(id)

## 施加状态：层数叠加、时长刷新、DoT 伤害取较大值；status_resist 只减免时长
func apply_status(id: String, stacks: int = 1, duration_override: float = 0.0,
		power: float = 0.0, dur_mult: float = 1.0) -> void:
	var cfg: Dictionary = Config.status_cfg(id)
	if cfg.is_empty() or hp <= 0.0 or flee > 0.0:
		return
	var add_stacks := maxi(1, stacks)
	var dur := duration_override if duration_override > 0.0 else float(cfg.duration)
	dur *= maxf(0.0, dur_mult) * (1.0 - status_resist)
	if dur <= 0.0:
		return
	var tick := float(cfg.get("tick", 0.0))
	var is_new := not statuses.has(id)
	if statuses.has(id):
		var st: Dictionary = statuses[id]
		st.stacks = mini(int(cfg.stack_max), int(st.stacks) + add_stacks)
		st.remaining = maxf(float(st.remaining), dur)
		st.power = maxf(float(st.power), power)
		if tick > 0.0:
			st.tick_t = minf(float(st.tick_t), tick)
	else:
		statuses[id] = {
			"stacks": mini(int(cfg.stack_max), add_stacks),
			"remaining": dur, "tick_t": tick, "power": power,
		}
	queue_redraw()
	if is_new:
		_status_trigger_feedback(id, cfg, add_stacks)
	# 五行反应检查：新状态施加后检查是否触发相生/相克
	check_reactions()

## 状态首次触发反馈：状态色粒子 + 飘字 + 扩散环 + EventBus 事件（音效由 Sfx 订阅节流播放）
func _status_trigger_feedback(id: String, cfg: Dictionary, stacks: int) -> void:
	var col := Color(String(cfg.get("color", "#ffffff")))
	Burst.spawn(get_parent(), global_position, col, 8, 150.0)
	FloatingText.spawn(get_parent(), global_position + Vector2(0.0, -radius - 18.0),
		"%s%s" % [String(cfg.get("ico", "")), String(cfg.get("name", id))], col, 12)
	_status_flash_t = 0.35
	_status_flash_color = col
	EventBus.status_applied.emit(id, stacks, global_position)

## 结算一次命中携带的状态载荷（由 player._roll_damage 打包，子弹/近战/爆炸共用）
func apply_hit_roll(roll: Dictionary) -> void:
	if roll.is_empty() or hp <= 0.0 or flee > 0.0:
		return
	var dur_mult := float(roll.get("dur_mult", 1.0))
	var power := float(roll.get("status_power", 0.0))
	var sid := String(roll.get("status", ""))
	if sid != "" and GameRng.chance(float(roll.get("status_chance", 0.0))):
		apply_status(sid, int(roll.get("status_stacks", 1)),
			float(roll.get("status_dur", 0.0)), power, dur_mult)
	var on_hit: Variant = roll.get("on_hit", {})
	if typeof(on_hit) != TYPE_DICTIONARY:
		return
	for id in on_hit:
		if GameRng.chance(float(on_hit[id])):
			apply_status(String(id), 1, 0.0, power, dur_mult)

## 状态减速/定身：取所有状态中最低移速倍率
func _status_speed_mult() -> float:
	var mult := 1.0
	for id in statuses:
		mult = minf(mult, float(Config.status_cfg(id).get("speed_mult", 1.0)))
	return mult

## 状态易伤：冰冻目标受到额外伤害
func _damage_taken_mult() -> float:
	var mult := 1.0
	for id in statuses:
		mult *= float(Config.status_cfg(id).get("dmg_taken_mult", 1.0))
	return mult * _reaction_dmg_taken_mult()

func _status_signature() -> int:
	var sig := 0
	for id in statuses:
		sig = (sig * 31 + hash(String(id)) + int(statuses[id].stacks)) & 0x7FFFFFFF
	return sig

## 每帧推进状态时长与 DoT 跳伤；到期清除
func _tick_statuses(delta: float) -> void:
	_tick_reaction_debuffs(delta)
	if statuses.is_empty():
		return
	var expired: Array = []
	for id in statuses:
		var st: Dictionary = statuses[id]
		st.remaining = float(st.remaining) - delta
		if float(st.remaining) <= 0.0:
			expired.append(id)
			continue
		var cfg: Dictionary = Config.status_cfg(id)
		var tick := float(cfg.get("tick", 0.0))
		if tick <= 0.0:
			continue
		st.tick_t = float(st.tick_t) - delta
		if float(st.tick_t) <= 0.0:
			st.tick_t = tick
			_apply_dot(String(id), cfg, st)
	for id in expired:
		statuses.erase(id)

## DoT 跳伤：优先按最大生命百分比（中毒），否则按施加时伤害 × dot_scale × 层数
func _apply_dot(id: String, cfg: Dictionary, st: Dictionary) -> void:
	var stacks := int(st.stacks)
	var tick_dmg := 0.0
	var pct := float(cfg.get("dot_max_hp_pct", 0.0))
	if pct > 0.0:
		tick_dmg = max_hp * pct * float(stacks)
	else:
		tick_dmg = float(st.power) * float(cfg.get("dot_scale", 0.0)) * float(stacks)
	tick_dmg *= _reaction_dot_mult()
	if tick_dmg <= 0.0:
		return
	FloatingText.spawn(get_parent(), global_position + Vector2(
		GameRng.range_f(-8.0, 8.0), -radius - 6.0),
		str(maxi(1, roundi(tick_dmg))), Color(cfg.color), 11)
	take_damage(tick_dmg, false, true)

## 中毒传染（瘟疫之心）：死亡时把中毒扩散给附近敌人
func _spread_poison() -> void:
	if not statuses.has("poison"):
		return
	var st: Dictionary = statuses.poison
	var stacks := maxi(1, int(st.stacks) / 2)
	var dur := maxf(0.5, float(st.remaining) * 0.5)
	var power := float(st.power) * 0.5
	for other in Combat.enemies_near(global_position, 110.0 + Combat.MAX_ENTITY_RADIUS):
		if other == self or other.flee > 0.0 or other.is_queued_for_deletion():
			continue
		if global_position.distance_to(other.global_position) <= 110.0 + other.radius:
			other.apply_status("poison", stacks, dur, power, 1.0)

# ------------------------------------------------------------
# 五行反应系统：相生（增强）+ 相克（爆发）
# 入口：apply_status() → check_reactions()；反应表见 Config.REACTIONS
# 相生 generate 不消耗层数；相克 overcome 消耗层数并爆发
# ------------------------------------------------------------

## 连锁深度上限：spread / AOE 会在其他敌人身上再次触发反应，限深防雪崩
static var _reaction_depth := 0
const MAX_REACTION_DEPTH := 3

## 检查五行反应：遍历身上所有状态，查找相生/相克组合
func check_reactions() -> void:
	if statuses.size() < 2 or hp <= 0.0 or flee > 0.0:
		return
	var status_list := statuses.keys()
	for i in range(status_list.size()):
		for j in range(i + 1, status_list.size()):
			var reaction := Registry.find_reaction(String(status_list[i]), String(status_list[j]))
			# 跳过正在执行的反应：效果里再次上状态不得把自己套娃
			# （金生水 convert_dmg 会再上冰冻，bleed+freeze 否则递归到深度上限）
			if reaction.is_empty() \
					or _reaction_active.has(String(reaction.get("id", ""))):
				continue
			trigger_reaction(reaction)
			return  # 每次只触发一个反应（避免同帧连锁爆炸）

## 触发五行反应：执行效果 + 解锁图鉴 + 发出特效信号
func trigger_reaction(reaction: Dictionary) -> void:
	if reaction.is_empty() or hp <= 0.0 or flee > 0.0 \
			or _reaction_depth >= MAX_REACTION_DEPTH:
		return
	var reaction_id := String(reaction.get("id", ""))
	# 法宝改写（熔金炉/孢心/落魂钟/蛟皇目）必须在执行效果【之前】应用：
	# element_reaction 信号在本函数末尾才发，那时破甲/阈值/扩散半径已经结算完了
	var effect: Dictionary = ArtifactSystem.patch_reaction_effect(player,
		String(reaction.get("key", "")), reaction.get("effect", {}))
	_reaction_active[reaction_id] = true
	_reaction_depth += 1
	if String(reaction.get("type", "")) == "overcome":
		_execute_overcome_effect(effect)
	else:
		_execute_generate_effect(effect)
	_reaction_depth -= 1
	_reaction_active.erase(reaction_id)
	queue_redraw()
	CodexData.unlock("reaction", reaction_id)
	EventBus.element_reaction.emit(reaction_id, global_position, [self])

## 取状态条目引用（字典按引用传递，可直接改 stacks/remaining/power）
func _status_entry(id: String) -> Dictionary:
	return statuses.get(id, {})

## 相生效果：加层 / 延时 / 提伤 / 必暴 / 转属 / 扩散（不消耗层数）
func _execute_generate_effect(effect: Dictionary) -> void:
	var add: Dictionary = effect.get("add_stacks", {})
	for sid in add:
		var st := _status_entry(String(sid))
		if st.is_empty():
			continue
		var cap := int(Config.status_cfg(String(sid)).get("stack_max", 1))
		st.stacks = mini(cap, int(st.stacks) + int(add[sid]))
	var dmul: Dictionary = effect.get("duration_mult", {})
	for sid2 in dmul:
		var st2 := _status_entry(String(sid2))
		if not st2.is_empty():
			st2.remaining = float(st2.remaining) * float(dmul[sid2])
	var dadd: Dictionary = effect.get("duration_add", {})
	for sid3 in dadd:
		var st3 := _status_entry(String(sid3))
		if not st3.is_empty():
			st3.remaining = float(st3.remaining) + float(dadd[sid3])
	# DoT 提伤（火生土：燃烧伤害 +30%）
	var pmul: Dictionary = effect.get("dmg_mult", {})
	for sid4 in pmul:
		var st4 := _status_entry(String(sid4))
		if not st4.is_empty():
			st4.power = float(st4.power) * float(pmul[sid4])
	# 必暴（土生金：眩晕期间流血 DoT 按暴击倍率结算）
	var crit: Dictionary = effect.get("crit_guarantee", {})
	for sid5 in crit:
		var st5 := _status_entry(String(sid5))
		if not st5.is_empty() and bool(crit[sid5]):
			st5.power = float(st5.power) * _reaction_crit_mult()
	# 转属（金生水：流血转冰伤 → 附加短时冰冻易伤）
	var conv: Dictionary = effect.get("convert_dmg", {})
	for sid6 in conv:
		if statuses.has(String(sid6)):
			apply_status(String(conv[sid6]), 1, REACTION_CONVERT_DURATION, 0.0, 1.0)
	# 扩散（水生木：中毒扩散到周围敌人）
	var spread: Dictionary = effect.get("spread", {})
	for sid7 in spread:
		var st7 := _status_entry(String(sid7))
		if st7.is_empty():
			continue
		_apply_status_in_radius(String(sid7), int(st7.stacks), float(st7.remaining),
			float(st7.power), float(spread[sid7]))

## 相克效果：消耗层数 + 爆发（AOE / 处决 / 破甲 / DoT 翻倍）
func _execute_overcome_effect(effect: Dictionary) -> void:
	# 爆发基数必须在消耗前结算：消耗会清空层数，之后 power×stacks 归零。
	# 同时取「施加这些状态时的玩家单次命中伤害」作为爆发上限的参考值
	# （power 记录的就是施加时那一次命中的伤害）
	var burst := 0.0
	var ref_hit := 0.0
	for sid in statuses:
		var st: Dictionary = statuses[String(sid)]
		burst += float(st.power) * float(int(st.stacks))
		ref_hit = maxf(ref_hit, float(st.power))
	var consume: Dictionary = effect.get("consume", {})
	for sid2 in consume:
		var st2 := _status_entry(String(sid2))
		if st2.is_empty():
			continue
		st2.stacks = int(st2.stacks) - int(consume[sid2])
		if int(st2.stacks) <= 0:
			statuses.erase(String(sid2))
	# AOE 爆发（含自身；status_resist 减免，BOSS 抗反应）
	if effect.has("aoe_dmg_scale"):
		var raw_burst := burst * float(effect.aoe_dmg_scale) * (1.0 - status_resist)
		# 平衡护栏（Config.REACTION_BURST_CAP_MULT）：防止异常叠层堆到极端时一击清场
		var cap := ref_hit * Config.REACTION_BURST_CAP_MULT
		if cap > 0.0:
			raw_burst = minf(raw_burst, cap)
		_damage_in_radius(raw_burst, float(effect.get("aoe_radius", REACTION_AOE_RADIUS)))
	# 处决（土克水：血量低于阈值直接碎裂）
	if effect.has("execute_threshold") and max_hp > 0.0 \
			and hp / max_hp < float(effect.execute_threshold):
		take_damage(hp + 1.0, false, false)
		# 蛟皇目：碎裂成功时回复生命（execute_heal 由法宝 patch 注入，内置反应没这个键）
		# queue_free 是延迟的，此处 self / player 仍有效
		if effect.has("execute_heal") and player and is_instance_valid(player):
			player.heal(float(effect.execute_heal))
		return
	# 破甲（火克金：护甲无效化 → 受伤提升，持续 armor_break_duration）
	if effect.has("armor_break"):
		_add_reaction_debuff(1.0 + float(effect.armor_break), 1.0,
			float(effect.get("armor_break_duration", REACTION_DEBUFF_DURATION)))
	# DoT 翻倍（金克木：持续伤害提升，持续 dot_duration）
	if effect.has("dot_mult"):
		_add_reaction_debuff(1.0, float(effect.dot_mult),
			float(effect.get("dot_duration", REACTION_DEBUFF_DURATION)))

## 对半径内其他敌人施加状态（水生木扩散）
func _apply_status_in_radius(id: String, stacks: int, dur: float, power: float,
		r: float) -> void:
	for other in Combat.enemies_near(global_position, r + Combat.MAX_ENTITY_RADIUS):
		if other == self or other.flee > 0.0 or other.is_queued_for_deletion():
			continue
		if global_position.distance_to(other.global_position) <= r + other.radius:
			other.apply_status(id, stacks, dur, power, 1.0)

## 对半径内敌人造成伤害，最后结算自身（自身可能死亡，避免提前失效位置）
func _damage_in_radius(dmg: float, r: float) -> void:
	if dmg <= 0.0:
		return
	for other in Combat.enemies_near(global_position, r + Combat.MAX_ENTITY_RADIUS):
		if other == self or other.flee > 0.0 or other.is_queued_for_deletion():
			continue
		if global_position.distance_to(other.global_position) <= r + other.radius:
			other.take_damage(dmg * (1.0 - other.status_resist), false, false)
	take_damage(dmg, false, false)

## 暴击倍率（土生金“必暴”用；玩家已升级则取玩家值）
func _reaction_crit_mult() -> float:
	if player and is_instance_valid(player):
		return float(player.stats.get("crit_mult", Config.PLAYER.crit_mult))
	return float(Config.PLAYER.crit_mult)

func _add_reaction_debuff(dmg_mult: float, dot_mult: float, duration: float) -> void:
	if duration <= 0.0:
		return
	reaction_debuffs.append({
		"dmg_taken_mult": maxf(1.0, dmg_mult),
		"dot_mult": maxf(1.0, dot_mult),
		"remaining": duration,
	})

func _tick_reaction_debuffs(delta: float) -> void:
	for i in range(reaction_debuffs.size() - 1, -1, -1):
		var d: Dictionary = reaction_debuffs[i]
		d.remaining = float(d.remaining) - delta
		if float(d.remaining) <= 0.0:
			reaction_debuffs.remove_at(i)

func _reaction_dmg_taken_mult() -> float:
	var mult := 1.0
	for d in reaction_debuffs:
		mult *= float(d.get("dmg_taken_mult", 1.0))
	return mult

func _reaction_dot_mult() -> float:
	var mult := 1.0
	for d in reaction_debuffs:
		mult *= float(d.get("dot_mult", 1.0))
	return mult

func _ready() -> void:
	add_to_group("enemies")

func _physics_process(delta: float) -> void:
	if not GameState.is_running():
		return
	flash_t = maxf(0.0, flash_t - delta)
	bar_t = maxf(0.0, bar_t - delta)
	touch_cd = maxf(0.0, touch_cd - delta)
	if _status_flash_t > 0.0:
		_status_flash_t = maxf(0.0, _status_flash_t - delta)
		queue_redraw()
	# ---- 退场淡出，期间跳过一切行为 ----
	if flee > 0.0:
		flee -= delta
		modulate.a = clampf(flee / 0.55, 0.0, 1.0) * 0.6
		if flee <= 0.0:
			queue_free()
		return
	# 状态效果：先结算 DoT/到期，再决定 AI；被 DoT 击杀则本帧不再行动
	_tick_statuses(delta)
	if hp <= 0.0:
		return
	if player == null or not is_instance_valid(player):
		return
	wob += delta * 6.0
	var spd := speed
	if not statuses.is_empty():
		spd *= _status_speed_mult()   # 空容器快路径：240 敌群逐帧零开销
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
		mv = (mv + Vector2(-ux.y, ux.x) * side) * spd
		shoot_cd -= delta
		if shoot_cd <= 0.0 and d < 620.0:
			shoot_cd = float(cfg.shoot_cd)
			_fire_shooter(ux.angle())
	elif is_boss():
		mv = ux * spd
		ring_cd -= delta
		if not enraged and hp < max_hp * 0.5:
			enraged = true
			speed *= 1.35
		# 螺旋织网者：短间隔连续发弹，弹幕角随发射次数旋转形成螺旋
		if bool(cfg.get("spiral_mode", false)):
			if ring_cd <= 0.0 and d < 820.0:
				ring_cd = (1.1 if enraged else float(cfg.ring_cd))
				_spiral_angle += 0.45
				_fire_spiral_volley()
				EventBus.screen_shake.emit(2.5)
		# 腐土孵化者：周期召唤蜂群幼体围攻
		var summon_cd := float(cfg.get("summon_cd", 0.0))
		if summon_cd > 0.0:
			_summon_cd -= delta
			if _summon_cd <= 0.0:
				_summon_cd = summon_cd * (0.7 if enraged else 1.0)
				_summon_minions()
		# 通用环形弹幕（织网者不用，由螺旋弹替代）
		if ring_cd <= 0.0 and d < 760.0 and not bool(cfg.get("spiral_mode", false)):
			ring_cd = 1.6 if enraged else float(cfg.ring_cd)
			_fire_ring()
			EventBus.screen_shake.emit(3.0)
	else:
		# 追击型；runner（ai="runner"）带轻微抖动冲刺感
		var wobble := (1.0 + 0.12 * sin(wob * 2.0)) if ai_type() == "runner" else 1.0
		mv = ux * spd * wobble
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
	# 敌间分离：隔帧错峰（按实例 ID 奇偶分半），大规模敌群下查询开销减半；
	# 索引位置容许一帧偏差（≤3px / 128px 网格），省去逐敌逐帧的中间索引更新
	if (Engine.get_physics_frames() + (get_instance_id() % 2)) % 2 == 0:
		# 空间索引只查询邻近敌人，并按实例 ID 每对只处理一次。
		var pad := SEPARATION_PAD_LARGE if radius > 40.0 else SEPARATION_PAD_NORMAL
		var my_id := get_instance_id()
		for other in Combat.enemies_near(global_position, radius + pad):
			if other == self or other.flee > 0.0 \
					or other.is_queued_for_deletion() or my_id >= other.get_instance_id():
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
	# 障碍物推出（Phase 5）：本项目未使用物理引擎，障碍物是手写判定，
	# 放在最终边界钳制之前，推出结果仍在世界内
	global_position = Obstacles.resolve_circle(global_position, radius)
	global_position = global_position.clamp(
		Vector2(radius, radius), world - Vector2(radius, radius))
	Combat.update_enemy_position(self)
	# 仅在视觉状态（闪白/血条）变化时重绘，位置由节点变换承担
	var vis := 1 if flash_t > 0.0 else (2 if (bar_t > 0.0 and hp < max_hp) else 0)
	var sig := 0
	if not statuses.is_empty():
		sig = _status_signature()
	if vis != _vis_state or sig != _status_sig:
		_vis_state = vis
		_status_sig = sig
		queue_redraw()

func _fire_shooter(ang: float) -> void:
	_fire_enemy_bullet(ang, float(cfg.bspeed), 6.0, 3.0, touch_dmg)

func _fire_ring() -> void:
	var n: int = cfg.ring_count
	var off := GameRng.next() * TAU
	for i in n:
		var a := off + TAU * float(i) / float(n)
		_fire_enemy_bullet(a, float(cfg.bspeed), 7.0, 4.5, touch_dmg * 0.7)

## 螺旋弹幕：以当前相位为起点扇形连发数发，形成旋转的"织网"轨迹
func _fire_spiral_volley() -> void:
	var count := int(cfg.ring_count)
	var base := _spiral_angle
	for i in count:
		var a := base + TAU * float(i) / float(count)
		_fire_enemy_bullet(a, float(cfg.bspeed), 6.0, 4.0, touch_dmg * 0.6)

## 召唤蜂群：在自身周围一圈生成小怪（腐土孵化者）
func _summon_minions() -> void:
	var stype := String(cfg.get("summon_type", "swarm"))
	var count := int(cfg.get("summon_count", 4))
	for i in count:
		var a := GameRng.next() * TAU
		var pos := global_position + Vector2.from_angle(a) * (radius + 46.0)
		pos = pos.clamp(Vector2(40.0, 40.0),
			Vector2(Config.WORLD.w, Config.WORLD.h) - Vector2(40.0, 40.0))
		var minion: Node2D = preload("res://scenes/enemies/enemy.tscn").instantiate()
		minion.setup(stype, spawn_wave)
		minion.position = pos
		get_parent().add_child(minion)
		minion.player = player
	EventBus.screen_shake.emit(2.0)
	Sfx.play("shoot_rocket")

func _fire_enemy_bullet(ang: float, bspeed: float, r: float, life_t: float, dmg: float) -> void:
	# 弹幕护栏：极端敌群下放弃超量射击，避免敌弹无限堆积
	if get_tree().get_nodes_in_group("enemy_bullets").size() >= 150:
		return
	var b = ObjectPool.acquire("enemy_bullet", EnemyBulletScene, get_parent())
	b.setup(global_position, ang, bspeed, dmg, r, life_t)
	b.player = player

func take_damage(dmg: float, crit: bool, dot: bool = false) -> void:
	if hp <= 0.0 or flee > 0.0:
		return
	# 刑天斧：低血加成必须在 hp 扣减【之前】按当前血量比例判定，扣完再算就晚了
	var final_dmg := dmg * ArtifactSystem.execute_damage_mult(player, self) \
		* _damage_taken_mult()
	hp -= final_dmg
	bar_t = 0.9
	queue_redraw()   # 每次受击都重绘（血条比例随 hp 变化）
	if dot:
		# DoT 跳伤：不播放受击音效/粒子，避免大规模燃烧时刷屏
		if hp <= 0.0:
			die()
		return
	flash_t = 0.09
	Sfx.play("enemy_hit")
	FloatingText.spawn(get_parent(), global_position + Vector2(0.0, -radius - 4.0),
		str(roundi(final_dmg)) + ("!" if crit else ""), Color("ffd24a") if crit else Color.WHITE,
		16 if crit else 12)
	Burst.spawn(get_parent(), global_position, color, 3, 90.0)
	if hp <= 0.0:
		die()

func die() -> void:
	# 焚天凤凰·涅槃：第一次死亡回血复活，不结算击杀/掉落、不真正死亡。
	# 必须放在 enemy_killed 之前拦截 —— 否则复活会让「一个 BOSS 计两次击杀」，
	# 也会让法宝 on_kill 在假死时提前结算
	if is_boss() and String(cfg.get("death_skill", "")) == "rebirth" and not _reborn:
		_reborn = true
		hp = max_hp * 0.5
		enraged = true
		speed *= 1.5
		bar_t = 0.9
		queue_redraw()
		Burst.spawn(get_parent(), global_position, color, 30, 240.0)
		EventBus.screen_shake.emit(10.0)
		return
	EventBus.enemy_killed.emit(type)
	# 携带节点引用的死亡事件：法宝 on_kill 要读死前身上的状态（凤凰翎要燃烧、断刃锋要流血）
	# 必须在 queue_free 之前发，订阅者才能安全访问节点；BOSS 也要发（无尽模式 BOSS 每波都死）
	EventBus.enemy_died.emit(self)
	if is_boss():
		# 原型：BOSS 死亡大爆发（40 粒 / 260 速度）+ 震屏 14，直接胜利结算不掉落
		Burst.spawn(get_parent(), global_position, color, 40, 260.0)
		EventBus.screen_shake.emit(14.0)
		_execute_death_skill()   # BOSS 专属死亡技能（最后一击）
		EventBus.boss_killed.emit()
		queue_free()
		return
	Burst.spawn(get_parent(), global_position, color, 10, 150.0)
	# 瘟疫之心：中毒目标死亡时向周围传染
	if player and is_instance_valid(player) and float(player.stats.get("status_spread", 0.0)) >= 1.0:
		_spread_poison()
	_drop_loot()
	# 吸血：每击杀回复 lifesteal（原型 killEnemy）
	if player and is_instance_valid(player) and player.stats.lifesteal > 0.0:
		player.hp = minf(player.stats.max_hp, player.hp + player.stats.lifesteal)
	queue_free()

## BOSS 专属死亡技能：死亡瞬间释放的最后一击（数据驱动，见 death_skill 字段）。
## 设计克制 —— 形态明确可躲、伤害不高（≤ touch_dmg 且按距离衰减），
## 只制造「胜利时刻仍需应对」的紧张，不做成「打赢却被反杀」的挫败。
func _execute_death_skill() -> void:
	match String(cfg.get("death_skill", "")):
		"ring":
			# 单圈爆发：一圈均匀弹幕收尾
			for i in 16:
				_fire_enemy_bullet(TAU * float(i) / 16.0, 300.0, 7.0, 4.0, touch_dmg * 0.5)
		"double_ring":
			# 双圈交叉：螺旋网崩解，两圈错相弹幕
			for ring in 2:
				var off := TAU * float(ring) / 2.0
				for i in 14:
					_fire_enemy_bullet(off + TAU * float(i) / 14.0,
						260.0 + float(ring) * 70.0, 6.0, 4.0, touch_dmg * 0.4)
		"miasma":
			# 腐土孵化者：死后爆出瘴气，贴脸玩家按距离衰减受伤
			var d := 99999.0
			if player and is_instance_valid(player):
				d = player.global_position.distance_to(global_position)
			if d < radius + 200.0:
				player.take_damage(touch_dmg * (1.0 - d / (radius + 200.0)))
			for i in 12:
				Burst.spawn(get_parent(),
					global_position + Vector2.from_angle(TAU * float(i) / 12.0) * radius,
					Color("4caf50"), 2, 80.0)
		"shockwave":
			# 玄武岩王：山崩地裂，贴身玩家受重击，远离即安全
			var d2 := 99999.0
			if player and is_instance_valid(player):
				d2 = player.global_position.distance_to(global_position)
			if d2 < radius + 300.0:
				player.take_damage(touch_dmg * (1.0 - d2 / (radius + 300.0)))
			EventBus.screen_shake.emit(16.0)

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
	# 精英怪掉法宝（spec：精英是三大获取渠道之一）
	# 只认实例 elite 标志，不按敌人类型判定 —— Config.wave_composition 里
	# guard/wizard/shadow/bomber 在 W7+ 常规波就会出现，按类型会误伤大量常规怪。
	# 先判 sys 再掷 RNG：无 ArtifactSystem 的环境（冒烟测试）不消耗随机数，保持确定性
	if elite:
		var sys = _artifact_system()   # 不用 := ：返回不定型节点，无法标注类型供推断
		if sys != null and GameRng.chance(Config.ARTIFACT_ELITE_DROP_CHANCE):
			var aid := String(sys.pick_artifact(false))
			if aid != "":
				_spawn_artifact(aid)

## 法宝系统节点（main.tscn 下）：精英掉落需要它抽取法宝 id
## 用组查找而非 preload/单例：ArtifactSystem 随 main.tscn 生灭，
## 冒烟测试等无此节点的场景返回 null 自然降级
func _artifact_system():
	return get_tree().get_first_node_in_group("artifact_system")

## 法宝掉落物：Loot.setup 的 value 是 int，承载不了法宝字符串 id，走独立入口
func _spawn_artifact(id: String) -> void:
	var l = ObjectPool.acquire("loot", LootScene, get_parent())
	l.setup_artifact(id, global_position + Vector2(0.0, -6.0), Vector2(0.0, -70.0))
	l.player = player

func _spawn_loot(kind_name: String, value: int, velocity: Vector2) -> void:
	var l = ObjectPool.acquire("loot", LootScene, get_parent())
	l.setup(kind_name, value, global_position + Vector2(GameRng.range_f(-6.0, 6.0),
		GameRng.range_f(-6.0, 6.0)), velocity)
	l.player = player

func _draw() -> void:
	var sc := 1.0 + (0.12 if flash_t > 0.0 else 0.0)
	var rr := radius * sc
	var fill := Color.WHITE if flash_t > 0.0 else color
	if flash_t <= 0.0 and (statuses.has("freeze") or statuses.has("stun")):
		fill = fill.lerp(Color("9fdcff"), 0.45)
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
	# 状态效果：定身环 + 顶部状态色点（最多 4 个）
	if not statuses.is_empty():
		if statuses.has("freeze") or statuses.has("stun"):
			draw_arc(Vector2.ZERO, rr + 4.0, 0.0, TAU, 32, Color(0.56, 0.85, 1.0, 0.85), 2.5, true)
		var count := mini(statuses.size(), 4)
		var pip_x := -float(count - 1) * 5.0
		var idx := 0
		for id in statuses:
			if idx >= count:
				break
			var pip_col := Color(String(Config.status_cfg(String(id)).get("color", "#ffffff")))
			var pip_pos := Vector2(pip_x + float(idx) * 10.0, -radius - 18.0)
			draw_circle(pip_pos, 3.0, pip_col)
			var stacks := int(statuses[id].stacks)
			if stacks > 1:
				draw_string(ThemeDB.fallback_font, Vector2(pip_pos.x - 5.0, pip_pos.y - 5.0),
					str(stacks), HORIZONTAL_ALIGNMENT_CENTER, 10.0, 9, Color(1.0, 1.0, 1.0, 0.9))
			idx += 1
	# 状态触发彩色扩散环（向外扩散并淡出）
	if _status_flash_t > 0.0:
		var fk := _status_flash_t / 0.35
		draw_arc(Vector2.ZERO, rr + (1.0 - fk) * 16.0, 0.0, TAU, 32,
			Color(_status_flash_color.r, _status_flash_color.g, _status_flash_color.b, fk * 0.85), 2.5, true)
	# 血条（受击后短暂显示）
	if bar_t > 0.0 and hp < max_hp:
		var bw := maxf(26.0, radius * 2.0)
		draw_rect(Rect2(-bw / 2.0, -radius - 10.0, bw, 4.0), Color(0.0, 0.0, 0.0, 0.6))
		draw_rect(Rect2(-bw / 2.0, -radius - 10.0, bw * clampf(hp / max_hp, 0.0, 1.0), 4.0), Color("e8b84b"))
