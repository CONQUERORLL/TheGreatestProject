extends Node
## 三槽自动存档 autoload：每槽独立 JSON 文件（user://save_slot_N.json）
## 存/读/清均作用于 GameState.slot_id 指定的当前槽（主菜单选槽后设置）
## 波次间（商店阶段）为安全点，战斗中退出保留进度；死亡/胜利清档
## 存档点语义：wave = 接下来要打的波次编号（商店后 = 刚结束波+1；战斗中退出 = 当前波）

const VERSION := 1
const SLOT_COUNT := 3
const LEGACY_PATH := "user://save_run.json"   # 旧单槽档（启动时迁移到槽 1）

func _ready() -> void:
	_migrate_legacy()

func slot_path(slot: int) -> String:
	return "user://save_slot_%d.json" % clampi(slot, 1, SLOT_COUNT)

func exists(slot: int) -> bool:
	return FileAccess.file_exists(slot_path(slot))

## 任一槽有档（主菜单"继续游戏"入口显隐用）
func any_exists() -> bool:
	for i in range(1, SLOT_COUNT + 1):
		if exists(i):
			return true
	return false

## 保存当前局到当前槽：next_wave = 恢复后要打的波次
func save(next_wave: int, player: Node) -> void:
	if next_wave <= 0:
		return
	var data := {
		"version": VERSION,
		"saved_at": Time.get_datetime_string_from_system(false, true),   # 本地时间 YYYY-MM-DD HH:MM:SS
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
		},
		"player": {
			"hp": player.hp,
			"stats": player.stats.duplicate(),
			"weapons": player.weapons.map(func(w: Dictionary) -> Dictionary:
				return { "type": w.type }),
			"items_owned": player.items_owned.duplicate(),
		},
	}
	var path := slot_path(GameState.slot_id)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("SaveRun: 写入失败 " + path)
		return
	f.store_string(JSON.stringify(data))
	f.close()

## 恢复当前槽：写回 GameState / player / GameRng（player._ready 已跑，直接覆盖）
## 返回接下来要打的波次；0 = 档无效/空槽（调用方回退正常开局）
func restore(player: Node) -> int:
	var data := _read(GameState.slot_id)
	if data.is_empty():
		return 0
	var run: Dictionary = data.run
	# 角色 id 失效（创意工坊内容卸载）回退内置角色
	if not Registry.characters.has(String(run.get("character_id", ""))):
		run.character_id = "potato"
	GameState.materials = int(run.get("materials", 0))
	GameState.kills = int(run.get("kills", 0))
	GameState.run_time = float(run.get("run_time", 0.0))
	GameState.level = int(run.get("level", 1))
	GameState.xp = int(run.get("xp", 0))
	GameState.level_queue = int(run.get("level_queue", 0))
	GameState.difficulty_id = String(run.get("difficulty_id", "normal"))
	GameState.character_id = String(run.character_id)
	GameState.loadout_weapon = String(run.get("loadout_weapon", ""))
	GameState.loadout_item = String(run.get("loadout_item", ""))
	GameRng._a = int(data.get("rng_a", 0)) & 0xFFFFFFFF
	var pl: Dictionary = data.player
	player.stats = (pl.get("stats", {}) as Dictionary).duplicate()
	player.hp = minf(float(pl.get("hp", 0.0)), float(player.stats.max_hp))
	player.weapons = []
	for w in pl.get("weapons", []):
		if Registry.weapons.has(String(w.get("type", ""))):
			player.weapons.append({ "type": String(w.type), "cd": 0.3 })
	if player.weapons.is_empty():
		player.weapons = [{ "type": "pistol", "cd": 0.3 }]   # 武器全失效兜底
	player.items_owned = {}
	for id: String in (pl.get("items_owned", {}) as Dictionary):
		if Registry.items.has(id):
			player.items_owned[id] = int(pl.items_owned[id])
	player.queue_redraw()
	return int(run.get("wave", 0))

## 选槽界面展示摘要 { wave, character_id, saved_at }；空槽/损坏返回空
func summary(slot: int) -> Dictionary:
	var data := _read(slot)
	if data.is_empty():
		return {}
	return { "wave": int(data.run.get("wave", 0)),
		"character_id": String(data.run.get("character_id", "potato")),
		"saved_at": String(data.get("saved_at", "")) }

## 清当前槽（死亡 / 胜利 / 覆盖开新局）
func clear() -> void:
	var path := slot_path(GameState.slot_id)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

# ---------------- 内部 ----------------

## 读指定槽 + 版本/结构校验；无效返回空 Dictionary
func _read(slot: int) -> Dictionary:
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var data: Dictionary = parsed
	if int(data.get("version", 0)) != VERSION:
		return {}
	if typeof(data.get("run")) != TYPE_DICTIONARY \
			or typeof(data.get("player")) != TYPE_DICTIONARY:
		return {}
	return data

## 旧单槽档一次性迁移到槽 1（损坏则直接删除）
func _migrate_legacy() -> void:
	if not FileAccess.file_exists(LEGACY_PATH) or exists(1):
		return
	var f := FileAccess.open(LEGACY_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	var legacy_path := ProjectSettings.globalize_path(LEGACY_PATH)
	if typeof(parsed) != TYPE_DICTIONARY \
			or int((parsed as Dictionary).get("version", 0)) != VERSION:
		DirAccess.remove_absolute(legacy_path)
		return
	var data: Dictionary = parsed
	if typeof(data.get("run")) != TYPE_DICTIONARY \
			or typeof(data.get("player")) != TYPE_DICTIONARY:
		DirAccess.remove_absolute(legacy_path)
		return
	data["saved_at"] = String(data.get("saved_at", "（迁移档）"))
	var w := FileAccess.open(slot_path(1), FileAccess.WRITE)
	w.store_string(JSON.stringify(data))
	w.close()
	DirAccess.remove_absolute(legacy_path)
