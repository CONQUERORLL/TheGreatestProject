extends Node
## 图鉴解锁 + 跨局统计 + 成就 的持久层（user://codex.json）
## - 图鉴：状态/武器/道具/升级/敌人 首次遇见或获得即永久解锁
## - 统计：击杀/波次/BOSS/进化/购买/状态触发/局数/最高分等累计计数器
## - 成就：由统计阈值判定，达成后广播 EventBus.achievement_unlocked 并发放土豆精华
## 测试可用 set_storage_path_for_tests 隔离路径，避免污染本机档

const SAVE_PATH := "user://codex.json"
const CATEGORIES := ["status", "reaction", "weapon", "item",
	"upgrade", "enemy"]
const CAT_NAMES := {
	"status": "状态", "reaction": "五行", "weapon": "武器", "item": "道具",
	"upgrade": "升级", "enemy": "敌人",
}

## 图鉴首次解锁奖励（土豆精华）：收集越多，局外天赋成型越快
## 五行反应需主动凑状态组合才能触发，门槛高于普通条目，取平衡区间上限
## 难度介于道具（5）与反应（7）之间，取 6（与敌人同级）
## （冒烟测试限定每类奖励在 [4, 7]，超出会被判为失衡）
const UNLOCK_REWARDS := {
	"status": 4, "reaction": 7, "weapon": 7, "item": 5,
	"upgrade": 4, "enemy": 6,
}

## 成就定义：stat 计数器达到 target 即达成（desc 同时用于图鉴详情）
## reward = 达成后一次性发放的土豆精华（MetaProgress），Steam 成就可另订阅 EventBus.achievement_unlocked
const ACHIEVEMENTS := {
	"first_blood": { "name": "初次击杀", "ico": "🩸", "desc": "击败第一个敌人",
		"stat": "kills", "target": 1, "reward": 6 },
	"slayer_100": { "name": "百人斩", "ico": "⚔", "desc": "累计击败 100 个敌人",
		"stat": "kills", "target": 100, "reward": 20 },
	"slayer_1000": { "name": "千人斩", "ico": "💀", "desc": "累计击败 1000 个敌人",
		"stat": "kills", "target": 1000, "reward": 90 },
	"survivor_5": { "name": "站稳脚跟", "ico": "🛡", "desc": "单局推进到第 5 波",
		"stat": "best_wave", "target": 5, "reward": 12 },
	"clear_10": { "name": "通关达人", "ico": "👑", "desc": "推进到第 10 波（标准通关线）",
		"stat": "best_wave", "target": 10, "reward": 36 },
	"boss_hunter": { "name": "BOSS 猎手", "ico": "🎯", "desc": "击破 1 个 BOSS",
		"stat": "boss_kills", "target": 1, "reward": 16 },
	"boss_10": { "name": "BOSS 克星", "ico": "💥", "desc": "累计击破 10 个 BOSS",
		"stat": "boss_kills", "target": 10, "reward": 72 },
	"evolver": { "name": "进化时刻", "ico": "🔱", "desc": "完成 1 次武器进化",
		"stat": "evolutions", "target": 1, "reward": 24 },
	"status_master": { "name": "状态大师", "ico": "🔥", "desc": "累计触发 100 次异常状态",
		"stat": "status_triggers", "target": 100, "reward": 30 },
	"shopper": { "name": "购物达人", "ico": "🛒", "desc": "累计商店购买 50 次",
		"stat": "purchases", "target": 50, "reward": 24 },
	"veteran": { "name": "老兵", "ico": "🎖", "desc": "累计开始 10 局游戏",
		"stat": "runs", "target": 10, "reward": 18 },
	"endless_20": { "name": "炼狱行者", "ico": "🌋", "desc": "单局推进到第 20 波（无尽）",
		"stat": "best_wave", "target": 20, "reward": 120 },
}

const STAT_NAMES := {
	"kills": "累计击杀", "boss_kills": "BOSS 击破", "waves": "累计清波",
	"best_wave": "最远波次", "status_triggers": "状态触发", "runs": "累计局数",
	"evolutions": "武器进化", "purchases": "商店购买", "best_score": "最高积分",
	"victories": "胜利局数", "reactions": "五行反应",
}

