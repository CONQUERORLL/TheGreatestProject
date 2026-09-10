class_name ArtifactSystem
extends Node
## ============================================================
## 法宝触发执行器（Phase 3）
## 法宝 = 触发条件 + 参数 + 效果，区别于道具（ITEMS）的纯属性被动。
##
## 两类接口务必分清：
## 【1】静态同步查询 —— 由战斗代码在结算【之前】主动调用，改写本次结算的数值。
##     EventBus 信号都是结算之后才发的，在回调里改已经太晚：
##       patch_reaction_effect  enemy.trigger_reaction 执行反应效果前
##                              （熔金炉 / 孢心 / 落魂钟 / 蛟皇目）
##       armor_bonus            player.take_damage 护甲结算前（岩肤符高血护甲）
##       incoming_damage_mult   player.take_damage 减伤结算前（岩肤符低血减伤）
##       execute_damage_mult    enemy.take_damage 伤害结算前（刑天斧低血加成）
##       attack_power           焚天印「追加 N% 攻击力」与状态 DoT 强度的统一基准
## 【2】实例信号回调 —— 世界侧表现（施加状态 / 回复 / 掉材料 / 叠层）。
##     做成 main.tscn 下的场景节点而非 autoload：需要 player 引用、世界坐标与
##     add_child 权限；且随 main.tscn 每次重开天然重置，不必手写清场。
##
## 性能与稳健：
##   - 所有回调先过 _active()（player 有效 + 局内 + 至少持有 1 件法宝），没拿法宝时零开销
##   - AOE 一律复用 Combat 空间索引，不做全场遍历
##   - _proc_depth 限制连锁深度：施加状态 → 触发反应 → 再施加状态 的链条有界
## ============================================================

## 连锁深度上限：法宝施加的状态可能再触发五行反应，反应又可能再触发法宝
const MAX_PROC_DEPTH := 4

var player   # 不定型引用 characters/player.gd（与 enemy.gd / wave_manager.gd 同款，避免循环依赖）
var wave := 1   # 当前波次（wave_started 同步；artifact_pool 的稀有度进度用）

## 测试观测：法宝 id -> 成功触发次数（冒烟测试断言用，只记真正生效的触发）
var proc_log: Dictionary = {}
var _proc_depth := 0

func _ready() -> void:
	# 供 enemy.gd 反查（精英掉法宝要抽 id）：ArtifactSystem 随 main.tscn 生灭，
	# 做成场景节点而非 autoload，组查找让冒烟测试等无此节点的环境自然降级
	add_to_group("artifact_system")
	EventBus.element_reaction.connect(_on_element_reaction)
	EventBus.enemy_died.connect(_on_enemy_died)
	EventBus.boss_killed.connect(_on_boss_killed)
	EventBus.status_applied.connect(_on_status_applied)
	EventBus.player_damaged.connect(_on_player_damaged)
	EventBus.wave_ended.connect(_on_wave_ended)
	EventBus.wave_started.connect(_on_wave_started)
	EventBus.run_started.connect(_on_run_started)

# ------------------------------------------------------------
# 【1】静态同步查询（战斗结算前调用；无 player / 无法宝时一律返回中性值）
# ------------------------------------------------------------

## 静态守卫：player 有效且至少持有 1 件法宝
static func _live(p) -> bool:
	return p != null and is_instance_valid(p) and not p.artifacts_owned.is_empty()

## 玩家攻击力 = 已装备武器基础伤害（含弹丸数）均值 × 伤害加成
## 焚天印的「追加 40% 攻击力」与法宝施加状态的 DoT 强度都以这个为基准，
## 避免为法宝另造一套伤害公式（否则数值无法与武器构筑对齐）
static func attack_power(p) -> float:
	if p == null or not is_instance_valid(p) or p.weapons.is_empty():
		return 0.0
	var total := 0.0
	for w in p.weapons:
		var c: Dictionary = Registry.weapons.get(String(w.get("type", "")), {})
		total += float(c.get("dmg", 0.0)) * float(int(c.get("pellets", 1)))
	return total / float(p.weapons.size()) * float(p.stats.get("dmg_mult", 1.0))

