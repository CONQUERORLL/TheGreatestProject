extends Node
## ============================================================
## 唯一配置源 CONFIG —— 从 Web 原型（index.html, brotato-lite-v1.0）1:1 移植
## 数值调整只改这里；后续可迁移为 resources/ 下的 .tres 资源
## ============================================================

const RULESET_ID := "brotato-lite-v1.0"

const WORLD := { "w": 1600.0, "h": 1600.0 }

const PLAYER := {
	"radius": 16.0, "accel": 1500.0, "base_speed": 742.0,
	"max_hp": 100.0, "regen": 0.0, "armor": 0.0, "dodge": 0.0,
	"dmg_mult": 1.0, "as_mult": 1.0, "crit_ch": 0.05, "crit_mult": 2.0,
	"speed_mult": 1.0, "pickup_range": 95.0, "harvesting": 0.0, "lifesteal": 0.0,
	"iframes": 0.45, "touch_tick": 0.6,
}

## ============================================================
## 状态效果（异常状态）—— 数据驱动，武器/道具/升级只引用状态 id
## 字段说明：
##   duration       基础持续时间（秒）
##   tick           伤害跳数间隔（0 = 无持续伤害）
##   dot_scale      每跳伤害 = 施加时伤害 × dot_scale × 层数
##   dot_max_hp_pct 每跳伤害 = 目标最大生命 × 该比例 × 层数（优先于 dot_scale）
##   speed_mult     持续期间移速倍率（0 = 完全定身）
##   dmg_taken_mult 持续期间受到伤害倍率（冰冻易伤）
##   stack_max      最大叠层；重复施加叠加层数并刷新时长
## 施加入口：Enemy.apply_status() / Enemy.apply_hit_roll()；敌人字段 status_resist 可减免时长
## ============================================================
const STATUS := {
	"burn": { "name": "燃烧", "ico": "🔥", "color": "#ff7a3c",
		"desc": "持续伤害，最多 5 层", "duration": 3.0, "tick": 0.5, "dot_scale": 0.18,
		"stack_max": 5, "speed_mult": 1.0, "dmg_taken_mult": 1.0 },
	"poison": { "name": "中毒", "ico": "🧪", "color": "#7ec850",
		"desc": "按最大生命百分比掉血", "duration": 4.0, "tick": 0.8, "dot_max_hp_pct": 0.008,
		"stack_max": 5, "speed_mult": 1.0, "dmg_taken_mult": 1.0 },
	"bleed": { "name": "流血", "ico": "🩸", "color": "#e0564f",
		"desc": "持续伤害，高频武器叠加快", "duration": 4.0, "tick": 0.6, "dot_scale": 0.12,
		"stack_max": 6, "speed_mult": 1.0, "dmg_taken_mult": 1.0 },
	"freeze": { "name": "冰冻", "ico": "❄", "color": "#8fd8ff",
		"desc": "定身，受到伤害 +25%", "duration": 1.1, "tick": 0.0, "dot_scale": 0.0,
		"stack_max": 1, "speed_mult": 0.0, "dmg_taken_mult": 1.25 },
	"slow": { "name": "减速", "ico": "🐌", "color": "#b9a6ff",
		"desc": "移速降低 45%", "duration": 2.6, "tick": 0.0, "dot_scale": 0.0,
		"stack_max": 1, "speed_mult": 0.55, "dmg_taken_mult": 1.0 },
	"stun": { "name": "眩晕", "ico": "💫", "color": "#ffd24a",
		"desc": "短暂无法行动", "duration": 0.9, "tick": 0.0, "dot_scale": 0.0,
		"stack_max": 1, "speed_mult": 0.0, "dmg_taken_mult": 1.0 },
}

static func status_cfg(id: String) -> Dictionary:
	return STATUS.get(id, {})

static func status_ids() -> Array:
	return STATUS.keys()

## ============================================================
## 五行归属映射 —— 每个状态归属一个五行（金木水火土）
## 用于五行相生相克反应系统
## ============================================================
const STATUS_ELEMENT := {
	"burn": "fire",      # 火
	"poison": "wood",    # 木
	"bleed": "metal",    # 金
	"freeze": "water",   # 水
	"slow": "water",     # 水
	"stun": "earth",     # 土
}

## 五行集合（字母序）：REACTIONS 的 key = 两五行按本表顺序拼接
const ELEMENTS := ["earth", "fire", "metal", "water", "wood"]

## 五行配色（反应粒子 / 中央提示 / 图鉴与 HUD 反应表共用）
## 除金之外均沿用对应状态色，便于玩家建立 状态→五行 映射
const ELEMENT_COLOR := {
	"wood": "#7ec850",   # 同中毒
	"fire": "#ff7a3c",   # 同燃烧
	"earth": "#ffd24a",  # 同眩晕
	"metal": "#dfe6f0",  # 金：银白（与流血红区分，避免与火反应混淆）
	"water": "#8fd8ff",  # 同冰冻
}

## 五行中文名（HUD / 图鉴展示）
const ELEMENT_NAME := {
	"wood": "木", "fire": "火", "earth": "土", "metal": "金", "water": "水",
}

static func get_element(status_id: String) -> String:
	return String(STATUS_ELEMENT.get(status_id, ""))

## 两五行 → 反应表 key；同元素/非法元素返回 ""（无反应）
## 排序保证 (a,b) 与 (b,a) 得到同一 key，反应无方向性
static func reaction_key(element_a: String, element_b: String) -> String:
	if element_a == element_b or not ELEMENTS.has(element_a) \
			or not ELEMENTS.has(element_b):
		return ""
	var pair := [element_a, element_b]
	pair.sort()
	return String(pair[0]) + "+" + String(pair[1])

## ============================================================
## 五行反应表 —— 相生（增强）+ 相克（爆发）
## 相生 generate：不消耗层数，温和增强（加层/延时/提伤/扩散）
## 相克 overcome：消耗层数，爆发伤害（AOE/处决/破甲/DoT 翻倍）
## key = 两五行按 ELEMENTS 字母序拼接（如木生火 = "fire+wood"）
## 运行时查询走 Registry.find_reaction()，使 mod 可注册/覆盖反应
## ============================================================
const REACTIONS := {
	# ---- 相生反应（5 种）----
	"fire+wood": {
		"id": "wood_fire", "name": "木生火", "ico": "🌿🔥",
		"type": "generate", "rarity": "common",
		"desc": "中毒 + 燃烧 → 燃烧层数+1，持续时间延长 50%",
		"effect": {"add_stacks": {"burn": 1}, "duration_mult": {"burn": 1.5}},
		"sfx": "reaction_wood_fire", "shake": 1.6,
	},
	"earth+fire": {
		"id": "fire_earth", "name": "火生土", "ico": "🔥⛰",
		"type": "generate", "rarity": "common",
		"desc": "燃烧 + 眩晕 → 眩晕延长 0.5s，燃烧伤害+30%",
		"effect": {"duration_add": {"stun": 0.5}, "dmg_mult": {"burn": 1.3}},
		"sfx": "reaction_fire_earth", "shake": 1.6,
	},
	"earth+metal": {
		"id": "earth_metal", "name": "土生金", "ico": "⛰⚔",
		"type": "generate", "rarity": "rare",
		"desc": "眩晕 + 流血 → 流血层数+2，眩晕期间流血必暴击",
		"effect": {"add_stacks": {"bleed": 2}, "crit_guarantee": {"bleed": true}},
		"sfx": "reaction_earth_metal", "shake": 2.0,
	},
	"metal+water": {
		"id": "metal_water", "name": "金生水", "ico": "⚔💧",
		"type": "generate", "rarity": "rare",
		"desc": "流血 + 冰冻/减速 → 冰冻延长 0.3s，流血伤害转为冰伤",
		"effect": {"duration_add": {"freeze": 0.3}, "convert_dmg": {"bleed": "freeze"}},
		"sfx": "reaction_metal_water", "shake": 2.0,
	},
	"water+wood": {
		"id": "water_wood", "name": "水生木", "ico": "💧🌿",
		"type": "generate", "rarity": "epic",
		"desc": "冰冻/减速 + 中毒 → 中毒扩散到周围敌人（半径 100）",
		"effect": {"spread": {"poison": 100.0}},
		"sfx": "reaction_water_wood", "shake": 2.2,
	},
	# ---- 相克反应（5 种）----
	"earth+wood": {
		"id": "wood_earth", "name": "木克土", "ico": "🌿⛰",
		"type": "overcome", "rarity": "rare",
		"desc": "中毒 + 眩晕 → 消耗双方，AOE 伤害（半径 100，状态强度×2）",
		"effect": {"consume": {"poison": 1, "stun": 1}, "aoe_dmg_scale": 2.0, "aoe_radius": 100.0},
		"sfx": "reaction_wood_earth", "shake": 3.0,
	},
	"earth+water": {
		"id": "earth_water", "name": "土克水", "ico": "⛰💧",
		"type": "overcome", "rarity": "legendary",
		"desc": "眩晕 + 冰冻/减速 → 消耗双方，目标碎裂（血量<20% 直接死亡）",
		"effect": {"consume": {"stun": 1, "freeze": 1, "slow": 1}, "execute_threshold": 0.20},
		"sfx": "reaction_earth_water", "shake": 5.0,
	},
	"fire+water": {
		"id": "fire_water", "name": "水克火 · 蒸汽爆炸", "ico": "💧🔥",
		"type": "overcome", "rarity": "rare",
		"desc": "冰冻/减速 + 燃烧 → 消耗双方，蒸汽爆炸（半径 120 AOE 伤害×2.5）",
		"effect": {"consume": {"freeze": 1, "slow": 1, "burn": 2}, "aoe_dmg_scale": 2.5, "aoe_radius": 120.0},
		"sfx": "reaction_fire_water", "shake": 4.0,
	},
	"fire+metal": {
		"id": "fire_metal", "name": "火克金", "ico": "🔥⚔",
		"type": "overcome", "rarity": "epic",
		"desc": "燃烧 + 流血 → 消耗双方，目标熔金（受伤+50%，持续 3s）",
		"effect": {"consume": {"burn": 2, "bleed": 1}, "armor_break": 0.5, "armor_break_duration": 3.0},
		"sfx": "reaction_fire_metal", "shake": 3.5,
	},
	"metal+wood": {
		"id": "metal_wood", "name": "金克木 · 败血症", "ico": "⚔🌿",
		"type": "overcome", "rarity": "mythic",
		"desc": "流血 + 中毒 → 消耗双方，败血症（持续伤害翻倍，持续 4s）",
		"effect": {"consume": {"bleed": 1, "poison": 1}, "dot_mult": 2.0, "dot_duration": 4.0},
		"sfx": "reaction_metal_wood", "shake": 4.5,
	},
}

## 内置反应查询（mod 内容需走 Registry.find_reaction）
static func get_reaction(status_a: String, status_b: String) -> Dictionary:
	return REACTIONS.get(reaction_key(get_element(status_a), get_element(status_b)), {})

## ============================================================
## 五行反应伤害护栏（Phase 5 平衡性）
## 约束：单次相克爆发对单个目标的伤害 ≤「玩家单次命中伤害 × 该倍率」。
## 参考值由状态携带的 power 反推——power 就是施加该状态时那次命中的玩家伤害，
## 因此这个上限与玩家当前的构筑强度同步，不会出现「后期反应伤害形同虚设」。
##
## 内置相克的等效倍率（层数 × aoe_dmg_scale）最高约 10×：
##   水克火 = (燃烧2 + 冰冻1 + 减速1) × 2.5 = 10×
## 故取 12× 作为护栏：只砍掉「异常叠层被堆到极端」时的失控爆发（例如多层燃烧 + 水克火），
## 不改动正常手感。若封闭测试反馈「异常流仍然无敌」，把这个值下调到 3.0 即可——
## 那是总计划里更保守的口径，会明显削弱相克爆发，属于需要实测手感再定的取舍。
## ============================================================
const REACTION_BURST_CAP_MULT := 12.0

