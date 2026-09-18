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
## 所属五行（五行体系 §12-S1）：空串 = 无属性。取自 cfg.element，setup 时快照。
## ⚠️ 快照而不是每次读 cfg —— 后续 S4.5 的「区块偏置」会按波次动态改这个值，
##    快照语义让「这只怪属于哪一行」在它出生那一刻就确定，不会中途变卦。
var element := ""
## 元素减伤（五行体系 §5.5.2 怪物抗性模型）：0 = 不减伤。
## 与 status_resist（状态时长减免）是两回事，别混用。
## 受击时它是**独立的减伤乘区**，与 §2.3-B 的关系修正相乘（不是取更严/取 min）——
## 理由见 take_damage 里那段注释：取更严会让「高波次同属性怪」的抗性完全吞掉关系收益。
var element_resist := 0.0
## BOSS 光环加成（§5.5.5 规则 3）：光环内**同元素**怪 R +0.15。
## 由 BOSS 侧的低频扫描写入（见 `_refresh_boss_aura`），异元素怪保持 0。
var aura_bonus := 0.0
## 「自身吃自己光环」标记（§5.5.5 规则 1）：**同属性** BOSS（玩家元素 == BOSS 元素）为 true。
## 只有它为 true 时，抗性上限才提到 0.90 —— 也正因如此，这条规则在标准 20 波里
## 有且只有一个可达点：区域元素序末位（W20 BOSS 与玩家同属，见 §5.5.3）。
var _aura_self_active := false
## 区块偏置（§5.5.3）：本区块**主元素**的怪 R +0.10。
## S3 尚无区块概念（区块划分是 S3.5），故当前恒 0 —— 但公式与接口先落地：
## S3.5 只需在 spawn 时写 `enemy.block_bias = Config.RESIST_BLOCK_BIAS` 再调
## `refresh_element_resist()`，不必回头改公式。
var block_bias := 0.0
## 地形区域加成（第 9 轮 · 需求 4）：站在本区地形圆内、且元素与本区相同时 R +该值。
## 由 `fx/terrain_zone.gd` 每 0.35s 低频扫描写入（与 BOSS 光环同一口径）；离开圆即归零。
## 与 block_bias / aura_bonus 进同一个加法项 → 天然被 `_resist_cap()` 压住（普通 0.75）。
var zone_bonus := 0.0
## ---- 五行机制字段（§12-S3），全部来自 cfg，setup 时快照 ----
var shield := 0.0           # 当前护盾值（先扣盾、后扣血）
var max_shield := 0.0
var shield_resist := 0.0    # 护盾存在期间的额外减伤（与元素修正相乘）
var armor_pierce := 0.0     # 穿甲：打玩家时按 (1 - pierce) 加权玩家护甲项
var regen := 0.0            # 每秒回血（HP/s）
var regen_delay := 0.0      # 受击后暂停回血的秒数
var _regen_hold := 0.0      # 当前回血暂停剩余时间
var _split_gen := 0         # 分裂代数：0 = 原生，1 = 分裂体（分裂体不再分裂）
var _aura_t := 0.0          # BOSS 光环扫描计时
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
# ---- BOSS 技能运行时（cfg.skills 数据驱动；普通敌恒为空，零开销）----
var _skill_cds: Array = []      # 与 cfg.skills 对齐的冷却计时
var _cast_t := 0.0              # 施法闪光剩余秒（_draw 外发光环）
var _charge_state := 0          # 0 无 / 1 蓄力预警 / 2 冲撞中
var _charge_t := 0.0            # 当前阶段剩余秒
var _charge_dir := Vector2.ZERO
var _charge_skill: Dictionary = {}
var _aimed_left := 0            # 狙射连发剩余发数
var _aimed_t := 0.0             # 狙射连发间隔计时
var _aimed_skill: Dictionary = {}

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
		# BOSS 不吃普通怪的 `wave_hp_scale`，血量曲线**唯一真值** = `Config.boss_hp_scale(w)`：
		#   · 无尽 = 1 + 0.30(w−10)（W10 = 1.0，与改动前逐字一致）；
		#   · 标准最终波 = 0.85（第 14 轮 W20 再砍 15%）；
		#   · 中间 BOSS（W4/8/12/16）= `BOSS_HP_FRAC` 随区块成长；非 BOSS 波 = 1.0。
		#
		# ⚠️⚠️ 第 9 轮踩过的静默坑（**不报错、冒烟当时也全绿**）：`boss_hp_scale` 当时只写进了
		#    Config 并配了纯函数断言，**这里从没调用过它** —— 于是中间 BOSS 与最终 BOSS 血量
		#    完全相同（56 万~90 万），而中间 BOSS 还额外背 105~195s 限时
		#    → 必然打不死 →「时间结束没有击杀则不掉落」变成常态、法宝盒子永远拿不到。
		#    教训：**新加的公式必须确认它有消费点**；只断言纯函数返回值 = 没断言「有人读」。
		hp_s = Config.boss_hp_scale(wave)
		dmg_s = 1.0 + 0.13 * float(wave - 1)
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
	# 元素归属快照（§12-S1）。区块偏置由外部写 `block_bias` 后调 refresh（见该变量注释）。
	element = String(cfg.get("element", ""))
	if element != "" and not Config.ELEMENTS.has(element):
		element = ""
	# ---- 五行机制字段（§12-S3）----
	# 护盾：独立于血量的第二条命。先扣盾、后扣血。
	max_shield = maxf(0.0, float(cfg.get("shield", 0.0)))
	shield = max_shield
	shield_resist = clampf(float(cfg.get("shield_resist", 0.0)), 0.0, 0.95)
	armor_pierce = clampf(float(cfg.get("armor_pierce", 0.0)), 0.0, 1.0)
	regen = maxf(0.0, float(cfg.get("regen", 0.0)))
	regen_delay = maxf(0.0, float(cfg.get("regen_delay", 0.0)))
	_regen_hold = 0.0
	# 元素抗性（§5.5.2）—— 四项全部接上，走 Config.mob_resist 这一条唯一公式：
	#     R = clamp( 波次成长 × 难度系数 + 区块偏置 + BOSS光环 , 0 , cap )
	#   ⚠️ 难度系数与波次成长是**相乘**、不是相加。理由见 Config.mob_resist 的长注释：
	#      相加会让三档难度在 W20 全部撞上 0.75 → 后期失去区分度，
	#      且与「即使噩梦最后一波怪物抵抗也就 75%」的原话矛盾（乘法才能得出 0.45/0.60/0.75）。
	#   cap：普通怪一律 0.75（§5.5.1）；**同属性 BOSS 自身吃光环**时才提到 0.90
	#       （唯一的 90% 通道）—— 那条由 `_refresh_boss_aura` 在玩家元素确定后提升，
	#       这里先按保守档算，避免依赖「setup 时 player 已绑定」这个不成立的假设。
	element_resist = _calc_element_resist()
	# BOSS 技能冷却初始化：首发 cd × 0.5 并逐个错开，避免进场瞬间技能齐发
	_skill_cds = []
	var sk_list: Array = cfg.get("skills", [])
	for si in sk_list.size():
		var first_cd := float(sk_list[si].get("cd", 4.0)) * 0.5
		_skill_cds.append(first_cd + float(si) * 0.8)
	_charge_state = 0
	_aimed_left = 0
	CodexData.unlock("enemy", type_name)   # 图鉴：遭遇即解锁