## 法宝施加状态时的 DoT 强度（燃烧/中毒/流血需要 power，冰冻/减速 tick=0 用不到）
## power 传 0 会让 DoT 打不出伤害，所以至少给 1.0 兜底
static func status_power(p) -> float:
	return maxf(1.0, attack_power(p))

## 熔金炉 / 孢心 / 落魂钟 / 蛟皇目：把已持有法宝的 patch 依次应用到反应 effect 上
## 返回新字典，不改 Registry 里的原数据（同一反应下一局仍从基准值开始）
static func patch_reaction_effect(p, rkey: String, effect: Dictionary) -> Dictionary:
	if not _live(p) or rkey == "":
		return effect
	var out := effect
	for id in p.artifacts_owned:
		var a: Dictionary = Registry.get_artifact(String(id))
		if String(a.get("params", {}).get("key", "")) != rkey:
			continue
		var patch: Dictionary = a.get("effect", {}).get("patch", {})
		if not patch.is_empty():
			out = Config.apply_patch(out, patch)
	return out

## 岩肤符：生命高于 high_hp 时的护甲加成（受击前叠加到 stats.armor）
static func armor_bonus(p) -> float:
	if not _live(p):
		return 0.0
	var bonus := 0.0
	var ratio := _hp_ratio(p)
	for id in p.artifacts_owned:
		var effect: Dictionary = Registry.get_artifact(String(id)).get("effect", {})
		if not effect.has("high_hp_armor") or not effect.has("high_hp"):
			continue
		if ratio >= float(effect.high_hp):
			bonus += float(effect.high_hp_armor)
	return bonus

## 岩肤符：生命低于 low_hp 时的受伤倍率（<= 1.0，多件可乘算）
static func incoming_damage_mult(p) -> float:
	if not _live(p):
		return 1.0
	var mult := 1.0
	var ratio := _hp_ratio(p)
	for id in p.artifacts_owned:
		var effect: Dictionary = Registry.get_artifact(String(id)).get("effect", {})
		if not effect.has("low_hp_dmg_reduce") or not effect.has("low_hp"):
			continue
		if ratio <= float(effect.low_hp):
			mult *= clampf(1.0 - float(effect.low_hp_dmg_reduce), 0.0, 1.0)
	return mult

## 刑天斧：目标生命低于 params.hp_below 时的伤害倍率（enemy.take_damage 结算前）
## 挂在 enemy.take_damage 而非武器命中处：一处覆盖子弹/爆炸/近战/反应 AOE/DoT，
## 且与法宝描述「对生命低于 25% 的敌人伤害 +45%」不限来源的语义一致
static func execute_damage_mult(p, target) -> float:
	if not _live(p) or target == null or not is_instance_valid(target):
		return 1.0
	var target_max := float(target.max_hp)
	if target_max <= 0.0:
		return 1.0
	var ratio := float(target.hp) / target_max
	var mult := 1.0
	for id in p.artifacts_owned:
		var a: Dictionary = Registry.get_artifact(String(id))
		if String(a.get("trigger", "")) != "on_deal_hit":
			continue
		var params: Dictionary = a.get("params", {})
		var effect: Dictionary = a.get("effect", {})
		if not params.has("hp_below") or not effect.has("dmg_mult"):
			continue
		if ratio < float(params.hp_below):
			mult *= maxf(1.0, float(effect.dmg_mult))
	return mult

static func _hp_ratio(p) -> float:
	return float(p.hp) / maxf(1.0, float(p.stats.get("max_hp", 1.0)))

# ------------------------------------------------------------
# 抽取（掉落 / 商店 / BOSS 入账共用）
# ------------------------------------------------------------

