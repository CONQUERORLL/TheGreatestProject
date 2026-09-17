extends Node
## 单档自动存档（S4.5 · §10.1）：**唯一档** `user://save_run.json`，
## 菜单「继续游戏」直读这一份，不再有存档栏；存档时机 = 通过波次、进入商店时。
## 每次写入先落临时文件并保留上一版备份，避免截断正式存档后写入失败。
##
## ⚠️ 唯一档文件名**刻意复用 v1 的单槽文件名** `save_run.json` ——
##    于是 v1 老玩家的档「原地」就是新唯一档，一格字节都不用搬；需要搬迁的是三槽那一批。
##    历史布局（`migrate_legacy_if_needed` 合并，取 `saved_at` 最新的一份）：
##      v1 = 单槽 `save_run.json`（无 `checkpoint` 键 → 一律按商店恢复）
##      v2 = 三槽 `save_slot_1..3.json`（自动档写槽 1）

const VERSION := 2
const COMPATIBLE_VERSIONS := [1, 2]
## 唯一档只有 1 个。**保留 `slot` 形参**是为了让调用方继续用同一套「按槽寻址」API，
## 而不是把 `slot_path` 拆成两套函数 —— 槽数由本常量单点控制（§13-28 断言它 == 1）。
const SLOT_COUNT := 1
## 唯一档文件名（= v1 的单槽文件名，见文件头）
const SAVE_FILE := "save_run.json"
## 旧三槽布局的文件名：**只在迁移时读取**，合并完即删除
const LEGACY_SLOT_FILES := ["save_slot_1.json", "save_slot_2.json", "save_slot_3.json"]
const DEFAULT_STORAGE_ROOT := "user://"
const CHECKPOINT_SHOP := "shop"
const CHECKPOINT_WAVE_START := "wave_start"

var restored_checkpoint := CHECKPOINT_SHOP
var current_run_owns_slot := false
var _storage_root := DEFAULT_STORAGE_ROOT

func migrate_legacy_if_needed(allow_test_storage := false) -> void:
	if _storage_root == DEFAULT_STORAGE_ROOT or allow_test_storage:
		_migrate_old_layout()

func slot_path(slot: int) -> String:
	if slot < 1 or slot > SLOT_COUNT:
		return ""
	return _storage_root.path_join(SAVE_FILE)

func exists(slot: int) -> bool:
	return not _read(slot).is_empty()

func any_exists() -> bool:
	for i in range(1, SLOT_COUNT + 1):
		if exists(i):
			return true
	return false

## 仅供自动化测试隔离 user:// 正式存档。
func set_storage_root_for_tests(path: String) -> void:
	_storage_root = path.trim_suffix("/")

func reset_storage_root_after_tests() -> void:
	_storage_root = DEFAULT_STORAGE_ROOT

