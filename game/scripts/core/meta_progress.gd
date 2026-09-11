extends Node
## 局外成长（Meta Progress）：土豆精华 + 天赋树，跨局持久化 user://meta_progress.json
## 精华获取：每局按积分/波次折算，死亡/通关结算，永不清零
## 天赋生效：开局（main._ready 新局分支）一次性应用到 player.stats / GameState

const SAVE_PATH := "user://meta_progress.json"

## 天赋树：5 系 × 3 级。cost 为每级价格（等差递增由公式算）。
## effect 字段 = 开局应用方式：
##   stats:直接叠加到 player.stats / gold:开局材料 / reroll:商店刷新折扣 / slot:武器槽+1
const TALENTS := {
	"vitality": { "name": "生命强化", "ico": "❤", "desc": "最大生命 +15 / 级", "max_lv": 3,
		"base_cost": 60, "cost_step": 40, "effect": { "stats": { "max_hp": 15.0 } } },
	"power": { "name": "力量觉醒", "ico": "⚔", "desc": "伤害 +6% / 级", "max_lv": 3,
		"base_cost": 80, "cost_step": 50, "effect": { "stats": { "dmg_mult": 0.06 } } },
	"fortune": { "name": "财运亨通", "ico": "💰", "desc": "开局材料 +40 / 级", "max_lv": 3,
		"base_cost": 70, "cost_step": 40, "effect": { "gold": 40 } },
	"haggler": { "name": "砍价大师", "ico": "🛒", "desc": "商店刷新费 -12% / 级", "max_lv": 3,
		"base_cost": 60, "cost_step": 40, "effect": { "reroll": 0.12 } },
	"arsenal": { "name": "军火专家", "ico": "🎒", "desc": "武器槽 +1（仅 1 级）", "max_lv": 1,
		"base_cost": 400, "cost_step": 0, "effect": { "slot": 1 } },
}

## 门派专属天赋：5 门派 × 3 级，仅对对应门派角色生效（开局按 GameState.character_id 判断）。
## 与通用天赋（TALENTS，全员生效）互补：这里堆「门派的特色深度」。
## character 字段是该门派的唯一代表角色；effect.stats 键必须落在 player.stats 已知键内。
const SECT_TALENTS := {
	"fire": { "name": "焚天门", "ico": "🔥", "character": "pyromancer",
		"desc": "状态伤害 +15% · 异常持续 +10% / 级", "max_lv": 3,
		"base_cost": 130, "cost_step": 90,
		"effect": { "stats": { "status_dmg_mult": 0.15, "status_dur_mult": 0.10 } } },
	"wood": { "name": "青囊谷", "ico": "🌿", "character": "druid",
		"desc": "异常扩散 +15% · 异常命中 +5% / 级", "max_lv": 3,
		"base_cost": 130, "cost_step": 90,
		"effect": { "stats": { "status_spread": 0.15, "status_chance": 0.05 } } },
	"metal": { "name": "太白剑阁", "ico": "⚔", "character": "swordmaster",
		"desc": "斩击范围 +12% · 暴击伤害 +15% / 级", "max_lv": 3,
		"base_cost": 130, "cost_step": 90,
		"effect": { "stats": { "melee_range_bonus": 0.12, "crit_mult": 0.15 } } },
	"water": { "name": "沧海门", "ico": "💧", "character": "tidecaller",
		"desc": "异常持续 +15% · 移速 +4% / 级", "max_lv": 3,
		"base_cost": 130, "cost_step": 90,
		"effect": { "stats": { "status_dur_mult": 0.15, "speed_mult": 0.04 } } },
	"earth": { "name": "厚土宗", "ico": "⛰", "character": "guardian",
		"desc": "最大生命 +20 · 护甲 +1 / 级", "max_lv": 3,
		"base_cost": 130, "cost_step": 90,
		"effect": { "stats": { "max_hp": 20.0, "armor": 1.0 } } },
}

var essence := 0            # 当前土豆精华
var total_earned := 0       # 历史累计（展示用）
var talent_levels := {}     # 通用天赋 id -> 已购等级
var sect_levels := {}       # 门派天赋 id -> 已购等级
var _path := SAVE_PATH      # 测试可切换到隔离路径

func _ready() -> void:
	_load()

# ---------------- 查询 ----------------

func talent_level(id: String) -> int:
	return int(talent_levels.get(id, 0))

func talent_cost(id: String) -> int:
	var t: Dictionary = TALENTS.get(id, {})
	var lv := talent_level(id)
	return int(t.get("base_cost", 0)) + int(t.get("cost_step", 0)) * lv

## 某系天赋效果数值合计（如 stats 内某键 / gold / reroll）
func effect_sum(effect_key: String, stat_key: String = "") -> float:
	var total := 0.0
	for id in talent_levels:
		var t: Dictionary = TALENTS.get(id, {})
		var eff: Dictionary = t.get("effect", {})
		if not eff.has(effect_key):
			continue
		if effect_key == "stats":
			total += float(eff.stats.get(stat_key, 0.0)) * talent_level(id)
		else:
			total += float(eff[effect_key]) * talent_level(id)
	return total

# ---------------- 交易 ----------------

## 购买一级天赋；成功扣精华返回 true
func buy_talent(id: String) -> bool:
	if not TALENTS.has(id):
		return false
	var t: Dictionary = TALENTS[id]
	var lv := talent_level(id)
	if lv >= int(t.max_lv):
		return false
	var cost := talent_cost(id)
	if essence < cost:
		return false
	essence -= cost
	talent_levels[id] = lv + 1
	_save()
	return true

