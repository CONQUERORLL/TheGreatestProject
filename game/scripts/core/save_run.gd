extends Node
## 单槽自动存档 autoload：波次间（商店阶段）为安全点，战斗中退出保留进度
## 存 user://save_run.json；死亡/胜利清档；主菜单"继续游戏"恢复
## 存档点语义：wave = 接下来要打的波次编号（商店后 = 刚结束波+1；战斗中退出 = 当前波）

const SAVE_PATH := "user://save_run.json"
const VERSION := 1

func exists() -> bool:
	return FileAccess.file_exists(SAVE_PATH)

## 保存当前局：next_wave = 恢复后要打的波次
func save(next_wave: int, player: Node) -> void:
	if next_wave <= 0:
		return
	var data := {
		"version": VERSION,
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
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("SaveRun: 写入失败 " + SAVE_PATH)
		return
	f.store_string(JSON.stringify(data))
	f.close()

## 恢复：写回 GameState / player / GameRng（player._ready 已跑，直接覆盖）
## 返回接下来要打的波次；0 = 档无效（调用方回退正常开局）
func restore(player: Node) -> int:
	var data := _read()
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

## 主菜单展示用摘要 { wave, character_id }；无档/损坏返回空
func summary() -> Dictionary:
	var data := _read()
	if data.is_empty():
		return {}
	return { "wave": int(data.run.get("wave", 0)),
		"character_id": String(data.run.get("character_id", "potato")) }

## 清档（死亡 / 胜利）
func clear() -> void:
	if exists():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))

# ---------------- 内部 ----------------

## 读档 + 版本/结构校验；无效返回空 Dictionary
func _read() -> Dictionary:
	if not exists():
		return {}
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
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