## 保存当前局到唯一档。`checkpoint` 决定**恢复后从哪儿接上**：
##   `shop`（默认 = 本项目的存档时机口径）= 刚打完第 `next_wave - 1` 波、正要进商店
##          → 恢复后直接开商店（不重打该波，见 main.gd 的 restored_checkpoint 分支）
##   `wave_start` = 即将从 `next_wave` 开场起跑：新局第 1 波（第 1 波之前没有商店）、
##          以及「通关转无尽」这种直接开波的切换
## 无尽模式波次上限放宽到 ENDLESS_MAX_WAVE。
## 每日挑战不落盘（slot 0 / 全服同局，不存档），直接返回 true 跳过。
func save(next_wave: int, player: Node, checkpoint: String = CHECKPOINT_SHOP) -> bool:
	if GameState.daily:
		return true
	var wave_max := Config.ENDLESS_MAX_WAVE if GameState.endless \
		else RunRules.wave_total(Config.WAVES_TOTAL)
	if next_wave < 1 or next_wave > wave_max:
		push_warning("SaveRun: 非法波次 %d，拒绝保存" % next_wave)
		return false
	if checkpoint not in [CHECKPOINT_SHOP, CHECKPOINT_WAVE_START]:
		push_warning("SaveRun: 非法检查点 " + checkpoint)
		return false
	var path := slot_path(GameState.slot_id)
	if path == "":
		push_warning("SaveRun: 非法槽位 %d" % GameState.slot_id)
		return false
	var data := {
		"version": VERSION,
		"checkpoint": checkpoint,
		"saved_at": Time.get_datetime_string_from_system(false, true),
		"rng_a": GameRng._a,
		"run": {
			"wave": next_wave,
			"materials": GameState.materials,
			"kills": GameState.kills,
			"run_time": GameState.run_time,
			"level": GameState.level,
			"xp": GameState.xp,
			"level_queue": GameState.level_queue,
			"difficulty_id": GameState.difficulty_id,
			"character_id": GameState.character_id,
			"loadout_weapon": GameState.loadout_weapon,
			"loadout_item": GameState.loadout_item,
			"endless": GameState.endless,
			"score": GameState.score,
			# 自定义开局规则：连参数一起存（只存 id 不够 —— 读档时必须先重建
			# "custom" 难度条目，否则 Registry 会回落到 normal）
			"run_rules": RunRules.to_save(),
		},
		"player": {
			"hp": player.hp,
			"stats": player.stats.duplicate(),
			"weapons": player.weapons.map(func(w: Dictionary) -> Dictionary:
				return { "type": w.type }),
			"items_owned": player.items_owned.duplicate(),
			# 升级记账（第 7 轮新增）：金/红升级「本局唯一」的唯一依据。
			# 不落盘的话续档后 upgrades_owned 归空 → 同一张金升级能再刷一遍，唯一性静默失效
			"upgrades_owned": player.upgrades_owned.duplicate(),
			# 法宝必须连叠层一起存：叠层属性已含在 stats 里，但层数记录丢了
			# 会让 _set_artifact_stacks 的 cur 归零，下次叠层重复加成
			"artifacts_owned": player.artifacts_owned.duplicate(),
			"artifact_stacks": player.artifact_stacks.duplicate(),
		},
	}
	var saved := _write_json_atomic(path, data)
	if saved:
		current_run_owns_slot = true
	return saved