## 抽一件玩家尚未持有的法宝 id；池空（全部已持有）时返回 ""
## boss=true 时 legendary 权重 ×Config.ARTIFACT_BOSS_LEGENDARY_MULT
## 掉落同样按构筑亲和加权：与当前角色 / 武器同系的法宝更容易掉出来
func pick_artifact(boss: bool = false) -> String:
	if player == null or not is_instance_valid(player):
		return ""
	var aff := Config.affinity_tags(GameState.character_id,
		player.weapons, player.artifacts_owned)
	var pool := Registry.artifact_pool(player.artifacts_owned, wave, boss, aff)
	if pool.is_empty():
		return ""
	return String(GameRng.weighted_pick(pool))

# ------------------------------------------------------------
# 【2】信号回调（世界侧表现）
# ------------------------------------------------------------

## 触发闸门：player 有效 + 局内 + 至少持有 1 件法宝
func _active() -> bool:
	return player != null and is_instance_valid(player) and GameState.is_running() \
		and not player.artifacts_owned.is_empty() \
		and _proc_depth < MAX_PROC_DEPTH

## 已持有法宝中筛出指定 trigger 的配置列表
func _owned(trigger: String) -> Array:
	var out: Array = []
	for id in player.artifacts_owned:
		var a: Dictionary = Registry.get_artifact(String(id))
		if not a.is_empty() and String(a.get("trigger", "")) == trigger:
			out.append(a)
	return out

func _log(id: String) -> void:
	proc_log[id] = int(proc_log.get(id, 0)) + 1

## 五行反应：焚天印追加伤害 / 寒镜冰冻 nova / 玄武核叠「磐石」
## patch 类法宝（熔金炉/孢心/落魂钟/蛟皇目）走静态 patch_reaction_effect，不在这里处理
func _on_element_reaction(reaction_id: String, pos: Vector2, targets: Array) -> void:
	if not _active():
		return
	var rkey := String(Registry.get_reaction(reaction_id).get("key", ""))
	for a in _owned("on_reaction"):
		var effect: Dictionary = a.get("effect", {})
		if effect.has("patch"):
			continue   # 已在 enemy.trigger_reaction 执行前应用
		if not _reaction_matches(a.get("params", {}), rkey):
			continue
		if effect.has("bonus_dmg_pct") and _proc_bonus_damage(targets, pos,
				float(effect.bonus_dmg_pct)):
			_log(String(a.id))
		elif effect.has("apply_status") and _proc_status_nova(a, pos):
			_log(String(a.id))
		elif effect.has("stat") and _proc_stack(a):
			_log(String(a.id))

## params 匹配：key（反应 key 完全相等）或 element（反应 key 含该五行）；都没给 = 任意反应
static func _reaction_matches(params: Dictionary, rkey: String) -> bool:
	if params.has("key"):
		return String(params.key) == rkey
	if params.has("element"):
		var parts := rkey.split("+")
		var elem := String(params.element)
		return parts.size() == 2 and (String(parts[0]) == elem or String(parts[1]) == elem)
	return true

## 焚天印：对反应目标追加 = 攻击力 × bonus_dmg_pct 的伤害
func _proc_bonus_damage(targets: Array, pos: Vector2, pct: float) -> bool:
	var dmg := attack_power(player) * pct
	if dmg <= 0.0:
		return false
	var hit := 0
	for t in targets:
		if t == null or not is_instance_valid(t) or t.is_queued_for_deletion() \
				or float(t.hp) <= 0.0:
			continue
		t.take_damage(dmg, false, false)
		hit += 1
	if hit == 0:
		return false
	Burst.spawn(player.get_parent(), pos, Color(Config.ELEMENT_COLOR.fire), 8, 150.0)
	return true