## 元素抗性标量 R 的统一计算口（§5.5.2）。setup 与「光环/区块偏置变化」时都调它。
##
## ⚠️ 与 `take_damage` 里的逐关系 cap 不冲突：这里给的是**单个标量 R**，
##    take_damage 再按「来袭元素 vs 自身元素」的关系决定 R 的有效上限。
func _calc_element_resist() -> float:
	var diff: Dictionary = Registry.get_difficulty(GameState.difficulty_id)
	return Config.mob_resist(spawn_wave, float(diff.get("resist_mult", 0.0)),
		block_bias, aura_bonus, _resist_cap(), zone_bonus)

## 本敌当前的抗性上限：普通怪 0.75；同属性 BOSS 自身吃光环时 0.90（唯一 90% 通道）。
func _resist_cap() -> float:
	return Config.CAP_MOB_SAME_BOSS if _aura_self_active else 0.75

## 外部改了 `block_bias` / `aura_bonus` / `_aura_self_active` 之后调它重算。
## S3.5 接区块偏置时就用这个口，不必重新 setup（重 setup 会重置血量与护盾）。
func refresh_element_resist() -> void:
	element_resist = _calc_element_resist()

## 地形区域（第 9 轮 · 需求 4）：由 `fx/terrain_zone.gd` 写入。
## 写前比较（照抄 `_refresh_boss_aura`）—— 距离判定每 0.35s 跑一次、怪又多，
## 不做这个比较就是每次扫描把全场怪的抗性重算一遍，纯白烧 CPU。
func set_zone_bonus(v: float) -> void:
	if is_equal_approx(zone_bonus, v):
		return
	zone_bonus = v
	refresh_element_resist()

