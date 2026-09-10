extends Node
## ============================================================
## 内容注册表 REGISTRY —— 创意工坊接口层
## 游戏逻辑（玩家/敌人/商店/升级/HUD）一律从这里取内容，
## Config 只作内置基准值。自定义内容通过 JSON manifest 加载后覆盖合并。
##
## mod 目录：user://mods/<模组名>/manifest.json（也扫描 res://mods 内置示例）
## manifest 格式见 game/mods/example_mod/manifest.json；
## 校验失败的条目跳过并 push_warning，不影响其他内容。
## ============================================================

signal content_changed   # mods 重载后发出（工坊 UI 刷新用）

var characters: Dictionary = {}   # id -> 角色（stats 可只覆盖部分，merge 到 Config.PLAYER）
var weapons: Dictionary = {}      # id -> 武器（同 Config.WEAPONS 结构，全字段驱动）
var items: Dictionary = {}        # id -> 道具（effects 键 = player.stats 键）
var upgrades: Dictionary = {}     # id -> 升级（effects 同上）
var enemies: Dictionary = {}      # id -> 敌人（boss 也在此；is_boss=true 或 ai="boss"）
var difficulties: Dictionary = {} # id -> 难度（hp_mult / dmg_mult / spawn_mult）
var reactions: Dictionary = {}    # id -> 五行反应（同 Config.REACTIONS 条目结构 + key）
var _reaction_keys: Dictionary = {}   # "elemA+elemB"（字母序）-> 反应 id

var boss_override := ""           # 校验后的最终 BOSS 敌人 id
var spawn_table: Dictionary = {}  # 校验后的波次刷怪覆盖
var _pending_boss_override := ""
var _pending_spawn_table: Dictionary = {}

const USER_MOD_ID := "workshop_user"
const USER_MANIFEST_PATH := "user://mods/workshop_user/manifest.json"
const STAT_LIMITS := {
	"max_hp": Vector2(1.0, 10000.0), "regen": Vector2(0.0, 1000.0),
	"armor": Vector2(-7.9, 1000.0), "dodge": Vector2(0.0, 0.95),
	"dmg_mult": Vector2(0.01, 100.0), "as_mult": Vector2(0.01, 100.0),
	"crit_ch": Vector2(0.0, 1.0), "crit_mult": Vector2(1.0, 100.0),
	"speed_mult": Vector2(0.01, 100.0), "base_speed": Vector2(1.0, 2000.0),
	"pickup_range": Vector2(0.0, 5000.0), "harvesting": Vector2(-0.99, 10.0),
	"lifesteal": Vector2(0.0, 10000.0),
	"status_chance": Vector2(0.0, 1.0), "status_dmg_mult": Vector2(0.0, 10.0),
	"status_dur_mult": Vector2(0.0, 10.0), "status_spread": Vector2(0.0, 1.0),
	"on_hit_burn": Vector2(0.0, 1.0), "on_hit_poison": Vector2(0.0, 1.0),
	"on_hit_freeze": Vector2(0.0, 1.0), "on_hit_slow": Vector2(0.0, 1.0),
	"on_hit_stun": Vector2(0.0, 1.0), "on_hit_bleed": Vector2(0.0, 1.0),
}
const EFFECT_LIMITS := {
	"max_hp": 10000.0, "regen": 1000.0, "armor": 1000.0, "dodge": 0.95,
	"dmg_mult": 10.0, "as_mult": 10.0, "crit_ch": 1.0, "crit_mult": 10.0,
	"speed_mult": 10.0, "base_speed": 2000.0, "pickup_range": 5000.0,
	"harvesting": 10.0, "lifesteal": 10000.0, "heal_flat": 10000.0, "heal_pct": 1.0,
	"status_chance": 1.0, "status_dmg_mult": 10.0, "status_dur_mult": 10.0,
	"status_spread": 1.0, "on_hit_burn": 1.0, "on_hit_poison": 1.0,
	"on_hit_freeze": 1.0, "on_hit_slow": 1.0, "on_hit_stun": 1.0, "on_hit_bleed": 1.0,
}

## 五行反应：type 取值 + 各 type 允许的 effect 键
## 未知键直接拒登，防 mod 写错字后静默无效
const REACTION_TYPES := ["generate", "overcome"]
const GENERATE_EFFECT_KEYS := ["add_stacks", "duration_mult", "duration_add",
	"dmg_mult", "crit_guarantee", "convert_dmg", "spread"]
const OVERCOME_EFFECT_KEYS := ["consume", "aoe_dmg_scale", "aoe_radius",
	"execute_threshold", "execute_heal", "armor_break", "armor_break_duration",
	"dot_mult", "dot_duration"]
## 未知键直接拒登，防 mod 写错字后静默无效（与五行反应同款策略）
func _ready() -> void:
	reload_content()

## 重置为内置内容并重新加载全部 mods（工坊"重新加载"也走这里）
func reload_content() -> void:
	_register_builtin()
	boss_override = ""
	spawn_table = {}
	_pending_boss_override = ""
	_pending_spawn_table = {}
	var n := 0
	for base in ["res://mods", "user://mods"]:
		n += _load_mod_dir(base)
	_resolve_overrides()
	if n > 0:
		print("Registry: 已加载 %d 条自定义内容" % n)
	content_changed.emit()

## 最终 BOSS 敌人 id（mod 可覆盖）
func boss_id() -> String:
	if boss_override != "" and enemies.has(boss_override) and _enemy_is_boss(enemies[boss_override]):
		return boss_override
	return "boss"

## 某波刷怪组合：覆盖表仍做最终防御检查，异常时回退内置曲线。
func wave_composition(w: int) -> Array:
	if spawn_table.has(w) and _valid_spawn_entries(spawn_table[w]):
		return spawn_table[w]
	return Config.wave_composition(w)