## 寒镜 / 凤凰翎 / 潮汐珠：以 pos 为中心，概率对半径内敌人施加状态
## 返回是否真正命中至少 1 个敌人（未命中不计入 proc_log，也不放特效）
func _proc_status_nova(a: Dictionary, pos: Vector2) -> bool:
	var effect: Dictionary = a.get("effect", {})
	if not GameRng.chance(float(effect.get("chance", 0.0))):
		return false
	var sid := String(effect.get("apply_status", ""))
	var r := float(effect.get("radius", 0.0))
	if not Config.STATUS.has(sid) or r <= 0.0:
		return false
	var stacks := int(effect.get("stacks", 1))
	var dur := float(effect.get("duration", 0.0))
	var power := status_power(player)
	_proc_depth += 1
	var hit := 0
	for other in Combat.enemies_near(pos, r + Combat.MAX_ENTITY_RADIUS):
		if other.is_queued_for_deletion() or float(other.flee) > 0.0 \
				or float(other.hp) <= 0.0:
			continue
		if pos.distance_to(other.global_position) <= r + float(other.radius):
			other.apply_status(sid, stacks, dur, power, 1.0)
			hit += 1
	_proc_depth -= 1
	if hit == 0:
		return false
	Burst.spawn(player.get_parent(), pos,
		Color(String(Config.status_cfg(sid).get("color", "#ffffff"))), 10, 170.0)
	Sfx.play("shoot_rocket")
	return true

## 叠层法宝：断刃锋（暴击率，每波重置）/ 玄武核（护甲，永久）
## 已满层不算触发（返回 false），避免刷满后每次击杀都弹飘字
func _proc_stack(a: Dictionary) -> bool:
	var effect: Dictionary = a.get("effect", {})
	var id := String(a.get("id", ""))
	var cap := int(effect.get("stack_max", 1))
	if int(player.artifact_stacks.get(id, 0)) >= cap:
		return false
	player.add_artifact_stacks(id, 1)
	var now := int(player.artifact_stacks.get(id, 0))
	if now <= 0:
		return false
	Sfx.play("buy")
	FloatingText.spawn(player.get_parent(),
		player.global_position + Vector2(0.0, -34.0),
		"%s%s 层 %d/%d" % [String(a.get("ico", "")), String(a.get("name", id)), now, cap],
		Config.rarity_color(String(a.get("rarity", "common"))), 12)
	return true

## 击杀：凤凰翎点燃周围 / 断刃锋叠暴击 / 后土符额外材料
## enemy_died 在 queue_free 之前发出，此时 enemy.statuses 仍是死前状态，可读
func _on_enemy_died(enemy) -> void:
	if not _active() or enemy == null or not is_instance_valid(enemy):
		return
	var pos: Vector2 = enemy.global_position
	for a in _owned("on_kill"):
		var effect: Dictionary = a.get("effect", {})
		# params.status：要求目标死前身上带该状态（凤凰翎要燃烧、断刃锋要流血）
		var need := String(a.get("params", {}).get("status", ""))
		if need != "" and not enemy.statuses.has(need):
			continue
		if effect.has("apply_status"):
			if _proc_status_nova(a, pos):
				_log(String(a.id))
		elif effect.has("stat"):
			if _proc_stack(a):
				_log(String(a.id))
		elif effect.has("bonus_materials") \
				and GameRng.chance(float(effect.get("chance", 0.0))):
			GameState.add_materials(int(effect.bonus_materials))
			_log(String(a.id))

## 施加状态：缠藤结给中毒追加层数
## status_applied 只在状态【首次】上身时发出，追加层数不会再发，天然无递归
func _on_status_applied(status_id: String, _stacks: int, pos: Vector2) -> void:
	if not _active():
		return
	for a in _owned("on_status_apply"):
		if String(a.get("params", {}).get("status", "")) != status_id:
			continue
		var effect: Dictionary = a.get("effect", {})
		if not GameRng.chance(float(effect.get("chance", 0.0))):
			continue
		var target = _enemy_at(pos)   # 不用 := ：_enemy_at 返回不定型节点，无法标注类型供推断
		if target == null:
			continue
		_proc_depth += 1
		target.apply_status(status_id, int(effect.get("add_stacks", 1)), 0.0,
			status_power(player), 1.0)
		_proc_depth -= 1
		_log(String(a.id))
		FloatingText.spawn(player.get_parent(), pos + Vector2(0.0, -20.0),
			"%s+%d" % [String(Config.status_cfg(status_id).get("ico", "")),
				int(effect.get("add_stacks", 1))],
			Color(String(Config.status_cfg(status_id).get("color", "#ffffff"))), 12)