## BOSS 光环（§5.5.5）。两条规则：
##   规则 1 —— **玩家元素 == BOSS 元素**（同属性）时，BOSS 自身 R +0.15，
##             且「同属性」行的抗性上限提到 0.90（`CAP_MOB_SAME_BOSS`，全项目唯一 90% 通道）。
##   规则 3 —— 光环半径内 `element == 本 BOSS 元素` 的怪 R +0.15；**异元素怪不受益**。
##
## 为什么规则 1 要卡「同属性」：这条规则的全部意义就是给「照镜子」的 BOSS 波
## 一个有仪式感的检验点（§5.5.3 末位放「同属」正是为了让它在标准 20 波里可达）。
## 若对所有 BOSS 都开 90%，那 90% 就成了"BOSS 默认值"，仪式感消失，
## 且与「只有同属性 boss 波次，在 boss 光环加持下，才能到 90%」的原话不符。
##
## ⚠️ 用 `node.get/set/call` 而不是直接点属性：`get_nodes_in_group` 返回 `Array[Node]`，
##    静态类型下访问 `.element` 会直接编译报错。`has_method` 同时充当「它是不是 Enemy」的判据。
func _refresh_boss_aura() -> void:
	var same_as_player := player != null and is_instance_valid(player) \
		and String(player.element) == element
	if _aura_self_active != same_as_player:
		_aura_self_active = same_as_player
		refresh_element_resist()
	for node in get_tree().get_nodes_in_group("enemies"):
		if node == self or not node.has_method("refresh_element_resist"):
			continue
		var n2 := node as Node2D
		if n2 == null:
			continue
		var in_aura := String(node.get("element")) == element \
			and n2.global_position.distance_to(global_position) <= Config.BOSS_AURA_RADIUS
		var want := Config.RESIST_BOSS_AURA if in_aura else 0.0
		if not is_equal_approx(float(node.get("aura_bonus")), want):
			node.set("aura_bonus", want)
			node.call("refresh_element_resist")

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
	take_damage(tick_dmg, false, true, "", "status")

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
	if _cast_t > 0.0:
		_cast_t = maxf(0.0, _cast_t - delta)
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
	# ---- 回血（§5.3）：受击后 `regen_delay` 秒内不回血 ----
	# 只在没满血时走；重绘用「整数位变化」而不是每帧，回春灵每秒 3 次重绘而非 60 次。
	if regen > 0.0 and hp < max_hp:
		if _regen_hold > 0.0:
			_regen_hold = maxf(0.0, _regen_hold - delta)
		else:
			var hp_before := hp
			hp = minf(max_hp, hp + regen * delta)
			if int(hp_before) != int(hp):
				queue_redraw()
	# ---- BOSS 光环（§5.5.5）：低频扫描，只由 BOSS 执行 ----
	# 用 0.5s 而不是逐帧：光环是「场上有没有一只同元素 BOSS」的**宏观状态**，
	# 玩家感觉不到 0.5s 的延迟；而 240 敌群下逐帧扫 group 是纯粹的浪费。
	if is_boss() and element != "":
		_aura_t -= delta
		if _aura_t <= 0.0:
			_aura_t = 0.5
			_refresh_boss_aura()
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
		# 第 14 轮需求 1：前八波无远程弹幕 —— 远程怪照常出场（保元素闸门 / 图鉴完整）但不开火。
		if spawn_wave > Config.RANGED_NO_SHOOT_THROUGH_WAVE and shoot_cd <= 0.0 and d < 620.0:
			shoot_cd = float(cfg.shoot_cd)
			_fire_shooter(ux.angle())
	elif is_boss():
		if _charge_state == 1:
			# 蓄力预警：原地不动，到点后沿锁定方向爆发冲撞
			_charge_t -= delta
			queue_redraw()
			if _charge_t <= 0.0:
				_charge_state = 2
				_charge_t = float(_charge_skill.get("duration", 0.45))
				EventBus.screen_shake.emit(4.0)
				Sfx.play("shoot_rocket")
		elif _charge_state == 2:
			# 冲撞：沿锁定方向高速直线推进（接触伤害由既有 touch 逻辑承担）
			_charge_t -= delta
			mv = _charge_dir * spd * float(_charge_skill.get("speed_mult", 6.0))
			if _charge_t <= 0.0:
				_charge_state = 0
		else:
			mv = ux * spd
			_tick_boss_skills(delta)
			_tick_aimed_burst(delta)
		ring_cd -= delta
		if not enraged and hp < max_hp * 0.5:
			enraged = true
			speed *= 1.35
			# 狂暴亮相：全屏震动 + 头顶提示，玩家能读懂「阶段变了」
			EventBus.screen_shake.emit(6.0)
			FloatingText.spawn(get_parent(), global_position + Vector2(0.0, -radius - 20.0),
				"狂暴！", Color("ff5e3a"), 22)
			Burst.spawn(get_parent(), global_position, color, 16, 200.0)
		# 螺旋织网者：短间隔连续发弹，弹幕角随发射次数旋转形成螺旋
		if _charge_state == 0 and bool(cfg.get("spiral_mode", false)):
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
		if _charge_state == 0 and ring_cd <= 0.0 and d < 760.0 \
				and not bool(cfg.get("spiral_mode", false)):
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
		player.take_damage(touch_dmg, element)
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