# ------------------------------------------------------------
# 查询便捷 API（游戏逻辑用）
# ------------------------------------------------------------

func get_character(id: String) -> Dictionary:
	if characters.has(id):
		return characters[id]
	return characters.get("potato", {})

func get_difficulty(id: String) -> Dictionary:
	if difficulties.has(id):
		return difficulties[id]
	return difficulties.get("normal",
		{ "id": "normal", "name": "普通", "hp_mult": 1.0, "dmg_mult": 1.0, "spawn_mult": 1.0 })

func item_list() -> Array:
	return items.values()   # GDScript Dictionary 保持插入序

func upgrade_list() -> Array:
	return upgrades.values()

func reaction_list() -> Array:
	return reactions.values()

## 按反应 id 取配置
func get_reaction(id: String) -> Dictionary:
	return reactions.get(id, {})

## 按两个状态 id 查五行反应（同五行/无五行归属时无反应）
## 战斗逻辑统一走这里，mod 可用同 key 反应覆盖内置反应
func find_reaction(status_a: String, status_b: String) -> Dictionary:
	var key := Config.reaction_key(Config.get_element(status_a), Config.get_element(status_b))
	if key == "" or not _reaction_keys.has(key):
		return {}
	return reactions.get(String(_reaction_keys[key]), {})
## 状态图鉴数据源：某状态的施加/强化来源（遍历 Registry，mod 内容自动出现）
## 返回 { "weapons": [...], "items": [...], "boosts": [...] }
##   weapons：{ id, ico, name, desc, rarity, chance, stacks }
##   items：  { id, ico, name, desc, rarity, chance }
##   boosts： { id, ico, name, desc, rarity, kind, effects }
func status_sources(sid: String) -> Dictionary:
	var apply_weapons: Array = []
	for id in weapons:
		var w: Dictionary = weapons[id]
		if String(w.get("status", "")) != sid:
			continue
		apply_weapons.append({
			"id": id, "ico": w.get("ico", "🔧"), "name": w.get("name", id),
			"desc": w.get("desc", ""), "rarity": w.get("rarity", "common"),
			"chance": float(w.get("status_chance", 1.0)),
			"stacks": int(w.get("status_stacks", 1)),
		})
	var apply_items: Array = []
	var boosts: Array = []
	for id in items:
		var it: Dictionary = items[id]
		var eff: Dictionary = it.get("effects", {})
		if float(eff.get("on_hit_" + sid, 0.0)) > 0.0:
			apply_items.append({
				"id": id, "ico": it.get("ico", "🧩"), "name": it.get("name", id),
				"desc": it.get("desc", ""), "rarity": it.get("rarity", "common"),
				"chance": float(eff["on_hit_" + sid]),
			})
		var b := _status_boost_effects(eff, sid)
		if not b.is_empty():
			boosts.append({
				"id": id, "ico": it.get("ico", "🧩"), "name": it.get("name", id),
				"desc": it.get("desc", ""), "rarity": it.get("rarity", "common"),
				"kind": "道具", "effects": b,
			})
	for id in upgrades:
		var up: Dictionary = upgrades[id]
		var b2 := _status_boost_effects(up.get("effects", {}), sid)
		if b2.is_empty():
			continue
		boosts.append({
			"id": id, "ico": up.get("ico", "✨"), "name": up.get("name", id),
			"desc": up.get("desc", ""), "rarity": up.get("rarity", "common"),
			"kind": "升级", "effects": b2,
		})
	return { "weapons": apply_weapons, "items": apply_items, "boosts": boosts }

## 强化键筛选：通用异常强化对全部状态生效；status_spread 只对中毒有意义
func _status_boost_effects(eff: Dictionary, sid: String) -> Dictionary:
	var out: Dictionary = {}
	for k in ["status_chance", "status_dmg_mult", "status_dur_mult"]:
		var v := float(eff.get(k, 0.0))
		if v != 0.0:
			out[k] = v
	if sid == "poison" and float(eff.get("status_spread", 0.0)) > 0.0:
		out["status_spread"] = float(eff["status_spread"])
	return out

## 商店武器权重池：mod 武器默认 shop_weight=1.0
func shop_weapon_pool() -> Array:
	var pool: Array = []
	for id in weapons:
		var weight := float(weapons[id].get("shop_weight", 1.0))
		if weight > 0.0:
			pool.append({ "item": id, "w": weight })
	if pool.is_empty() and weapons.has("pistol"):
		pool.append({ "item": "pistol", "w": 1.0 })
	return pool

func weapon_price(id: String) -> int:
	return int(weapons.get(id, {}).get("price", 30))

# ------------------------------------------------------------
# 注册 API（mod 加载与未来属性编辑器共用；同 id 覆盖 = mod 优先）
# ------------------------------------------------------------

func register_character(data: Dictionary) -> bool:
	if not _valid(data, "角色", ["id", "name"]):
		return false
	_apply_defaults(data, {"ico": "🧑", "desc": "", "color": "#e8b84b",
		"start_weapon": "pistol", "stats": {}})
	if not _string_fields(data, ["id", "name", "ico", "desc", "color", "start_weapon"]):
		return _reject("角色", data, "文本字段类型非法")
	if String(data.id).strip_edges().is_empty() or String(data.name).strip_edges().is_empty():
		return _reject("角色", data, "ID/名称不能为空")
	if not Color.html_is_valid(data.color):
		return _reject("角色", data, "颜色必须是 HTML 色值")
	if typeof(data.stats) != TYPE_DICTIONARY or not _valid_stat_values(data.stats):
		return _reject("角色", data, "stats 必须是合法数值字典")
	characters[String(data.id)] = data
	return true

