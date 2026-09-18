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
var artifacts: Dictionary = {}    # id -> 法宝（触发式特效，同 Config.ARTIFACTS 条目结构）
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
	"crit_ch": Vector2(0.0, Config.CRIT_CHANCE_CAP), "crit_mult": Vector2(1.0, 100.0),
	"speed_mult": Vector2(0.01, 100.0), "base_speed": Vector2(1.0, 2000.0),
	"pickup_range": Vector2(0.0, 5000.0), "harvesting": Vector2(-0.99, 10.0),
	"lifesteal": Vector2(0.0, 10000.0),
	"status_chance": Vector2(0.0, 1.0), "status_dmg_mult": Vector2(0.0, 10.0),
	"status_dur_mult": Vector2(0.0, 10.0), "status_spread": Vector2(0.0, 1.0),
	"on_hit_burn": Vector2(0.0, 1.0), "on_hit_poison": Vector2(0.0, 1.0),
	"on_hit_freeze": Vector2(0.0, 1.0), "on_hit_slow": Vector2(0.0, 1.0),
	"on_hit_stun": Vector2(0.0, 1.0), "on_hit_bleed": Vector2(0.0, 1.0),
	# 武器行为加成（角色特性 / 道具 / 升级共用；加成语义）
	"bullet_speed_bonus": Vector2(0.0, 10.0), "bullet_range_bonus": Vector2(0.0, 10.0),
	"throw_speed_bonus": Vector2(0.0, 10.0), "throw_range_bonus": Vector2(0.0, 10.0),
	"melee_range_bonus": Vector2(0.0, 10.0), "aoe_radius_bonus": Vector2(0.0, 10.0),
	# 第 11 轮：喷射散布角倍率增量。⚠️ **可为负**（负 = 收窄）——
	#    这是全表唯一下限不是 0 的武器加成通道，别照抄上面的 `maxf(0.0, …)`。
	"proj_spread_mult": Vector2(-0.8, 4.0),
	"low_hp_dmg_bonus": Vector2(0.0, 5.0), "momentum_dmg_bonus": Vector2(0.0, 5.0),
	# 元素同化度（五行体系 §7）：0 = 无亲和，1.0 = 满。上限 2.0 是给 mod 的余量，
	# 游戏内实际由 §7.2 的分档上限约束（角色/道具各自有更严的口径）。
	# ⚠️ 这 5 键必须同时存在于 player._sanitize_stats 与 save_run 的两份表中，
	#    否则会出现「注册通过但存/读档判非法」→ 整档被拒（SaveRun.restore 返回 {}）。
	"assim_metal": Vector2(0.0, 2.0), "assim_wood": Vector2(0.0, 2.0),
	"assim_water": Vector2(0.0, 2.0), "assim_fire": Vector2(0.0, 2.0),
	"assim_earth": Vector2(0.0, 2.0),
}
const EFFECT_LIMITS := {
	"max_hp": 10000.0, "regen": 1000.0, "armor": 1000.0, "dodge": 0.95,
	"dmg_mult": 10.0, "as_mult": 10.0, "crit_ch": Config.CRIT_CHANCE_CAP, "crit_mult": 10.0,
	"speed_mult": 10.0, "base_speed": 2000.0, "pickup_range": 5000.0,
	"harvesting": 10.0, "lifesteal": 10000.0, "heal_flat": 10000.0, "heal_pct": 1.0,
	"status_chance": 1.0, "status_dmg_mult": 10.0, "status_dur_mult": 10.0,
	"status_spread": 1.0, "on_hit_burn": 1.0, "on_hit_poison": 1.0,
	"on_hit_freeze": 1.0, "on_hit_slow": 1.0, "on_hit_stun": 1.0, "on_hit_bleed": 1.0,
	"bullet_speed_bonus": 10.0, "bullet_range_bonus": 10.0, "melee_range_bonus": 10.0,
	"throw_speed_bonus": 10.0, "throw_range_bonus": 10.0,
	"aoe_radius_bonus": 10.0, "low_hp_dmg_bonus": 5.0, "momentum_dmg_bonus": 5.0,
	"proj_spread_mult": 0.8,   # 第 11 轮：单条喷嘴道具的散布改动上限（绝对值）
	# S5 元素同化度（§7）：5 个扁平键，单条效果上限与 STAT_LIMITS 一致（2.0）
	"assim_metal": 2.0, "assim_wood": 2.0, "assim_water": 2.0, "assim_fire": 2.0, "assim_earth": 2.0,
}

## 角色专属特性的实现类别（未知 kind 直接拒登，防 mod 写错字后静默无效）
##   stats    开局一次性注入 effects（与升级/道具同一套加法语义）
##   aura     光环：按 interval 对范围内敌人施加状态 / 伤害
##   thorns   荆棘：受击瞬间对周围敌人反击
##   momentum 战意：每波按击杀累积增伤
const TRAIT_KINDS := ["stats", "aura", "thorns", "momentum"]

