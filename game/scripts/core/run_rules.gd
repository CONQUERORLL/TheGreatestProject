extends Node
## ============================================================
## 自定义开局规则（Custom Run Rules）
##
## 设计要点：**不新增任何战斗逻辑**。整套规则最终收敛成一个「合成难度条目」，
## 塞进 Registry.difficulties，于是 enemy.gd / wave_manager.gd 那 3 个
## Registry.get_difficulty() 调用点无需改动即可生效。
## 其余几项（波次上限/时长/武器槽/材料/商店价）走本单例的只读查询接口。
##
## **与向导所选难度的关系（方案 A：继承 + 叠加）**
## 规则里的「难度组」四项（敌人血量/伤害/刷怪密度/精英概率）是**倍率**，
## 叠乘在向导选择的基准难度之上，而不是各自从 1.0 起算：
##   · 基准难度 = 向导第 4 步选的 normal / hard / nightmare
##   · 规则倍率 = 1.0 → 完全沿用基准难度（不改变任何东西）
##   · 规则倍率 = 1.5 → 基准值 × 1.5（如噩梦血量 2.2 → 3.3）
## 这样"选噩梦 + 加 2 倍血"才符合直觉，也让向导那一步不被浪费。
## 基准难度 id 由 apply_to_run() 存入 base_difficulty_id，随 to_save() 落存档。
##
## 持久化：user://run_rules.json（当前生效规则 + 命名预设列表）
## 挑战码：规则参数 → 紧凑串（人类可复制传播），见 encode/decode
##
## ⚠ 自定义规则**不参与**每日挑战与排行榜 —— 见 is_competitive()
## ============================================================

const SAVE_PATH := "user://run_rules.json"

## 合成难度条目的固定 id。存档里若出现这个 id，读档时必须先用存档内的参数
## 重建条目（见 apply_from_save），否则 Registry 会回落到 normal。
const CUSTOM_DIFF_ID := "custom"

## 内置难度 id 白名单（基准难度只能从这里选；不在表内则回落 "normal"）
const BUILTIN_DIFF_IDS := ["normal", "hard", "nightmare"]

## 合成条目时会被基准难度"打底"的字段（规则值是叠乘倍率）
const SCALED_FIELDS := ["hp_mult", "dmg_mult", "spawn_mult"]

## 规则定义表：UI 逐项渲染 + clamp + 编解码全部由本表驱动。
##   key      规则键（也是存档/挑战码里的字段名）
##   name     显示名
##   min/max  合法区间（硬边界，clamp 用）
##   step     UI 调节步进
##   default  默认值（"重置"与新建规则时用）
##   fmt      显示格式（"pct" 百分比 / "mul" x倍率 / "int" 整数 / "bool" 开关）
##   group    分组（UI 分区显示）
const RULES := [
	{ "key": "enemy_hp", "name": "敌人血量", "group": "难度", "min": 0.5, "max": 3.0,
		"step": 0.1, "default": 1.0, "fmt": "mul" },
	{ "key": "enemy_dmg", "name": "敌人伤害", "group": "难度", "min": 0.5, "max": 3.0,
		"step": 0.1, "default": 1.0, "fmt": "mul" },
	{ "key": "spawn_density", "name": "刷怪密度", "group": "难度", "min": 0.5, "max": 3.0,
		"step": 0.1, "default": 1.0, "fmt": "mul" },
	{ "key": "elite_chance", "name": "精英概率", "group": "难度", "min": 0.0, "max": 0.5,
		"step": 0.05, "default": 0.0, "fmt": "pct" },
	{ "key": "waves", "name": "波次总数", "group": "节奏", "min": 5, "max": 30,
		"step": 1, "default": 10, "fmt": "int" },
	{ "key": "wave_time", "name": "波次时长", "group": "节奏", "min": 0.5, "max": 2.0,
		"step": 0.1, "default": 1.0, "fmt": "mul" },
	{ "key": "weapon_slots", "name": "武器槽位", "group": "经济", "min": 4, "max": 8,
		"step": 1, "default": 6, "fmt": "int" },
	{ "key": "materials", "name": "材料掉落", "group": "经济", "min": 0.5, "max": 3.0,
		"step": 0.1, "default": 1.0, "fmt": "mul" },
	{ "key": "shop_price", "name": "商店价格", "group": "经济", "min": 0.5, "max": 2.0,
		"step": 0.1, "default": 1.0, "fmt": "mul" },
	{ "key": "no_reroll", "name": "禁用商店刷新", "group": "限制", "min": 0, "max": 1,
		"step": 1, "default": 0, "fmt": "bool" },
	{ "key": "no_heal", "name": "禁用商店回血", "group": "限制", "min": 0, "max": 1,
		"step": 1, "default": 0, "fmt": "bool" },
]