func register_weapon(data: Dictionary) -> bool:
	if not _valid(data, "武器", ["id", "name", "cd", "dmg"]):
		return false
	if not data.has("attack_type"):
		data["attack_type"] = "melee" if data.has("range") and data.has("swing_arc") else "projectile"
	_apply_defaults(data, {"ico": "🔧", "desc": "", "rarity": "common", "sfx": "shoot_pistol",
		"bspeed": 540.0, "pellets": 1, "arc": 0.0, "spread": 0.0, "splash": 0.0,
		"bullet_life": 1.1, "shake": 0.0, "price": 30, "shop_weight": 1.0,
		"status": "", "status_chance": 1.0, "status_stacks": 1, "status_duration": 0.0})
	if not _string_fields(data, ["id", "name", "ico", "desc", "rarity", "sfx", "attack_type"]):
		return _reject("武器", data, "文本字段类型非法")
	if data.attack_type == "spread":   # 兼容早期清单命名
		data["attack_type"] = "projectile"
	var attack_type := String(data.attack_type)
	if String(data.id).strip_edges().is_empty() or String(data.name).strip_edges().is_empty():
		return _reject("武器", data, "ID/名称不能为空")
	if attack_type not in ["projectile", "melee"]:
		return _reject("武器", data, "attack_type 非法")
	if data.rarity not in Config.RARITIES:
		return _reject("武器", data, "rarity 非法")
	if typeof(data.status) != TYPE_STRING:
		return _reject("武器", data, "status 必须是字符串")
	if String(data.status) != "" and not Config.STATUS.has(String(data.status)):
		return _reject("武器", data, "status 状态 id 未注册：%s" % data.status)
	if not _number_in_range(data.get("status_chance"), 0.0, 1.0) \
			or not _positive_integer(data.get("status_stacks")) or int(data.status_stacks) > 10 \
			or not _number_in_range(data.get("status_duration"), 0.0, 30.0):
		return _reject("武器", data, "状态参数超出范围（chance 0~1 / stacks 1~10 / duration 0~30）")
	for key in ["cd", "dmg", "price", "shop_weight", "shake"]:
		if not _finite_number(data.get(key)):
			return _reject("武器", data, "%s 必须是有限数值" % key)
	if float(data.cd) < 0.05 or float(data.cd) > 5.0 \
			or float(data.dmg) < 0.0 or float(data.dmg) > 500.0 \
			or not _nonnegative_integer(data.price) or int(data.price) > 300 \
			or float(data.shop_weight) < 0.0 or float(data.shop_weight) > 5.0 \
			or float(data.shake) < 0.0 or float(data.shake) > 10.0:
		return _reject("武器", data, "通用数值超出范围")
	if attack_type == "melee":
		if not _positive_number(data.get("range")) or float(data.range) > 400.0 \
				or not _positive_number(data.get("swing_arc")) or float(data.swing_arc) > TAU:
			return _reject("武器", data, "近战需要合法 range/swing_arc")
	else:
		for key in ["bspeed", "pellets", "arc", "spread", "splash", "bullet_life"]:
			if not _finite_number(data.get(key)):
				return _reject("武器", data, "%s 必须是有限数值" % key)
		if float(data.bspeed) < 1.0 or float(data.bspeed) > 1200.0 \
				or not _positive_integer(data.pellets) or int(data.pellets) > 32 \
				or float(data.arc) < 0.0 or float(data.arc) > TAU \
				or float(data.spread) < 0.0 or float(data.spread) > PI \
				or float(data.splash) < 0.0 or float(data.splash) > 400.0 \
				or float(data.bullet_life) < 0.05 or float(data.bullet_life) > 10.0:
			return _reject("武器", data, "弹丸数值超出范围")
	weapons[String(data.id)] = data
	return true

func register_item(data: Dictionary) -> bool:
	if not _valid(data, "道具", ["id", "name", "effects"]):
		return false
	_apply_defaults(data, {"ico": "🧩", "desc": "", "rarity": "common", "price": 30})
	if not _string_fields(data, ["id", "name", "ico", "desc", "rarity"]):
		return _reject("道具", data, "文本字段类型非法")
	if data.rarity not in Config.RARITIES:
		return _reject("道具", data, "rarity 非法")
	if String(data.id).strip_edges().is_empty() or String(data.name).strip_edges().is_empty() \
			or not _valid_effects(data.effects) or not _nonnegative_integer(data.price) \
			or int(data.price) > 300:
		return _reject("道具", data, "ID、名称、effects 或价格非法")
	items[String(data.id)] = data
	return true

func register_upgrade(data: Dictionary) -> bool:
	if not _valid(data, "升级", ["id", "name", "effects"]):
		return false
	_apply_defaults(data, {"ico": "✨", "desc": "", "rarity": "common", "price": 22})
	if not _string_fields(data, ["id", "name", "ico", "desc", "rarity"]):
		return _reject("升级", data, "文本字段类型非法")
	if data.rarity not in Config.RARITIES:
		return _reject("升级", data, "rarity 非法")
	if String(data.id).strip_edges().is_empty() or String(data.name).strip_edges().is_empty() \
			or not _valid_effects(data.effects) or not _nonnegative_integer(data.price) \
			or int(data.price) > 300:
		return _reject("升级", data, "ID、名称、effects 或价格非法")
	upgrades[String(data.id)] = data
	return true