## 武器外观族：决定弹丸 / 挥砍 / 爆炸的绘制形态
## （见 weapons/bullet.gd、slash.gd、explosion.gd 的 fx 分支）
## 刻意与 Config.WEAPONS 数值表分开放 —— 数值表只管平衡，美术表现集中一处便于统一调整。
## 武器配色走 status（火焰长剑橙、毒牙匕首绿、霜冻法杖冰蓝），所以同一外观族也能一眼区分元素。
## 缺失 / 未知 fx 由 bullet/slash 按 attack_type 兜底：外观错误不该让武器失效
##
## ⚠️ 本表只列**当前会出现的 id**：内置 5 把五行武器 + 5 个进化形态，
##    外加**已停用**的工坊包那 23 把旧武器（见下方 `FROZEN_PACK_WEAPONS`）。
##    （S2 前这里列的是内置表全量；内容迁出后同步跟过去，否则工坊包那 23 把会全部
##    退回按 attack_type 兜底的普通外观 —— 不报错，但外观静默劣化。）
const WEAPON_FX := {
	# ---- 内置：5 把五行武器 ----
	"knife": "slash",          # 金剑
	"flamethrower": "flame",   # 喷火枪
	"frost_staff": "frost",    # 水枪
	"thunder_gong": "thunder", # 土质炸弹
	"blight_bow": "bolt",      # 木弓
	# ---- 内置：五行武器的进化形态（S8 补做）—— 沿用基础体的外观族，只换色/尺寸 ----
	"knife_ex": "slash", "flamethrower_ex": "flame", "frost_staff_ex": "frost",
	"thunder_gong_ex": "thunder", "blight_bow_ex": "bolt",
	# ---- 工坊包 brotato_lite_core：枪械 / 弹道 ----
	"pistol": "bolt", "smg": "bolt", "pistol_ex": "bolt", "smg_ex": "bolt",
	"gatling": "bolt", "gold_bell": "bell",
	"shotgun": "pellet", "shotgun_ex": "pellet",
	# ---- 工坊包：元素 / 爆炸 ----
	"ember_fan": "flame",
	"rocket": "rocket", "grenade": "rocket",
	"sniper": "lance", "railgun": "lance",
	"frost_nova": "frost",
	"gold_scepter": "thunder",
	"vine_lash": "vine",
	# ---- 工坊包：近战 ----
	"blade": "slash", "blade_ex": "slash",
	"venom_dagger": "slash", "flame_jian": "slash",
	"tar_whip": "whip",
	"chaos_hammer": "smash", "frost_hammer": "smash",
}
const WEAPON_FX_KINDS := ["bolt", "pellet", "flame", "rocket", "lance",
	"frost", "thunder", "vine", "bell", "slash", "whip", "smash"]

## **已停用**的官方工坊包（`game/mods_disabled/brotato_lite_core/manifest.json`）里的
## 23 把武器 id。存在的唯一理由是给 `WEAPON_FX` 里那 23 条**刻意保留**的映射当白名单 ——
## 它们是「外观族表保留全量」这条设计的合法条目，不是写错的幽灵 id。
##
## ⚠️ 2026-09-17（第 7 轮）：包按用户要求从 `game/mods/` 移出（`registry.gd:146` 只扫
##    `res://mods` / `user://mods`）→ 这 23 把不再注册，`WEAPON_FX` 立刻出现 23 条"孤儿"。
##    冒烟的「孤儿映射」断言必须能区分「合法冻结条目」与「幽灵 id」，故需要这份清单。
##
## ⚠️⚠️ 移动 / 增删工坊包时**必须同步这里**：少写一个 → 合法的冻结条目会被判成幽灵而报红；
##    多写一个 → 等于给一个不存在的武器开了后门。冒烟有一条计数断言双向钉住这一点。
const FROZEN_PACK_WEAPONS := ["pistol", "smg", "shotgun", "rocket", "sniper", "blade",
	"venom_dagger", "tar_whip", "ember_fan", "vine_lash", "gold_bell", "frost_nova",
	"flame_jian", "chaos_hammer", "railgun", "frost_hammer", "gold_scepter",
	"pistol_ex", "smg_ex", "shotgun_ex", "blade_ex", "gatling", "grenade"]

## 五行反应：type 取值 + 各 type 允许的 effect 键
## 未知键直接拒登，防 mod 写错字后静默无效
const REACTION_TYPES := ["generate", "overcome"]
const GENERATE_EFFECT_KEYS := ["add_stacks", "duration_mult", "duration_add",
	"dmg_mult", "crit_guarantee", "convert_dmg", "spread"]
const OVERCOME_EFFECT_KEYS := ["consume", "aoe_dmg_scale", "aoe_radius",
	"execute_threshold", "execute_heal", "armor_break", "armor_break_duration",
	"dot_mult", "dot_duration"]

## 法宝：effect 载荷键白名单 + params 键白名单 + 叠层重置时机
## 未知键直接拒登，防 mod 写错字后静默无效（与五行反应同款策略）
const ARTIFACT_EFFECT_KEYS := ["patch", "bonus_dmg_pct", "chance", "radius",
	"apply_status", "stacks", "duration", "stat", "per_stack", "stack_max",
	"stack_reset", "dmg_mult", "heal_pct", "high_hp", "high_hp_armor",
	"low_hp", "low_hp_dmg_reduce", "add_stacks", "bonus_materials"]
const ARTIFACT_PARAM_KEYS := ["element", "key", "status", "hp_below"]
const ARTIFACT_PATCH_OPS := ["set", "add"]
const ARTIFACT_STACK_RESETS := ["wave", "run"]

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
## 出怪表（S4 元素闸门 §9.2）：`difficulty_id` 为空 = **不设闸门**（图鉴 / 存档校验用）。
## ⚠️ mod 覆盖的 `spawn_table` 也走 `Config.gate_pool` —— 否则工坊包只要覆盖一张波次表，
##    三档难度的元素节奏就被整条绕过，而且**不报错**（只表现为「简单难度怎么还有金怪」）。
func wave_composition(w: int, difficulty_id: String = "", player_element: String = "") -> Array:
	if spawn_table.has(w) and _valid_spawn_entries(spawn_table[w]):
		return Config.gate_pool(spawn_table[w], difficulty_id, player_element,
			Config.block_of(w))
	return Config.wave_composition(w, difficulty_id, player_element)

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
		{ "id": "normal", "name": "简单", "hp_mult": 1.0, "dmg_mult": 1.0, "spawn_mult": 1.0 })

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

func artifact_list() -> Array:
	return artifacts.values()

## 按 id 取法宝配置
func get_artifact(id: String) -> Dictionary:
	return artifacts.get(id, {})