## 把法宝 patch 应用到反应 effect 上，返回新字典（不改原数据）
##   set：整键覆盖（字典值也是整体替换）
##   add：数值相加；字典值按子键合并（缺失则新建）；类型不兼容时退化为覆盖
## 纯函数：Registry 注册校验与 ArtifactSystem 运行时共用，保证“验的就是跑的”
static func apply_patch(base: Variant, patch: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if typeof(base) == TYPE_DICTIONARY:
		out = (base as Dictionary).duplicate(true)
	for op in patch:
		if typeof(patch[op]) != TYPE_DICTIONARY:
			continue
		var delta: Dictionary = patch[op]
		if String(op) == "set":
			out.merge(delta, true)
			continue
		if String(op) != "add":
			continue
		for k in delta:
			if typeof(delta[k]) == TYPE_DICTIONARY:
				var sub: Dictionary = {}
				if typeof(out.get(k)) == TYPE_DICTIONARY:
					sub = (out[k] as Dictionary).duplicate(true)
				sub.merge(delta[k], true)
				out[k] = sub
			elif out.has(k) and _is_number(out[k]) and _is_number(delta[k]):
				out[k] = float(out[k]) + float(delta[k])
			else:
				out[k] = delta[k]
	return out

static func _is_number(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT

## 武器：dmg 基础伤害，cd 基础冷却秒；近战用 range / swing_arc
## evolve_need：持有同名武器达到该数量，波末自动合成为 evolve_to（吸血鬼幸存者式）
const WEAPONS := {
	"pistol": { "name": "手枪", "ico": "🔫", "attack_type": "projectile", "sfx": "shoot_pistol", "cd": 0.55, "dmg": 12.0, "bspeed": 540.0, "rarity": "common", "evolve_need": 4, "evolve_to": "pistol_ex", "desc": "稳定单体远程" },
	"smg": { "name": "冲锋枪", "ico": "💢", "attack_type": "projectile", "sfx": "shoot_smg", "cd": 0.16, "dmg": 5.0, "bspeed": 600.0, "spread": 0.13, "rarity": "rare", "evolve_need": 4, "evolve_to": "smg_ex", "desc": "极快射速，轻微散射" },
	"shotgun": { "name": "霰弹枪", "ico": "💥", "attack_type": "projectile", "sfx": "shoot_shotgun", "cd": 0.90, "dmg": 7.0, "bspeed": 480.0, "pellets": 5, "arc": 0.7, "bullet_life": 0.55, "shake": 2.0, "rarity": "rare", "evolve_need": 3, "evolve_to": "shotgun_ex", "desc": "一次射出5发扇形弹丸" },
	"knife": { "name": "砍刀", "ico": "🔪", "attack_type": "melee", "sfx": "shoot_knife", "cd": 0.38, "dmg": 16.0, "range": 82.0, "swing_arc": 1.5, "status": "bleed", "status_chance": 0.30, "rarity": "common", "evolve_need": 4, "evolve_to": "blade_ex", "desc": "近战弧形挥砍，概率造成流血" },
	"rocket": { "name": "火箭筒", "ico": "🚀", "attack_type": "projectile", "sfx": "shoot_rocket", "cd": 1.30, "dmg": 34.0, "bspeed": 380.0, "splash": 88.0, "shake": 2.5, "status": "burn", "status_chance": 0.45, "rarity": "epic", "desc": "命中范围爆炸 AOE，概率点燃" },
	"sniper": { "name": "狙击枪", "ico": "🎯", "attack_type": "projectile", "sfx": "shoot_pistol", "cd": 1.55, "dmg": 58.0, "bspeed": 920.0, "bullet_life": 1.4, "shake": 1.5, "status": "bleed", "status_chance": 0.35, "rarity": "epic", "desc": "一发入魂的超远距重击，概率造成流血" },
	"blade": { "name": "太刀", "ico": "🗡", "attack_type": "melee", "sfx": "shoot_knife", "cd": 0.50, "dmg": 30.0, "range": 120.0, "swing_arc": 1.9, "status": "bleed", "status_chance": 0.45, "rarity": "epic", "desc": "刀身更长的大开大合宽弧重斩，高概率造成流血" },
	# ---- 状态效果武器（数据驱动：status = Config.STATUS 键） ----
	"flamethrower": { "name": "火焰喷射器", "ico": "🔥", "attack_type": "projectile", "sfx": "shoot_smg", "cd": 0.10, "dmg": 4.0, "bspeed": 300.0, "spread": 0.34, "bullet_life": 0.34, "status": "burn", "status_chance": 0.85, "rarity": "rare", "desc": "短程火舌，高频叠加燃烧" },
	"frost_staff": { "name": "霜冻法杖", "ico": "❄", "attack_type": "projectile", "sfx": "shoot_rocket", "cd": 0.80, "dmg": 9.0, "bspeed": 420.0, "splash": 58.0, "status": "freeze", "status_chance": 0.55, "rarity": "epic", "desc": "范围冰冻定身，冻结目标受到额外伤害" },
	"venom_dagger": { "name": "毒牙匕首", "ico": "🐍", "attack_type": "melee", "sfx": "shoot_knife", "cd": 0.42, "dmg": 12.0, "range": 88.0, "swing_arc": 1.6, "status": "poison", "status_chance": 0.70, "rarity": "rare", "desc": "淬毒近战，按最大生命持续掉血" },
	# ---- Phase 2 主题包新增（8 把，补齐五行状态覆盖） ----
	"thunder_gong": { "name": "震雷法锣", "ico": "🔔", "attack_type": "projectile", "sfx": "shoot_rocket", "cd": 1.10, "dmg": 22.0, "bspeed": 340.0, "splash": 90.0, "status": "stun", "status_chance": 0.45, "status_stacks": 1, "shake": 2.5, "rarity": "epic", "desc": "锣声震荡，范围眩晕，控场利器" },
	"tar_whip": { "name": "沥青长鞭", "ico": "🕸", "attack_type": "melee", "sfx": "shoot_knife", "cd": 0.55, "dmg": 14.0, "range": 110.0, "swing_arc": 2.0, "status": "slow", "status_chance": 0.65, "status_stacks": 1, "rarity": "rare", "desc": "长鞭横扫，高频减速，牵制群敌" },
	"ember_fan": { "name": "赤焰折扇", "ico": "🪭", "attack_type": "projectile", "sfx": "shoot_smg", "cd": 0.70, "dmg": 10.0, "bspeed": 460.0, "pellets": 3, "arc": 0.55, "status": "burn", "status_chance": 0.50, "status_stacks": 1, "rarity": "rare", "desc": "扇形三射火舌，快速铺设燃烧" },
	"vine_lash": { "name": "青藤缠索", "ico": "🌱", "attack_type": "projectile", "sfx": "shoot_pistol", "cd": 0.90, "dmg": 13.0, "bspeed": 380.0, "splash": 60.0, "status": "poison", "status_chance": 0.55, "status_stacks": 2, "rarity": "rare", "desc": "藤蔓爆裂散毒，双层中毒叠加" },
	"gold_bell": { "name": "金铃破空", "ico": "🛎", "attack_type": "projectile", "sfx": "shoot_pistol", "cd": 0.85, "dmg": 26.0, "bspeed": 720.0, "bullet_life": 1.2, "status": "bleed", "status_chance": 0.55, "status_stacks": 2, "rarity": "epic", "desc": "金铃高速激射，双层流血叠加" },
	"frost_nova": { "name": "玄冰新星", "ico": "🧊", "attack_type": "projectile", "sfx": "shoot_rocket", "cd": 1.30, "dmg": 18.0, "bspeed": 320.0, "splash": 110.0, "status": "freeze", "status_chance": 0.40, "status_stacks": 1, "shake": 1.5, "rarity": "epic", "desc": "寒冰爆发大范围冰冻，冻结目标易伤" },
	"flame_jian": { "name": "火焰长剑", "ico": "🌋", "attack_type": "melee", "sfx": "shoot_knife", "cd": 0.48, "dmg": 24.0, "range": 118.0, "swing_arc": 2.2, "status": "burn", "status_chance": 0.75, "status_stacks": 3, "shake": 1.5, "rarity": "legendary", "desc": "剑身缠火，横扫三层燃烧，火系构筑顶点" },
	"chaos_hammer": { "name": "混沌重锤", "ico": "🔨", "attack_type": "melee", "sfx": "shoot_knife", "cd": 1.20, "dmg": 45.0, "range": 130.0, "swing_arc": 2.4, "status": "stun", "status_chance": 0.60, "status_stacks": 1, "shake": 4.0, "rarity": "mythic", "desc": "开天一锤，眩晕 + 高爆发伤害" },
	# ---- Phase 3 内容扩充（4 把：超重单发 / 双发连弩 / 冰系近战 / 佛门爆发） ----
	"railgun": { "name": "磁轨炮", "ico": "🛰", "attack_type": "projectile", "sfx": "shoot_pistol", "cd": 2.40, "dmg": 120.0, "bspeed": 1200.0, "bullet_life": 1.8, "shake": 4.0, "status": "bleed", "status_chance": 0.40, "status_stacks": 2, "rarity": "legendary", "desc": "蓄力后的一发贯穿重击，弹速拉满，命中附带双层流血" },
	"blight_bow": { "name": "疫病连弩", "ico": "🏹", "attack_type": "projectile", "sfx": "shoot_pistol", "cd": 0.70, "dmg": 9.0, "bspeed": 560.0, "pellets": 2, "arc": 0.18, "status": "poison", "status_chance": 0.50, "status_stacks": 1, "rarity": "rare", "desc": "每次双发，高频铺毒，按最大生命持续掉血" },
	"frost_hammer": { "name": "霜牙重锤", "ico": "🔨", "attack_type": "melee", "sfx": "shoot_knife", "cd": 1.30, "dmg": 48.0, "range": 122.0, "swing_arc": 2.6, "status": "freeze", "status_chance": 0.35, "status_stacks": 1, "shake": 3.0, "rarity": "epic", "desc": "范围重砸，概率冻结，冻结目标受到额外伤害" },
	"gold_scepter": { "name": "鎏金权杖", "ico": "🪄", "attack_type": "projectile", "sfx": "shoot_rocket", "cd": 1.10, "dmg": 28.0, "bspeed": 380.0, "splash": 105.0, "status": "stun", "status_chance": 0.30, "status_stacks": 1, "shake": 2.5, "rarity": "legendary", "desc": "范围震荡，伤害更高但眩晕概率低于震雷法锣" },
	# ---- 进化形态（不进商店池：shop_weight 极低但保持可注册校验；波末合成获得） ----
	"pistol_ex": { "name": "双管神射", "ico": "🔱", "attack_type": "projectile", "sfx": "shoot_pistol", "cd": 0.32, "dmg": 20.0, "bspeed": 680.0, "pellets": 2, "arc": 0.12, "rarity": "mythic", "shop_weight": 0.001, "desc": "进化：双联齐射，单发伤害 +67%" },
	"smg_ex": { "name": "蜂巢风暴", "ico": "🌪", "attack_type": "projectile", "sfx": "shoot_smg", "cd": 0.10, "dmg": 7.0, "bspeed": 640.0, "spread": 0.20, "pellets": 3, "arc": 0.5, "rarity": "mythic", "shop_weight": 0.001, "desc": "进化：三管齐喷的弹幕风暴" },
	"shotgun_ex": { "name": "毁灭炮", "ico": "💣", "attack_type": "projectile", "sfx": "shoot_shotgun", "cd": 0.75, "dmg": 12.0, "bspeed": 520.0, "pellets": 8, "arc": 1.1, "bullet_life": 0.6, "splash": 60.0, "shake": 3.0, "rarity": "legendary", "shop_weight": 0.001, "desc": "进化：8 弹丸 + 爆炸溅射" },
	"blade_ex": { "name": "斩魄刀", "ico": "⚔", "attack_type": "melee", "sfx": "shoot_knife", "cd": 0.34, "dmg": 42.0, "range": 145.0, "swing_arc": 2.4, "shake": 1.5, "rarity": "mythic", "shop_weight": 0.001, "desc": "进化：更长的刀身全域横扫，伤害 +162%" },
}

const WEAPON_SLOTS := 6
const WEAPON_SHOP_CHANCE := 0.42
const WEAPON_SHOP_WEIGHTS := { "pistol": 3.0, "smg": 2.4, "knife": 2.4, "shotgun": 1.6, "rocket": 0.8, "sniper": 0.7, "blade": 1.0, "flamethrower": 1.5, "frost_staff": 0.9, "venom_dagger": 1.4, "thunder_gong": 0.9, "tar_whip": 1.5, "ember_fan": 1.3, "vine_lash": 1.2, "gold_bell": 1.0, "frost_nova": 0.9, "flame_jian": 1.2, "chaos_hammer": 1.0, "railgun": 0.55, "blight_bow": 1.3, "frost_hammer": 0.85, "gold_scepter": 0.6, "pistol_ex": 0.0, "smg_ex": 0.0, "shotgun_ex": 0.0, "blade_ex": 0.0 }
const WEAPON_PRICES := { "pistol": 25, "smg": 35, "knife": 28, "shotgun": 42, "rocket": 60, "sniper": 75, "blade": 68, "flamethrower": 52, "frost_staff": 72, "venom_dagger": 48, "thunder_gong": 72, "tar_whip": 42, "ember_fan": 46, "vine_lash": 48, "gold_bell": 74, "frost_nova": 78, "flame_jian": 145, "chaos_hammer": 105, "railgun": 250, "blight_bow": 52, "frost_hammer": 92, "gold_scepter": 235, "pistol_ex": 30, "smg_ex": 30, "shotgun_ex": 30, "blade_ex": 30 }

## 敌人：W1 基础值；血量/伤害随波次缩放（见 wave_* 系列函数）
const ENEMIES := {
	"grunt": { "name": "追击者", "hp": 14.0, "speed": 88.0, "dmg": 8.0, "xp": 2, "mat": 2, "r": 14.0, "color": "#d9534f", "shape": "circle", "heart_chance": 0.04 },
	"runner": { "name": "冲锋者", "hp": 8.0, "speed": 168.0, "dmg": 6.0, "xp": 3, "mat": 2, "r": 11.0, "color": "#e8902a", "shape": "diamond", "heart_chance": 0.04 },
	"tank": { "name": "坦克", "hp": 46.0, "speed": 50.0, "dmg": 16.0, "xp": 8, "mat": 6, "r": 23.0, "color": "#8e5bbf", "shape": "circle", "heart_chance": 0.12 },
	"shooter": { "name": "射手", "hp": 12.0, "speed": 72.0, "dmg": 10.0, "xp": 5, "mat": 4, "r": 14.0, "color": "#3bbfae", "shape": "square", "keep_dist": 270.0, "shoot_cd": 2.2, "bspeed": 300.0, "heart_chance": 0.08 },
	"swarm": { "name": "蜂群幼体", "hp": 5.0, "speed": 118.0, "dmg": 4.0, "xp": 2, "mat": 1, "r": 8.0, "color": "#cdd94f", "shape": "circle", "heart_chance": 0.02 },
	"bomber": { "name": "自爆虫", "hp": 10.0, "speed": 150.0, "dmg": 14.0, "xp": 4, "mat": 3, "r": 12.0, "color": "#ff5e3a", "shape": "diamond", "heart_chance": 0.05 },
	"wizard": { "name": "蛊惑法师", "hp": 26.0, "speed": 66.0, "dmg": 12.0, "xp": 9, "mat": 6, "r": 16.0, "color": "#b05ae0", "shape": "circle", "keep_dist": 320.0, "shoot_cd": 1.7, "bspeed": 340.0, "heart_chance": 0.10 },
	"shadow": { "name": "暗影刺客", "hp": 18.0, "speed": 205.0, "dmg": 12.0, "xp": 6, "mat": 4, "r": 10.0, "color": "#3d4356", "shape": "diamond", "heart_chance": 0.05 },
	"guard": { "name": "重装卫兵", "hp": 120.0, "speed": 42.0, "dmg": 20.0, "xp": 14, "mat": 10, "r": 30.0, "color": "#5a6dbf", "shape": "square", "heart_chance": 0.18 },
	"chest_guard": { "name": "宝箱守卫", "hp": 90.0, "speed": 60.0, "dmg": 14.0, "xp": 12, "mat": 15, "r": 24.0, "color": "#c9a24a", "shape": "square", "heart_chance": 0.10 },
	# ---- Phase 2 主题包新增（10 敌人 + 3 BOSS，五行阵营） ----
	"fire_imp": { "name": "火鸦童子", "hp": 12.0, "speed": 175.0, "dmg": 7.0, "xp": 3, "mat": 2, "r": 11.0, "color": "#ff7a3c", "shape": "diamond", "heart_chance": 0.04, "status_resist": 0.30 },
	"fire_shaman": { "name": "赤焰巫师", "hp": 24.0, "speed": 62.0, "dmg": 11.0, "xp": 8, "mat": 5, "r": 15.0, "color": "#ff5e3a", "shape": "circle", "keep_dist": 300.0, "shoot_cd": 2.0, "bspeed": 320.0, "heart_chance": 0.08, "status_resist": 0.30 },
	"wood_sprite": { "name": "木灵幼芽", "hp": 18.0, "speed": 80.0, "dmg": 6.0, "xp": 3, "mat": 3, "r": 12.0, "color": "#7ec850", "shape": "circle", "heart_chance": 0.05, "status_resist": 0.30 },
	"vine_beast": { "name": "藤蔓妖", "hp": 30.0, "speed": 92.0, "dmg": 10.0, "xp": 6, "mat": 4, "r": 14.0, "color": "#5aa040", "shape": "diamond", "heart_chance": 0.06, "status_resist": 0.30 },
	"metal_puppet": { "name": "金傀武士", "hp": 42.0, "speed": 62.0, "dmg": 14.0, "xp": 7, "mat": 6, "r": 18.0, "color": "#dfe6f0", "shape": "square", "heart_chance": 0.10, "status_resist": 0.30 },
	"blade_monk": { "name": "刀锋武僧", "hp": 20.0, "speed": 190.0, "dmg": 13.0, "xp": 6, "mat": 4, "r": 11.0, "color": "#c0c8d4", "shape": "diamond", "heart_chance": 0.06, "status_resist": 0.30 },
	"water_nymph": { "name": "水泽鲛奴", "hp": 16.0, "speed": 68.0, "dmg": 8.0, "xp": 5, "mat": 4, "r": 13.0, "color": "#8fd8ff", "shape": "circle", "keep_dist": 280.0, "shoot_cd": 2.4, "bspeed": 280.0, "heart_chance": 0.06, "status_resist": 0.30 },
	"ice_witch": { "name": "玄冰女妖", "hp": 28.0, "speed": 58.0, "dmg": 12.0, "xp": 10, "mat": 7, "r": 16.0, "color": "#5aa8d8", "shape": "circle", "keep_dist": 320.0, "shoot_cd": 1.8, "bspeed": 340.0, "heart_chance": 0.10, "status_resist": 0.40 },
	"earth_golem": { "name": "土灵石俑", "hp": 75.0, "speed": 38.0, "dmg": 18.0, "xp": 12, "mat": 8, "r": 24.0, "color": "#ffd24a", "shape": "square", "heart_chance": 0.12, "status_resist": 0.30 },
	"stone_titan": { "name": "山岳巨人", "hp": 140.0, "speed": 32.0, "dmg": 24.0, "xp": 16, "mat": 12, "r": 30.0, "color": "#c8a030", "shape": "square", "heart_chance": 0.18, "status_resist": 0.40 },
	"boss": { "name": "巨型土豆王", "hp": 768000.0, "speed": 64.0, "dmg": 28.0, "xp": 60, "mat": 100, "r": 56.0, "color": "#b01e2e", "shape": "circle", "ring_cd": 2.2, "ring_count": 16, "bspeed": 260.0, "status_resist": 0.55, "heart_chance": 1.0 },
	"boss_spiral": { "name": "深渊织网者", "hp": 640000.0, "speed": 56.0, "dmg": 24.0, "xp": 60, "mat": 100, "r": 50.0, "color": "#7a3df0", "shape": "diamond", "ring_cd": 1.6, "ring_count": 6, "bspeed": 300.0, "spiral_mode": true, "status_resist": 0.55, "heart_chance": 1.0 },
	"boss_summoner": { "name": "腐土孵化者", "hp": 560000.0, "speed": 48.0, "dmg": 22.0, "xp": 60, "mat": 100, "r": 54.0, "color": "#3d8a3d", "shape": "square", "ring_cd": 3.0, "ring_count": 10, "bspeed": 240.0, "summon_cd": 4.5, "summon_type": "swarm", "summon_count": 6, "status_resist": 0.55, "heart_chance": 1.0 },
	"boss_phoenix": { "name": "焚天凤凰", "hp": 720000.0, "speed": 78.0, "dmg": 26.0, "xp": 60, "mat": 100, "r": 52.0, "color": "#ff5e3a", "shape": "diamond", "ring_cd": 1.8, "ring_count": 12, "bspeed": 320.0, "status_resist": 0.55, "heart_chance": 1.0 },
	"boss_leviathan": { "name": "沧溟蛟皇", "hp": 800000.0, "speed": 60.0, "dmg": 24.0, "xp": 60, "mat": 100, "r": 54.0, "color": "#5aa8d8", "shape": "circle", "ring_cd": 2.0, "ring_count": 18, "bspeed": 260.0, "summon_cd": 8.0, "summon_type": "water_nymph", "summon_count": 3, "status_resist": 0.55, "heart_chance": 1.0 },
	"boss_titan": { "name": "玄武岩王", "hp": 900000.0, "speed": 42.0, "dmg": 32.0, "xp": 60, "mat": 100, "r": 58.0, "color": "#c8a030", "shape": "square", "ring_cd": 2.4, "ring_count": 10, "bspeed": 220.0, "status_resist": 0.70, "heart_chance": 1.0 },
}

## BOSS 轮换池：标准第 10 波 / 无尽每 10 波，按种子随机轮换（每日挑战全服同 BOSS）
const BOSS_POOL := ["boss", "boss_spiral", "boss_summoner", "boss_phoenix", "boss_leviathan", "boss_titan"]

## BOSS id → 中文称号（HUD/横幅展示用）
const BOSS_TITLES := {
	"boss": "土豆之王 · 弹幕压制",
	"boss_spiral": "深渊织网者 · 螺旋封锁",
	"boss_summoner": "腐土孵化者 · 群海战术",
	"boss_phoenix": "焚天凤凰 · 烈焰风暴",
	"boss_leviathan": "沧溟蛟皇 · 寒潮召唤",
	"boss_titan": "玄武岩王 · 山岳镇压",
}

## 高难度精英替换池（难度 elite_chance 触发时从中抽取，W4+ 生效）
const ELITE_POOL := [
	{ "item": "guard", "w": 0.22 }, { "item": "wizard", "w": 0.22 },
	{ "item": "shadow", "w": 0.18 }, { "item": "bomber", "w": 0.14 },
	{ "item": "ice_witch", "w": 0.14 }, { "item": "stone_titan", "w": 0.10 },
]

## 事件波：每 4 波触发一次（波 3/7/11/15…，跳过 BOSS 波），从 3 种事件随机
## - treasure 宝箱守卫波：全场只刷宝箱守卫，清完必掉 1 件高品阶道具（紫/金/红加权）
## - hunt 精英狩猎波：少量精英怪 + 常规怪，波末存活精英数越少奖励材料越多
## - meteor 流星雨波：常规怪 + 天降流星（预警圈 0.9s 后砸落 AOE），考验走位
const EVENT_WAVE_INTERVAL := 4
const EVENT_WAVE_FIRST := 3
const METEOR_WARN_TIME := 0.9
const METEOR_DAMAGE := 22.0
const METEOR_RADIUS := 78.0
const METEOR_FALL_CD := 1.5

static func is_event_wave(w: int) -> bool:
	if w < EVENT_WAVE_FIRST or Config.is_boss_wave(w):
		return false
	return (w - EVENT_WAVE_FIRST) % EVENT_WAVE_INTERVAL == 0

## ---- 每日挑战（全服同局）：当日日期决定种子/角色/难度/BOSS ----
## 日期串（如 "2026-09-08"）→ 稳定哈希（FNV-1a 32 位）
static func daily_hash(date_str: String) -> int:
	var h := 0x811C9DC5
	for i in date_str.length():
		h = ((h ^ (date_str.unicode_at(i) & 0xFF)) * 0x01000193) & 0xFFFFFFFF
	return h

## 每日挑战的角色池。抽出来单独放，是为了让冒烟测试能断言「池子覆盖了全部已注册角色」——
## 之前它是 daily_setup 里的局部变量，新增角色忘了加进来时完全静默（新角色永远不出现在每日挑战）
const DAILY_CHARACTERS := ["potato", "berserker", "ranger", "gambler", "farmer", "vampire",
	"guardian", "pyromancer", "druid", "swordmaster", "tidecaller", "geomancer",
	"gunner", "artillery", "monk", "ascetic", "alchemist", "warlord"]

## 今日挑战配置：{seed, character_id, difficulty_id, boss_id}（全服一致）
static func daily_setup(date_str: String) -> Dictionary:
	var h := daily_hash(date_str)
	var chars: Array = DAILY_CHARACTERS
	var diffs := ["normal", "hard", "nightmare"]
	var pool: Array = BOSS_POOL.duplicate()
	return {
		"seed": h,
		"character_id": chars[h % chars.size()],
		"difficulty_id": diffs[(h >> 5) % diffs.size()],
		"boss_id": String(pool[(h >> 11) % pool.size()]),
	}

## 升级池（可重复叠加；effects 键 = player.stats 键，创意工坊数据驱动；
## 特例：heal_flat = 最大生命+立即回复同值，heal_pct = 立即回复最大生命百分比）
const UPGRADES := [
	{ "id": "hp", "ico": "❤", "name": "强壮", "desc": "最大生命 +18，并立即回复 18", "rarity": "common", "effects": { "heal_flat": 18.0 } },
	{ "id": "dmg", "ico": "⚔", "name": "蛮力", "desc": "伤害 +10%", "rarity": "common", "effects": { "dmg_mult": 0.10 } },
	{ "id": "as", "ico": "⚡", "name": "急速", "desc": "攻击速度 +8%", "rarity": "common", "effects": { "as_mult": 0.08 } },
	{ "id": "spd", "ico": "👟", "name": "飞毛腿", "desc": "移动速度 +8%", "rarity": "common", "effects": { "speed_mult": 0.08 } },
	{ "id": "crit", "ico": "🎯", "name": "锐利", "desc": "暴击率 +6%", "rarity": "rare", "effects": { "crit_ch": 0.06 } },
	{ "id": "critd", "ico": "✦", "name": "狂暴", "desc": "暴击伤害 +30%", "rarity": "rare", "effects": { "crit_mult": 0.30 } },
	{ "id": "armor", "ico": "🛡", "name": "坚甲", "desc": "护甲 +2（递减减伤）", "rarity": "rare", "effects": { "armor": 2.0 } },
	{ "id": "dodge", "ico": "🍃", "name": "灵巧", "desc": "闪避率 +6%", "rarity": "rare", "effects": { "dodge": 0.06 } },
	{ "id": "magnet", "ico": "🧲", "name": "磁力", "desc": "拾取范围 +35", "rarity": "common", "effects": { "pickup_range": 35.0 } },
	{ "id": "regen", "ico": "✚", "name": "再生", "desc": "生命回复 +0.6 / 秒", "rarity": "rare", "effects": { "regen": 0.6 } },
	{ "id": "harv", "ico": "🌾", "name": "丰收", "desc": "材料获取 +18%", "rarity": "rare", "effects": { "harvesting": 0.18 } },
	{ "id": "heal", "ico": "🥔", "name": "急救土豆", "desc": "立即回复 35% 最大生命", "rarity": "epic", "effects": { "heal_pct": 0.35 } },
	{ "id": "precision", "ico": "🔭", "name": "精密校准", "desc": "暴击率 +12%", "rarity": "mythic", "effects": { "crit_ch": 0.12 } },
	{ "id": "greed", "ico": "💰", "name": "贪婪之心", "desc": "材料获取 +50%", "rarity": "mythic", "effects": { "harvesting": 0.50 } },
	{ "id": "frenzy", "ico": "🎶", "name": "狂热节拍", "desc": "攻击速度 +18%", "rarity": "mythic", "effects": { "as_mult": 0.18 } },
	{ "id": "berserk", "ico": "💀", "name": "血之狂怒", "desc": "伤害 +35%", "rarity": "legendary", "effects": { "dmg_mult": 0.35 } },
	{ "id": "overdrive", "ico": "🔥", "name": "极限超频", "desc": "攻速 +25%，暴击伤害 +40%", "rarity": "legendary", "effects": { "as_mult": 0.25, "crit_mult": 0.40 } },
	{ "id": "titanheart", "ico": "🫀", "name": "泰坦心脏", "desc": "最大生命 +60（并回复 60），护甲 +3", "rarity": "legendary", "effects": { "heal_flat": 60.0, "armor": 3.0 } },
	# ---- 状态效果升级（异常流构筑） ----
	{ "id": "pyromancy", "ico": "🔥", "name": "纵火", "desc": "状态伤害 +25%", "rarity": "rare", "effects": { "status_dmg_mult": 0.25 } },
	{ "id": "lingering", "ico": "⏳", "name": "延烧", "desc": "异常持续时间 +30%", "rarity": "epic", "effects": { "status_dur_mult": 0.30 } },
	{ "id": "hex", "ico": "🕯", "name": "咒术", "desc": "异常命中率 +10%", "rarity": "epic", "effects": { "status_chance": 0.10 } },
	# ---- 武器向升级：只强化特定武器形态，属于「构筑向」而非泛用强化 ----
	# （这些键在角色特性里先出现，此处把它们开放给升级池，让构筑有成长路径）
	{ "id": "edge", "ico": "🗡", "name": "开刃", "desc": "斩击范围 +18%（近战武器）", "rarity": "rare", "effects": { "melee_range_bonus": 0.18 } },
	{ "id": "barrel", "ico": "🏹", "name": "加长枪管", "desc": "弹丸射程 +20%（投射武器）", "rarity": "rare", "effects": { "bullet_range_bonus": 0.20 } },
	{ "id": "velocity", "ico": "💨", "name": "高初速", "desc": "子弹速度 +20%，命中更跟手", "rarity": "rare", "effects": { "bullet_speed_bonus": 0.20 } },
	{ "id": "warhead", "ico": "💥", "name": "高爆装药", "desc": "爆炸范围 +20%（溅射武器：火箭筒 / 冰霜新星 / 震雷法锣…）", "rarity": "rare", "effects": { "aoe_radius_bonus": 0.20 } },
	# ---- 角色向升级：effects 刻意集中在**单一标签族**（近战范围 / 弹速射程 / 异常 / 残血 / 经济），
	# 于是对对应角色的亲和倍率天然高达 ×2.7~3.55，对无关角色接近不出现 ——
	# 不用新增「专属」机制，靠既有的 affinity 推导就形成了角色向内容池
	{ "id": "swordmanual", "ico": "📜", "name": "剑冢图谱", "desc": "斩击范围 +22%，暴击伤害 +60（近战构筑）", "rarity": "epic", "effects": { "melee_range_bonus": 0.22, "crit_mult": 0.60 } },
	{ "id": "ballistic", "ico": "📐", "name": "弹道校准", "desc": "子弹速度 +25%，弹丸射程 +18%（投射构筑）", "rarity": "epic", "effects": { "bullet_speed_bonus": 0.25, "bullet_range_bonus": 0.18 } },
	{ "id": "burningheart", "ico": "🔥", "name": "灼心诀", "desc": "命中时 12% 概率点燃，状态伤害 +35%", "rarity": "epic", "effects": { "on_hit_burn": 0.12, "status_dmg_mult": 0.35 } },
	{ "id": "frostmantra", "ico": "🧊", "name": "玄冰诀", "desc": "命中时 10% 概率冻结，异常持续 +45%", "rarity": "epic", "effects": { "on_hit_freeze": 0.10, "status_dur_mult": 0.45 } },
	{ "id": "bloodoath", "ico": "🩸", "name": "血战令", "desc": "生命越低伤害越高，濒死时最高 +30%", "rarity": "epic", "effects": { "low_hp_dmg_bonus": 0.30 } },
	{ "id": "harvestrite", "ico": "🌾", "name": "丰饶祭", "desc": "材料获取 +45%，拾取范围 +70", "rarity": "epic", "effects": { "harvesting": 0.45, "pickup_range": 70.0 } },
]

## 商店道具（被动 = 永久属性；effects 键 = player.stats 键，创意工坊数据驱动；
## i-hp 只加上限不立即回血，与原型一致）
const ITEMS := [
	{ "id": "i-hp", "ico": "🍅", "name": "番茄", "desc": "最大生命 +28", "price": 30, "rarity": "common", "effects": { "max_hp": 28.0 } },
	{ "id": "i-dmg", "ico": "🧨", "name": "弹药袋", "desc": "伤害 +14%", "price": 38, "rarity": "rare", "effects": { "dmg_mult": 0.14 } },
	{ "id": "i-as", "ico": "🔋", "name": "弹簧", "desc": "攻速 +12%", "price": 38, "rarity": "rare", "effects": { "as_mult": 0.12 } },
	{ "id": "i-spd", "ico": "👟", "name": "运动鞋", "desc": "移速 +10%", "price": 26, "rarity": "common", "effects": { "speed_mult": 0.10 } },
	{ "id": "i-crit", "ico": "🔭", "name": "瞄准镜", "desc": "暴击率 +10%", "price": 42, "rarity": "epic", "effects": { "crit_ch": 0.10 } },
	{ "id": "i-arm", "ico": "⚙", "name": "钢板", "desc": "护甲 +3", "price": 36, "rarity": "rare", "effects": { "armor": 3.0 } },
	{ "id": "i-dod", "ico": "🧥", "name": "斗篷", "desc": "闪避 +8%", "price": 32, "rarity": "rare", "effects": { "dodge": 0.08 } },
	{ "id": "i-mag", "ico": "🧲", "name": "大磁铁", "desc": "拾取范围 +55", "price": 22, "rarity": "common", "effects": { "pickup_range": 55.0 } },
	{ "id": "i-reg", "ico": "💊", "name": "再生器", "desc": "生命回复 +1.0 / 秒", "price": 42, "rarity": "epic", "effects": { "regen": 1.0 } },
	{ "id": "i-harv", "ico": "💰", "name": "金币袋", "desc": "材料获取 +25%", "price": 32, "rarity": "rare", "effects": { "harvesting": 0.25 } },
	{ "id": "i-ls", "ico": "🩸", "name": "血蛭", "desc": "每击杀 1 个敌人回复 1 点生命（可叠加）", "price": 48, "rarity": "epic", "effects": { "lifesteal": 1.0 } },
	# ---- 状态效果道具（on_hit_* = 命中时施加概率；status_dmg_mult = 持续伤害加成） ----
	{ "id": "i-ember", "ico": "🔥", "name": "余烬", "desc": "命中时 20% 概率点燃（伤害随攻击力）", "price": 44, "rarity": "rare", "effects": { "on_hit_burn": 0.20 } },
	{ "id": "i-venom", "ico": "🧪", "name": "毒囊", "desc": "命中时 20% 概率使目标中毒", "price": 44, "rarity": "rare", "effects": { "on_hit_poison": 0.20 } },
	{ "id": "i-hemo", "ico": "🩸", "name": "放血针", "desc": "命中时 25% 概率造成流血", "price": 40, "rarity": "rare", "effects": { "on_hit_bleed": 0.25 } },
	{ "id": "i-frost", "ico": "❄", "name": "霜核", "desc": "命中时 12% 概率冰冻目标", "price": 58, "rarity": "epic", "effects": { "on_hit_freeze": 0.12 } },
	{ "id": "i-tar", "ico": "🕸", "name": "沥青网", "desc": "命中时 18% 概率减速目标", "price": 42, "rarity": "rare", "effects": { "on_hit_slow": 0.18 } },
	{ "id": "i-thunder", "ico": "🌩", "name": "雷击石", "desc": "命中时 8% 概率眩晕目标", "price": 66, "rarity": "epic", "effects": { "on_hit_stun": 0.08 } },
	{ "id": "i-plague", "ico": "☠", "name": "瘟疫之心", "desc": "中毒伤害 +60%，中毒目标死亡时传染", "price": 175, "rarity": "mythic", "effects": { "status_dmg_mult": 0.60, "status_spread": 1.0 } },
	{ "id": "i-pyro", "ico": "🌋", "name": "熔火核心", "desc": "状态伤害 +35%，异常持续时间 +25%", "price": 195, "rarity": "mythic", "effects": { "status_dmg_mult": 0.35, "status_dur_mult": 0.25 } },
	{ "id": "i-conductor", "ico": "⚡", "name": "异常导体", "desc": "异常命中率 +15%，状态伤害 +20%", "price": 230, "rarity": "legendary", "effects": { "status_chance": 0.15, "status_dmg_mult": 0.20 } },
	{ "id": "i-goldcore", "ico": "✨", "name": "黄金核心", "desc": "伤害 +25%，攻速 +15%", "price": 200, "rarity": "mythic", "effects": { "dmg_mult": 0.25, "as_mult": 0.15 } },
	{ "id": "i-fortress", "ico": "🏰", "name": "堡垒之心", "desc": "护甲 +6，最大生命 +45", "price": 185, "rarity": "mythic", "effects": { "armor": 6.0, "max_hp": 45.0 } },
	{ "id": "i-fortune", "ico": "🤑", "name": "财神金蟾", "desc": "材料获取 +80%，拾取范围 +80", "price": 170, "rarity": "mythic", "effects": { "harvesting": 0.80, "pickup_range": 80.0 } },
	{ "id": "i-bladesoul", "ico": "🗡", "name": "剑圣之魂", "desc": "暴击率 +15%，暴击伤害 +80%", "price": 210, "rarity": "mythic", "effects": { "crit_ch": 0.15, "crit_mult": 0.80 } },
	{ "id": "i-titan", "ico": "🏆", "name": "泰坦之力", "desc": "伤害 +45%，最大生命 +30", "price": 260, "rarity": "legendary", "effects": { "dmg_mult": 0.45, "max_hp": 30.0 } },
	{ "id": "i-gale", "ico": "🌪", "name": "风神羽靴", "desc": "移速 +35%，攻速 +30%，闪避 +10%", "price": 250, "rarity": "legendary", "effects": { "speed_mult": 0.35, "as_mult": 0.30, "dodge": 0.10 } },
	{ "id": "i-sanguine", "ico": "🧛", "name": "血族圣冠", "desc": "击杀回血 +3，生命回复 +2 / 秒", "price": 280, "rarity": "legendary", "effects": { "lifesteal": 3.0, "regen": 2.0 } },
	{ "id": "i-crown", "ico": "👑", "name": "王者桂冠", "desc": "伤害 +15%，攻速 +15%，暴击 +8%，暴伤 +50%", "price": 300, "rarity": "legendary", "effects": { "dmg_mult": 0.15, "as_mult": 0.15, "crit_ch": 0.08, "crit_mult": 0.50 } },
	# ---- Phase 3 内容扩充（8 件：低阶补位 3 + 带代价的中阶取舍 3 + 高阶 2） ----
	{ "id": "i-warden", "ico": "🛡", "name": "守望徽章", "desc": "护甲 +2，闪避 +4%", "price": 30, "rarity": "common", "effects": { "armor": 2.0, "dodge": 0.04 } },
	{ "id": "i-hunter", "ico": "📕", "name": "猎人手记", "desc": "暴击率 +7%，移速 +5%", "price": 28, "rarity": "common", "effects": { "crit_ch": 0.07, "speed_mult": 0.05 } },
	{ "id": "i-lodestone", "ico": "🧿", "name": "磁极核心", "desc": "拾取范围 +85，材料获取 +10%", "price": 32, "rarity": "common", "effects": { "pickup_range": 85.0, "harvesting": 0.10 } },
	{ "id": "i-thorn", "ico": "🌵", "name": "荆棘重铠", "desc": "生命 +45，护甲 +3；代价：移速 -5%", "price": 44, "rarity": "rare", "effects": { "max_hp": 45.0, "armor": 3.0, "speed_mult": -0.05 } },
	{ "id": "i-feather", "ico": "🪶", "name": "轻羽披风", "desc": "移速 +18%，闪避 +5%；代价：护甲 -2", "price": 40, "rarity": "rare", "effects": { "speed_mult": 0.18, "dodge": 0.05, "armor": -2.0 } },
	{ "id": "i-focus", "ico": "🔮", "name": "凝神宝珠", "desc": "攻速 +20%；代价：伤害 -8%", "price": 46, "rarity": "rare", "effects": { "as_mult": 0.20, "dmg_mult": -0.08 } },
	{ "id": "i-plaguevial", "ico": "⚗", "name": "疫病瓶", "desc": "命中时 25% 概率使目标中毒，状态伤害 +25%", "price": 72, "rarity": "epic", "effects": { "on_hit_poison": 0.25, "status_dmg_mult": 0.25 } },
	{ "id": "i-sunstone", "ico": "☀", "name": "日曜石", "desc": "生命回复 +1.6 / 秒，最大生命 +30", "price": 68, "rarity": "epic", "effects": { "regen": 1.6, "max_hp": 30.0 } },
	# ---- 武器向道具（Phase 3.5）：把「武器形态强化」做成可购买的构筑件 ----
	# 与泛用道具不同，这些只对特定武器形态生效 —— 买之前先想清楚自己在玩什么
	{ "id": "i-whetstone", "ico": "🪨", "name": "磨刀石", "desc": "斩击范围 +35%：近战刀光挥得更远，太刀/长剑尤其明显", "price": 58, "rarity": "epic", "effects": { "melee_range_bonus": 0.35 } },
	{ "id": "i-longbarrel", "ico": "🔩", "name": "铳匠长管", "desc": "弹丸射程 +35%：火焰喷射距离、弹药飞行距离同步拉长", "price": 62, "rarity": "epic", "effects": { "bullet_range_bonus": 0.35 } },
	{ "id": "i-frostcore", "ico": "🧊", "name": "霜核", "desc": "爆炸范围 +42%：冰冻、毒爆、火箭的覆盖面大幅提升", "price": 66, "rarity": "epic", "effects": { "aoe_radius_bonus": 0.42 } },
	{ "id": "i-accelerator", "ico": "⚙", "name": "高速膛线", "desc": "子弹速度 +38%，弹道更直更难被走位躲开", "price": 48, "rarity": "rare", "effects": { "bullet_speed_bonus": 0.38 } },
	{ "id": "i-venomsac", "ico": "☣", "name": "毒囊", "desc": "爆炸范围 +22%，异常持续时间 +20%", "price": 44, "rarity": "rare", "effects": { "aoe_radius_bonus": 0.22, "status_dur_mult": 0.20 } },
	# ---- 元素附魔向（Phase 3.6）：让**任意武器**都能挂上某种状态。
	# 与状态流 / 五行反应构筑天然关联，且因为用了 on_hit_* 键，
	# 会被 Config.entry_tags 自动打上对应元素标签 → 抽取时自动亲和（见 affinity_mult）
	{ "id": "i-emberdust", "ico": "🔥", "name": "火绒", "desc": "命中时 18% 概率点燃，状态伤害 +20%", "price": 50, "rarity": "rare", "effects": { "on_hit_burn": 0.18, "status_dmg_mult": 0.20 } },
	{ "id": "i-venomgland", "ico": "🐍", "name": "毒腺", "desc": "命中时 18% 概率使目标中毒，异常持续 +20%", "price": 50, "rarity": "rare", "effects": { "on_hit_poison": 0.18, "status_dur_mult": 0.20 } },
	{ "id": "i-bloodvial", "ico": "🩸", "name": "血瓶", "desc": "命中时 20% 概率造成流血，击杀回复 +1.5", "price": 52, "rarity": "rare", "effects": { "on_hit_bleed": 0.20, "lifesteal": 1.5 } },
	{ "id": "i-frostshard", "ico": "❄", "name": "霜片", "desc": "命中时 12% 概率冻结目标，异常持续 +15%", "price": 58, "rarity": "epic", "effects": { "on_hit_freeze": 0.12, "status_dur_mult": 0.15 } },
	{ "id": "i-thunderrod", "ico": "⚡", "name": "雷杵", "desc": "命中时 10% 概率眩晕目标，子弹速度 +15%", "price": 58, "rarity": "epic", "effects": { "on_hit_stun": 0.10, "bullet_speed_bonus": 0.15 } },
	# ---- 角色向道具：与元素附魔同一思路，但标签更集中（对对应角色的亲和倍率更高）----
	# 近战（太白剑客 / 无相武僧 / 百战军侯）/ 投射（游侠 / 弹雨枪手）/ 火（焚天祭司）/
	# 冰（沧海鲛人）/ 残血（狂战士 / 血族）/ 经济（收获者）各有 1 件
	{ "id": "i-swordcase", "ico": "🗡", "name": "剑匣", "desc": "斩击范围 +35%，暴击率 +6%", "price": 72, "rarity": "epic", "effects": { "melee_range_bonus": 0.35, "crit_ch": 0.06 } },
	{ "id": "i-calibrator", "ico": "🎯", "name": "校准仪", "desc": "弹丸射程 +30%，子弹速度 +20%", "price": 68, "rarity": "epic", "effects": { "bullet_range_bonus": 0.30, "bullet_speed_bonus": 0.20 } },
	{ "id": "i-pyrotalisman", "ico": "🧧", "name": "焚天符", "desc": "命中时 16% 概率点燃，状态伤害 +40%", "price": 74, "rarity": "epic", "effects": { "on_hit_burn": 0.16, "status_dmg_mult": 0.40 } },
	{ "id": "i-frostmirror", "ico": "🪞", "name": "霜心镜", "desc": "命中时 14% 概率冻结，异常持续 +50%", "price": 72, "rarity": "epic", "effects": { "on_hit_freeze": 0.14, "status_dur_mult": 0.50 } },
	{ "id": "i-ragecloak", "ico": "🧥", "name": "怒血披风", "desc": "濒死时最高 +28% 伤害，闪避 +5%", "price": 54, "rarity": "rare", "effects": { "low_hp_dmg_bonus": 0.28, "dodge": 0.05 } },
	{ "id": "i-luckypouch", "ico": "👝", "name": "聚宝囊", "desc": "材料获取 +50%，拾取范围 +60", "price": 48, "rarity": "rare", "effects": { "harvesting": 0.50, "pickup_range": 60.0 } },
]

## ============================================================
## 法宝（Phase 3）—— 触发式特效，区别于 ITEMS 的纯属性被动
## 每种限 1 件、无总上限；重复获得转化为 ARTIFACT_DUP_MATERIALS 材料
## 字段说明：
##   element  五行归属（ELEMENTS 之一），图鉴/商店分组与五行加成用
##   trigger  触发时机，必须是 ARTIFACT_TRIGGERS 之一
##   params   触发过滤条件：element / key（五行反应）/ status / hp_below
##   effect   动作载荷，键随 trigger 而变（见各条目行内注释）
## effect 载荷约定（ArtifactSystem 按存在的键分派）：
##   patch          改写五行反应效果本身：set 覆盖 / add 叠加合并。
##                  由 enemy.gd 在执行反应效果【之前】同步调用
##                  ArtifactSystem.patch_reaction_effect() 应用（信号太晚）
##   bonus_dmg_pct  对反应目标追加 = 玩家攻击力 × 该比例 的伤害
##   chance + apply_status + radius + stacks + duration
##                  概率对半径内敌人施加状态（凤凰翎/寒镜/潮汐珠）
##   stat + per_stack + stack_max + stack_reset
##                  叠层属性：stack_reset = "wave"（每波重置）/ "run"（仅局终重置）
##   dmg_mult       命中低血量目标时的伤害倍率（配合 params.hp_below）
##   heal_pct       按最大生命百分比回复（建木枝）
##   high_hp / high_hp_armor / low_hp / low_hp_dmg_reduce
##                  受击前修正：由 player.take_damage 同步查询（岩肤符）
##   add_stacks     概率给已施加的状态追加层数（缠藤结）
##   bonus_materials 概率额外获得材料（后土符）
## ============================================================
const ARTIFACT_TRIGGERS := ["on_reaction", "on_kill", "on_status_apply",
	"on_deal_hit", "on_take_hit", "on_wave_end"]

const ARTIFACT_ELITE_DROP_CHANCE := 0.12     # 精英怪（实例 elite 标志）击杀掉法宝概率
const ARTIFACT_BOSS_LEGENDARY_MULT := 3.0    # BOSS 掉落时 legendary 权重倍率
const ARTIFACT_SHOP_CHANCE := 0.25           # 商店每格刷出法宝（而非武器/道具/升级）概率
const ARTIFACT_DUP_MATERIALS := 60           # 重复获得已持有法宝的材料补偿

const ARTIFACTS := [
	# ---- 火 · 爆发 ----
	{ "id": "art_cinder_seal", "ico": "🔥", "name": "焚天印", "element": "fire", "rarity": "common",
		"desc": "火系五行反应触发时，对反应目标追加 40% 攻击力的额外伤害",
		"trigger": "on_reaction", "params": { "element": "fire" },
		"effect": { "bonus_dmg_pct": 0.40 }, "price": 110, "shop_weight": 1.0 },
	{ "id": "art_phoenix_plume", "ico": "🪶", "name": "凤凰翎", "element": "fire", "rarity": "epic",
		"desc": "击杀燃烧中的敌人时，12% 概率点燃周围 120 范围内敌人 1 层",
		"trigger": "on_kill", "params": { "status": "burn" },
		"effect": { "chance": 0.12, "radius": 120.0, "apply_status": "burn",
			"stacks": 1, "duration": 3.0 }, "price": 210, "shop_weight": 1.0 },
	{ "id": "art_molten_crucible", "ico": "🌋", "name": "熔金炉", "element": "fire", "rarity": "legendary",
		"desc": "「火克金」熔金强化：受伤 +50%→+80%，持续 3 秒→5 秒",
		"trigger": "on_reaction", "params": { "key": "fire+metal" },
		"effect": { "patch": { "set": { "armor_break": 0.8, "armor_break_duration": 5.0 } } },
		"price": 300, "shop_weight": 1.0 },
	# ---- 木 · 持续 / 回复 ----
	{ "id": "art_vine_knot", "ico": "🌿", "name": "缠藤结", "element": "wood", "rarity": "common",
		"desc": "施加中毒时 15% 概率额外 +1 层",
		"trigger": "on_status_apply", "params": { "status": "poison" },
		"effect": { "chance": 0.15, "add_stacks": 1 }, "price": 110, "shop_weight": 1.0 },
	{ "id": "art_spore_heart", "ico": "🍄", "name": "孢心", "element": "wood", "rarity": "epic",
		"desc": "「水生木」毒素扩散半径 100→180",
		"trigger": "on_reaction", "params": { "key": "water+wood" },
		"effect": { "patch": { "set": { "spread": { "poison": 180.0 } } } },
		"price": 210, "shop_weight": 1.0 },
	{ "id": "art_world_tree", "ico": "🌳", "name": "建木枝", "element": "wood", "rarity": "legendary",
		"desc": "每波结束回复 18% 最大生命",
		"trigger": "on_wave_end", "params": {},
		"effect": { "heal_pct": 0.18 }, "price": 300, "shop_weight": 1.0 },
	# ---- 金 · 暴击 / 处决 ----
	{ "id": "art_notch_blade", "ico": "⚔", "name": "断刃锋", "element": "metal", "rarity": "common",
		"desc": "击杀流血中的敌人 +4% 暴击率（本波内有效，最多 8 层）",
		"trigger": "on_kill", "params": { "status": "bleed" },
		"effect": { "stat": "crit_ch", "per_stack": 0.04, "stack_max": 8,
			"stack_reset": "wave" }, "price": 110, "shop_weight": 1.0 },
	{ "id": "art_executioner", "ico": "🪓", "name": "刑天斧", "element": "metal", "rarity": "epic",
		"desc": "对生命低于 25% 的敌人伤害 +45%",
		"trigger": "on_deal_hit", "params": { "hp_below": 0.25 },
		"effect": { "dmg_mult": 1.45 }, "price": 210, "shop_weight": 1.0 },
	{ "id": "art_soul_bell", "ico": "🔔", "name": "落魂钟", "element": "metal", "rarity": "legendary",
		"desc": "「金克木」败血症期间，目标受到的伤害额外 +35%",
		"trigger": "on_reaction", "params": { "key": "metal+wood" },
		"effect": { "patch": { "add": { "armor_break": 0.35, "armor_break_duration": 4.0 } } },
		"price": 300, "shop_weight": 1.0 },
	# ---- 水 · 控制 / 生存 ----
	{ "id": "art_frost_mirror", "ico": "❄", "name": "寒镜", "element": "water", "rarity": "common",
		"desc": "水系五行反应触发时，12% 概率冰冻周围 140 范围内敌人 0.8 秒",
		"trigger": "on_reaction", "params": { "element": "water" },
		"effect": { "chance": 0.12, "radius": 140.0, "apply_status": "freeze",
			"stacks": 1, "duration": 0.8 }, "price": 110, "shop_weight": 1.0 },
	{ "id": "art_tide_pearl", "ico": "🫧", "name": "潮汐珠", "element": "water", "rarity": "epic",
		"desc": "受到攻击时 18% 概率释放寒冰新星，减速周围 150 范围内敌人 2 秒",
		"trigger": "on_take_hit", "params": {},
		"effect": { "chance": 0.18, "radius": 150.0, "apply_status": "slow",
			"stacks": 1, "duration": 2.0 }, "price": 210, "shop_weight": 1.0 },
	{ "id": "art_leviathan_eye", "ico": "👁", "name": "蛟皇目", "element": "water", "rarity": "legendary",
		"desc": "「土克水」碎裂阈值 20%→32%，碎裂成功时回复 8 点生命",
		"trigger": "on_reaction", "params": { "key": "earth+water" },
		"effect": { "patch": { "set": { "execute_threshold": 0.32, "execute_heal": 8.0 } } },
		"price": 300, "shop_weight": 1.0 },
	# ---- 土 · 防御 / 资源 ----
	{ "id": "art_stone_skin", "ico": "🪨", "name": "岩肤符", "element": "earth", "rarity": "common",
		"desc": "生命高于 70% 时护甲 +4；低于 30% 时受到的伤害 -22%",
		"trigger": "on_take_hit", "params": {},
		"effect": { "high_hp": 0.70, "high_hp_armor": 4.0,
			"low_hp": 0.30, "low_hp_dmg_reduce": 0.22 }, "price": 110, "shop_weight": 1.0 },
	{ "id": "art_earth_tally", "ico": "🏵", "name": "后土符", "element": "earth", "rarity": "epic",
		"desc": "每次击杀 8% 概率额外获得 1 份材料",
		"trigger": "on_kill", "params": {},
		"effect": { "chance": 0.08, "bonus_materials": 1 }, "price": 210, "shop_weight": 1.0 },
	{ "id": "art_titan_core", "ico": "⛰", "name": "玄武核", "element": "earth", "rarity": "legendary",
		"desc": "土系五行反应触发时获得 1 层「磐石」（护甲 +1.5，永久，最多 12 层）",
		"trigger": "on_reaction", "params": { "element": "earth" },
		"effect": { "stat": "armor", "per_stack": 1.5, "stack_max": 12,
			"stack_reset": "run" }, "price": 300, "shop_weight": 1.0 },
	# ---- rare 档（Phase 3.6）：补齐 common(110) → epic(210) 的梯度。
	# 三件都走 on_status_apply，刻意挑现有法宝未覆盖的状态（燃烧 / 流血 / 减速）避免同质，
	# 并且因为 element 与 params.status 都会被 entry_tags 打标，
	# 玩状态流 / 对应元素流的构筑会明显更容易刷到它们
	{ "id": "art_pyre_brand", "ico": "🔥", "name": "燎原印", "element": "fire", "rarity": "rare",
		"desc": "施加燃烧时 30% 概率额外 +1 层",
		"trigger": "on_status_apply", "params": { "status": "burn" },
		"effect": { "chance": 0.30, "add_stacks": 1 }, "price": 160, "shop_weight": 1.0 },
	{ "id": "art_blood_fang", "ico": "🦷", "name": "饮血齿", "element": "metal", "rarity": "rare",
		"desc": "施加流血时 28% 概率额外 +1 层",
		"trigger": "on_status_apply", "params": { "status": "bleed" },
		"effect": { "chance": 0.28, "add_stacks": 1 }, "price": 160, "shop_weight": 1.0 },
	{ "id": "art_mist_veil", "ico": "🌫", "name": "雾隐纱", "element": "water", "rarity": "rare",
		"desc": "施加减速时 25% 概率额外 +1 层",
		"trigger": "on_status_apply", "params": { "status": "slow" },
		"effect": { "chance": 0.25, "add_stacks": 1 }, "price": 160, "shop_weight": 1.0 },
]

## ============================================================
## 江湖奇遇事件卡（Phase 4）—— 商店后的三选一叙事决策
## 触发：每波商店关闭后 30% 概率，每局上限随局随机 3~5 次
## 字段说明：
##   theme   所属地域主题（bamboo/temple/nether），与 Phase 5 地图主题呼应
##   rarity  稀有度，仅用于抽取权重与卡面配色（复用 RARITY_*）
##   choices 三选一，每项 { text, hint, effect }
## choice.effect 载荷约定（由 main._execute_event_effect 按存在的键分派）：
##   cost_materials  前置消耗；材料不足时该选项禁用（不出现在可选状态）
##   hp_pct_cost     前置消耗：按最大生命百分比扣血（可能致死，不致死时保底 1 点）
##   effects         属性增益字典，键 = player.stats 键（走 player.apply_effects）
##   grant_materials 直接获得材料
##   grant_item_rarity  随机获得该品阶道具（"epic"/"mythic"/"legendary"）
##   grant_weapon    随机获得一把武器（占用武器槽，槽满则转材料补偿）
##   grant_relic     随机获得一件未持有法宝
##   free_upgrade    免费升级次数（进 GameState.level_queue，下波开场补弹）
##   next_wave_elite 下一波开始时额外生成的精英数量（风险选项）
## ============================================================
const EVENT_CARD_CHANCE := 0.30        # 商店关闭后触发概率
const EVENT_CARD_MIN := 3              # 每局触发次数下限
const EVENT_CARD_MAX := 5              # 每局触发次数上限

const EVENT_CARDS := [
	{ "id": "ev_bamboo_spring", "title": "竹海清泉", "ico": "🎋", "theme": "bamboo", "rarity": "common",
		"desc": "林间一泓清泉，水面浮着薄薄竹叶。饮下它，能洗去一路风尘。",
		"choices": [
			{ "text": "掬水而饮", "hint": "回复 30% 生命", "effect": { "effects": { "heal_pct": 0.30 } } },
			{ "text": "涤荡经脉", "hint": "最大生命 +22", "effect": { "effects": { "max_hp": 22.0 } } },
			{ "text": "取竹而去", "hint": "获得 55 ◆", "effect": { "grant_materials": 55 } },
		] },
	{ "id": "ev_old_monk", "title": "古刹老僧", "ico": "🪷", "theme": "temple", "rarity": "common",
		"desc": "破败古刹只剩一位老僧，他不看你，只看着你身后的路。",
		"choices": [
			{ "text": "静听禅音", "hint": "免费升级一次", "effect": { "free_upgrade": 1 } },
			{ "text": "布施香火", "hint": "消耗 80 ◆ · 随机法宝", "effect": { "cost_materials": 80, "grant_relic": true } },
			{ "text": "合十而去", "hint": "回复 15% 生命 · 获得 40 ◆", "effect": { "effects": { "heal_pct": 0.15 }, "grant_materials": 40 } },
		] },
	{ "id": "ev_ghost_lantern", "title": "幽冥鬼灯", "ico": "🏮", "theme": "nether", "rarity": "rare",
		"desc": "一盏青灯悬在岔路口，灯芯是冷的，火是活的。",
		"choices": [
			{ "text": "续上灯油", "hint": "消耗 60 ◆ · 伤害 +18%", "effect": { "cost_materials": 60, "effects": { "dmg_mult": 0.18 } } },
			{ "text": "一口吹灭", "hint": "回复 40% 生命", "effect": { "effects": { "heal_pct": 0.40 } } },
			{ "text": "提灯照路", "hint": "暴击率 +8%", "effect": { "effects": { "crit_ch": 0.08 } } },
		] },
	{ "id": "ev_sword_grave", "title": "剑冢遗藏", "ico": "🗡", "theme": "temple", "rarity": "rare",
		"desc": "万剑插于荒丘，剑锋皆朝内。最中央那一柄，还在轻轻震颤。",
		"choices": [
			{ "text": "拔剑出鞘", "hint": "随机获得一把武器", "effect": { "grant_weapon": true } },
			{ "text": "只取剑穗", "hint": "暴击伤害 +35%", "effect": { "effects": { "crit_mult": 0.35 } } },
			{ "text": "以血祭剑", "hint": "消耗 15% 生命 · 伤害 +22%", "effect": { "hp_pct_cost": 0.15, "effects": { "dmg_mult": 0.22 } } },
		] },
	{ "id": "ev_fox_spirit", "title": "白狐讨封", "ico": "🦊", "theme": "bamboo", "rarity": "rare",
		"desc": "白狐立起身子，学人作揖：「你看我，像人还是像仙？」",
		"choices": [
			{ "text": "封它作仙", "hint": "收获率 +35%", "effect": { "effects": { "harvesting": 0.35 } } },
			{ "text": "讨要好处", "hint": "获得 110 ◆", "effect": { "grant_materials": 110 } },
			{ "text": "挥手驱赶", "hint": "伤害 +20% · 下波多 2 精英", "effect": { "effects": { "dmg_mult": 0.20 }, "next_wave_elite": 2 } },
		] },
	{ "id": "ev_iron_abbot", "title": "铁臂武僧", "ico": "🥋", "theme": "temple", "rarity": "epic",
		"desc": "武僧双臂如铁，在石阶上等你开口。他不出招，只等你先动。",
		"choices": [
			{ "text": "与他对练", "hint": "护甲 +4 · 最大生命 +15", "effect": { "effects": { "armor": 4.0, "max_hp": 15.0 } } },
			{ "text": "切磋招式", "hint": "攻速 +15% · 移速 +6%", "effect": { "effects": { "as_mult": 0.15, "speed_mult": 0.06 } } },
			{ "text": "供奉兵器", "hint": "消耗 140 ◆ · 随机史诗道具", "effect": { "cost_materials": 140, "grant_item_rarity": "epic" } },
		] },
	{ "id": "ev_nether_market", "title": "鬼市交易", "ico": "👺", "theme": "nether", "rarity": "epic",
		"desc": "鬼市只在子时开张，摊主不收钱，只收你身上还热着的东西。",
		"choices": [
			{ "text": "买下无名之物", "hint": "消耗 180 ◆ · 随机法宝", "effect": { "cost_materials": 180, "grant_relic": true } },
			{ "text": "典当一块血肉", "hint": "消耗 25% 生命 · 获得 240 ◆", "effect": { "hp_pct_cost": 0.25, "grant_materials": 240 } },
			{ "text": "转身离开", "hint": "拾取范围 +60", "effect": { "effects": { "pickup_range": 60.0 } } },
		] },
	{ "id": "ev_bamboo_spirit", "title": "竹灵赐福", "ico": "🌱", "theme": "bamboo", "rarity": "epic",
		"desc": "竹节裂开，走出一位只有半尺高的竹灵，捧着一枚沉甸甸的竹实。",
		"choices": [
			{ "text": "收下竹实", "hint": "回复 +1.6/秒 · 最大生命 +20", "effect": { "effects": { "regen": 1.6, "max_hp": 20.0 } } },
			{ "text": "求一段灵竹", "hint": "随机获得一把武器", "effect": { "grant_weapon": true } },
			{ "text": "求一场富贵", "hint": "获得 150 ◆", "effect": { "grant_materials": 150 } },
		] },
	{ "id": "ev_blood_moon", "title": "血月当空", "ico": "🌑", "theme": "nether", "rarity": "legendary",
		"desc": "月亮红了。你听见自己的心跳，比平时快了一倍。",
		"choices": [
			{ "text": "沐浴血光", "hint": "消耗 30% 生命 · 伤害 +45%", "effect": { "hp_pct_cost": 0.30, "effects": { "dmg_mult": 0.45 } } },
			{ "text": "持咒镇之", "hint": "护甲 +6 · 闪避 +6%", "effect": { "effects": { "armor": 6.0, "dodge": 0.06 } } },
			{ "text": "远遁避祸", "hint": "移速 +20%", "effect": { "effects": { "speed_mult": 0.20 } } },
		] },
	{ "id": "ev_dragon_gate", "title": "龙门试炼", "ico": "🐉", "theme": "temple", "rarity": "legendary",
		"desc": "石门高百丈，门上刻着一行字：「跃过者，脱胎换骨；落败者，尸骨无存。」",
		"choices": [
			{ "text": "跃龙门", "hint": "伤害 +35% · 暴击 +10% · 下波多 3 精英",
				"effect": { "effects": { "dmg_mult": 0.35, "crit_ch": 0.10 }, "next_wave_elite": 3 } },
			{ "text": "取龙门鳞", "hint": "随机法宝 · 最大生命 +25", "effect": { "grant_relic": true, "effects": { "max_hp": 25.0 } } },
			{ "text": "养精蓄锐", "hint": "回复 60% 生命 · 最大生命 +40", "effect": { "effects": { "heal_pct": 0.60, "max_hp": 40.0 } } },
		] },
]

static func event_card(id: String) -> Dictionary:
	for e in EVENT_CARDS:
		if String(e.get("id", "")) == id:
			return e
	return {}

static func event_card_ids() -> Array:
	var out: Array = []
	for e in EVENT_CARDS:
		out.append(String(e.get("id", "")))
	return out

## 事件卡抽取池：[{ item: 卡片, w: rarity_weight(稀有度, 当前波次) }]
## 排除本局已抽到过的卡，保证 10 个事件都能被见到
static func event_card_pool(seen: Array, wave: int) -> Array:
	var pool: Array = []
	for e in EVENT_CARDS:
		if seen.has(String(e.get("id", ""))):
			continue
		pool.append({ "item": e,
			"w": rarity_weight(String(e.get("rarity", "common")), wave) })
	return pool

## ============================================================
## 地图主题（Phase 5）—— 按波次切换的竞技场氛围
## 字段说明：
##   name    中文名（横幅/图鉴展示）
##   bg      竞技场底色（main._draw 填充）
##   grid    网格线颜色（与底色同系，保持可读性）
##   accent  边框与装饰强调色
##   obstacle 障碍物外观 id（obstacle.gd 的 SHAPES 键）
##   particle 主题氛围粒子（fx/ 下的粒子脚本键）
##   waves   适用波次区间 [起, 止]（含两端；无尽模式只有首段生效，之后循环）
## ============================================================
const MAP_THEMES := {
	"bamboo": { "name": "幽篁竹林", "bg": "#16221a", "grid": "#1f3325", "accent": "#3f6b46",
		"obstacle": "bamboo", "particle": "bamboo_leaf", "waves": [1, 3] },
	"temple": { "name": "荒古废庙", "bg": "#241a17", "grid": "#33241f", "accent": "#6b4a3a",
		"obstacle": "pillar", "particle": "incense", "waves": [4, 6] },
	"nether": { "name": "幽冥鬼域", "bg": "#141728", "grid": "#1d2138", "accent": "#4a3f7a",
		"obstacle": "stele", "particle": "ghost_fire", "waves": [7, 10] },
}

const MAP_THEME_ORDER := ["bamboo", "temple", "nether"]

## 障碍物数量：普通波 30-50，BOSS 波压到 15 以内（性能与走位空间取舍）
const OBSTACLE_MIN := 30
const OBSTACLE_MAX := 50
const OBSTACLE_BOSS_MAX := 15
const OBSTACLE_SAFE_RADIUS := 200.0   # 玩家出生点周围禁放半径

## 波次 → 主题 id；无尽模式超过最后一个区间后按 ORDER 循环
static func map_theme_for_wave(w: int) -> String:
	for tid in MAP_THEME_ORDER:
		var r: Array = MAP_THEMES[tid].waves
		if w >= int(r[0]) and w <= int(r[1]):
			return String(tid)
	# 无尽：10 波之后按 (w-1)/3 在 ORDER 内循环，保持换景节奏
	var idx := (maxi(1, w) - 1) / 3
	return String(MAP_THEME_ORDER[idx % MAP_THEME_ORDER.size()])

static func map_theme(id: String) -> Dictionary:
	return MAP_THEMES.get(id, {})

static func map_theme_name(id: String) -> String:
	return String(MAP_THEMES.get(id, {}).get("name", id))

const WAVES_TOTAL := 10
const BOSS_WAVE := 10
const ENDLESS_MAX_WAVE := 9999   # 无尽模式波次上限（防溢出的护栏值）
const ENEMY_HARD_CAP := 240      # 同屏敌人绝对上限（大规模敌群性能护栏）
const HEAL_DROP_CHANCE := 0.05
const SHOP_HEAL_PRICE := 15
const SHOP_UPGRADE_CHANCE := 0.29   # 商店刷出升级属性的概率（武器 42% 之外再分摊）

## 是否 BOSS 波：标准模式 = 第 10 波；无尽炼狱 = 每 10 波一轮
static func is_boss_wave(w: int) -> bool:
	return (w % 10 == 0) if GameState.endless else (w == BOSS_WAVE)

## 击杀积分（无尽模式）：基础 + 经验/材料折算，精英/BOSS 天然更值钱
static func kill_score(cfg: Dictionary) -> int:
	return 5 + int(cfg.get("xp", 1)) * 3 + int(cfg.get("mat", 1)) * 2

## BOSS 击破积分奖励（无尽模式）
static func boss_kill_score(w: int) -> int:
	return 800 + w * 30

## 波次清场积分奖励（无尽模式）
static func wave_clear_score(w: int) -> int:
	return w * 30

## 稀有度枚举（低 → 高）：common 白 / rare 蓝 / epic 紫 / mythic 金 / legendary 红
const RARITIES := ["common", "rare", "epic", "mythic", "legendary"]

## 稀有度色（商店/向导/暂停页卡片背景与边框共用）
const RARITY_COLORS := {
	"common": Color("e6e6e6"),
	"rare": Color("5aa9e6"),
	"epic": Color("b07fe0"),
	"mythic": Color("ffb42e"),
	"legendary": Color("e0564f"),
}

## 稀有度中文名（图鉴/商店展示）
const RARITY_NAMES := {
	"common": "普通", "rare": "稀有", "epic": "史诗",
	"mythic": "神话", "legendary": "传说",
}

## 商店/升级池按稀有度抽取的基础权重（单条目权重，品阶越高越稀有）
const RARITY_BASE_WEIGHTS := {
	"common": 1.0, "rare": 0.50, "epic": 0.22, "mythic": 0.055, "legendary": 0.018,
}

## 稀有度抽取权重：progress = 波次（商店）或等级（升级三选一），
## 越往后高品阶权重越高，构筑成型期才有机会刷出金色/红色
static func rarity_weight(rarity: String, progress: int) -> float:
	var w := float(RARITY_BASE_WEIGHTS.get(rarity, 1.0))
	var t := maxf(0.0, float(progress - 1))
	match rarity:
		"mythic": w *= 1.0 + 0.22 * t
		"legendary": w *= 1.0 + 0.28 * t
		"epic": w *= 1.0 + 0.06 * t
	return w

# ============================================================
# 构筑亲和（Affinity）：让商店 / 升级三选一 / 法宝掉落的抽取
# 向「当前角色 + 当前武器」靠拢，而不是纯随机。
#
# 做法：把角色特性、武器形态、已持有法宝归纳成一组标签，
# 再给每个候选条目按 effects 键自动打标（entry_tags），交集越多权重越高。
# 全部由数据推导 —— 不手工维护对照表，因此 mod 内容与后续新增内容
# 都会自动获得亲和能力。
# ============================================================
const AFFINITY_BONUS := 0.85      # 每命中一个亲和标签的权重增幅
const AFFINITY_MAX_TAGS := 3      # 最多按 3 个匹配计（防止叠满后抽取池被锁死）

## 从角色 + 武器 + 已持有法宝推导「当前构筑的亲和标签」
## 需读 Registry，故为实例方法（Config 是 autoload）
func affinity_tags(character_id: String, weapons: Array, artifacts_owned: Dictionary) -> Array:
	var tags := {}
	# ① 武器：状态元素 / 攻击形态 / 溅射 / 弹速 / 多发
	for w in weapons:
		var wid := ""
		if typeof(w) == TYPE_DICTIONARY:
			wid = String(w.get("type", ""))
		else:
			wid = String(w)
		var wcfg: Dictionary = Registry.weapons.get(wid, {})
		if wcfg.is_empty():
			continue
		var sid := String(wcfg.get("status", ""))
		if sid != "":
			tags[sid] = true
		if String(wcfg.get("attack_type", "")) == "melee":
			tags["melee"] = true
		else:
			tags["ranged"] = true
		if float(wcfg.get("splash", 0.0)) > 0.0:
			tags["aoe"] = true
		if float(wcfg.get("bspeed", 0.0)) >= 600.0:
			tags["speed"] = true
		if int(wcfg.get("pellets", 1)) > 1:
			tags["multi"] = true
	# ② 角色特性：光环元素 / 荆棘 / 战意 / 属性加成
	var tr: Dictionary = Registry.get_character(character_id).get("trait", {})
	var kind := String(tr.get("kind", ""))
	if kind == "aura":
		var asid := String(tr.get("status", ""))
		if asid != "":
			tags[asid] = true
	elif kind == "thorns":
		tags["tank"] = true
	elif kind == "momentum":
		tags["atkspeed"] = true
	for k in tr.get("effects", {}):
		for t in effect_tags(String(k)):
			tags[t] = true
	# ③ 已持有法宝：继续深耕同一元素（玩家已经选了这条路，就该继续给同系）
	for aid in artifacts_owned:
		var et := element_tag(String(Registry.get_artifact(String(aid)).get("element", "")))
		if et != "":
			tags[et] = true
	return tags.keys()

## 单个 effects 键 → 标签（道具 / 升级 / 法宝共用同一套推导规则）
static func effect_tags(key: String) -> Array:
	var out: Array = []
	if key.begins_with("on_hit_"):
		out.append(key.substr(7))     # on_hit_burn → burn
		out.append("status")
		return out
	match key:
		"status_dmg_mult", "status_dur_mult", "status_chance", "status_spread":
			out.append("status")
		"melee_range_bonus":
			out.append("melee")
			out.append("range")
		"bullet_speed_bonus":
			out.append("speed")
		"bullet_range_bonus":
			out.append("range")
		"aoe_radius_bonus":
			out.append("aoe")
		"max_hp", "armor", "regen", "heal_flat", "heal_pct", "lifesteal":
			out.append("tank")
		"harvesting", "pickup_range":
			out.append("economy")
		"crit_ch", "crit_mult":
			out.append("crit")
		"as_mult":
			out.append("atkspeed")
		"dodge", "speed_mult", "base_speed":
			out.append("mobility")
		"low_hp_dmg_bonus":
			out.append("lowhp")
	return out

## 元素 ↔ 状态标签归一：法宝用 element、武器用 status，统一到状态 id 才能比较
static func element_tag(element: String) -> String:
	return { "fire": "burn", "wood": "poison", "metal": "bleed",
		"water": "freeze", "earth": "stun" }.get(element, "")

## 条目（道具 / 升级 / 法宝）自动打标
static func entry_tags(cfg: Dictionary) -> Array:
	var tags := {}
	if cfg.has("element"):
		var et := element_tag(String(cfg.element))
		if et != "":
			tags[et] = true
	var params: Variant = cfg.get("params", null)
	if typeof(params) == TYPE_DICTIONARY:
		var pd: Dictionary = params
		var ps := String(pd.get("status", ""))
		if ps != "":
			tags[ps] = true
			tags["status"] = true
		var pe := element_tag(String(pd.get("element", "")))
		if pe != "":
			tags[pe] = true
	for key in ["effects", "effect"]:
		var eff: Variant = cfg.get(key, null)
		if typeof(eff) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = eff
		var asid := String(d.get("apply_status", ""))
		if asid != "":
			tags[asid] = true
			tags["status"] = true
		for k in d:
			for t in effect_tags(String(k)):
				tags[t] = true
	return tags.keys()

## 亲和倍率：条目标签与构筑亲和的交集数量 → 权重倍数（无交集返回 1.0）
static func affinity_mult(item_tags: Array, affinity: Array) -> float:
	if item_tags.is_empty() or affinity.is_empty():
		return 1.0
	var hit := 0
	for t in item_tags:
		if t in affinity:
			hit += 1
			if hit >= AFFINITY_MAX_TAGS:
				break
	if hit <= 0:
		return 1.0
	return 1.0 + AFFINITY_BONUS * float(hit)

# ============================================================
# 角色印记（SIGIL）—— 角色的元素 / 风格在武器表现上的专属痕迹
#
# 与「武器外观族」正交：外观族回答「这是什么武器」（火舌 / 冰晶 / 刀光），
# 印记回答「这是谁在用」（焚天祭司的火星 / 沧海鲛人的霜粒 / 太白剑客的刃光）。
# 于是同一个角色换武器，画面里仍留有他的味道；同一把武器换角色，表现也随之改变。
#
# 每个印记只用四种绘制原语之一，避免为 11 个印记各写一套绘制代码：
#   spark 飞散火星（火 / 爆 / 血）    mote 漂浮微粒（水 / 木 / 土 / 生）
#   edge  附加锋线（剑 / 疾）          ring 脉动光环（守 / 运）
# ============================================================
const SIGIL_GLYPHS := ["spark", "mote", "edge", "ring"]
const SIGILS := {
	"fire":  { "name": "烈焰", "color": "#ff7a3c", "glyph": "spark" },
	"water": { "name": "寒霜", "color": "#8fd8ff", "glyph": "mote" },
	"wood":  { "name": "青瘴", "color": "#6ab04c", "glyph": "mote" },
	"earth": { "name": "厚土", "color": "#ffd24a", "glyph": "mote" },
	"blade": { "name": "剑意", "color": "#e8eef8", "glyph": "edge" },
	"swift": { "name": "疾风", "color": "#9fe8d8", "glyph": "edge" },
	"blast": { "name": "轰爆", "color": "#ffb347", "glyph": "spark" },
	"guard": { "name": "坚守", "color": "#8fa8ff", "glyph": "ring" },
	"luck":  { "name": "鸿运", "color": "#ffd76a", "glyph": "ring" },
	"blood": { "name": "血怒", "color": "#c23b52", "glyph": "spark" },
	"vigor": { "name": "生生", "color": "#a8e6a0", "glyph": "mote" },
}

## 五行状态 → 印记
static func element_sigil(status: String) -> String:
	return {
		"burn": "fire", "poison": "wood", "bleed": "blood",
		"freeze": "water", "slow": "water", "stun": "earth",
	}.get(status, "")

## effects 键 → 印记（角色特性 / 升级 / 道具共用同一张表）
static func effect_sigil(key: String) -> String:
	return {
		"melee_range_bonus": "blade",
		"bullet_speed_bonus": "swift",
		"bullet_range_bonus": "swift",
		"aoe_radius_bonus": "blast",
		"low_hp_dmg_bonus": "blood",
		"momentum_dmg_bonus": "blade",
		"status_dmg_mult": "wood",
		"status_dur_mult": "wood",
		"status_chance": "wood",
		"crit_ch": "luck",
		"crit_mult": "luck",
		"harvesting": "vigor",
		"pickup_range": "vigor",
		"regen": "vigor",
		"lifesteal": "blood",
		"max_hp": "guard",
		"armor": "guard",
		"dodge": "swift",
		"speed_mult": "swift",
		"base_speed": "swift",
	}.get(key, "")

## 角色印记推导：trait.sigil 显式声明优先（显式写空串 = 刻意「无印记」，
## 如土豆勇者的「均衡之道」），否则按 kind → status → effects 顺序推断。
## 返回 "" 表示该角色不带印记。
static func sigil_for(character_id: String) -> String:
	var tr: Dictionary = Registry.get_character(character_id).get("trait", {})
	if tr.is_empty():
		return ""
	if tr.has("sigil"):
		return String(tr["sigil"])
	match String(tr.get("kind", "")):
		"aura":
			return element_sigil(String(tr.get("status", "")))
		"thorns":
			return "guard"
		"momentum":
			return "blade"
	for k in tr.get("effects", {}):
		var s := effect_sigil(String(k))
		if s != "":
			return s
	return ""

## 印记是否合法（空串合法 = 无印记）
static func sigil_valid(id: String) -> bool:
	return id == "" or SIGILS.has(id)

static func sigil_color(id: String) -> Color:
	if not SIGILS.has(id):
		return Color(0, 0, 0, 0)
	return Color(String(SIGILS[id].get("color", "#ffffff")))

static func sigil_glyph(id: String) -> String:
	return String(SIGILS.get(id, {}).get("glyph", ""))

static func rarity_color(r: String) -> Color:
	return RARITY_COLORS.get(r, Color("9aa3b2"))

static func rarity_name(r: String) -> String:
	return RARITY_NAMES.get(r, r)

## 难度色阶（向导卡片）
const DIFFICULTY_COLORS := {
	"normal": Color("7ec850"),
	"hard": Color("e8902a"),
	"nightmare": Color("e0564f"),
}

# ---- 波次曲线（对应原型 JS 内联函数） ----

static func wave_duration(w: int) -> float:
	return 45.0 + (w - 1) * 5.0   # 初始 45s，每波 +5s

static func wave_interval(w: int) -> float:
	return maxf(0.4, 1.0 - 0.07 * (w - 1))   # 前期刷怪更密，保证经验/材料流转

static func wave_cap(w: int) -> int:
	return 24 + w * 6

static func wave_hp_scale(w: int) -> float:
	return 1.0 + 0.30 * (w - 1)

static func wave_dmg_scale(w: int) -> float:
	return 1.0 + 0.18 * (w - 1)

static func wave_spd_scale(w: int) -> float:
	return 1.0 + minf(0.18, 0.015 * (w - 1))

static func xp_need(level: int) -> int:
	return 4 + (level - 1) * 3

## 刷怪权重组合：[{ "item": 敌人类型, "w": 权重 }]
## w >= 10 仅无尽模式可达：精英占比随波次渐进上升（波 10 → 30 逐步拉满）
static func wave_composition(w: int) -> Array:
	if w <= 1:
		return [{ "item": "grunt", "w": 0.72 }, { "item": "swarm", "w": 0.28 }]
	if w == 2:
		return [{ "item": "grunt", "w": 0.42 }, { "item": "swarm", "w": 0.28 }, { "item": "runner", "w": 0.30 }]
	if w == 3:
		return [{ "item": "grunt", "w": 0.32 }, { "item": "swarm", "w": 0.20 }, { "item": "runner", "w": 0.26 }, { "item": "tank", "w": 0.22 }]
	if w <= 5:
		return [{ "item": "grunt", "w": 0.26 }, { "item": "swarm", "w": 0.14 }, { "item": "runner", "w": 0.24 },
			{ "item": "tank", "w": 0.16 }, { "item": "shooter", "w": 0.20 }]
	if w <= 7:
		return [{ "item": "grunt", "w": 0.16 }, { "item": "swarm", "w": 0.09 }, { "item": "runner", "w": 0.20 },
			{ "item": "tank", "w": 0.13 }, { "item": "shooter", "w": 0.14 }, { "item": "bomber", "w": 0.09 },
			{ "item": "wizard", "w": 0.09 },
			{ "item": "fire_imp", "w": 0.05 }, { "item": "wood_sprite", "w": 0.05 }]
	if w <= 9:
		return [{ "item": "grunt", "w": 0.10 }, { "item": "swarm", "w": 0.06 }, { "item": "runner", "w": 0.16 },
			{ "item": "tank", "w": 0.11 }, { "item": "shooter", "w": 0.12 }, { "item": "bomber", "w": 0.09 },
			{ "item": "wizard", "w": 0.08 }, { "item": "shadow", "w": 0.06 }, { "item": "guard", "w": 0.03 },
			{ "item": "fire_imp", "w": 0.04 }, { "item": "wood_sprite", "w": 0.04 },
			{ "item": "vine_beast", "w": 0.04 }, { "item": "metal_puppet", "w": 0.04 },
			{ "item": "water_nymph", "w": 0.04 }, { "item": "earth_golem", "w": 0.03 }]
	# 无尽后期（w >= 10）：难度随波次上升，精英比重逐步拉满，五行敌人全覆盖
	var t := minf(1.0, float(w - 9) / 21.0)
	return [{ "item": "grunt", "w": 0.10 - 0.04 * t }, { "item": "swarm", "w": 0.05 },
		{ "item": "runner", "w": 0.14 }, { "item": "tank", "w": 0.10 + 0.02 * t },
		{ "item": "shooter", "w": 0.10 }, { "item": "bomber", "w": 0.08 + 0.03 * t },
		{ "item": "wizard", "w": 0.08 + 0.04 * t }, { "item": "shadow", "w": 0.06 + 0.04 * t },
		{ "item": "guard", "w": 0.05 + 0.06 * t },
		{ "item": "fire_imp", "w": 0.03 }, { "item": "fire_shaman", "w": 0.03 + 0.02 * t },
		{ "item": "wood_sprite", "w": 0.03 }, { "item": "vine_beast", "w": 0.04 + 0.02 * t },
		{ "item": "metal_puppet", "w": 0.04 + 0.02 * t }, { "item": "blade_monk", "w": 0.03 + 0.02 * t },
		{ "item": "water_nymph", "w": 0.03 }, { "item": "ice_witch", "w": 0.02 + 0.03 * t },
		{ "item": "earth_golem", "w": 0.03 + 0.02 * t }, { "item": "stone_titan", "w": 0.02 + 0.03 * t }]

# ---- 商店公式 ----

static func shop_reroll_cost(wave: int) -> int:
	return 8 + wave * 3

static func shop_price(base_price: int, wave: int) -> int:
	return int(round(float(base_price) * (1.0 + 0.08 * (wave - 1))))