## 恢复唯一档并返回波次；restored_checkpoint 告知调用方恢复到商店或波次开始。
func restore(player: Node) -> int:
	var data := _read(GameState.slot_id)
	if data.is_empty():
		return 0
	var run: Dictionary = data.run
	var wave := int(run.wave)
	restored_checkpoint = String(data.get("checkpoint", CHECKPOINT_SHOP))
	if restored_checkpoint not in [CHECKPOINT_SHOP, CHECKPOINT_WAVE_START]:
		restored_checkpoint = CHECKPOINT_SHOP
	# 第 1 波之前没有商店：`shop` 档的波号至少是 2（存档点 = 打完 n-1 波、正要进商店）。
	# 手改或半损坏的档若写成「wave 1 + shop」，按原样恢复会去开一个不存在的「第 0 波商店」，
	# 所以这里降级为「从第 1 波起跑」—— 与 `save()` 的新局口径对齐。
	if wave <= 1:
		restored_checkpoint = CHECKPOINT_WAVE_START
	var character_id := String(run.get("character_id", "potato"))
	if not Registry.characters.has(character_id):
		character_id = "potato"
	# 自定义规则必须先恢复并重新注入难度条目 ——
	# 存档里 difficulty_id = "custom" 时，Registry 此刻还没有这个条目（它不落盘），
	# 不先重建就会被下面的校验判为非法而回落 normal，玩家的自定义局被静默改档
	RunRules.apply_from_save(run.get("run_rules", {}))
	var difficulty_id := String(run.get("difficulty_id", "normal"))
	if not Registry.difficulties.has(difficulty_id):
		difficulty_id = "normal"
	var loadout_weapon := String(run.get("loadout_weapon", ""))
	if loadout_weapon != "" and not Registry.weapons.has(loadout_weapon):
		loadout_weapon = ""
	var loadout_item := String(run.get("loadout_item", ""))
	if loadout_item != "" and not Registry.items.has(loadout_item):
		loadout_item = ""
	GameState.set_materials(maxi(0, int(run.get("materials", 0))))
	GameState.kills = maxi(0, int(run.get("kills", 0)))
	GameState.run_time = maxf(0.0, float(run.get("run_time", 0.0)))
	GameState.level = maxi(1, int(run.get("level", 1)))
	GameState.xp = maxi(0, int(run.get("xp", 0)))
	GameState.level_queue = maxi(0, int(run.get("level_queue", 0)))
	GameState.difficulty_id = difficulty_id
	GameState.character_id = character_id
	GameState.loadout_weapon = loadout_weapon
	GameState.loadout_item = loadout_item
	GameState.endless = bool(run.get("endless", false))
	GameState.score = maxi(0, int(run.get("score", 0)))
	GameRng._a = int(data.get("rng_a", 0)) & 0xFFFFFFFF
	var pl: Dictionary = data.player
	var saved_stats: Dictionary = pl.stats
	var restored_stats: Dictionary = player.stats.duplicate()
	for key in restored_stats:
		if _is_number(saved_stats.get(key)):
			restored_stats[key] = float(saved_stats[key])
	_sanitize_stats(restored_stats)
	player.stats = restored_stats
	player.hp = clampf(float(pl.hp), 1.0, float(player.stats.max_hp))
	player.weapons = []
	for w in pl.weapons:
		var weapon_id := String(w.type)
		if Registry.weapons.has(weapon_id):
			player.weapons.append({ "type": weapon_id, "cd": 0.3 })
	if player.weapons.is_empty():
		# 存档里所有武器都读不出（旧档记着已冻结的武器 / 对应工坊包被停用）时的兜底。
		# 用 Config.FALLBACK_WEAPON，不再硬编码 "pistol" —— 后者已在 S2 迁入工坊包。
		player.weapons = [{ "type": Config.FALLBACK_WEAPON, "cd": 0.3 }]
	player.load_family_synergy_snapshot()   # 存档 stats 已含共鸣，只记录不重算
	player.items_owned = {}
	for id: String in pl.items_owned:
		if Registry.items.has(id):
			var count := int(pl.items_owned[id])
			if count > 0:
				player.items_owned[id] = count
	# 升级记账：只恢复「当前 Registry 里还存在」的条目（mod 卸载后存档里的升级失效，
	# 静默丢弃，与 items_owned 同款处理）。旧档没有这个键 → pl.get 取 {}，原地升级，
	# 唯一性从空集开始（唯一性只能往后保证，旧档无法追溯）。
	player.upgrades_owned = {}
	var saved_up: Dictionary = pl.get("upgrades_owned", {})
	for uid: String in saved_up:
		if Registry.upgrades.has(uid):
			player.upgrades_owned[uid] = int(saved_up[uid])
	# 法宝：stats 已随存档恢复（叠层加成已含在其中），这里只恢复持有表与层数记录。
	# 刻意不调 _set_artifact_stacks / apply_artifact：前者会把已入账的属性再加一遍，
	# 后者会重复发 artifact_acquired 与图鉴解锁
	player.artifacts_owned = {}
	player.artifact_stacks = {}
	var saved_stacks: Dictionary = pl.get("artifact_stacks", {})
	for aid: String in pl.get("artifacts_owned", {}):
		# mod 卸载后存档里的法宝失效：静默丢弃（与 items_owned 同款处理）
		if not Registry.artifacts.has(aid):
			continue
		player.artifacts_owned[aid] = 1
		var stacks := int(saved_stacks.get(aid, 0))
		if stacks > 0:
			player.artifact_stacks[aid] = stacks
	player.queue_redraw()
	current_run_owns_slot = true
	return wave

func summary(slot: int) -> Dictionary:
	var data := _read(slot)
	if data.is_empty():
		return {}
	var run: Dictionary = data.run
	return {
		"wave": int(run.wave),
		"character_id": String(run.get("character_id", "potato")),
		"saved_at": String(data.get("saved_at", "")),
		"checkpoint": String(data.get("checkpoint", CHECKPOINT_SHOP)),
		"endless": bool(run.get("endless", false)),
		"score": int(run.get("score", 0)),
	}