func register_enemy(data: Dictionary) -> bool:
	if not _valid(data, "敌人", ["id", "name", "hp", "speed", "dmg", "r"]):
		return false
	_apply_defaults(data, {"xp": 1, "mat": 1, "color": "#d9534f",
		"shape": "circle", "ai": "chaser", "heart_chance": Config.HEAL_DROP_CHANCE,
		"status_resist": 0.0})
	if not _string_fields(data, ["id", "name", "color", "shape", "ai"]):
		return _reject("敌人", data, "文本字段类型非法")
	if data.has("is_boss") and typeof(data.is_boss) != TYPE_BOOL:
		return _reject("敌人", data, "is_boss 必须是布尔值")
	var ai: String = data.ai
	var declared_boss: bool = data.id == "boss" or ai == "boss" or bool(data.get("is_boss", false))
	# 仅阻止 mod 把内置普通敌人（追击者等）覆盖为 BOSS；内置 BOSS 池本身允许
	if declared_boss and Config.ENEMIES.has(data.id) \
			and not Config.BOSS_POOL.has(data.id):
		return _reject("敌人", data, "内置普通敌人 ID 不能覆盖为 BOSS")
	if declared_boss:
		ai = "boss"
		data["ai"] = "boss"
		data["is_boss"] = true
		_apply_defaults(data, {"ring_count": 14, "ring_cd": 2.4, "bspeed": 240.0})
	elif ai == "shooter":
		_apply_defaults(data, {"keep_dist": 270.0, "shoot_cd": 2.2, "bspeed": 300.0})
	if String(data.id).strip_edges().is_empty() or String(data.name).strip_edges().is_empty():
		return _reject("敌人", data, "ID/名称不能为空")
	if ai not in ["chaser", "runner", "shooter", "boss"] \
			or String(data.shape) not in ["circle", "square", "diamond"]:
		return _reject("敌人", data, "AI 或形状非法")
	for key in ["hp", "speed", "dmg", "r", "xp", "mat", "heart_chance"]:
		if not _finite_number(data.get(key)):
			return _reject("敌人", data, "%s 必须是有限数值" % key)
	if not _number_in_range(data.get("status_resist"), 0.0, 0.95):
		return _reject("敌人", data, "status_resist 必须是 0~0.95 的数值")
	# BOSS 允许超高血量（无尽后期/自定义数值）；普通敌人维持 5000 上限
	var hp_max := 1.0e9 if ai == "boss" else 5000.0
	if float(data.hp) <= 0.0 or float(data.hp) > hp_max \
			or float(data.speed) < 0.0 or float(data.speed) > 400.0 \
			or float(data.dmg) < 0.0 or float(data.dmg) > 200.0 \
			or float(data.r) < 5.0 or float(data.r) > 120.0 \
			or not _nonnegative_integer(data.xp) or int(data.xp) > 100 \
			or not _nonnegative_integer(data.mat) or int(data.mat) > 100 \
			or float(data.heart_chance) < 0.0 or float(data.heart_chance) > 1.0:
		return _reject("敌人", data, "通用数值超出范围")
	if not Color.html_is_valid(String(data.color)):
		return _reject("敌人", data, "颜色必须是 HTML 色值")
	if ai == "shooter":
		if not _positive_number(data.get("keep_dist")) or float(data.keep_dist) > 600.0 \
				or not _number_in_range(data.get("shoot_cd"), 0.05, 10.0) \
				or not _number_in_range(data.get("bspeed"), 1.0, 800.0):
			return _reject("敌人", data, "射手弹速/距离/间隔超出范围")
	elif ai == "boss":
		if not _positive_integer(data.get("ring_count")) or int(data.ring_count) > 40 \
				or not _number_in_range(data.get("ring_cd"), 0.05, 10.0) \
				or not _number_in_range(data.get("bspeed"), 1.0, 800.0):
			return _reject("敌人", data, "BOSS 弹速/弹数/间隔超出范围")
	enemies[String(data.id)] = data
	return true

func register_difficulty(data: Dictionary) -> bool:
	if not _valid(data, "难度", ["id", "name"]):
		return false
	_apply_defaults(data, {"desc": "", "hp_mult": 1.0, "dmg_mult": 1.0,
		"spawn_mult": 1.0, "elite_chance": 0.0})
	if not _string_fields(data, ["id", "name", "desc"]):
		return _reject("难度", data, "文本字段类型非法")
	if String(data.id).strip_edges().is_empty() or String(data.name).strip_edges().is_empty():
		return _reject("难度", data, "ID 不能为空")
	for key in ["hp_mult", "dmg_mult"]:
		if not _number_in_range(data.get(key), 0.2, 10.0):
			return _reject("难度", data, "%s 必须在 [0.2, 10]" % key)
	if not _number_in_range(data.spawn_mult, 0.2, 5.0):
		return _reject("难度", data, "spawn_mult 必须在 [0.2, 5]")
	if not _number_in_range(data.elite_chance, 0.0, 1.0):
		return _reject("难度", data, "elite_chance 必须在 [0, 1]")
	difficulties[String(data.id)] = data
	return true

## 五行反应：generate 相生（不消耗层数）/ overcome 相克（消耗层数并爆发）
## key = 两个不同五行按 Config.ELEMENTS 字母序拼接（如木生火 "fire+wood"）
func register_reaction(data: Dictionary) -> bool:
	if not _valid(data, "五行反应", ["id", "name", "type", "effect", "key"]):
		return false
	_apply_defaults(data, {"ico": "☯", "desc": "", "rarity": "common",
		"sfx": "", "shake": 0.0})
	if not _string_fields(data, ["id", "name", "ico", "desc", "rarity", "type", "sfx", "key"]):
		return _reject("五行反应", data, "文本字段类型非法")
	if String(data.id).strip_edges().is_empty() or String(data.name).strip_edges().is_empty():
		return _reject("五行反应", data, "ID/名称不能为空")
	var type_id := String(data.type)
	if type_id not in REACTION_TYPES:
		return _reject("五行反应", data, "type 必须是 generate/overcome")
	if data.rarity not in Config.RARITIES:
		return _reject("五行反应", data, "rarity 非法")
	var key := String(data.key)
	var parts := key.split("+")
	if parts.size() != 2 \
			or Config.reaction_key(String(parts[0]), String(parts[1])) != key:
		return _reject("五行反应", data,
			"key 必须是两个不同五行按字母序拼接（如 fire+wood），当前：%s" % key)
	if typeof(data.effect) != TYPE_DICTIONARY or (data.effect as Dictionary).is_empty():
		return _reject("五行反应", data, "effect 必须是非空对象")
	if not _number_in_range(data.get("shake"), 0.0, 20.0):
		return _reject("五行反应", data, "shake 必须在 [0, 20]")
	if not _valid_reaction_effect(data, type_id):
		return false
	reactions[String(data.id)] = data
	_reaction_keys[key] = String(data.id)
	return true

