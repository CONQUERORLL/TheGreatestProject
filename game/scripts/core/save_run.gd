extends Node
## 三槽自动存档：v2 始终保存下一波开场快照；v1 商店检查点仅保留兼容读取。
## 每次写入先落临时文件并保留上一版备份，避免截断正式存档后写入失败。

const VERSION := 2
const COMPATIBLE_VERSIONS := [1, 2]
const SLOT_COUNT := 3
const LEGACY_PATH := "user://save_run.json"
const DEFAULT_STORAGE_ROOT := "user://"
const CHECKPOINT_SHOP := "shop"
const CHECKPOINT_WAVE_START := "wave_start"

var restored_checkpoint := CHECKPOINT_SHOP
var current_run_owns_slot := false
var _storage_root := DEFAULT_STORAGE_ROOT
var _legacy_path := LEGACY_PATH

func migrate_legacy_if_needed(allow_test_storage := false) -> void:
	if _storage_root == DEFAULT_STORAGE_ROOT or allow_test_storage:
		_migrate_legacy()

func slot_path(slot: int) -> String:
	if slot < 1 or slot > SLOT_COUNT:
		return ""
	return _storage_root.path_join("save_slot_%d.json" % slot)

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
	_legacy_path = _storage_root.path_join("save_run.json")

func reset_storage_root_after_tests() -> void:
	_storage_root = DEFAULT_STORAGE_ROOT
	_legacy_path = LEGACY_PATH

## 保存当前局到当前槽。checkpoint 表示恢复后进入商店还是直接重打该波。
## 无尽模式波次上限放宽到 ENDLESS_MAX_WAVE。
func save(next_wave: int, player: Node, checkpoint: String = CHECKPOINT_WAVE_START) -> bool:
	var wave_max := Config.ENDLESS_MAX_WAVE if GameState.endless else Config.WAVES_TOTAL
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
		},
		"player": {
			"hp": player.hp,
			"stats": player.stats.duplicate(),
			"weapons": player.weapons.map(func(w: Dictionary) -> Dictionary:
				return { "type": w.type }),
			"items_owned": player.items_owned.duplicate(),
		},
	}
	var saved := _write_json_atomic(path, data)
	if saved:
		current_run_owns_slot = true
	return saved

## 恢复当前槽并返回波次；restored_checkpoint 告知调用方恢复到商店或波次开始。
func restore(player: Node) -> int:
	var data := _read(GameState.slot_id)
	if data.is_empty():
		return 0
	var run: Dictionary = data.run
	var wave := int(run.wave)
	restored_checkpoint = String(data.get("checkpoint", CHECKPOINT_SHOP))
	if restored_checkpoint not in [CHECKPOINT_SHOP, CHECKPOINT_WAVE_START]:
		restored_checkpoint = CHECKPOINT_SHOP
	var character_id := String(run.get("character_id", "potato"))
	if not Registry.characters.has(character_id):
		character_id = "potato"
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
		player.weapons = [{ "type": "pistol", "cd": 0.3 }]
	player.items_owned = {}
	for id: String in pl.items_owned:
		if Registry.items.has(id):
			var count := int(pl.items_owned[id])
			if count > 0:
				player.items_owned[id] = count
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
	var wave_max := Config.ENDLESS_MAX_WAVE if bool(run.get("endless", false)) else Config.WAVES_TOTAL
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
	if not _is_finite_number(pl.get("hp")) or float(pl.hp) <= 0.0 \
			or typeof(pl.get("stats")) != TYPE_DICTIONARY \
			or typeof(pl.get("weapons")) != TYPE_ARRAY \
			or typeof(pl.get("items_owned")) != TYPE_DICTIONARY:
		return {}
	var stat_limits := {
		"max_hp": Vector2(1.0, 10_000_000.0), "regen": Vector2(0.0, 1_000_000.0),
		"armor": Vector2(-7.9, 1_000_000.0), "dodge": Vector2(0.0, 0.95),
		"dmg_mult": Vector2(0.01, 10_000.0), "as_mult": Vector2(0.01, 10_000.0),
		"crit_ch": Vector2(0.0, 1.0), "crit_mult": Vector2(1.0, 10_000.0),
		"speed_mult": Vector2(0.01, 10_000.0), "base_speed": Vector2(1.0, 100_000.0),
		"pickup_range": Vector2(0.0, 1_000_000.0), "harvesting": Vector2(-0.99, 1_000.0),
		"lifesteal": Vector2(0.0, 1_000_000.0),
	}
	for key in stat_limits:
		var limits: Vector2 = stat_limits[key]
		if not _number_in_range(pl.stats.get(key), limits.x, limits.y):
			return {}
	if float(pl.hp) > float(pl.stats.max_hp):
		return {}
	if pl.weapons.is_empty() or pl.weapons.size() > Config.WEAPON_SLOTS:
		return {}
	for w in pl.weapons:
		if typeof(w) != TYPE_DICTIONARY or typeof(w.get("type")) != TYPE_STRING \
				or String(w.type).is_empty() or String(w.type).length() > 128:
			return {}
	for id in pl.items_owned:
		if typeof(id) != TYPE_STRING or String(id).is_empty() or String(id).length() > 128 \
				or not _integer_in_range(pl.items_owned[id], 1, 1_000_000):
			return {}
	return data

func _sanitize_stats(stats: Dictionary) -> void:
	stats.max_hp = maxf(1.0, float(stats.max_hp))
	stats.base_speed = maxf(1.0, float(stats.base_speed))
	stats.dmg_mult = maxf(0.01, float(stats.dmg_mult))
	stats.as_mult = maxf(0.01, float(stats.as_mult))
	stats.speed_mult = maxf(0.01, float(stats.speed_mult))
	stats.crit_ch = clampf(float(stats.crit_ch), 0.0, 1.0)
	stats.crit_mult = maxf(1.0, float(stats.crit_mult))
	stats.armor = maxf(-7.9, float(stats.armor))
	stats.dodge = clampf(float(stats.dodge), 0.0, 0.95)
	stats.pickup_range = maxf(0.0, float(stats.pickup_range))
	stats.regen = maxf(0.0, float(stats.regen))
	stats.harvesting = maxf(-0.99, float(stats.harvesting))
	stats.lifesteal = maxf(0.0, float(stats.lifesteal))

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

func _migrate_legacy() -> void:
	if not FileAccess.file_exists(_legacy_path) or exists(1):
		return
	var data := _read_path(_legacy_path)
	if data.is_empty():
		push_warning("SaveRun: 旧单槽存档无效，已保留原文件")
		return
	data["version"] = VERSION
	data["checkpoint"] = String(data.get("checkpoint", CHECKPOINT_SHOP))
	data["saved_at"] = String(data.get("saved_at", "（迁移档）"))
	if _write_json_atomic(slot_path(1), data):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_legacy_path))