func clear() -> void:
	var path := slot_path(GameState.slot_id)
	if path == "":
		return
	for candidate in [path, path + ".tmp", path + ".bak", path + ".bak.old"]:
		if FileAccess.file_exists(candidate):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(candidate))
	current_run_owns_slot = false

# ---------------- 内部 ----------------

## 存档里这一局的波次总数：自定义规则局取 run_rules.values.waves（已 clamp 到规则区间），
## 其余情况回落 Config.WAVES_TOTAL。刻意不查 RunRules 当前状态 ——
## 校验发生在 apply_from_save 之前，那时的 RunRules 还停留在上一局的参数
func _saved_wave_total(run: Dictionary) -> int:
	var raw: Variant = run.get("run_rules", {})
	if typeof(raw) != TYPE_DICTIONARY:
		return Config.WAVES_TOTAL
	var rules: Dictionary = raw
	if not bool(rules.get("active", false)):
		return Config.WAVES_TOTAL
	var vals: Variant = rules.get("values", {})
	if typeof(vals) != TYPE_DICTIONARY:
		return Config.WAVES_TOTAL
	var def := RunRules.rule_def("waves")
	var lo := int(def.get("min", 5))
	var hi := int(def.get("max", 30))
	var w := int(round(float((vals as Dictionary).get("waves", Config.WAVES_TOTAL))))
	return clampi(w, lo, hi)

func _read(slot: int) -> Dictionary:
	var path := slot_path(slot)
	if path == "":
		return {}
	var data := _read_path(path)
	if data.is_empty():
		data = _read_path(path + ".bak")
	return data