## effect 逐键校验：键白名单 + 状态 id 已注册 + 数值在安全区间
func _valid_reaction_effect(data: Dictionary, type_id: String) -> bool:
	var issue := _reaction_effect_issue(data.effect, type_id)
	if issue != "":
		return _reject("五行反应", data, issue)
	return true

## 反应 effect 的完整合法性检查，返回错误原因（"" = 合法）
func _reaction_effect_issue(effect: Dictionary, type_id: String) -> String:
	var allowed := OVERCOME_EFFECT_KEYS if type_id == "overcome" else GENERATE_EFFECT_KEYS
	for k in effect:
		if String(k) not in allowed:
			return "%s 反应不支持效果键 \"%s\"" % [type_id, k]
	if type_id == "overcome":
		if not _valid_status_amounts(effect.get("consume", {}), 1.0, 10.0):
			return "consume 必须是 状态 id -> [1,10] 层数 的非空对象"
		for key in ["aoe_dmg_scale", "execute_threshold", "armor_break", "dot_mult"]:
			if effect.has(key) and not _number_in_range(effect.get(key), 0.0, 20.0):
				return "%s 必须在 [0, 20]" % key
		if effect.has("execute_heal") \
				and not _number_in_range(effect.get("execute_heal"), 0.0, 1000.0):
			return "execute_heal 必须在 [0, 1000]"
		if effect.has("aoe_radius") \
				and not _number_in_range(effect.get("aoe_radius"), 0.0, 600.0):
			return "aoe_radius 必须在 [0, 600]"
		for key2 in ["armor_break_duration", "dot_duration"]:
			if effect.has(key2) and not _number_in_range(effect.get(key2), 0.0, 30.0):
				return "%s 必须在 [0, 30]" % key2
		return ""
	if effect.has("add_stacks") \
			and not _valid_status_amounts(effect.get("add_stacks"), 1.0, 10.0):
		return "add_stacks 必须是 状态 id -> [1,10] 层数 的非空对象"
	if effect.has("duration_add") \
			and not _valid_status_amounts(effect.get("duration_add"), 0.0, 30.0):
		return "duration_add 必须是 状态 id -> [0,30] 秒 的非空对象"
	for key3 in ["duration_mult", "dmg_mult"]:
		if effect.has(key3) and not _valid_status_amounts(effect.get(key3), 0.0, 10.0):
			return "%s 必须是 状态 id -> [0,10] 倍率 的非空对象" % key3
	if effect.has("spread") and not _valid_status_amounts(effect.get("spread"), 0.0, 400.0):
		return "spread 必须是 状态 id -> [0,400] 半径 的非空对象"
	if effect.has("crit_guarantee"):
		if typeof(effect.crit_guarantee) != TYPE_DICTIONARY \
				or (effect.crit_guarantee as Dictionary).is_empty():
			return "crit_guarantee 必须是非空对象"
		for sid in effect.crit_guarantee:
			if not Config.STATUS.has(String(sid)):
				return "crit_guarantee 状态 id 未注册：%s" % sid
	if effect.has("convert_dmg"):
		if typeof(effect.convert_dmg) != TYPE_DICTIONARY \
				or (effect.convert_dmg as Dictionary).is_empty():
			return "convert_dmg 必须是非空对象"
		for sid2 in effect.convert_dmg:
			if not Config.STATUS.has(String(sid2)) \
					or not Config.STATUS.has(String(effect.convert_dmg[sid2])):
				return "convert_dmg 两端状态 id 均需已注册"
	return ""
## “状态 id -> 数值”映射校验：非空、状态已注册、数值在 [low, high]
func _valid_status_amounts(value: Variant, low: float, high: float) -> bool:
	if typeof(value) != TYPE_DICTIONARY or (value as Dictionary).is_empty():
		return false
	for sid in value:
		if not Config.STATUS.has(String(sid)):
			return false
		if not _number_in_range(value[sid], low, high):
			return false
	return true

## params 逐键校验：键白名单 + 引用的五行/反应/状态真实存在

## patch 校验：目标反应必须已注册，且补丁并入原 effect 后仍通过反应自身的合法性检查
## 缺省字段补全（mod/编辑器漏填时兜底）
func _apply_defaults(data: Dictionary, defaults: Dictionary) -> void:
	for k in defaults:
		if not data.has(k):
			data[k] = defaults[k]

func _valid(data: Dictionary, kind: String, required: Array) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("Registry: %s 条目不是对象，已跳过" % kind)
		return false
	for k in required:
		if not data.has(k):
			push_warning("Registry: %s 缺少必填字段 \"%s\"，已跳过（id=%s）"
				% [kind, k, data.get("id", "?")])
			return false
	return true

func _reject(kind: String, data: Dictionary, reason: String) -> bool:
	push_warning("Registry: %s 条目无效（id=%s）：%s，已跳过" % [kind, data.get("id", "?"), reason])
	return false