## 法宝抽取池：排除已持有（每种限 1 件），按 稀有度权重 × shop_weight 加权
## progress = 波次（复用 Config.rarity_weight，越往后高品阶越多）
## boss=true 时 legendary 权重 ×Config.ARTIFACT_BOSS_LEGENDARY_MULT（BOSS 必掉更出彩）
## 返回 [{ "item": id, "w": weight }]，供 GameRng.weighted_pick 使用；全部已持有则返回空数组
## 法宝抽取池。
## affinity 为构筑亲和标签（Config.affinity_tags）：与当前角色 / 武器同系的法宝权重更高，
## 让玩家能顺着自己已经在走的路继续深耕，而不是被随机塞一件无关法宝
func artifact_pool(owned: Dictionary, wave: int, boss: bool = false,
		affinity: Array = []) -> Array:
	var pool: Array = []
	for id in artifacts:
		if owned.has(id):
			continue
		var a: Dictionary = artifacts[id]
		var rarity := String(a.get("rarity", "common"))
		var w := Config.rarity_weight(rarity, wave) * float(a.get("shop_weight", 1.0))
		w *= Config.affinity_mult(Config.entry_tags(a), affinity)
		if boss and rarity == "legendary":
			w *= Config.ARTIFACT_BOSS_LEGENDARY_MULT
		if w > 0.0:
			pool.append({ "item": id, "w": w })
	return pool

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
	if pool.is_empty() and weapons.has(Config.FALLBACK_WEAPON):
		# 理论上到不了这里（内置 5 把 shop_weight > 0）。留着是防「内置全被 mod 覆盖成
		# shop_weight = 0」的极端情况 —— 兜底值取开局池第一把，与 player/save_run 一致。
		pool.append({ "item": Config.FALLBACK_WEAPON, "w": 1.0 })
	return pool

func weapon_price(id: String) -> int:
	return int(weapons.get(id, {}).get("price", 30))

# ------------------------------------------------------------
# 注册 API（mod 加载与未来属性编辑器共用；同 id 覆盖 = mod 优先）
# ------------------------------------------------------------

func register_character(data: Dictionary) -> bool:
	if not _valid(data, "角色", ["id", "name"]):
		return false
	_apply_defaults(data, {"ico": "🧑", "desc": "", "color": "#e8b84b", "stats": {}})
	if not _string_fields(data, ["id", "name", "ico", "desc", "color"]):
		return _reject("角色", data, "文本字段类型非法")
	if String(data.id).strip_edges().is_empty() or String(data.name).strip_edges().is_empty():
		return _reject("角色", data, "ID/名称不能为空")
	if not Color.html_is_valid(data.color):
		return _reject("角色", data, "颜色必须是 HTML 色值")
	if typeof(data.stats) != TYPE_DICTIONARY or not _valid_stat_values(data.stats):
		return _reject("角色", data, "stats 必须是合法数值字典")
	if not _valid_character_trait(data):
		return false
	characters[String(data.id)] = data
	return true

## 角色专属特性校验：trait 可选（模组角色可以不带）；有则必须是完整可执行的描述。
## 宁可拒登也不"当作没有特性" —— 静默降级会让玩家选到一个看似有特色、实则裸奔的角色
func _valid_character_trait(data: Dictionary) -> bool:
	# 注意：不能用 data.trait 点号访问 —— Godot 4.7 里 trait 是保留关键字，
	# 只能走字典下标 data["trait"]
	if not data.has("trait") or typeof(data["trait"]) != TYPE_DICTIONARY:
		return true
	var t: Dictionary = data["trait"]
	if t.is_empty():
		return true
	if not _valid(t, "角色特性", ["id", "name", "kind"]):
		return false
	_apply_defaults(t, {"ico": "✨", "desc": ""})
	if not _string_fields(t, ["id", "name", "ico", "desc", "kind"]):
		return _reject("角色特性", data, "文本字段类型非法")
	if String(t.id).strip_edges().is_empty() or String(t.name).strip_edges().is_empty():
		return _reject("角色特性", data, "ID/名称不能为空")
	if String(t.kind) not in TRAIT_KINDS:
		return _reject("角色特性", data, "未知 kind：%s" % String(t.kind))
	# 印记：可选。显式声明空串合法（= 刻意「无印记」，如土豆勇者的均衡之道），
	# 但写错 id 必须拒登 —— 否则角色的元素风格会静默消失，玩家只看到「特色没生效」
	if t.has("sigil"):
		if typeof(t["sigil"]) != TYPE_STRING or not Config.sigil_valid(String(t["sigil"])):
			return _reject("角色特性", data, "未知印记 id：%s" % str(t["sigil"]))
	# 五行归属：可选。显式空串合法（= 刻意「无属性」）。
	# 写错必须拒登 —— 否则角色会静默落回「推断」路径，拿到与作者意图不同（甚至相反）的五行。
	if t.has("element"):
		var el := String(t["element"])
		if typeof(t["element"]) != TYPE_STRING or (el != "" and not Config.ELEMENTS.has(el)):
			return _reject("角色特性", data, "未知五行 element：%s" % str(t["element"]))
	if String(t.kind) == "stats":
		# effects 是「增量」语义，必须走 EFFECT_LIMITS：
		# STAT_LIMITS 描述的是角色 stats 的绝对值区间（crit_mult 下限 1.0），
		# 拿它校验增量会把合法的 "+0.4 暴伤" 判为非法
		if not _valid_effects(t.get("effects", {})):
			return _reject("角色特性", data, "effects 必须是合法数值字典")
	elif String(t.kind) == "aura":
		var sid := String(t.get("status", ""))
		if sid != "" and not Config.STATUS.has(sid):
			return _reject("角色特性", data, "未知状态 id：%s" % sid)
		if t.has("interval") and not _number_in_range(t.interval, 0.05, 10.0):
			return _reject("角色特性", data, "interval 必须在 [0.05, 10]")
		if t.has("chance") and not _number_in_range(t.chance, 0.0, 1.0):
			return _reject("角色特性", data, "chance 必须在 [0, 1]")
	elif String(t.kind) == "thorns":
		if not _number_in_range(t.get("dmg", 0.0), 0.0, 10000.0):
			return _reject("角色特性", data, "thorns 必须给出合法 dmg")
		if t.has("radius") and not _number_in_range(t.radius, 1.0, 600.0):
			return _reject("角色特性", data, "radius 必须在 [1, 600]")
	return true