## ---- BOSS 技能系统（cfg.skills 数据驱动）----
## 四个技能形态，全部带可读预警：
##   fan    扇形弹幕：施法闪光 + 头顶技能名，朝玩家扇形铺开
##   aimed  锁定连狙：连续数发高速弹咬死玩家当前位置（走位逼停）
##   nova   地面预警圈：复用流星雨的收缩预警圈，延迟落点 AOE
##   charge 蓄力冲撞：预警线 → 高速直线冲撞（接触伤害）
## 狂暴（半血）后冷却 ×0.65，技能明显更密 —— 阶段感来自行为变化而非单纯加血

func _tick_boss_skills(delta: float) -> void:
	var skills: Array = cfg.get("skills", [])
	if skills.is_empty():
		return
	var cd_rate := 1.0 / 0.65 if enraged else 1.0   # 狂暴：技能冷却转得更快
	for i in mini(skills.size(), _skill_cds.size()):
		_skill_cds[i] = float(_skill_cds[i]) - delta * cd_rate
		if float(_skill_cds[i]) <= 0.0:
			var sk: Dictionary = skills[i]
			_skill_cds[i] = float(sk.get("cd", 4.0))
			_cast_boss_skill(sk)

## 狙射连发队列：一次启动后按 interval 连续出弹，不占技能冷却
func _tick_aimed_burst(delta: float) -> void:
	if _aimed_left <= 0:
		return
	_aimed_t -= delta
	if _aimed_t > 0.0:
		return
	_aimed_t = float(_aimed_skill.get("interval", 0.15))
	_aimed_left -= 1
	if player != null and is_instance_valid(player):
		var a: float = (player.global_position - global_position).angle()
		_fire_enemy_bullet(a, float(_aimed_skill.get("bspeed", 420.0)),
			6.0, 4.0, touch_dmg * float(_aimed_skill.get("dmg_mult", 0.7)))