func _string_fields(data: Dictionary, keys: Array) -> bool:
	for key in keys:
		if typeof(data.get(key)) != TYPE_STRING:
			return false
	return true

func _finite_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value))

func _positive_number(value: Variant) -> bool:
	return _finite_number(value) and float(value) > 0.0

func _number_in_range(value: Variant, minimum: float, maximum: float) -> bool:
	return _finite_number(value) and float(value) >= minimum and float(value) <= maximum

func _positive_integer(value: Variant) -> bool:
	return _finite_number(value) and int(value) >= 1 \
		and is_equal_approx(float(value), float(int(value)))

func _nonnegative_integer(value: Variant) -> bool:
	return _finite_number(value) and int(value) >= 0 \
		and is_equal_approx(float(value), float(int(value)))

func _valid_stat_values(stats: Dictionary) -> bool:
	for key in stats:
		if not STAT_LIMITS.has(key) or not _finite_number(stats[key]):
			return false
		var limits: Vector2 = STAT_LIMITS[key]
		if float(stats[key]) < limits.x or float(stats[key]) > limits.y:
			return false
	return true

func _valid_effects(effects: Variant) -> bool:
	if typeof(effects) != TYPE_DICTIONARY:
		return false
	for key in effects:
		if not EFFECT_LIMITS.has(key) or not _finite_number(effects[key]):
			return false
		if absf(float(effects[key])) > float(EFFECT_LIMITS[key]):
			return false
	return true

func _enemy_is_boss(data: Dictionary) -> bool:
	return bool(data.get("is_boss", false)) or String(data.get("ai", "")) == "boss"

# ------------------------------------------------------------
# 内置内容桥接（Config -> Registry）
# ------------------------------------------------------------

func _register_builtin() -> void:
	# 内置角色：stats 仅覆盖差异项（其余沿用 Config.PLAYER）
	characters = {
		"potato": {
			"id": "potato", "name": "土豆勇者", "ico": "🥔",
			"desc": "均衡的冒险家，各项属性标准，适合任何构筑",
			"color": "#e8b84b", "start_weapon": "pistol",
			"stats": {},
		},
		"berserker": {
			"id": "berserker", "name": "狂战士", "ico": "🪓",
			"desc": "嗜血近战：生命与伤害极高、自带护甲，但攻速与移速略降。初始武器：太刀",
			"color": "#d9534f", "start_weapon": "blade",
			"stats": { "max_hp": 130.0, "armor": 3.0, "dmg_mult": 1.25,
				"as_mult": 0.95, "speed_mult": 0.92, "crit_ch": 0.03 },
		},
		"ranger": {
			"id": "ranger", "name": "游侠", "ico": "🏹",
			"desc": "远程精准：高暴击高机动，放风筝打法，但身板脆弱。初始武器：狙击枪",
			"color": "#3bbfae", "start_weapon": "sniper",
			"stats": { "crit_ch": 0.15, "crit_mult": 2.4, "dodge": 0.10,
				"speed_mult": 1.10, "max_hp": 75.0, "armor": -1.0 },
		},
		"gambler": {
			"id": "gambler", "name": "赌徒", "ico": "🎲",
			"desc": "高风险高回报：暴击与闪避拉满、材料加成，但血薄甲脆、伤害不稳",
			"color": "#e8902a", "start_weapon": "pistol",
			"stats": { "crit_ch": 0.28, "crit_mult": 2.6, "dodge": 0.12,
				"harvesting": 0.35, "max_hp": 65.0, "armor": -2.0, "dmg_mult": 0.90 },
		},
		"farmer": {
			"id": "farmer", "name": "收获者", "ico": "🌾",
			"desc": "经济流：材料获取 +60%、超大拾取范围，用钱滚雪球碾压商店",
			"color": "#7ec850", "start_weapon": "pistol",
			"stats": { "harvesting": 0.60, "pickup_range": 260.0,
				"max_hp": 95.0, "dmg_mult": 0.92, "speed_mult": 1.02 },
		},
		"vampire": {
			"id": "vampire", "name": "血族", "ico": "🧛",
			"desc": "续航之王：击杀回血 + 持续回复，越战越勇，但生命上限很低",
			"color": "#b05ae0", "start_weapon": "knife",
			"stats": { "lifesteal": 2.0, "regen": 1.2, "dodge": 0.08,
				"max_hp": 70.0, "dmg_mult": 0.95, "speed_mult": 1.06 },
		},
		"guardian": {
			"id": "guardian", "name": "铁卫", "ico": "🐢",
			"desc": "不动如山：超高生命、护甲与回复，攻速补偿，代价是移速大幅降低",
			"color": "#5a6dbf", "start_weapon": "knife",
			"stats": { "max_hp": 165.0, "armor": 6.0, "regen": 0.5,
				"speed_mult": 0.82, "dodge": 0.0, "as_mult": 1.08 },
		},
	}
	weapons = {}
	for id in Config.WEAPONS:
		var w: Dictionary = Config.WEAPONS[id].duplicate()
		w["id"] = id
		w["price"] = int(Config.WEAPON_PRICES[id])
		w["shop_weight"] = float(Config.WEAPON_SHOP_WEIGHTS[id])
		register_weapon(w)
	items = {}
	for it in Config.ITEMS:
		var d: Dictionary = it.duplicate(true)
		register_item(d)
	upgrades = {}
	for u in Config.UPGRADES:
		var d2: Dictionary = u.duplicate(true)
		register_upgrade(d2)
	enemies = {}
	# AI 行为类型：chaser 追击 / runner 抖动冲刺 / shooter 风筝射击 / boss 环形弹幕
	var ai_map := { "grunt": "chaser", "runner": "runner", "tank": "chaser",
		"shooter": "shooter", "boss": "boss", "boss_spiral": "boss", "boss_summoner": "boss",
		"swarm": "chaser", "bomber": "runner", "wizard": "shooter",
		"shadow": "runner", "guard": "chaser", "chest_guard": "chaser" }
	for id2 in Config.ENEMIES:
		var e: Dictionary = Config.ENEMIES[id2].duplicate()
		e["id"] = id2
		e["ai"] = ai_map.get(id2, "chaser")
		if ai_map.get(id2, "") == "boss":
			e["is_boss"] = true
		register_enemy(e)
	difficulties = {
		"normal": { "id": "normal", "name": "普通", "desc": "标准挑战",
			"hp_mult": 1.0, "dmg_mult": 1.0, "spawn_mult": 1.0, "elite_chance": 0.0 },
		"hard": { "id": "hard", "name": "困难", "desc": "敌人更硬更痛，刷怪更密，混入精英怪",
			"hp_mult": 1.5, "dmg_mult": 1.3, "spawn_mult": 1.25, "elite_chance": 0.10 },
		"nightmare": { "id": "nightmare", "name": "噩梦", "desc": "精英成群，为成型的构筑准备",
			"hp_mult": 2.2, "dmg_mult": 1.6, "spawn_mult": 1.5, "elite_chance": 0.20 },
	}
	reactions = {}
	_reaction_keys = {}
	for rkey in Config.REACTIONS:
		var r: Dictionary = Config.REACTIONS[rkey].duplicate(true)
		r["key"] = String(rkey)
		register_reaction(r)