func _read_path(path: String) -> Dictionary:
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
	var data: Dictionary = json.data
	if not _is_exact_integer(data.get("version")) \
			or int(data.version) not in COMPATIBLE_VERSIONS \
			or not _integer_in_range(data.get("rng_a"), 0, 0xFFFFFFFF):
		return {}
	if data.has("checkpoint") and (typeof(data.checkpoint) != TYPE_STRING \
			or String(data.checkpoint) not in [CHECKPOINT_SHOP, CHECKPOINT_WAVE_START]):
		return {}
	if typeof(data.get("run")) != TYPE_DICTIONARY or typeof(data.get("player")) != TYPE_DICTIONARY:
		return {}
	var run: Dictionary = data.run
	var pl: Dictionary = data.player
	if run.has("endless") and typeof(run.endless) != TYPE_BOOL:
		return {}
	# 波次上限：无尽 9999；自定义规则局读存档里的波次总数（不读当前 RunRules.state ——
	# 此刻还没 apply_from_save，读到的是上一局的残留值）；普通局回落 10
	var wave_max := Config.ENDLESS_MAX_WAVE if bool(run.get("endless", false)) \
		else _saved_wave_total(run)
	if not _integer_in_range(run.get("wave"), 1, wave_max) \
			or not _integer_in_range(run.get("materials"), 0, 2_000_000_000) \
			or not _integer_in_range(run.get("kills"), 0, 2_000_000_000) \
			or not _integer_in_range(run.get("level"), 1, 100_000) \
			or not _integer_in_range(run.get("xp"), 0, 2_000_000_000) \
			or not _integer_in_range(run.get("level_queue"), 0, 100_000) \
			or not _number_in_range(run.get("run_time"), 0.0, 315_360_000.0) \
			or (run.has("score") and not _integer_in_range(run.get("score"), 0, 2_000_000_000)):
		return {}
	for key in ["difficulty_id", "character_id", "loadout_weapon", "loadout_item"]:
		if run.has(key) and typeof(run[key]) != TYPE_STRING:
			return {}
	# 自定义规则字段：旧存档没有这个键（用 .get 默认值放行）；
	# 出现时必须是字典，否则整档拒绝 —— 半截数据会让读档后难度静默错位
	if run.has("run_rules") and typeof(run.run_rules) != TYPE_DICTIONARY:
		return {}
	if not _is_finite_number(pl.get("hp")) or float(pl.hp) <= 0.0 \
			or typeof(pl.get("stats")) != TYPE_DICTIONARY \
			or typeof(pl.get("weapons")) != TYPE_ARRAY \
			or typeof(pl.get("items_owned")) != TYPE_DICTIONARY:
		return {}
	# 法宝字段用 .get 默认值：旧存档（Phase 3 之前）无这两个键，仍须能恢复
	if typeof(pl.get("artifacts_owned", {})) != TYPE_DICTIONARY \
			or typeof(pl.get("artifact_stacks", {})) != TYPE_DICTIONARY:
		return {}
	var stat_limits := {
		"max_hp": Vector2(1.0, 10_000_000.0), "regen": Vector2(0.0, 1_000_000.0),
		"armor": Vector2(-7.9, 1_000_000.0), "dodge": Vector2(0.0, 0.95),
		"dmg_mult": Vector2(0.01, 10_000.0), "as_mult": Vector2(0.01, 10_000.0),
		"crit_ch": Vector2(0.0, Config.CRIT_CHANCE_CAP), "crit_mult": Vector2(1.0, 10_000.0),
		"speed_mult": Vector2(0.01, 10_000.0), "base_speed": Vector2(1.0, 100_000.0),
		"pickup_range": Vector2(0.0, 1_000_000.0), "harvesting": Vector2(-0.99, 1_000.0),
		"lifesteal": Vector2(0.0, 1_000_000.0),
		"status_chance": Vector2(0.0, 1.0), "status_dmg_mult": Vector2(0.0, 1_000.0),
		"status_dur_mult": Vector2(0.0, 1_000.0), "status_spread": Vector2(0.0, 1.0),
		"on_hit_burn": Vector2(0.0, 1.0), "on_hit_poison": Vector2(0.0, 1.0),
		"on_hit_freeze": Vector2(0.0, 1.0), "on_hit_slow": Vector2(0.0, 1.0),
		"on_hit_stun": Vector2(0.0, 1.0), "on_hit_bleed": Vector2(0.0, 1.0),
		# 元素同化度（五行体系 §7）：缺失按默认值恢复（旧档没有这 5 键），
		# 出现时严格校验 —— 上限与 Registry.STAT_LIMITS 对齐到 2.0，
		# 这里不外扩：存档恢复走的是「玩家实际值」而非 mod 余量。
		"assim_metal": Vector2(0.0, 2.0), "assim_wood": Vector2(0.0, 2.0),
		"assim_water": Vector2(0.0, 2.0), "assim_fire": Vector2(0.0, 2.0),
		"assim_earth": Vector2(0.0, 2.0),
	}
	for key in stat_limits:
		# 旧版本存档没有状态字段：缺失按默认值恢复，出现时仍严格校验
		if not pl.stats.has(key):
			continue
		var limits: Vector2 = stat_limits[key]
		if not _number_in_range(pl.stats.get(key), limits.x, limits.y):
			return {}
	if float(pl.hp) > float(pl.stats.get("max_hp", 0.0)):
		return {}
	# 6 基础槽 + 1 军火专家天赋槽；玩家可能购买天赋后存 7 把再读档
	if pl.weapons.is_empty() or pl.weapons.size() > Config.WEAPON_SLOTS + 1:
		return {}
	for w in pl.weapons:
		if typeof(w) != TYPE_DICTIONARY or typeof(w.get("type")) != TYPE_STRING \
				or String(w.type).is_empty() or String(w.type).length() > 128:
			return {}
	for id in pl.items_owned:
		if typeof(id) != TYPE_STRING or String(id).is_empty() or String(id).length() > 128 \
				or not _integer_in_range(pl.items_owned[id], 1, 1_000_000):
			return {}
	for uid in pl.get("upgrades_owned", {}):
		if typeof(uid) != TYPE_STRING or String(uid).is_empty() or String(uid).length() > 128 \
				or not _integer_in_range(pl.upgrades_owned[uid], 1, 1_000_000):
			return {}
	for aid in pl.get("artifacts_owned", {}):
		if typeof(aid) != TYPE_STRING or String(aid).is_empty() \
				or String(aid).length() > 128:
			return {}
	for sid in pl.get("artifact_stacks", {}):
		# 上限 1000：stack_max 本身被 Registry 限定在 [1, 100]，给 mod 改版留余量
		if typeof(sid) != TYPE_STRING or String(sid).is_empty() \
				or not _integer_in_range(pl.artifact_stacks[sid], 0, 1000):
			return {}
	return data