func _cast_boss_skill(sk: Dictionary) -> void:
	var stype := String(sk.get("type", ""))
	_cast_t = 0.3
	queue_redraw()
	var label := String(sk.get("name", ""))
	if label != "":
		FloatingText.spawn(get_parent(), global_position + Vector2(0.0, -radius - 14.0),
			label, Color("ff8a5e"), 15)
	match stype:
		"fan":
			_fire_fan(sk)
		"aimed":
			_aimed_skill = sk
			_aimed_left = int(sk.get("count", 3))
			_aimed_t = 0.0   # 立即出第一发
		"nova":
			_cast_nova(sk)
		"charge":
			_charge_skill = sk
			_charge_state = 1
			_charge_t = float(sk.get("warn", 0.5))
			if player != null and is_instance_valid(player):
				_charge_dir = (player.global_position - global_position).normalized()
			queue_redraw()

## 扇形弹幕：以玩家方向为中心轴，count 发按 arc 弧度铺开
func _fire_fan(sk: Dictionary) -> void:
	if player == null or not is_instance_valid(player):
		return
	var to_p: float = (player.global_position - global_position).angle()
	var n := maxi(1, int(sk.get("count", 5)))
	var arc := float(sk.get("arc", 0.9))
	var spd2 := float(sk.get("bspeed", cfg.get("bspeed", 260.0)))
	for i in n:
		var a: float = to_p
		if n > 1:
			a += -arc / 2.0 + arc * float(i) / float(n - 1)
		_fire_enemy_bullet(a, spd2, 7.0, 4.5, touch_dmg * float(sk.get("dmg_mult", 0.65)))
	Sfx.play("shoot_smg")

## 地面预警圈 AOE：首圈锁定玩家脚下；后续圈按 0°/120°/240°… 均匀散开（带小幅抖动），
## 避免三颗流星雨挤在玩家脚下叠在一起（前期移速低时几乎必吃满，难以躲开）。
## spread_radius 控制落点与玩家的距离（越大越易躲，默认 200），可由 boss 技能表逐技能覆盖。
func _cast_nova(sk: Dictionary) -> void:
	if player == null or not is_instance_valid(player):
		return
	var count := maxi(1, int(sk.get("count", 1)))
	var r := float(sk.get("radius", 110.0))
	var warn := float(sk.get("warn", 0.8))
	var dmg := touch_dmg * float(sk.get("dmg_mult", 0.9))
	var spread_r := float(sk.get("spread_radius", 200.0))
	for i in count:
		var pos: Vector2 = player.global_position
		if i > 0:
			var ang := float(i) / float(count) * TAU + GameRng.range_f(-0.3, 0.3)
			pos += Vector2.from_angle(ang) * spread_r
		pos = pos.clamp(Vector2(40.0, 40.0),
			Vector2(Config.WORLD.w, Config.WORLD.h) - Vector2(40.0, 40.0))
		Meteor.spawn(get_parent(), pos, player, dmg, r, warn, element)

func _fire_enemy_bullet(ang: float, bspeed: float, r: float, life_t: float, dmg: float) -> void:
	# 弹幕护栏：极端敌群下放弃超量射击，避免敌弹无限堆积
	if get_tree().get_nodes_in_group("enemy_bullets").size() >= 150:
		return
	var b = ObjectPool.acquire("enemy_bullet", EnemyBulletScene, get_parent())
	b.setup(global_position, ang, bspeed, dmg, r, life_t)
	b.player = player
	b.element = element   # 五行：敌弹带着发射者的属性飞出去（§12-S1）
	b.armor_pierce = armor_pierce   # 穿甲（§5.3）：与属性同路透传，别漏（漏了会静默失效）