func register_weapon(data: Dictionary) -> bool:
	if not _valid(data, "武器", ["id", "name", "cd", "dmg"]):
		return false
	if not data.has("attack_type"):
		data["attack_type"] = "melee" if data.has("range") and data.has("swing_arc") else "projectile"
	_apply_defaults(data, {"ico": "🔧", "desc": "", "rarity": "common", "sfx": "shoot_pistol",
		"bspeed": 540.0, "pellets": 1, "arc": 0.0, "spread": 0.0, "splash": 0.0,
		"bullet_life": 1.1, "shake": 0.0, "price": 30, "shop_weight": 1.0,
		"status": "", "status_chance": 1.0, "status_stacks": 1, "status_duration": 0.0,
		# 五行归属（五行体系 §2.5）：武器自带元素**覆盖**角色归属元素，
		# 决定输出侧关系（角色元素 vs 武器元素，§2.3-A）与受击侧的「来袭元素」。
		# 缺省 "" = 不声明 → 沿用角色归属（白板角色因此仍是白板，不吃任何修正）。
		"element": "",
		# fx 缺省为空：mod 武器不写外观族时，由弹丸/挥砍按 attack_type 兜底成普通弹/刀光
		"fx": ""})
	if not _string_fields(data, ["id", "name", "ico", "desc", "rarity", "sfx", "attack_type"]):
		return _reject("武器", data, "文本字段类型非法")
	# 五行归属：非法值**拒登**（而非静默清空）。
	# ⚠️ 这里是刻意与 fx 的「未知值降级」相反的处置 —— 外观写错只是不好看，
	#    而元素写错会让这把武器默默变成白板，玩家看到的伤害数字与内容表对不上，
	#    属于"内容表里有、游戏里没有"那一类最难查的静默失效。宁可拒登。
	if typeof(data.element) != TYPE_STRING:
		return _reject("武器", data, "element 必须是字符串")
	if String(data.element) != "" and not Config.ELEMENTS.has(String(data.element)):
		return _reject("武器", data, "element 五行非法：%s（应为 %s 之一，或空串）"
			% [data.element, ", ".join(Config.ELEMENTS)])
	# 外观族：未知值只提示并回退默认，不拒登 —— 外观写错不该让整把武器不可用
	if data.has("fx"):
		if typeof(data.fx) != TYPE_STRING:
			return _reject("武器", data, "fx 必须是字符串")
		if String(data.fx) != "" and String(data.fx) not in WEAPON_FX_KINDS:
			push_warning("Registry: 武器 %s 的 fx 未知（%s），已回退默认外观"
				% [data.get("id", "?"), data.fx])
			data["fx"] = ""
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
		"status_resist": 0.0, "element": ""})
	if not _string_fields(data, ["id", "name", "color", "shape", "ai", "element"]):
		return _reject("敌人", data, "文本字段类型非法")
	# 五行体系 §12-S1：element 必须合法或为空。空串 = 无属性（不吃元素修正）。
	# ⚠️ 这里不做「无属性自动推断」—— 元素是设计常量，从命名猜会埋雷（如 blood → metal）。
	if String(data.element) != "" and not Config.ELEMENTS.has(String(data.element)):
		return _reject("敌人", data, "element 必须是合法五行或空串")
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
	# ---- 五行机制字段（§12-S3）：护盾 / 穿甲 / 回血 / 死亡分裂 ----
	#
	# ⚠️ 为什么必须在这里显式校验：`_valid()` 只检查「必需字段是否存在」，
	#    **不拒绝未知字段** —— 所以一个写错的机制字段会**静默注册成功**，
	#    然后以「内容表里有、游戏里没效果」的面目出现。这正是最难查的一类问题。
	#    校验的目的不是"拦住 mod"，而是让错值变成一条**明确的 warning**。
	if data.has("shield") and not _number_in_range(data.get("shield"), 0.0, 5000.0):
		return _reject("敌人", data, "shield 必须是 0~5000 的数值")
	if data.has("shield_resist") and not _number_in_range(data.get("shield_resist"), 0.0, 0.95):
		return _reject("敌人", data, "shield_resist 必须是 0~0.95 的数值")
	if data.has("armor_pierce") and not _number_in_range(data.get("armor_pierce"), 0.0, 1.0):
		return _reject("敌人", data, "armor_pierce 必须是 0~1 的数值")
	if data.has("regen") and not _number_in_range(data.get("regen"), 0.0, 50.0):
		return _reject("敌人", data, "regen 必须是 0~50 的数值（HP/秒）")
	if data.has("regen_delay") and not _number_in_range(data.get("regen_delay"), 0.0, 10.0):
		return _reject("敌人", data, "regen_delay 必须是 0~10 的数值（秒）")
	if data.has("split_on_death") and not _valid_split(data.get("split_on_death"), String(data.id)):
		return _reject("敌人", data, "split_on_death 必须是 {type, count, hp_pct}，"
			+ "且 type 为已注册敌人或其自身")
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
		if not _number_in_range(data.get("dmg_cap_pct", 0.005), 0.001, 0.2):
			return _reject("敌人", data, "dmg_cap_pct 必须在 [0.001, 0.2]")
		if data.has("skills") and not _valid_boss_skills(data.skills):
			return _reject("敌人", data, "BOSS 技能配置非法")
	enemies[String(data.id)] = data
	return true

## 死亡分裂配置校验（§5.3）。`type` 必须是**已注册敌人**或**其自身**。
##
## ⚠️ 必须放行「自身」：`water_splitter` 的分裂目标就是它自己，
##    而校验发生在 `enemies[id] = data` **之前** → 只查 `enemies.has(t)` 会把
##    内置的分裂水灵自己判为非法（表现为"内容表里有、游戏里没有"，且 warning 看着像写错了）。
##    自引用的**递归护栏**不在这里管 —— 那是运行期的事（`Enemy._split_gen`）。
func _valid_split(v: Variant, self_id: String = "") -> bool:
	if typeof(v) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = v
	var t := String(d.get("type", ""))
	if t.is_empty() or (t != self_id and not enemies.has(t)):
		return false
	if not _number_in_range(d.get("count", 3), 1, 8):
		return false
	if not _number_in_range(d.get("hp_pct", 0.5), 0.05, 1.0):
		return false
	return true

## BOSS 技能白名单校验：type 必须是已实现形态，cd/count 等参数在合理区间。
## 缺省参数由 enemy._cast_boss_skill 兜底，这里只查显式写出的值。
const BOSS_SKILL_TYPES := ["fan", "aimed", "nova", "charge"]