func _sanitize_stats(stats: Dictionary) -> void:
	stats.max_hp = maxf(1.0, float(stats.max_hp))
	stats.base_speed = maxf(1.0, float(stats.base_speed))
	stats.dmg_mult = maxf(0.01, float(stats.dmg_mult))
	stats.as_mult = maxf(0.01, float(stats.as_mult))
	stats.speed_mult = maxf(0.01, float(stats.speed_mult))
	stats.crit_ch = clampf(float(stats.crit_ch), 0.0, Config.CRIT_CHANCE_CAP)
	stats.crit_mult = maxf(1.0, float(stats.crit_mult))
	stats.armor = maxf(-7.9, float(stats.armor))
	stats.dodge = clampf(float(stats.dodge), 0.0, 0.95)
	stats.pickup_range = maxf(0.0, float(stats.pickup_range))
	stats.regen = maxf(0.0, float(stats.regen))
	stats.harvesting = maxf(-0.99, float(stats.harvesting))
	stats.lifesteal = maxf(0.0, float(stats.lifesteal))
	stats.status_chance = clampf(float(stats.status_chance), 0.0, 1.0)
	stats.status_dmg_mult = maxf(0.0, float(stats.status_dmg_mult))
	stats.status_dur_mult = maxf(0.0, float(stats.status_dur_mult))
	stats.status_spread = clampf(float(stats.status_spread), 0.0, 1.0)
	# 投掷类加成（第 8 轮）：与 player._sanitize_stats 保持一致。
	# ⚠️ 不加这行也不会报错（这两键不在上面的 stat_limits 校验表里），
	#    但读档后会把负数原样恢复 —— 那等于「穿甲正数变负数」的同类静默坑。
	stats.throw_speed_bonus = maxf(0.0, float(stats.throw_speed_bonus))
	stats.throw_range_bonus = maxf(0.0, float(stats.throw_range_bonus))
	# 元素同化度（五行体系 §7）：与 player._sanitize_stats 的副本保持一致
	for eid in Config.ELEMENTS:
		var assim_key := "assim_" + String(eid)
		stats[assim_key] = clampf(float(stats.get(assim_key, 0.0)), 0.0, 2.0)
	for sid in Config.STATUS:
		var status_key := "on_hit_" + String(sid)
		stats[status_key] = clampf(float(stats.get(status_key, 0.0)), 0.0, 1.0)

func _write_json_atomic(path: String, data: Dictionary) -> bool:
	var dir := path.get_base_dir()
	var dir_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		push_warning("SaveRun: 无法创建目录 " + dir)
		return false
	var tmp := path + ".tmp"
	var bak := path + ".bak"
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("SaveRun: 无法创建临时存档 " + tmp)
		return false
	f.store_string(JSON.stringify(data))
	f.flush()
	var write_err := f.get_error()
	f.close()
	if write_err != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
		push_warning("SaveRun: 临时存档写入失败 " + tmp)
		return false
	if _read_path(tmp).is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
		push_warning("SaveRun: 临时存档校验失败 " + tmp)
		return false
	var path_abs := ProjectSettings.globalize_path(path)
	var tmp_abs := ProjectSettings.globalize_path(tmp)
	var bak_abs := ProjectSettings.globalize_path(bak)
	var bak_old := bak + ".old"
	var bak_old_abs := ProjectSettings.globalize_path(bak_old)
	var moved_existing := false
	var rotated_backup := false
	if FileAccess.file_exists(path):
		if _read_path(path).is_empty():
			# 正式档已坏时保留现有有效 .bak，只移除坏文件。
			if DirAccess.remove_absolute(path_abs) != OK:
				DirAccess.remove_absolute(tmp_abs)
				return false
		else:
			# 先把旧备份移到旁路；任何后续失败都可以原位回滚。
			if FileAccess.file_exists(bak_old) and DirAccess.remove_absolute(bak_old_abs) != OK:
				DirAccess.remove_absolute(tmp_abs)
				return false
			if FileAccess.file_exists(bak):
				if DirAccess.rename_absolute(bak_abs, bak_old_abs) != OK:
					DirAccess.remove_absolute(tmp_abs)
					return false
				rotated_backup = true
			if DirAccess.rename_absolute(path_abs, bak_abs) != OK:
				if rotated_backup:
					DirAccess.rename_absolute(bak_old_abs, bak_abs)
				DirAccess.remove_absolute(tmp_abs)
				push_warning("SaveRun: 无法备份旧存档 " + path)
				return false
			moved_existing = true
	if DirAccess.rename_absolute(tmp_abs, path_abs) != OK:
		if moved_existing:
			DirAccess.rename_absolute(bak_abs, path_abs)
		if rotated_backup:
			DirAccess.rename_absolute(bak_old_abs, bak_abs)
		push_warning("SaveRun: 无法替换正式存档 " + path)
		return false
	if FileAccess.file_exists(bak_old):
		DirAccess.remove_absolute(bak_old_abs)
	# 保留上一版有效 .bak；正式档后续损坏时 _read 会自动回退。
	return true