## 受击结算。element_atk = 来袭伤害的五行（空串 = 无属性攻击，不吃元素修正）。
##
## 五行体系 §12-S1 + §5.5.2，三件事按顺序叠：
##   1. 关系修正（§2.3-B）：clamp(关系基数(来袭元素→我的元素) − 我对该元素的同化度, −cap)
##   2. 怪物元素抗性（§5.5.2）：按波次/难度成长的减伤，与关系修正取 min（抗性与关系不叠乘）
##   3. BOSS 单发上限 / 狂暴（沿用旧逻辑，位置不变）
##
## ⚠️ 怪物侧同化度恒为 0：同化度是「玩家养成的亲和」，怪物没有养成系统。
##    故受击侧基数是纯关系值，怪物抗性才是怪物的「成长曲线」。两者别混为一谈。
## src（第 5 参 · 2026-09-17 第 8 轮）：伤害来源标签，**只喂给逐波平衡日志**，
## 不参与任何结算。缺省 "" = 未标注，结算行为与改动前逐字节一致。
func take_damage(dmg: float, crit: bool, dot: bool = false, element_atk: String = "",
		src: String = "") -> void:
	if hp <= 0.0 or flee > 0.0:
		return
	# 刑天斧：低血加成必须在 hp 扣减【之前】按当前血量比例判定，扣完再算就晚了
	var final_dmg := dmg * ArtifactSystem.execute_damage_mult(player, self) \
		* _damage_taken_mult()
	# ---- 五行：关系修正 × 怪物元素抗性（两个独立乘区，各自按自己的 cap 封顶）----
	# 关系修正（§2.3-B）回答「我的五行属性能不能扛住这一发」；
	# 元素抗性（§5.5.2）回答「我这一波本身有多硬」。两者来源不同，故相乘而非取更严 ——
	# 取更严会让「高波次同属性怪」的抗性完全吞掉关系收益，玩家堆同化度看不到任何反馈。
	# 两个乘区各自 clamp 到自己的 cap，叠加后最坏情况是 (1-cap_rel)×(1-cap_res)，
	# 普通怪 75% 封顶那一条由下面的 eff_cap 统一施加在两处，保证不会出现「无效抗性叠加」。
	if element_atk != "" and element != "":
		# 逐关系有效 cap（§5.5.1）—— 走 Config.mob_cap 统一查表，别在这里另写一套数字。
		# ⚠️ 与玩家侧表的差异只有 same 一行（0.90 → 0.75）；i_beat/beats_me/other 三行相同。
		# ⚠️ 90% 的**唯一**通道 = 同属性 BOSS 自身吃光环（`_aura_self_active`）。
		#    S1 曾写成 `0.90 if is_boss() else 0.75` —— 那对**所有** BOSS 都开了 0.90，
		#    包括不与玩家同属性的 BOSS，比 §5.5.5 规则 1 宽松得多。这里一并收紧。
		var eff_cap := Config.mob_cap(element_atk, element, _aura_self_active)
		# 关系修正：直接走 Config.hit_mult（已含「基数>0 时下限为 0」的特例处理）
		var rel_red := Config.hit_mult(element_atk, element, 0.0)   # ≤0 即减伤
		var rel_mult := 1.0 + maxf(rel_red, -eff_cap)
		var res_mult := 1.0 - clampf(element_resist, 0.0, eff_cap)
		final_dmg *= rel_mult * res_mult
	# ---- 护盾（§5.3）：先扣盾、后扣血，溢出部分照常扣血 ----
	# 护盾期减伤（shield_resist）是**独立乘区**，作用在「这一发」上。
	# ⚠️ 只在护盾 > 0 时生效 —— 盾碎后减伤必须消失，
	#    否则「40 盾」会退化成一个永久的 50% 减伤（与"护盾"这个直觉命名不符）。
	# 采用**溢出**语义（超出盾量的部分打进血量）：不溢出会让高伤单发被盾完全吞掉，
	# 「白吃一发」的怪异感比"盾被一枪打穿"严重得多。
	if shield > 0.0:
		final_dmg *= (1.0 - shield_resist)
		var absorbed := minf(shield, final_dmg)
		shield -= absorbed
		final_dmg -= absorbed
		if shield <= 0.0:
			shield = 0.0
			bar_t = 0.9   # 破盾瞬间亮血条，给玩家"打穿了"的反馈
		queue_redraw()
	# 回血暂停：受击后 regen_delay 秒内不回血（§5.3）。
	# 没有这条的话「回春灵 + 玩家 DPS 不足」会变成打不死的怪。
	if regen > 0.0:
		_regen_hold = regen_delay
	if is_boss():
		# 巨额抗性：单次伤害不得超过最大生命的一定比例（dmg_cap_pct，默认 0.5%）——
		# 爆发构筑不能一发跳过阶段，BOSS 战必须有「打阶段」的过程；
		# 顺带堵死土克水处决路径（take_damage(hp+1) 直接秒 BOSS 的漏洞）。
		# 高频低伤武器不受影响（单发远低于上限），惩罚的是单发超爆发
		final_dmg = minf(final_dmg, max_hp * float(cfg.get("dmg_cap_pct", 0.005)))
		if enraged:
			final_dmg *= 0.8   # 狂暴阶段再减伤：半血后明显更硬
	hp -= final_dmg
	# 逐波平衡日志（第 8 轮）：记「实际打进血的量」（BOSS 单发上限、护盾吸收、
	# 元素抗性都已生效），含击杀那一下的溢出伤害 —— 它是玩家真实看到的输出。
	BalanceLog.add_damage_dealt(final_dmg, src)
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
	# ---- 死亡分裂（§5.3）：水灵这类怪死后裂成数只小体 ----
	# 放在掉落/吸血之前：先把分裂体放出来，它们的掉落由各自死亡时结算。
	_split_on_death()
	# 瘟疫之心：中毒目标死亡时向周围传染
	if player and is_instance_valid(player) and float(player.stats.get("status_spread", 0.0)) >= 1.0:
		_spread_poison()
	_drop_loot()
	# 吸血：每击杀回复 lifesteal（原型 killEnemy）
	if player and is_instance_valid(player) and player.stats.lifesteal > 0.0:
		player.hp = minf(player.stats.max_hp, player.hp + player.stats.lifesteal)
	queue_free()