# ------------------------------------------------------------
# mod 加载：扫描目录下的 manifest.json
# ------------------------------------------------------------

func _load_mod_dir(base: String) -> int:
	var total := 0
	var dir := DirAccess.open(base)
	if dir == null:
		return 0   # 目录不存在（如用户还没建 user://mods）
	var subdirs := dir.get_directories()
	subdirs.sort()
	for sub in subdirs:
		var manifest_path := base.path_join(sub).path_join("manifest.json")
		if not FileAccess.file_exists(manifest_path) and sub == USER_MOD_ID \
				and FileAccess.file_exists(manifest_path + ".bak"):
			manifest_path += ".bak"
		if FileAccess.file_exists(manifest_path):
			total += _apply_manifest(manifest_path, sub)
	return total

func _apply_manifest(path: String, mod_name: String) -> int:
	var parsed := _read_manifest_path(path)
	if parsed.is_empty() and path == USER_MANIFEST_PATH:
		parsed = _read_manifest_path(USER_MANIFEST_PATH + ".bak")
	if parsed.is_empty():
		push_warning("Registry: mod 清单 JSON 解析失败 " + path)
		return 0
	var raw_content: Variant = parsed.get("content", {})
	if typeof(raw_content) != TYPE_DICTIONARY:
		push_warning("Registry: %s 的 content 必须是对象" % mod_name)
		return 0
	var content: Dictionary = raw_content
	var n := 0
	var handled := {
		"characters": register_character, "weapons": register_weapon,
		"items": register_item, "upgrades": register_upgrade,
		"enemies": register_enemy, "difficulties": register_difficulty,
		"reactions": register_reaction,
	}
	for key in handled:
		var entries: Variant = content.get(key, [])
		if typeof(entries) != TYPE_ARRAY:
			push_warning("Registry: %s 清单中的 %s 必须是数组" % [mod_name, key])
			continue
		for entry in entries:
			if typeof(entry) != TYPE_DICTIONARY:
				push_warning("Registry: %s 清单中的 %s 条目不是对象，已跳过" % [mod_name, key])
				continue
			entry["source"] = mod_name
			if handled[key].call(entry):
				n += 1
	# 顶层引用延迟到全部 Mod 内容加载后统一解析，支持同清单及跨清单引用。
	if parsed.has("boss"):
		if typeof(parsed.boss) == TYPE_STRING:
			_pending_boss_override = String(parsed.boss)
		else:
			push_warning("Registry: %s 的 boss 必须是敌人 ID 字符串" % mod_name)
	if parsed.has("spawn_table"):
		if typeof(parsed.spawn_table) == TYPE_DICTIONARY:
			for wave_key in parsed.spawn_table:
				_pending_spawn_table[wave_key] = {
					"entries": parsed.spawn_table[wave_key], "source": mod_name }
		else:
			push_warning("Registry: %s 的 spawn_table 必须是对象" % mod_name)
	return n

func _resolve_overrides() -> void:
	for character_id in characters:
		var character: Dictionary = characters[character_id]
		if not weapons.has(String(character.start_weapon)):
			push_warning("Registry: 角色 %s 的初始武器不存在，已回退手枪" % character_id)
			character["start_weapon"] = "pistol"
	if _pending_boss_override != "":
		if enemies.has(_pending_boss_override) and _enemy_is_boss(enemies[_pending_boss_override]):
			boss_override = _pending_boss_override
		else:
			push_warning("Registry: boss 覆盖不是有效 BOSS：" + _pending_boss_override)
	for raw_key in _pending_spawn_table:
		var wave := -1
		if typeof(raw_key) == TYPE_INT:
			wave = int(raw_key)
		elif typeof(raw_key) == TYPE_STRING and String(raw_key).is_valid_int():
			wave = int(raw_key)
		var staged: Dictionary = _pending_spawn_table[raw_key]
		var source := String(staged.get("source", "?"))
		if wave < 1 or wave >= Config.BOSS_WAVE:
			push_warning("Registry: %s 的 spawn_table 波次键无效：%s" % [source, raw_key])
			continue
		var entries: Variant = staged.get("entries")
		if not _valid_spawn_entries(entries):
			push_warning("Registry: %s 的第 %d 波刷怪表无效，已回退内置组合" % [source, wave])
			continue
		spawn_table[wave] = (entries as Array).duplicate(true)