var _seen: Dictionary = {}          # category -> { id: true }
var stats: Dictionary = {}          # stat_key -> int
var achievements: Dictionary = {}   # achievement_id -> true
var _rewarded: Dictionary = {}      # achievement_id -> true（奖励已发放，防重复/支持旧档补发）
var _unlock_rewarded: Dictionary = {}  # "cat:id" -> true（图鉴解锁奖励已发放）
var _path := SAVE_PATH
var _dirty := false
var _flush_t := 0.0

func _ready() -> void:
	_load()
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.wave_ended.connect(_on_wave_ended)
	EventBus.boss_killed.connect(_on_boss_killed)
	EventBus.run_started.connect(_on_run_started)
	EventBus.status_applied.connect(_on_status_applied)
	EventBus.element_reaction.connect(_on_element_reaction)
	EventBus.item_purchased.connect(_on_item_purchased)
	EventBus.run_ended.connect(_on_run_ended)
	# 旧档可能只记了统计、没记成就；延后到本帧末补判，此时 MetaProgress autoload 已就绪可发奖励
	call_deferred("_check_achievements")
	call_deferred("_check_unlock_rewards")

func _process(delta: float) -> void:
	if not _dirty:
		return
	_flush_t -= delta
	if _flush_t <= 0.0:
		_save_now()

func _exit_tree() -> void:
	if _dirty:
		_save_now()

# ---------------- 图鉴解锁 ----------------

func is_unlocked(cat: String, id: String) -> bool:
	if id == "":
		return false
	var bucket: Dictionary = _seen.get(cat, {})
	return bucket.has(id)

## 首次解锁返回 true（广播 codex_unlocked + 发放图鉴精华）；重复解锁无副作用
func unlock(cat: String, id: String) -> bool:
	if id == "" or not CATEGORIES.has(cat):
		return false
	if not _seen.has(cat):
		_seen[cat] = {}
	if _seen[cat].has(id):
		return false
	_seen[cat][id] = true
	_save_now()
	_grant_unlock_reward(cat, id)
	EventBus.codex_unlocked.emit(cat, id)
	return true

func unlock_reward(cat: String) -> int:
	return int(UNLOCK_REWARDS.get(cat, 0))

## 已发放的图鉴解锁精华合计（图鉴统计总览展示）
func unlock_essence_total() -> int:
	var total := 0
	for key in _unlock_rewarded:
		total += unlock_reward(String(key).get_slice(":", 0))
	return total

## 发放图鉴解锁奖励；与成就奖励同样幂等（_unlock_rewarded 随档持久化）
func _grant_unlock_reward(cat: String, id: String) -> void:
	var reward := unlock_reward(cat)
	if reward <= 0:
		return
	var key := cat + ":" + id
	if _unlock_rewarded.has(key):
		return
	var meta = get_node_or_null("/root/MetaProgress")
	if meta == null:
		return
	meta.grant_essence(reward)
	_unlock_rewarded[key] = true
	_save_now()

## 旧档补发：已解锁但未发过奖励的条目
func _check_unlock_rewards() -> void:
	for cat in CATEGORIES:
		for id in _seen.get(cat, {}):
			_grant_unlock_reward(String(cat), String(id))

func unlocked_count(cat: String) -> int:
	return int(_seen.get(cat, {}).size())

## 条目总数（含未解锁）；成就页由 ACHIEVEMENTS 提供
func total_entries(cat: String) -> int:
	match cat:
		"status": return Config.STATUS.size()
		"reaction": return Registry.reactions.size()
		"weapon": return Registry.weapons.size()
		"item": return Registry.items.size()
		"upgrade": return Registry.upgrades.size()
		"enemy": return Registry.enemies.size()
		"achieve": return ACHIEVEMENTS.size()
	return 0

func display_name(cat: String, id: String) -> String:
	match cat:
		"status": return String(Config.STATUS.get(id, {}).get("name", id))
		"reaction": return String(Registry.reactions.get(id, {}).get("name", id))
		"weapon": return String(Registry.weapons.get(id, {}).get("name", id))
		"item": return String(Registry.items.get(id, {}).get("name", id))
		"upgrade": return String(Registry.upgrades.get(id, {}).get("name", id))
		"enemy": return String(Registry.enemies.get(id, {}).get("name", id))
		"achieve": return String(ACHIEVEMENTS.get(id, {}).get("name", id))
	return id