## 挑战码前缀。v1 不含基准难度；v2 首字段带基准难度（方案 A 后新增）。
## 两个前缀都保留可解析能力 —— 旧码分享出去不能变成废码。
const CODE_PREFIX := "BTL1-"
const CODE_V2_PREFIX := "BTL2-"

var active := false            # 本局是否启用自定义规则
var values: Dictionary = {}    # key -> float（int/bool 也存 float，读时转换）
var presets: Dictionary = {}   # 预设名 -> values 字典
var _path := SAVE_PATH         # 测试可切到隔离路径

## 基准难度 id（向导第 4 步所选；规则倍率叠乘在它之上）。见文件头「方案 A」说明。
var base_difficulty_id := "normal"

## 记录「本次生成过自定义难度」的痕迹，便于测试断言与调试
var _injected := false

func _ready() -> void:
	reset_to_defaults()
	_load()

# ---------------- 默认值与区间 ----------------

func reset_to_defaults() -> void:
	values = {}
	for r in RULES:
		values[String(r.key)] = float(r.default)

## 规则定义（按 key 取；不存在返回空字典）
func rule_def(key: String) -> Dictionary:
	for r in RULES:
		if String(r.key) == key:
			return r
	return {}

## 按定义表把某键的值 clamp 进合法区间（未知键返回默认 0.0）
func clamp_value(key: String, v: float) -> float:
	var d := rule_def(key)
	if d.is_empty():
		return 0.0
	# 浮点用 step 对齐，避免挑战码/存档里出现 1.2999999 这种噪声
	var lo := float(d.min)
	var hi := float(d.max)
	var step := float(d.step)
	var c := clampf(v, lo, hi)
	if step > 0.0:
		c = lo + round((c - lo) / step) * step
		c = clampf(c, lo, hi)
	# 消除浮点尾差（0.1 步进相乘会攒出 1.0000000000000002）
	return snappedf(c, 0.001)

func get_value(key: String) -> float:
	return float(values.get(key, 0.0))

func get_int(key: String) -> int:
	return int(round(get_value(key)))

func get_bool(key: String) -> bool:
	return get_value(key) >= 0.5

func set_value(key: String, v: float) -> void:
	if rule_def(key).is_empty():
		return
	values[key] = clamp_value(key, v)

# ---------------- 难度评级（给玩家一个直观反馈） ----------------

## 基准难度的基准评分（普通 1.0 / 困难 / 噩梦），与规则无关。
## 用难度条目的四维算出，口径与 difficulty_rating() 的规则增量可相加。
func base_rating() -> float:
	var base := base_difficulty()
	return _difficulty_score(base)

## 基准难度四维 → 评分的公共算法（difficulty_rating 与 base_rating 共用，保证口径一致）
func _difficulty_score(d: Dictionary) -> float:
	var s := 1.0
	s += (float(d.get("hp_mult", 1.0)) - 1.0) * 0.9
	s += (float(d.get("dmg_mult", 1.0)) - 1.0) * 1.0
	s += (float(d.get("spawn_mult", 1.0)) - 1.0) * 0.7
	s += float(d.get("elite_chance", 0.0)) * 3.0
	return s