# ---------------- 门派天赋 ----------------

func sect_level(id: String) -> int:
	return int(sect_levels.get(id, 0))

func sect_cost(id: String) -> int:
	var t: Dictionary = SECT_TALENTS.get(id, {})
	var lv := sect_level(id)
	return int(t.get("base_cost", 0)) + int(t.get("cost_step", 0)) * lv

## 该角色所属门派 id（非门派角色返回空串）
func sect_for(character_id: String) -> String:
	for sid in SECT_TALENTS:
		if String(SECT_TALENTS[sid].get("character", "")) == character_id:
			return String(sid)
	return ""

## 购买一级门派天赋；成功扣精华返回 true
func buy_sect(id: String) -> bool:
	if not SECT_TALENTS.has(id):
		return false
	var t: Dictionary = SECT_TALENTS[id]
	var lv := sect_level(id)
	if lv >= int(t.max_lv):
		return false
	var cost := sect_cost(id)
	if essence < cost:
		return false
	essence -= cost
	sect_levels[id] = lv + 1
	_save()
	return true

## 局末结算精华：无尽按积分 8%、标准通关按波次 60/波；最少 5
func grant_run_essence(score: int, wave: int, endless: bool) -> int:
	var amount := 5
	if endless:
		amount = maxi(amount, int(float(score) * 0.08))
	else:
		amount = maxi(amount, wave * 60)
	essence += amount
	total_earned += amount
	_save()
	return amount

## 成就奖励等外部来源发放精华（与局末结算共用累计口径）
func grant_essence(amount: int) -> void:
	if amount <= 0:
		return
	essence += amount
	total_earned += amount
	_save()

# ---------------- 开局应用 ----------------

## 新局开始时应用全部天赋（main 新局分支调用；player 属性已就绪）
func apply_on_run_start(player: Node) -> void:
	for id in talent_levels:
		var lv := talent_level(id)
		if lv <= 0:
			continue
		var eff: Dictionary = TALENTS[id].get("effect", {})
		if eff.has("stats"):
			for k in eff.stats:
				player.stats[k] = float(player.stats.get(k, 0.0)) + float(eff.stats[k]) * lv
		if eff.has("gold"):
			GameState.add_materials(int(eff.gold) * lv)
	# 门派专属：只对当前角色的门派生效（其余门派的等级不参与本局）
	var sid := sect_for(GameState.character_id)
	var slv := sect_level(sid)
	if sid != "" and slv > 0:
		var seff: Dictionary = SECT_TALENTS[sid].get("effect", {})
		if seff.has("stats"):
			for k in seff.stats:
				player.stats[k] = float(player.stats.get(k, 0.0)) + float(seff.stats[k]) * slv
	# stats 类天赋可能推高上限，同步当前血量
	player.hp = player.stats.max_hp
	player._sanitize_stats()
	player.queue_redraw()

## 军火专家：武器槽上限（动态计算，非开局应用）
## 自定义开局规则可覆盖基础槽位数（RunRules.weapon_slots_total 内部处理 active 判断），
## 天赋加成仍然叠加 —— 全项目 11 处调用点因此自动感知规则，无需各自改动
func weapon_slots() -> int:
	return RunRules.weapon_slots_total()

# ---------------- 持久化 ----------------

func _load() -> void:
	essence = 0
	total_earned = 0
	talent_levels = {}
	sect_levels = {}
	if not FileAccess.file_exists(_path):
		return
	var f := FileAccess.open(_path, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	var parse_err := json.parse(f.get_as_text())
	f.close()
	if parse_err != OK or typeof(json.data) != TYPE_DICTIONARY:
		push_warning("MetaProgress: 存档损坏，已重置")
		return
	var d: Dictionary = json.data
	essence = _int_in(d.get("essence"), 0, 2_000_000_000)
	total_earned = _int_in(d.get("total_earned"), 0, 2_000_000_000)
	var raw: Variant = d.get("talents", {})
	if typeof(raw) == TYPE_DICTIONARY:
		for id in raw:
			if TALENTS.has(id):
				var lv := _int_in(raw[id], 0, int(TALENTS[id].max_lv))
				if lv > 0:
					talent_levels[id] = lv
	var raw_sect: Variant = d.get("sect_talents", {})
	if typeof(raw_sect) == TYPE_DICTIONARY:
		for id in raw_sect:
			if SECT_TALENTS.has(id):
				var lv2 := _int_in(raw_sect[id], 0, int(SECT_TALENTS[id].max_lv))
				if lv2 > 0:
					sect_levels[id] = lv2

func _save() -> void:
	var dir := _path.get_base_dir()
	var dir_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		push_warning("MetaProgress: 无法创建目录 " + dir)
		return
	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f == null:
		push_warning("MetaProgress: 无法写入 " + _path)
		return
	f.store_string(JSON.stringify({
		"essence": essence, "total_earned": total_earned, "talents": talent_levels,
		"sect_talents": sect_levels }))
	f.close()

## 仅供自动化测试：改用隔离路径（避免测试结算覆盖本机 user://meta_progress.json）
func set_storage_path_for_tests(path: String) -> void:
	_path = path

func reset_storage_path_after_tests() -> void:
	_path = SAVE_PATH

## 仅供自动化测试重置
func reset_for_tests() -> void:
	essence = 0
	total_earned = 0
	talent_levels = {}
	sect_levels = {}

func _int_in(value: Variant, minimum: int, maximum: int) -> int:
	if (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) \
			and is_finite(float(value)) and float(value) == floorf(float(value)) \
			and float(value) >= float(minimum) and float(value) <= float(maximum):
		return int(value)
	return minimum