func _valid_boss_skills(skills: Variant) -> bool:
	if typeof(skills) != TYPE_ARRAY or skills.size() > 6:
		return false
	for sk in skills:
		if typeof(sk) != TYPE_DICTIONARY:
			return false
		var stype := String(sk.get("type", ""))
		if stype not in BOSS_SKILL_TYPES:
			return false
		if not _number_in_range(sk.get("cd", 4.0), 0.5, 30.0):
			return false
		if sk.has("name") and typeof(sk.name) != TYPE_STRING:
			return false
		match stype:
			"fan":
				if not _number_in_range(sk.get("count", 5), 1, 12) \
						or not _number_in_range(sk.get("arc", 0.9), 0.1, 3.2) \
						or not _number_in_range(sk.get("bspeed", 300.0), 50.0, 800.0):
					return false
			"aimed":
				if not _number_in_range(sk.get("count", 3), 1, 8) \
						or not _number_in_range(sk.get("interval", 0.15), 0.05, 1.0) \
						or not _number_in_range(sk.get("bspeed", 420.0), 50.0, 900.0):
					return false
			"nova":
				if not _number_in_range(sk.get("count", 1), 1, 5) \
						or not _number_in_range(sk.get("radius", 110.0), 40.0, 300.0) \
						or not _number_in_range(sk.get("warn", 0.8), 0.3, 3.0):
					return false
			"charge":
				if not _number_in_range(sk.get("warn", 0.5), 0.2, 2.0) \
						or not _number_in_range(sk.get("duration", 0.45), 0.2, 1.5) \
						or not _number_in_range(sk.get("speed_mult", 6.0), 2.0, 12.0):
					return false
	return true

func register_difficulty(data: Dictionary) -> bool:
	if not _valid(data, "难度", ["id", "name"]):
		return false
	# resist_mult：元素抗性的难度系数（五行体系 §5.5.2）——
	#   简单 0.45 / 困难 0.60 / 噩梦 0.75，是怪物同化度 R 的加数项之一。
	# ⚠️ 必须在 _apply_defaults 里给出，否则 mod / 内置表里的该键会被静默丢弃。
	_apply_defaults(data, {"desc": "", "hp_mult": 1.0, "dmg_mult": 1.0,
		"spawn_mult": 1.0, "elite_chance": 0.0, "resist_mult": 0.45})
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
	# 上限 0.75：§5.5.1 规定普通怪的减伤极限就是 75%，难度系数不得单独突破它
	if not _number_in_range(data.resist_mult, 0.0, 0.75):
		return _reject("难度", data, "resist_mult 必须在 [0, 0.75]")
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
## 反应注册与法宝 patch 共用这里，保证两条路径的合法区间完全一致（不会漂移）
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

# ------------------------------------------------------------
# 法宝注册（Phase 3）：触发式特效，每种限 1 件
# ------------------------------------------------------------

func register_artifact(data: Dictionary) -> bool:
	if not _valid(data, "法宝", ["id", "name", "element", "rarity", "trigger",
			"params", "effect"]):
		return false
	_apply_defaults(data, {"ico": "🔮", "desc": "", "price": 110, "shop_weight": 1.0})
	if not _string_fields(data, ["id", "name", "ico", "desc", "rarity", "element", "trigger"]):
		return _reject("法宝", data, "文本字段类型非法")
	if String(data.id).strip_edges().is_empty() or String(data.name).strip_edges().is_empty():
		return _reject("法宝", data, "ID/名称不能为空")
	if data.rarity not in Config.RARITIES:
		return _reject("法宝", data, "rarity 非法")
	if String(data.element) not in Config.ELEMENTS:
		return _reject("法宝", data, "element 必须是五行之一：" + String(data.element))
	if String(data.trigger) not in Config.ARTIFACT_TRIGGERS:
		return _reject("法宝", data, "trigger 非法：" + String(data.trigger))
	if typeof(data.params) != TYPE_DICTIONARY:
		return _reject("法宝", data, "params 必须是对象（无过滤条件时给空对象）")
	if typeof(data.effect) != TYPE_DICTIONARY or (data.effect as Dictionary).is_empty():
		return _reject("法宝", data, "effect 必须是非空对象")
	# 法宝定位高于普通道具，价格上限 400（道具为 300）
	if not _nonnegative_integer(data.price) or int(data.price) > 400:
		return _reject("法宝", data, "price 必须是 [0, 400] 的整数")
	if not _number_in_range(data.shop_weight, 0.0, 5.0):
		return _reject("法宝", data, "shop_weight 必须在 [0, 5]")
	if not _valid_artifact_params(data):
		return false
	if not _valid_artifact_effect(data):
		return false
	artifacts[String(data.id)] = data
	return true

## params 逐键校验：键白名单 + 引用的五行/反应/状态真实存在
func _valid_artifact_params(data: Dictionary) -> bool:
	var params: Dictionary = data.params
	for k in params:
		var key := String(k)
		if key not in ARTIFACT_PARAM_KEYS:
			return _reject("法宝", data, "不支持的 params 键 \"%s\"" % key)
		match key:
			"element":
				if String(params.element) not in Config.ELEMENTS:
					return _reject("法宝", data, "params.element 必须是五行之一")
			"key":
				if not _reaction_keys.has(String(params.key)):
					return _reject("法宝", data,
						"params.key 不是已注册的五行反应：%s" % params.key)
			"status":
				if not Config.STATUS.has(String(params.status)):
					return _reject("法宝", data,
						"params.status 状态未注册：%s" % params.status)
			"hp_below":
				if not _number_in_range(params.hp_below, 0.0, 1.0):
					return _reject("法宝", data, "params.hp_below 必须在 [0, 1]")
	return true