func display_icon(cat: String, id: String) -> String:
	match cat:
		"status": return String(Config.STATUS.get(id, {}).get("ico", "❓"))
		"reaction": return String(Registry.reactions.get(id, {}).get("ico", "☯"))
		"weapon": return String(Registry.weapons.get(id, {}).get("ico", "🔧"))
		"item": return String(Registry.items.get(id, {}).get("ico", "🧩"))
		"upgrade": return String(Registry.upgrades.get(id, {}).get("ico", "✨"))
		"enemy": return "👾"
		"achieve": return String(ACHIEVEMENTS.get(id, {}).get("ico", "🏆"))
	return "❓"

# ---------------- 统计 ----------------

func stat(key: String) -> int:
	return int(stats.get(key, 0))

## 累加统计；成就判定在累加后立即进行（未达成时仅标脏，1.5s 后批量落盘）
func add_stat(key: String, delta: int = 1) -> void:
	if key == "" or delta == 0:
		return
	stats[key] = stat(key) + delta
	_mark_dirty()
	_check_achievements()

## 取最大值型统计（最远波次 / 最高积分）
func set_stat_max(key: String, value: int) -> void:
	if key == "" or value <= stat(key):
		return
	stats[key] = value
	_mark_dirty()
	_check_achievements()

# ---------------- 成就 ----------------

func achievement_unlocked(id: String) -> bool:
	return achievements.has(id)

func achievement_progress(id: String) -> int:
	var a: Dictionary = ACHIEVEMENTS.get(id, {})
	if a.is_empty():
		return 0
	return mini(stat(String(a.get("stat", ""))), int(a.get("target", 1)))

func achievement_target(id: String) -> int:
	return int(ACHIEVEMENTS.get(id, {}).get("target", 1))

func achievement_reward(id: String) -> int:
	return int(ACHIEVEMENTS.get(id, {}).get("reward", 0))

## 已达成成就累计发放的精华（图鉴统计总览展示）
func achievement_essence_total() -> int:
	var total := 0
	for id in achievements:
		total += achievement_reward(String(id))
	return total

func unlocked_achievement_count() -> int:
	return achievements.size()

func _check_achievements() -> void:
	for id in ACHIEVEMENTS:
		var aid := String(id)
		var a: Dictionary = ACHIEVEMENTS[aid]
		if not achievements.has(aid):
			if stat(String(a.get("stat", ""))) < int(a.get("target", 1)):
				continue
			achievements[aid] = true
			_save_now()
			_grant_achievement_reward(aid)
			EventBus.achievement_unlocked.emit(aid)
		elif not _rewarded.has(aid):
			# 旧档/崩溃恢复：成就已记录但奖励未发，补发一次
			_grant_achievement_reward(aid)

## 发放成就奖励精华；动态取节点，避免 CodexData 早于 MetaProgress 初始化时的空引用
## _rewarded 随图鉴档持久化，保证幂等（MetaProgress 未就绪时不标记，下次再补）
func _grant_achievement_reward(id: String) -> void:
	var reward := achievement_reward(id)
	if reward <= 0:
		return
	var meta = get_node_or_null("/root/MetaProgress")
	if meta == null:
		return
	meta.grant_essence(reward)
	_rewarded[id] = true
	_save_now()

func clear_all() -> void:
	_seen = {}
	stats = {}
	achievements = {}
	_rewarded = {}
	_unlock_rewarded = {}
	_save_now()

# ---------------- 事件接线 ----------------

func _on_enemy_killed(_type: String) -> void:
	add_stat("kills")

func _on_wave_ended(w: int) -> void:
	add_stat("waves")
	set_stat_max("best_wave", w)

func _on_boss_killed() -> void:
	add_stat("boss_kills")

func _on_run_started() -> void:
	add_stat("runs")

func _on_status_applied(_id: String, _stacks: int, _pos: Vector2) -> void:
	add_stat("status_triggers")