## 死亡分裂（§5.3）。两条护栏缺一不可，否则会做出「打不完的怪」：
##   ① **代数护栏** `_split_gen`：分裂体一律不再分裂（`_split_gen >= 1` 直接返回）。
##      没有它，每一代都再裂 N 只 → 无限增长，一波怪能把帧率打穿。
##   ② **血量递减** `hp_pct`：按**本体当前 max_hp 的比例**给，不是按配置 `hp` 重算。
##      按配置重算的话，分裂体血量 = 配置值 × 波次缩放（与本体同档）→ 越裂越硬。
func _split_on_death() -> void:
	var sp: Dictionary = cfg.get("split_on_death", {})
	if sp.is_empty() or _split_gen >= 1:
		return
	var stype := String(sp.get("type", type))
	var count := clampi(int(sp.get("count", 3)), 1, 8)
	var hp_pct := clampf(float(sp.get("hp_pct", 0.5)), 0.05, 1.0)
	var child_hp := maxf(1.0, max_hp * hp_pct)
	for i in count:
		var a := GameRng.next() * TAU
		var pos := global_position + Vector2.from_angle(a) * (radius + 26.0)
		pos = pos.clamp(Vector2(40.0, 40.0),
			Vector2(Config.WORLD.w, Config.WORLD.h) - Vector2(40.0, 40.0))
		var minion: Node2D = preload("res://scenes/enemies/enemy.tscn").instantiate()
		minion.setup(stype, spawn_wave)
		# setup 之后再覆盖血量与代数（setup 会按配置 + 波次缩放重算 max_hp）
		minion.max_hp = child_hp
		minion.hp = child_hp
		minion._split_gen = _split_gen + 1
		minion.global_position = pos
		get_parent().add_child(minion)
		minion.player = player
		minion.queue_redraw()
	EventBus.screen_shake.emit(1.5)

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
				player.take_damage(touch_dmg * (1.0 - d / (radius + 200.0)), element)
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
				player.take_damage(touch_dmg * (1.0 - d2 / (radius + 300.0)), element, armor_pierce)
			EventBus.screen_shake.emit(16.0)

