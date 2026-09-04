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

var boss_override := ""           # manifest 顶层 "boss"：自定义最终 BOSS 的敌人 id
var spawn_table: Dictionary = {}  # manifest 顶层 "spawn_table"：{波次(int): [{item,w}]} 覆盖内置组合

const USER_MOD_ID := "workshop_user"
const USER_MANIFEST_PATH := "user://mods/workshop_user/manifest.json"

func _ready() -> void:
	reload_content()

## 重置为内置内容并重新加载全部 mods（工坊"重新加载"也走这里）
func reload_content() -> void:
	_register_builtin()
	boss_override = ""
	spawn_table = {}
	var n := 0
	for base in ["res://mods", "user://mods"]:
		n += _load_mod_dir(base)
	if n > 0:
		print("Registry: 已加载 %d 条自定义内容" % n)
	content_changed.emit()

## 最终 BOSS 敌人 id（mod 可覆盖）
func boss_id() -> String:
	return boss_override if boss_override != "" and enemies.has(boss_override) else "boss"

## 某波刷怪组合：spawn_table 覆盖优先，否则内置曲线
func wave_composition(w: int) -> Array:
	if spawn_table.has(w):
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

## 商店武器权重池：mod 武器默认 shop_weight=1.0
func shop_weapon_pool() -> Array:
	var pool: Array = []
	for id in weapons:
		pool.append({ "item": id, "w": float(weapons[id].get("shop_weight", 1.0)) })
	return pool

func weapon_price(id: String) -> int:
	return int(weapons[id].get("price", 30))

# ------------------------------------------------------------
# 注册 API（mod 加载与未来属性编辑器共用；同 id 覆盖 = mod 优先）
# ------------------------------------------------------------

func register_character(data: Dictionary) -> bool:
	if not _valid(data, "角色", ["id", "name"]):
		return false
	_apply_defaults(data, {"ico": "🧑", "desc": "", "color": "#e8b84b",
		"start_weapon": "pistol", "stats": {}})
	characters[data.id] = data
	return true

func register_weapon(data: Dictionary) -> bool:
	if not _valid(data, "武器", ["id", "name", "cd", "dmg"]):
		return false
	_apply_defaults(data, {"ico": "🔧", "desc": "", "rarity": "common",
		"bspeed": 540.0, "price": 30, "shop_weight": 1.0})
	weapons[data.id] = data
	return true

func register_item(data: Dictionary) -> bool:
	if not _valid(data, "道具", ["id", "name", "effects"]):
		return false
	_apply_defaults(data, {"ico": "🧩", "desc": "", "rarity": "common", "price": 30})
	items[data.id] = data
	return true

func register_upgrade(data: Dictionary) -> bool:
	if not _valid(data, "升级", ["id", "name", "effects"]):
		return false
	_apply_defaults(data, {"ico": "✨", "desc": "", "rarity": "common", "price": 22})
	upgrades[data.id] = data
	return true

func register_enemy(data: Dictionary) -> bool:
	if not _valid(data, "敌人", ["id", "name", "hp", "speed", "dmg", "r"]):
		return false
	# 可选字段补默认（防止掉落/绘制读到 null）
	_apply_defaults(data, {"xp": 1, "mat": 1, "color": "#d9534f",
		"shape": "circle", "ai": "chaser"})
	enemies[data.id] = data
	return true

func register_difficulty(data: Dictionary) -> bool:
	if not _valid(data, "难度", ["id", "name"]):
		return false
	_apply_defaults(data, {"desc": "", "hp_mult": 1.0, "dmg_mult": 1.0, "spawn_mult": 1.0})
	difficulties[data.id] = data
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

# ------------------------------------------------------------
# 内置内容桥接（Config -> Registry）
# ------------------------------------------------------------