## 综合评分（**相对基准难度**：普通+无改动 = 1.0；噩梦+无改动 ≈ 噩梦本身的分值）。
## 仅用于 UI 显示与星级，不参与任何计算。
func difficulty_rating() -> float:
	# 起点 = 基准难度自身分值（方案 A：规则是叠加在基准之上的增量）
	var score := base_rating()
	score += (get_value("enemy_hp") - 1.0) * 0.9
	score += (get_value("enemy_dmg") - 1.0) * 1.0
	score += (get_value("spawn_density") - 1.0) * 0.7
	score += (get_value("elite_chance") - 0.0) * 3.0
	score += (get_value("waves") - 10.0) * 0.06
	score += (get_value("wave_time") - 1.0) * 0.4
	score += (get_value("weapon_slots") - 6.0) * -0.18
	score += (get_value("materials") - 1.0) * -0.35
	score += (get_value("shop_price") - 1.0) * -0.5
	if get_bool("no_reroll"):
		score += 0.35
	if get_bool("no_heal"):
		score += 0.25
	return clampf(score, 0.2, 5.0)

## 评级星级（1~5）；用于 UI 的 ★ 展示
func rating_stars() -> int:
	var r := difficulty_rating()
	if r < 0.7:
		return 1
	if r < 1.3:
		return 2
	if r < 2.0:
		return 3
	if r < 3.0:
		return 4
	return 5

## 启用的规则是否与内置难度完全一致（难度组四项都没动）。
## 注意：这只说"规则本身没改动"，不代表最终难度等于普通 —— 基准可能是噩梦。
func is_default() -> bool:
	for r in RULES:
		if not is_equal_approx(get_value(String(r.key)), float(r.default)):
			return false
	return true

# ---------------- 注入：合成难度条目 ----------------

## 基准难度条目（向导所选；非法/缺失一律回落 normal）。
## 内置难度表归 Registry 所有，这里只读不改。
func base_difficulty() -> Dictionary:
	var id := base_difficulty_id if base_difficulty_id in BUILTIN_DIFF_IDS else "normal"
	return Registry.get_difficulty(id)

## 基准难度的显示名（UI 用）
func base_difficulty_name() -> String:
	return String(base_difficulty().get("name", "普通"))

## 把当前规则写成 Registry 里的一个"custom"难度条目。
## **方案 A**：难度组三项以基准难度为底做叠乘（基准 × 规则倍率）；
## 精英概率是加成语义（基准 + 规则增量），因为它是百分比而非倍率。
## 必须在 Registry 就绪之后调用（开局前），此后 enemy/wave_manager 无需改动即生效。
## 返回被注入的难度字典（便于测试断言）。
func inject_difficulty() -> Dictionary:
	var base := base_difficulty()
	var d := {
		"id": CUSTOM_DIFF_ID,
		"name": "自定义 · %s" % String(base.get("name", "普通")),
		"desc": "以「%s」为基准，叠加自定义规则" % String(base.get("name", "普通")),
		# 倍率叠乘：规则值 1.0 = 完全沿用基准难度。精英概率是百分比，用加法
		"hp_mult": float(base.get("hp_mult", 1.0)) * get_value("enemy_hp"),
		"dmg_mult": float(base.get("dmg_mult", 1.0)) * get_value("enemy_dmg"),
		"spawn_mult": float(base.get("spawn_mult", 1.0)) * get_value("spawn_density"),
		"elite_chance": clampf(float(base.get("elite_chance", 0.0))
			+ get_value("elite_chance"), 0.0, 1.0),
	}
	# 注册表校验器要求 elite_chance ∈ [0,1]（Registry._valid_difficulty），
	# 叠加后必须夹回去，否则 mod 校验口径与这里不一致
	Registry.difficulties[CUSTOM_DIFF_ID] = d
	_injected = true
	return d

## 把本局开局要用的难度 id 落到 GameState：
## 启用自定义 → 记录基准难度、注入合成条目、返回 "custom"；
## 未启用 → 原样使用内置难度。
## base_id 必须是向导里选的难度 id（本局基准）。
## 返回最终生效的难度 id。
func apply_to_run(difficulty_id: String) -> String:
	base_difficulty_id = difficulty_id if difficulty_id in BUILTIN_DIFF_IDS else "normal"
	if not active:
		return difficulty_id
	inject_difficulty()
	return CUSTOM_DIFF_ID

# ---------------- 各项覆盖查询（消费点统一走这里） ----------------