## effect 逐键校验：键白名单 + 引用真实存在的状态/属性 + 数值在安全区间
func _valid_artifact_effect(data: Dictionary) -> bool:
	var effect: Dictionary = data.effect
	for k in effect:
		if String(k) not in ARTIFACT_EFFECT_KEYS:
			return _reject("法宝", data, "不支持的效果键 \"%s\"" % k)
	if effect.has("patch") and not _valid_artifact_patch(data, effect.patch):
		return false
	for key in ["chance", "bonus_dmg_pct", "heal_pct", "dmg_mult", "high_hp",
			"low_hp", "low_hp_dmg_reduce"]:
		if effect.has(key) and not _number_in_range(effect.get(key), 0.0, 10.0):
			return _reject("法宝", data, "%s 必须在 [0, 10]" % key)
	for key2 in ["high_hp_armor", "per_stack"]:
		if effect.has(key2) and not _number_in_range(effect.get(key2), 0.0, 1000.0):
			return _reject("法宝", data, "%s 必须在 [0, 1000]" % key2)
	if effect.has("radius") and not _number_in_range(effect.radius, 1.0, 600.0):
		return _reject("法宝", data, "radius 必须在 [1, 600]")
	if effect.has("duration") and not _number_in_range(effect.duration, 0.0, 30.0):
		return _reject("法宝", data, "duration 必须在 [0, 30]")
	for key3 in ["stacks", "add_stacks", "bonus_materials", "stack_max"]:
		if effect.has(key3) \
				and (not _positive_integer(effect.get(key3)) or int(effect[key3]) > 100):
			return _reject("法宝", data, "%s 必须是 [1, 100] 的整数" % key3)
	if effect.has("apply_status") and not Config.STATUS.has(String(effect.apply_status)):
		return _reject("法宝", data,
			"apply_status 状态未注册：%s" % effect.apply_status)
	if effect.has("stack_reset") and String(effect.stack_reset) not in ARTIFACT_STACK_RESETS:
		return _reject("法宝", data, "stack_reset 必须是 wave / run")
	if effect.has("stat"):
		var stat_id := String(effect.stat)
		if not STAT_LIMITS.has(stat_id):
			return _reject("法宝", data, "stat 不是可叠加属性：%s" % stat_id)
		if not _positive_number(effect.get("per_stack")):
			return _reject("法宝", data, "叠层法宝必须给出 > 0 的 per_stack")
		if not _positive_integer(effect.get("stack_max", 0)):
			return _reject("法宝", data, "叠层法宝必须给出 >= 1 的整数 stack_max")
		# 叠满后仍须落在属性区间内，防 mod 配出暴击率 900% 之类的溢出构筑
		var lim: Vector2 = STAT_LIMITS[stat_id]
		var peak := float(effect.per_stack) * float(int(effect.stack_max))
		if peak < lim.x or peak > lim.y:
			return _reject("法宝", data, "%s 叠满 %s 超出属性区间 %s"
				% [stat_id, peak, lim])
	return true