func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT

func _is_finite_number(value: Variant) -> bool:
	return _is_number(value) and is_finite(float(value))

func _is_exact_integer(value: Variant) -> bool:
	return _is_finite_number(value) and float(value) == floorf(float(value))

func _integer_in_range(value: Variant, minimum: int, maximum: int) -> bool:
	return _is_exact_integer(value) and float(value) >= float(minimum) \
		and float(value) <= float(maximum)

func _number_in_range(value: Variant, minimum: float, maximum: float) -> bool:
	return _is_finite_number(value) and float(value) >= minimum and float(value) <= maximum

## 旧布局 → 唯一档合并（§10.1）。幂等；**没有旧三槽文件时一个字节都不动**。
##
## 步骤：
##   1. 收集候选 = 三个旧槽文件（唯一档自身**不需要**参与合并：它就在目标路径上，
##      本来就是「已经到位」的那一份，见下面第 3 步的比较）；
##   2. 只有能通过 `_read_path` 校验的才算候选 —— **坏档不参与竞争，也不删**，
##      否则一个损坏的 `save_slot_3.json` 就能把有效的好档顶掉；
##   3. 取 `saved_at` 最新的一份写进唯一档；唯一档若已不比它旧，则只清理旧文件、不覆盖。
##
## ⚠️ `saved_at` 用字符串比较即可：`Time.get_datetime_string_from_system(false, true)`
##    输出 ISO 风格 "2026-09-16T19:01:17"，字典序 == 时间序。
## ⚠️ 不要写成「先 legacy 再三槽」的两段式定序 —— v1 单槽档与三槽档**可能同时残留**
##    （v1→三槽的那次迁移中断过），按文件名/先后顺序选会静默选错版本。
##    取最新 `saved_at` 与顺序无关，两种布局合流也安全。
func _migrate_old_layout() -> void:
	var target := slot_path(1)
	var valid: Array = []
	for name in LEGACY_SLOT_FILES:
		var p := _storage_root.path_join(String(name))
		if not FileAccess.file_exists(p):
			continue
		var d := _read_path(p)
		if d.is_empty():
			push_warning("SaveRun: 旧槽档无效，已保留原文件 " + p)
			continue
		valid.append({ "path": p, "at": String(d.get("saved_at", "")), "data": d })
	if valid.is_empty():
		return
	var best: Dictionary = valid[0]
	for e in valid:
		if String(e.at) > String(best.at):
			best = e
	var cur := _read_path(target)
	var cur_at := String(cur.get("saved_at", "")) if not cur.is_empty() else ""
	var merged := false
	if cur_at < String(best.at):
		merged = _write_json_atomic(target, best.data)
		if not merged:
			return          # 写失败：旧档一个都别删，下次启动再试
	if merged or cur_at >= String(best.at):
		for e2 in valid:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(String(e2.path)))