## 波次上限：自定义时用规则值，否则回落调用方给的默认（Config.WAVES_TOTAL / ENDLESS_MAX_WAVE）
func wave_total(fallback: int) -> int:
	if active:
		return get_int("waves")
	return fallback

## 波次时长倍率
func wave_duration_mult() -> float:
	return get_value("wave_time") if active else 1.0

## 本局武器槽上限：启用规则 → 规则值 + 天赋加成；未启用 → 沿用天赋公式。
## 规则给的是"基础槽位数"，天赋（军火专家）仍是额外 +1，两者语义不冲突。
func weapon_slots_total() -> int:
	var base := get_int("weapon_slots") if active else Config.WEAPON_SLOTS
	return base + int(MetaProgress.effect_sum("slot"))

## 是否启用自定义规则且参数与内置难度不同（首页/向导用来决定是否显示标记）
func has_effective_rules() -> bool:
	return active and not is_default()

## 材料掉落倍率（开局注入 player.stats.harvesting 的增量）
## harvesting 是"材料获取 +x%"，倍率 2.0 = +100%
func materials_bonus() -> float:
	return (get_value("materials") - 1.0) if active else 0.0

## 商店价格倍率
func shop_price_mult() -> float:
	return get_value("shop_price") if active else 1.0

func reroll_disabled() -> bool:
	return active and get_bool("no_reroll")

func heal_disabled() -> bool:
	return active and get_bool("no_heal")

## 是否可用于竞技性内容（每日挑战 / 排行榜）。
## 自定义规则一律排除：一是语义不符（那不是"全服同局"），二是防「调低难度刷榜」。
func is_competitive() -> bool:
	return not active

# ---------------- 挑战码 ----------------

## 挑战码 → 基准难度 id 的反查表（v2 码首字段存的是下标）
const _BASE_INDEX := { "normal": 0, "hard": 1, "nightmare": 2 }

## 规则 → 紧凑码。数值按 step 量化成整数，再拼成定长字段，便于跨设备复现。
##
## v2 格式：BTL2-<基准难度下标>|<规则字段…>
##   —— 首字段是基准难度。方案 A 下"噩梦 + 1.5 倍血"与"普通 + 1.5 倍血"是两局完全
##   不同的游戏，挑战码若不带上基准，分享出去会静默复现成另一局。
## v1 格式（BTL1-<规则字段…>）仍可解析，基准按 normal 处理 —— 兼容旧码。
func encode() -> String:
	var parts: Array = [str(int(_BASE_INDEX.get(base_difficulty_id, 0)))]
	for r in RULES:
		var key := String(r.key)
		var lo := float(r.min)
		var step := float(r.step)
		var v := get_value(key)
		var idx := 0 if step <= 0.0 else int(round((v - lo) / step))
		parts.append(str(maxi(0, idx)))
	return CODE_V2_PREFIX + "|".join(parts)

## 紧凑码 → 规则 + 基准难度。任何字段缺失/越界都会回落到默认值（不报错），
## 保证「别人发来的码」永远能导入而不是崩溃。
## 返回 true 表示至少成功解析出前缀与字段数匹配。
func decode(code: String) -> bool:
	var s := code.strip_edges()
	var body := ""
	var has_base := false
	if s.begins_with(CODE_V2_PREFIX):
		body = s.substr(CODE_V2_PREFIX.length())
		has_base = true
	elif s.begins_with(CODE_PREFIX):
		body = s.substr(CODE_PREFIX.length())   # v1 旧码：无基准字段，按 normal
	else:
		return false
	var parts := body.split("|", false)
	var want := RULES.size() + (1 if has_base else 0)
	if parts.size() != want:
		return false
	var offset := 0
	if has_base:
		var bi := int(parts[0]) if String(parts[0]).is_valid_int() else 0
		# 下标越界 → 回落 normal，不拒绝整码（分享来的码尽量能用）
		base_difficulty_id = BUILTIN_DIFF_IDS[clampi(bi, 0, BUILTIN_DIFF_IDS.size() - 1)]
		offset = 1
	else:
		# v1 旧码不含基准字段 —— 必须显式重置为 normal。
		# 否则会继承调用方残留的 base_difficulty_id，把旧码静默复现成另一局。
		base_difficulty_id = "normal"
	var out := {}
	for i in RULES.size():
		var r: Dictionary = RULES[i]
		var lo := float(r.min)
		var step := float(r.step)
		var field := String(parts[i + offset])
		var idx := int(field) if field.is_valid_int() else -1
		var v := float(r.default)
		if idx >= 0:
			v = lo + float(idx) * step
		out[String(r.key)] = clamp_value(String(r.key), v)
	values = out
	return true