func _on_element_reaction(_reaction_id: String, _pos: Vector2, _targets: Array) -> void:
	add_stat("reactions")

func _on_item_purchased(_id: String) -> void:
	add_stat("purchases")

func _on_run_ended(victory: bool) -> void:
	if victory:
		add_stat("victories")

# ---------------- 持久化 ----------------

## 仅供自动化测试：改用隔离路径并清空内存态
func set_storage_path_for_tests(path: String) -> void:
	_path = path
	_seen = {}
	stats = {}
	achievements = {}
	_rewarded = {}
	_unlock_rewarded = {}
	_dirty = false

func reset_storage_path_after_tests() -> void:
	_path = SAVE_PATH

func reset_for_tests() -> void:
	_seen = {}
	stats = {}
	achievements = {}
	_rewarded = {}
	_unlock_rewarded = {}
	_dirty = false

func _mark_dirty() -> void:
	_dirty = true
	_flush_t = 1.5

func _save_now() -> void:
	_dirty = false
	_flush_t = 0.0
	_save()

func _load() -> void:
	_seen = {}
	stats = {}
	achievements = {}
	_rewarded = {}
	_unlock_rewarded = {}
	if not FileAccess.file_exists(_path):
		return
	var f := FileAccess.open(_path, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	var parse_err := json.parse(f.get_as_text())
	f.close()
	if parse_err != OK or typeof(json.data) != TYPE_DICTIONARY:
		push_warning("CodexData: 存档损坏，已重置")
		return
	var d: Dictionary = json.data
	# 兼容旧格式：根对象直接是 category -> bucket
	var seen_raw: Variant = d.get("seen", null)
	_load_seen(seen_raw if typeof(seen_raw) == TYPE_DICTIONARY else d)
	var raw_stats: Variant = d.get("stats", {})
	if typeof(raw_stats) == TYPE_DICTIONARY:
		for k in raw_stats:
			var v := _int_in(raw_stats[k], 0, 2_000_000_000)
			if v > 0:
				stats[String(k)] = v
	var raw_ach: Variant = d.get("achievements", {})
	if typeof(raw_ach) == TYPE_DICTIONARY:
		for id in raw_ach:
			if ACHIEVEMENTS.has(String(id)) and bool(raw_ach[id]):
				achievements[String(id)] = true
	var raw_rew: Variant = d.get("rewarded", {})
	if typeof(raw_rew) == TYPE_DICTIONARY:
		for id in raw_rew:
			if ACHIEVEMENTS.has(String(id)) and bool(raw_rew[id]):
				_rewarded[String(id)] = true
	var raw_urew: Variant = d.get("unlock_rewarded", {})
	if typeof(raw_urew) == TYPE_DICTIONARY:
		for key in raw_urew:
			if bool(raw_urew[key]):
				_unlock_rewarded[String(key)] = true
	# 旧档/统计先于成就的档：由 _ready 的延后 _check_achievements 补判（需 MetaProgress 就绪）

func _load_seen(raw: Variant) -> void:
	if typeof(raw) != TYPE_DICTIONARY:
		return
	var src: Dictionary = raw
	for cat in CATEGORIES:
		var bucket_raw: Variant = src.get(cat, {})
		if typeof(bucket_raw) != TYPE_DICTIONARY:
			continue
		var bucket := {}
		for id in bucket_raw:
			if typeof(id) == TYPE_STRING and bool(bucket_raw[id]):
				bucket[String(id)] = true
		if not bucket.is_empty():
			_seen[cat] = bucket

func _save() -> void:
	var dir := _path.get_base_dir()
	var dir_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		push_warning("CodexData: 无法创建目录 " + dir)
		return
	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f == null:
		push_warning("CodexData: 无法写入 " + _path)
		return
	f.store_string(JSON.stringify({
		"seen": _seen, "stats": stats, "achievements": achievements,
		"rewarded": _rewarded, "unlock_rewarded": _unlock_rewarded }))
	f.close()

func _int_in(value: Variant, minimum: int, maximum: int) -> int:
	if (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) \
			and is_finite(float(value)) and float(value) == floorf(float(value)) \
			and float(value) >= float(minimum) and float(value) <= float(maximum):
		return int(value)
	return minimum