## 受击后：潮汐珠寒冰新星（岩肤符是受击【前】的静态修正，不在这里）
func _on_player_damaged(_amount: float) -> void:
	if not _active():
		return
	for a in _owned("on_take_hit"):
		if a.get("effect", {}).has("apply_status") \
				and _proc_status_nova(a, player.global_position):
			_log(String(a.id))

## 波次结束：建木枝回复最大生命百分比
func _on_wave_ended(_wave: int) -> void:
	if not _active():
		return
	for a in _owned("on_wave_end"):
		var effect: Dictionary = a.get("effect", {})
		if not effect.has("heal_pct"):
			continue
		var before := float(player.hp)
		player.heal(float(player.stats.max_hp) * float(effect.heal_pct))
		if float(player.hp) > before:
			_log(String(a.id))
			Sfx.play("heal")

## 每波开始：同步波次 + 重置「wave」档叠层（断刃锋的锋锐只在本波内有效）
func _on_wave_started(new_wave: int) -> void:
	wave = maxi(1, new_wave)
	if player != null and is_instance_valid(player):
		player.reset_artifact_stacks("wave")

## 新局开始：重置「run」档叠层（玄武核的磐石是永久的，只随局终清空）
func _on_run_started() -> void:
	wave = 1
	proc_log = {}
	if player != null and is_instance_valid(player):
		player.reset_artifact_stacks("run")

## BOSS 必掉法宝（spec：BOSS 是保底获取渠道，legendary 权重 ×ARTIFACT_BOSS_LEGENDARY_MULT）
## 直接入账而非掉在地上：BOSS 死亡即触发通关结算，胜利面板会立刻盖住场景，
## 掉落实体玩家来不及捡（无尽模式虽能捡，但两套路径会让保底变得不可靠）。
## 反馈走 artifact_acquired → main 的队列化 toast，不与「BOSS 击破！」横幅互相覆盖。
## 刻意不过 _active() 闸门：本节点在 main 之前收到 boss_killed，但顺序不该被依赖，
## 且结算时 GameState 可能已切到 VICTORY（is_running() 为假）。
func _on_boss_killed() -> void:
	if player == null or not is_instance_valid(player) or float(player.hp) <= 0.0:
		return
	var id := pick_artifact(true)
	if id == "":
		# 15 件全持有 → 池空，apply_artifact 的重复补偿分支走不到，这里显式兜底
		GameState.add_materials(Config.ARTIFACT_DUP_MATERIALS)
		FloatingText.spawn(player.get_parent(),
			player.global_position + Vector2(0.0, -40.0),
			"法宝已集齐 · +%d ◆" % Config.ARTIFACT_DUP_MATERIALS, Color("ffd24a"), 14)
		Sfx.play("buy")
		return
	var a: Dictionary = Registry.get_artifact(id)
	var col := Config.rarity_color(String(a.get("rarity", "common")))
	player.apply_artifact(id)
	Burst.spawn(player.get_parent(), player.global_position, col, 24, 220.0)
	FloatingText.spawn(player.get_parent(),
		player.global_position + Vector2(0.0, -40.0),
		"%s%s" % [String(a.get("ico", "")), String(a.get("name", id))], col, 16)
	Sfx.play("level_up")
	EventBus.screen_shake.emit(6.0)

## 按世界坐标找敌人：status_applied 信号只带坐标不带节点引用，缠藤结需要目标本体
func _enemy_at(pos: Vector2):
	for e in Combat.enemies_near(pos, Combat.MAX_ENTITY_RADIUS):
		if e.is_queued_for_deletion() or float(e.flee) > 0.0:
			continue
		if pos.distance_to(e.global_position) <= float(e.radius) + 2.0:
			return e
	return null