func _register_builtin() -> void:
	characters = {
		"potato": {
			"id": "potato", "name": "土豆勇者", "ico": "🥔",
			"desc": "均衡的冒险家，各项属性标准",
			"color": "#e8b84b", "start_weapon": "pistol",
			"stats": Config.PLAYER.duplicate(),
		},
	}
	weapons = {}
	for id in Config.WEAPONS:
		var w: Dictionary = Config.WEAPONS[id].duplicate()
		w["id"] = id
		w["price"] = int(Config.WEAPON_PRICES[id])
		w["shop_weight"] = float(Config.WEAPON_SHOP_WEIGHTS[id])
		weapons[id] = w
	items = {}
	for it in Config.ITEMS:
		var d: Dictionary = it.duplicate()
		items[d.id] = d
	upgrades = {}
	for u in Config.UPGRADES:
		var d2: Dictionary = u.duplicate()
		upgrades[d2.id] = d2
	enemies = {}
	# AI 行为类型：chaser 追击 / runner 抖动冲刺 / shooter 风筝射击 / boss 环形弹幕
	var ai_map := { "grunt": "chaser", "runner": "runner", "tank": "chaser",
		"shooter": "shooter", "boss": "boss" }
	for id2 in Config.ENEMIES:
		var e: Dictionary = Config.ENEMIES[id2].duplicate()
		e["id"] = id2
		e["ai"] = ai_map.get(id2, "chaser")
		if id2 == "boss":
			e["is_boss"] = true
		enemies[id2] = e
	difficulties = {
		"normal": { "id": "normal", "name": "普通", "desc": "标准挑战",
			"hp_mult": 1.0, "dmg_mult": 1.0, "spawn_mult": 1.0 },
		"hard": { "id": "hard", "name": "困难", "desc": "敌人更硬更痛，刷怪更密",
			"hp_mult": 1.5, "dmg_mult": 1.3, "spawn_mult": 1.15 },
		"nightmare": { "id": "nightmare", "name": "噩梦", "desc": "为构筑成型的老手准备",
			"hp_mult": 2.2, "dmg_mult": 1.6, "spawn_mult": 1.3 },
	}

# ------------------------------------------------------------
# mod 加载：扫描目录下的 manifest.json
# ------------------------------------------------------------

func _load_mod_dir(base: String) -> int:
	var total := 0
	var dir := DirAccess.open(base)
	if dir == null:
		return 0   # 目录不存在（如用户还没建 user://mods）
	for sub in dir.get_directories():
		var manifest_path := base.path_join(sub).path_join("manifest.json")
		if FileAccess.file_exists(manifest_path):
			total += _apply_manifest(manifest_path, sub)
	return total

func _apply_manifest(path: String, mod_name: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("Registry: 无法读取 " + path)
		return 0
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("Registry: mod 清单 JSON 解析失败 " + path)
		return 0
	# 顶层覆盖：最终 BOSS / 波次刷怪组合
	if parsed.has("boss") and typeof(parsed.boss) == TYPE_STRING:
		boss_override = parsed.boss
	if typeof(parsed.get("spawn_table")) == TYPE_DICTIONARY:
		for k in parsed.spawn_table:
			spawn_table[int(k)] = parsed.spawn_table[k]
	var content: Dictionary = parsed.get("content", {})
	var n := 0
	var handled := {
		"characters": register_character, "weapons": register_weapon,
		"items": register_item, "upgrades": register_upgrade,
		"enemies": register_enemy, "difficulties": register_difficulty,
	}
	for key in handled:
		for entry in content.get(key, []):
			if typeof(entry) != TYPE_DICTIONARY:
				push_warning("Registry: %s 清单中的 %s 条目不是对象，已跳过" % [mod_name, key])
				continue
			entry["source"] = mod_name   # 工坊 UI 显示来源
			if handled[key].call(entry):
				n += 1
	return n

# ------------------------------------------------------------
# 工坊编辑器：创建/覆盖内容并持久化到 user://mods/workshop_user/manifest.json
# kind 用 manifest 复数键：characters/weapons/items/upgrades/enemies/difficulties
# ------------------------------------------------------------

func save_content(kind: String, entry: Dictionary) -> bool:
	var ok := false
	match kind:
		"characters": ok = register_character(entry)
		"weapons": ok = register_weapon(entry)
		"items": ok = register_item(entry)
		"upgrades": ok = register_upgrade(entry)
		"enemies": ok = register_enemy(entry)
		"difficulties": ok = register_difficulty(entry)
		_:
			push_warning("Registry: 未知内容类别 " + kind)
			return false
	if not ok:
		return false
	entry["source"] = USER_MOD_ID
	var manifest := _read_user_manifest()
	var content: Dictionary = manifest.get("content", {})
	var arr: Array = content.get(kind, [])
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
	_write_user_manifest(manifest)
	content_changed.emit()
	return true

func _read_user_manifest() -> Dictionary:
	if FileAccess.file_exists(USER_MANIFEST_PATH):
		var f := FileAccess.open(USER_MANIFEST_PATH, FileAccess.READ)
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if typeof(parsed) == TYPE_DICTIONARY:
			return parsed
	return {
		"id": USER_MOD_ID, "name": "我的创作",
		"desc": "由游戏内创意工坊编辑器创建", "content": {},
	}

func _write_user_manifest(manifest: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(USER_MANIFEST_PATH.get_base_dir())
	var f := FileAccess.open(USER_MANIFEST_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("Registry: 无法写入 " + USER_MANIFEST_PATH)
		return
	f.store_string(JSON.stringify(manifest, "  "))