func _valid_spawn_entries(entries: Variant) -> bool:
	if typeof(entries) != TYPE_ARRAY or entries.is_empty():
		return false
	for entry in entries:
		if typeof(entry) != TYPE_DICTIONARY:
			return false
		if typeof(entry.get("item")) != TYPE_STRING:
			return false
		var enemy_id: String = entry.item
		if enemy_id.is_empty() or not enemies.has(enemy_id) \
				or _enemy_is_boss(enemies[enemy_id]) or not _positive_number(entry.get("w")):
			return false
	return true

# ------------------------------------------------------------
# 工坊编辑器：创建/覆盖内容并持久化到 user://mods/workshop_user/manifest.json
# kind 用 manifest 复数键：characters/weapons/items/upgrades/enemies/difficulties
# ------------------------------------------------------------

func save_content(kind: String, entry: Dictionary) -> bool:
	var target: Dictionary
	var register_call: Callable
	match kind:
		"characters": target = characters; register_call = register_character
		"weapons": target = weapons; register_call = register_weapon
		"items": target = items; register_call = register_item
		"upgrades": target = upgrades; register_call = register_upgrade
		"enemies": target = enemies; register_call = register_enemy
		"difficulties": target = difficulties; register_call = register_difficulty
		"reactions": target = reactions; register_call = register_reaction
		_:
			push_warning("Registry: 未知内容类别 " + kind)
			return false
	var entry_id := String(entry.get("id", ""))
	var had_previous := target.has(entry_id)
	var previous: Dictionary = target.get(entry_id, {}).duplicate(true)
	if not register_call.call(entry):
		return false
	entry["source"] = USER_MOD_ID
	var manifest := _read_user_manifest()
	var content: Dictionary = manifest.get("content", {}) if typeof(manifest.get("content")) == TYPE_DICTIONARY else {}
	var arr: Array = content.get(kind, []) if typeof(content.get(kind, [])) == TYPE_ARRAY else []
	var idx := -1
	for i in arr.size():
		if typeof(arr[i]) == TYPE_DICTIONARY and arr[i].get("id", "") == entry.id:
			idx = i
			break
	if idx >= 0:
		arr[idx] = entry
	else:
		arr.append(entry)
	content[kind] = arr
	manifest["content"] = content
	if not _write_user_manifest(manifest):
		if had_previous:
			target[entry_id] = previous
		else:
			target.erase(entry_id)
		return false
	content_changed.emit()
	return true

func _read_manifest_path(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var json := JSON.new()
	var parse_err := json.parse(f.get_as_text())
	f.close()
	if parse_err != OK or typeof(json.data) != TYPE_DICTIONARY:
		return {}
	return json.data

func _read_user_manifest() -> Dictionary:
	var parsed := _read_manifest_path(USER_MANIFEST_PATH)
	if parsed.is_empty():
		parsed = _read_manifest_path(USER_MANIFEST_PATH + ".bak")
	if not parsed.is_empty():
		return parsed
	return {
		"id": USER_MOD_ID, "name": "我的创作",
		"desc": "由游戏内创意工坊编辑器创建", "content": {},
	}

func _write_user_manifest(manifest: Dictionary) -> bool:
	var dir := ProjectSettings.globalize_path(USER_MANIFEST_PATH.get_base_dir())
	if DirAccess.make_dir_recursive_absolute(dir) not in [OK, ERR_ALREADY_EXISTS]:
		push_warning("Registry: 无法创建用户 Mod 目录")
		return false
	var tmp := USER_MANIFEST_PATH + ".tmp"
	var bak := USER_MANIFEST_PATH + ".bak"
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("Registry: 无法写入 " + tmp)
		return false
	f.store_string(JSON.stringify(manifest, "  "))
	f.flush()
	var write_err := f.get_error()
	f.close()
	if write_err != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
		return false
	if _read_manifest_path(tmp).is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
		return false
	var final_abs := ProjectSettings.globalize_path(USER_MANIFEST_PATH)
	var tmp_abs := ProjectSettings.globalize_path(tmp)
	var bak_abs := ProjectSettings.globalize_path(bak)
	var bak_old := bak + ".old"
	var bak_old_abs := ProjectSettings.globalize_path(bak_old)
	var moved_existing := false
	var rotated_backup := false
	if FileAccess.file_exists(USER_MANIFEST_PATH):
		if _read_manifest_path(USER_MANIFEST_PATH).is_empty():
			if DirAccess.remove_absolute(final_abs) != OK:
				DirAccess.remove_absolute(tmp_abs)
				return false
		else:
			if FileAccess.file_exists(bak_old) and DirAccess.remove_absolute(bak_old_abs) != OK:
				DirAccess.remove_absolute(tmp_abs)
				return false
			if FileAccess.file_exists(bak):
				if DirAccess.rename_absolute(bak_abs, bak_old_abs) != OK:
					DirAccess.remove_absolute(tmp_abs)
					return false
				rotated_backup = true
			if DirAccess.rename_absolute(final_abs, bak_abs) != OK:
				if rotated_backup:
					DirAccess.rename_absolute(bak_old_abs, bak_abs)
				DirAccess.remove_absolute(tmp_abs)
				return false
			moved_existing = true
	if DirAccess.rename_absolute(tmp_abs, final_abs) != OK:
		if moved_existing:
			DirAccess.rename_absolute(bak_abs, final_abs)
		if rotated_backup:
			DirAccess.rename_absolute(bak_old_abs, bak_abs)
		return false
	if FileAccess.file_exists(bak_old):
		DirAccess.remove_absolute(bak_old_abs)
	return true