# ---------------- 预设 ----------------

func preset_names() -> Array:
	var names: Array = presets.keys()
	names.sort()
	return names

func save_preset(name: String) -> bool:
	var n := name.strip_edges()
	if n.is_empty():
		return false
	presets[n] = values.duplicate(true)
	_save()
	return true

func load_preset(name: String) -> bool:
	if not presets.has(name):
		return false
	var raw: Variant = presets[name]
	if typeof(raw) != TYPE_DICTIONARY:
		return false
	for r in RULES:
		var k := String(r.key)
		set_value(k, float((raw as Dictionary).get(k, r.default)))
	return true

func delete_preset(name: String) -> bool:
	if not presets.has(name):
		return false
	presets.erase(name)
	_save()
	return true

# ---------------- 存档 ----------------

## 供 SaveRun 调用：把当前规则打包进局内存档（含参数本身，而非只存 id）。
## base 一并存：读档时要用同一个基准难度重建合成条目，否则"噩梦 + 2 倍血"会退化成"普通 + 2 倍血"
func to_save() -> Dictionary:
	return {
		"active": active,
		"base": base_difficulty_id,
		"values": values.duplicate(true),
	}

## 读档时恢复：先用存档内参数重建规则，再重新注入难度条目。
## 必须重新注入 —— 否则 Registry 里没有 "custom" 条目，会回落到 normal。
func apply_from_save(data: Variant) -> void:
	reset_to_defaults()
	active = false
	base_difficulty_id = "normal"
	if typeof(data) != TYPE_DICTIONARY:
		return
	var d: Dictionary = data
	active = bool(d.get("active", false))
	# 旧存档无 base 字段 → 回落 normal（那时本来也没有"继承基准"的语义）
	var saved_base := String(d.get("base", "normal"))
	base_difficulty_id = saved_base if saved_base in BUILTIN_DIFF_IDS else "normal"
	var raw: Variant = d.get("values", {})
	if typeof(raw) == TYPE_DICTIONARY:
		for r in RULES:
			var k := String(r.key)
			if (raw as Dictionary).has(k):
				set_value(k, float((raw as Dictionary)[k]))
	if active:
		inject_difficulty()

## 仅供测试：切到隔离存档路径
func set_storage_path_for_tests(path: String) -> void:
	_path = path

func reset_storage_path_after_tests() -> void:
	_path = SAVE_PATH

func _load() -> void:
	presets = {}
	if not FileAccess.file_exists(_path):
		return
	var f := FileAccess.open(_path, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	var parse_err := json.parse(f.get_as_text())
	f.close()
	if parse_err != OK or typeof(json.data) != TYPE_DICTIONARY:
		push_warning("RunRules: 存档损坏，已重置")
		return
	var d: Dictionary = json.data
	var raw: Variant = d.get("presets", {})
	if typeof(raw) != TYPE_DICTIONARY:
		return
	for name in raw:
		var one: Variant = (raw as Dictionary)[name]
		if typeof(one) != TYPE_DICTIONARY:
			continue
		# 逐键 clamp 后存入，避免手改存档注入越界值
		var clean := {}
		for r in RULES:
			var k := String(r.key)
			clean[k] = clamp_value(k, float((one as Dictionary).get(k, r.default)))
		presets[String(name)] = clean

func _save() -> void:
	var dir := _path.get_base_dir()
	var dir_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		push_warning("RunRules: 无法创建目录 " + dir)
		return
	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f == null:
		push_warning("RunRules: 无法写入 " + _path)
		return
	f.store_string(JSON.stringify({ "presets": presets }))
	f.close()