## patch 校验：目标反应必须已注册，且补丁并入原 effect 后仍通过反应自身的合法性检查
## 实际合并走 Config.apply_patch（与运行时同一函数），验的就是真正会执行的效果
func _valid_artifact_patch(data: Dictionary, patch: Variant) -> bool:
	if typeof(patch) != TYPE_DICTIONARY or (patch as Dictionary).is_empty():
		return _reject("法宝", data, "patch 必须是非空对象")
	var rkey := String(data.params.get("key", ""))
	if rkey == "":
		return _reject("法宝", data, "patch 类法宝的 params 必须给出 key（目标五行反应）")
	var rid := String(_reaction_keys.get(rkey, ""))
	var r: Dictionary = reactions.get(rid, {})
	if r.is_empty():
		return _reject("法宝", data, "patch 目标反应不存在：" + rkey)
	for op in patch:
		if String(op) not in ARTIFACT_PATCH_OPS:
			return _reject("法宝", data, "patch 只支持 set / add，当前：%s" % op)
		if typeof(patch[op]) != TYPE_DICTIONARY or (patch[op] as Dictionary).is_empty():
			return _reject("法宝", data, "patch.%s 必须是非空对象" % op)
	var merged := Config.apply_patch(r.get("effect", {}), patch)
	var issue := _reaction_effect_issue(merged, String(r.get("type", "")))
	if issue != "":
		return _reject("法宝", data, "patch 后的反应效果非法：%s" % issue)
	return true

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
		# ============================================================
		# 内置角色池：**只启用 6 个**（五行体系 §3.2.5 第 5 轮定稿）
		#
		# 沧溟原话：「我只要我自己预设的 6 个角色和五种武器，其他武器后续增加」
		#
		#   potato（白板）+ 5 个元素修士（金/木/水/火/土）
		#
		# 被冻结的 11 个（berserker/ranger/farmer/vampire/guardian/pyromancer/
		# druid/swordmaster/tidecaller/gunner/warlord）与 23 把旧武器原先放在官方工坊包
		# `game/mods/brotato_lite_core/manifest.json`，但那份清单只带 characters/weapons，
		# 而 `_load_mod_dir`（`registry.gd:146`）**无条件扫 `res://mods`** →
		# 它们会跟着"内置内容"一起进角色选择页与商店武器池。
		#
		# ⚠️ 2026-09-17（第 7 轮）用户反馈「角色没删干净 / 其他武器还能选到」→
		#    该目录已整体**搬到 `game/mods_disabled/brotato_lite_core/`**（文件保留，未删）。
		#    要重新启用：把目录移回 `game/mods/` 即可（代码零改动），
		#    但**必须同步改回 `smoke_test.gd` 的两组断言**（内置内容计数 + 印记分支），
		#    否则会把"包回来了"判绿。
		# ============================================================
		"potato": {
			"id": "potato", "name": "土豆勇者", "ico": "🥔",
			"desc": "均衡的冒险家，各项属性标准，适合任何构筑",
			"color": "#e8b84b",
			"stats": {},
			"trait": {
				"id": "even_keel", "name": "均衡之道", "ico": "✨",
				"desc": "伤害 +5% / 攻速 +2.5% / 移速 +5%，材料获取 +10%：没有短板，但也不走极端",
				"kind": "stats",
				# 显式声明「无印记」：均衡之道刻意不带任何元素 / 风格倾向。
				# 不写的话会被 effects 里的 speed_mult 推导成「疾风」，与角色定位矛盾
				"sigil": "",
				# ⚠️ 显式声明「无元素」，这是**刻意**的：白板角色是五行体系的对照组，
				#    攻守两侧都不参与任何元素修正（§2.3 的 element_relation 遇空串返回 other/0）。
				#    不写这一条虽然也会被推导成 ""（sigil 是空串 → 推导链落空），
				#    但那样是「碰巧对」—— 一旦哪天给均衡之道补了 status 类效果，
				#    就会莫名变成元素角色。显式声明把语义钉死。
				"element": "",
				"effects": { "dmg_mult": 0.05, "as_mult": 0.025, "speed_mult": 0.05,
					"harvesting": 0.10 },
			},
			"skill": {
				"name": "丰收鼓舞", "ico": "✨", "desc": "8 秒内伤害 +25%、攻速 +12.5%、移速 +15%", "cd": 15.0,
				"kind": "buff", "duration": 8.0,
				"effects": { "dmg_mult": 0.25, "as_mult": 0.125, "speed_mult": 0.15 },
			},
		},
		# ============================================================
		# 五元素修士（§3.2）
		#
		# 「元素亲和」的完整定义（§3.2 已澄清）：**本系双向 ±10%**，
		# 不是独立机制 —— 它就是 §2.3 两张表里「同属性」那一行的取值：
		#     本元素**造成**的伤害 +10% → 落在 §2.3-A「同属 +10%」的 out 列
		#     本元素**受到**的伤害 −10% → 落在 §2.3-B「同属 −10%」的 hit 基数
		# 数值已定稿 10%（沧溟 2026-09-14 确认，规格 3 原话的 25% 作废）：
		# 同属减伤要从基础 −10% 被同化度一路推到 −90% cap，基础用小值才留出成长空间。
		#
		# ⚠️ 因此这 5 个角色的 stats **不需要**任何元素加成字段 —— 亲和由
		#    `trait.element` + §2.3 关系表自动生效。写进 stats 反而会双重计算。
		#    这里只做「同其他角色等量级」的常规属性补正。
		#
		# ⚠️ 每个角色**必须**显式写 `trait.element`（`element_for_character` 第 1 步），
		#    否则会退到「五行印记 → 技能状态 → 特性状态」的推导链，
		#    那条链会拿 attr 去反推元素，语义上属于"碰巧"而非"声明"。
		# ============================================================
		"metal_adept": {
			"id": "metal_adept", "name": "鎏金修士", "ico": "⚔",
			"desc": "金系：本系伤害 +10%、受本系伤害 -10%。攻速与暴击见长，克制木属性敌人",
			"color": "#dfe6f0",
			# ⚠️ `crit_mult` 在角色 stats 里是**倍率**（`dmg *= stats.crit_mult`，基线 1.0，
			#    `player.gd:651` 有 `maxf(1.0, ...)` 下限），不是"增量百分比"。
			#    写 0.15 会被 clamp 到 1.0 = **完全没有加成且不报错**（静默失效）。
			#    +15% 暴伤 ⇒ 2.15。对照：ranger 2.6 / swordmaster 2.3（纯暴击定位更高）。
			"stats": { "crit_ch": 0.03, "crit_mult": 2.15, "as_mult": 1.03, "max_hp": 95.0 },
			"trait": {
				"id": "metal_affinity", "name": "金之亲和", "ico": "⚔",
				"desc": "金系伤害 +10%、受金系伤害 -10%（同属性双向亲和，见 §3.2）",
				"kind": "stats", "element": "metal",
				"effects": { "crit_ch": 0.02 },
			},
			"skill": {
				"name": "金锋斩", "ico": "⚔", "desc": "对周围敌人造成 1.6 倍伤害并施加 2 层流血", "cd": 13.0,
				"kind": "nova_status", "status": "bleed", "stacks": 2, "radius": 215.0, "dmg": 26.0,
			},
		},
		"wood_adept": {
			"id": "wood_adept", "name": "青囊修士", "ico": "🌿",
			"desc": "木系：本系伤害 +10%、受本系伤害 -10%。持续伤害与回复见长，克制土属性敌人",
			"color": "#7ec850",
			"stats": { "status_dmg_mult": 0.25, "status_dur_mult": 0.20, "regen": 0.3, "max_hp": 92.0 },
			"trait": {
				"id": "wood_affinity", "name": "木之亲和", "ico": "🌿",
				"desc": "木系伤害 +10%、受木系伤害 -10%（同属性双向亲和，见 §3.2）",
				"kind": "stats", "element": "wood",
				"effects": { "status_dmg_mult": 0.15 },
			},
			"skill": {
				"name": "青囊回春", "ico": "🌿", "desc": "立即回复 30% 生命，并给周围敌人施加 2 层中毒", "cd": 14.0,
				"kind": "self_heal", "heal_pct": 0.30, "stun_radius": 200.0, "stun_dur": 0.0,
			},
		},
		"water_adept": {
			"id": "water_adept", "name": "玄水修士", "ico": "💧",
			"desc": "水系：本系伤害 +10%、受本系伤害 -10%。控场与机动见长，克制火属性敌人",
			"color": "#8fd8ff",
			"stats": { "status_chance": 0.15, "status_dur_mult": 0.25, "speed_mult": 1.06, "max_hp": 90.0 },
			"trait": {
				"id": "water_affinity", "name": "水之亲和", "ico": "💧",
				"desc": "水系伤害 +10%、受水系伤害 -10%（同属性双向亲和，见 §3.2）",
				"kind": "stats", "element": "water",
				"effects": { "status_dur_mult": 0.15 },
			},
			"skill": {
				"name": "玄水凝霜", "ico": "💧", "desc": "对周围敌人施加 3 层减速并造成伤害", "cd": 12.0,
				"kind": "nova_status", "status": "slow", "stacks": 3, "radius": 225.0, "dmg": 18.0,
			},
		},
		"fire_adept": {
			"id": "fire_adept", "name": "赤焰修士", "ico": "🔥",
			"desc": "火系：本系伤害 +10%、受本系伤害 -10%。爆发与异常命中见长，克制金属性敌人",
			"color": "#ff7a3c",
			"stats": { "status_dmg_mult": 0.30, "status_chance": 0.12, "dmg_mult": 1.04, "max_hp": 88.0, "armor": -1.0 },
			"trait": {
				"id": "fire_affinity", "name": "火之亲和", "ico": "🔥",
				"desc": "火系伤害 +10%、受火系伤害 -10%（同属性双向亲和，见 §3.2）",
				"kind": "stats", "element": "fire",
				"effects": { "status_dmg_mult": 0.20 },
			},
			"skill": {
				"name": "赤焰焚天", "ico": "🔥", "desc": "对周围敌人造成伤害并施加 3 层燃烧", "cd": 12.0,
				"kind": "nova_status", "status": "burn", "stacks": 3, "radius": 220.0, "dmg": 22.0,
			},
		},
		"earth_adept": {
			"id": "earth_adept", "name": "厚土修士", "ico": "🪨",
			"desc": "土系：本系伤害 +10%、受本系伤害 -10%。厚血高甲见长，克制水属性敌人",
			"color": "#ffd24a",
			"stats": { "max_hp": 135.0, "armor": 4.0, "dmg_mult": 1.05, "speed_mult": 0.94 },
			"trait": {
				"id": "earth_affinity", "name": "土之亲和", "ico": "🪨",
				"desc": "土系伤害 +10%、受土系伤害 -10%（同属性双向亲和，见 §3.2）",
				"kind": "stats", "element": "earth",
				"effects": { "armor": 2.0 },
			},
			"skill": {
				"name": "厚土镇岳", "ico": "🪨", "desc": "对周围敌人造成高额伤害并施加 2 层眩晕", "cd": 15.0,
				"kind": "nova_status", "status": "stun", "stacks": 2, "radius": 200.0, "dmg": 30.0,
			},
		},
	}
	weapons = {}
	for id in Config.WEAPONS:
		var w: Dictionary = Config.WEAPONS[id].duplicate()
		w["id"] = id
		# price / shop_weight 已内联在 Config.WEAPONS 里，由 register_weapon 的 _apply_defaults
		# 兜底（缺省 price 30 / shop_weight 1.0）。这里不再从并行字典注入 —— 加武器只需改一处。
		w["fx"] = String(WEAPON_FX.get(id, ""))   # 外观族（缺省由弹丸/挥砍按攻击类型兜底）
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
	#
	# ⚠️⚠️ `ai_map` 是**历史遗留的并行表**，同时它也是**兜底表**：
	#     `Config.ENEMIES[id].ai` 显式声明优先，本表只在没写时兜底。
	#     曾经的写法是 `e["ai"] = ai_map.get(id2, "chaser")` —— 那会**无条件覆盖**内容表里
	#     写的 ai，把「赤焰法师 ai=shooter」静默改成 chaser：怪不再风筝，反而贴脸冲，
	#     同时 `keep_dist` / `shoot_cd` / `bspeed` 三个字段全部变成死数据，**全程无报错**。
	#     这正是「内容表里有、游戏里没效果」那一类问题，别再退回旧写法。
	#     （后续可把 ai 全量迁进 Config.ENEMIES 并删掉本表，属独立小重构，不在 S3 范围内。）
	var ai_map := { "grunt": "chaser", "runner": "runner", "tank": "chaser",
		"shooter": "shooter", "boss": "boss", "boss_spiral": "boss", "boss_summoner": "boss",
		"swarm": "chaser", "bomber": "runner", "wizard": "shooter",
		"shadow": "runner", "guard": "chaser", "chest_guard": "chaser",
		# ---- Phase 2 五行阵营（10 敌人 + 3 BOSS） ----
		"fire_imp": "runner", "fire_shaman": "shooter",
		"wood_sprite": "chaser", "vine_beast": "chaser",
		"metal_puppet": "chaser", "blade_monk": "runner",
		"water_nymph": "shooter", "ice_witch": "shooter",
		"earth_golem": "chaser", "stone_titan": "chaser",
		"boss_phoenix": "boss", "boss_leviathan": "boss", "boss_titan": "boss",
		# ---- 五行基础怪（§12-S3）：只有赤焰法师是远程，其余贴脸 ----
		"metal_guard": "chaser", "wood_healer": "chaser", "water_splitter": "chaser",
		"fire_caster": "shooter", "earth_bulwark": "chaser" }
	for id2 in Config.ENEMIES:
		var e: Dictionary = Config.ENEMIES[id2].duplicate()
		e["id"] = id2
		e["ai"] = String(Config.ENEMIES[id2].get("ai", ai_map.get(id2, "chaser")))
		if ai_map.get(id2, "") == "boss":
			e["is_boss"] = true
		register_enemy(e)
	difficulties = {
		# ⚠️ 只改 `name`（显示名），**id 一律不动** —— `Config.DIFFICULTY_COLORS` /
		#    `RunRules.BUILTIN_DIFF_IDS` / 存档 / 每日挑战的 difficulty_id 全按 id 写，
		#    改 id 会全线崩（§9.1）。
		# S4 起「难度」的首要含义是**元素出场节奏**（§9.2 闸门），数值只是第二重。
		"normal": { "id": "normal", "name": "简单", "desc": "教学 · 危险元素最晚出现",
			"hp_mult": 1.0, "dmg_mult": 0.9, "spawn_mult": 1.0, "elite_chance": 0.0,
			"resist_mult": 0.45 },
		"hard": { "id": "hard", "name": "困难", "desc": "敌人更硬更痛，刷怪更密，混入精英怪",
			"hp_mult": 1.5, "dmg_mult": 1.3, "spawn_mult": 1.25, "elite_chance": 0.10,
			"resist_mult": 0.60 },
		"nightmare": { "id": "nightmare", "name": "噩梦", "desc": "精英成群，为成型的构筑准备",
			"hp_mult": 2.2, "dmg_mult": 1.6, "spawn_mult": 1.5, "elite_chance": 0.20,
			"resist_mult": 0.75 },
	}
	reactions = {}
	_reaction_keys = {}
	for rkey in Config.REACTIONS:
		var r: Dictionary = Config.REACTIONS[rkey].duplicate(true)
		r["key"] = String(rkey)
		register_reaction(r)
	# 法宝必须在反应之后注册：patch 类法宝要校验 params.key 指向的反应已存在
	artifacts = {}
	for a in Config.ARTIFACTS:
		register_artifact(a.duplicate(true))

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
		# 法宝排最后：同一清单里新增反应 + patch 该反应的法宝时，反应先落地
		"artifacts": register_artifact,
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
		"artifacts": target = artifacts; register_call = register_artifact
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