## 掉落：经验晶体 + 材料（收获加成）+ 概率红心（越强掉越好，heart_chance 按怪物类型）
func _drop_loot() -> void:
	var harvest := 0.0
	if player and is_instance_valid(player):
		harvest = player.stats.harvesting
	_spawn_loot("xp", int(cfg.xp),
		Vector2(GameRng.range_f(-40.0, 40.0), GameRng.range_f(-40.0, 40.0)))
	# 材料掉落先乘全局系数（Config.MATERIAL_DROP_MULT = 0.9，怪物掉落整体 -10%），
	# 再叠玩家收获加成。系数只作用于**怪物掉落**，不动波次结算 / 事件卡 / 法宝补偿
	_spawn_loot("mat", maxi(1, roundi(float(cfg.mat) * Config.MATERIAL_DROP_MULT * (1.0 + harvest))),
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
	# BOSS 施法闪光：技能出手瞬间的外发光环（读技能的视觉锚点）
	if _cast_t > 0.0:
		var ck := _cast_t / 0.3
		draw_arc(Vector2.ZERO, rr + 6.0 + (1.0 - ck) * 10.0, 0.0, TAU, 40,
			Color(1.0, 0.55, 0.3, ck * 0.9), 4.0, true)
	# BOSS 冲撞预警线：蓄力期间沿冲撞方向渐亮的粗线，给玩家明确的躲避窗口
	if _charge_state == 1:
		var warn_total := maxf(0.2, float(_charge_skill.get("warn", 0.5)))
		var prog := clampf(1.0 - _charge_t / warn_total, 0.0, 1.0)
		var blink := 0.35 + 0.45 * prog + 0.15 * sin(Time.get_ticks_msec() * 0.03)
		var line_len := rr + 240.0
		draw_line(Vector2.ZERO, _charge_dir * line_len,
			Color(1.0, 0.4, 0.25, blink), 10.0, true)
		draw_line(Vector2.ZERO, _charge_dir * line_len,
			Color(1.0, 0.75, 0.5, blink * 0.6), 3.0, true)
	# 血条（受击后短暂显示）
	if bar_t > 0.0 and hp < max_hp:
		var bw := maxf(26.0, radius * 2.0)
		draw_rect(Rect2(-bw / 2.0, -radius - 10.0, bw, 4.0), Color(0.0, 0.0, 0.0, 0.6))
		draw_rect(Rect2(-bw / 2.0, -radius - 10.0, bw * clampf(hp / max_hp, 0.0, 1.0), 4.0), Color("e8b84b"))
	# 护盾条（§12-S3）：血条上方一档，冰蓝色。有盾时**常显**（不必等受击）——
	# 它是「还得先破一层」的唯一视觉线索，藏起来会让玩家以为伤害莫名其妙被吃掉。
	if max_shield > 0.0 and shield > 0.0:
		var bw2 := maxf(26.0, radius * 2.0)
		draw_rect(Rect2(-bw2 / 2.0, -radius - 15.0, bw2, 3.0), Color(0.0, 0.0, 0.0, 0.6))
		draw_rect(Rect2(-bw2 / 2.0, -radius - 15.0, bw2 * clampf(shield / max_shield, 0.0, 1.0), 3.0),
			Color("7fd8ff"))
	# 元素描边环（§12-S3 · 纯视觉）：本怪所属元素的外圈细环。
	# ⚠️ 只读 `element`（Config 真值），不提供任何判定语义 —— 铁律 3。
	if element != "":
		var ecol := Color(String(Config.ELEMENT_COLOR.get(element, "#ffffff")))
		draw_arc(Vector2.ZERO, rr + 2.5, 0.0, TAU, 36,
			Color(ecol.r, ecol.g, ecol.b, 0.75), 1.6, true)
