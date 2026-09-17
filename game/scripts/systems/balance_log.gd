class_name BalanceLog
extends RefCounted
## 逐波平衡日志（2026-09-17 · 第 8 轮需求 4）
##
## 目的：让「这一局到底是怎么变强 / 变弱的」可被**离线分析**。
## 每一波结束落一次盘，记录该波结束瞬间的全量数据（属性 / 武器 / 道具 / 法宝 +
## 本波战斗统计），既够画曲线，也够对着数字复盘平衡。
##
## ---- 三条口径（改代码前先读）----
##
## 1. **一个存档一份日志**：`user://balance_log.json`，与唯一档
##    （`SaveRun.SAVE_FILE`）一一对应。新局开始（`main._ready` 的新局分支）清空重记；
##    续档（`restored_wave > 0`）接着写，不丢前面几波的历史。
##
## 2. **落盘点 = 存档点**：写在 `main._finish_evolve_flow()` 里紧挨 `SaveRun.save()`。
##    这样日志里的玩家状态与存档**同源同刻**，不会出现「日志说 A、读档是 B」。
##    通关 / 阵亡各补记一次（`outcome` = victory / death）—— 那是分析最想看的两个点。
##
## 3. **纯读不写**：本模块只读取运行时真值（`player.stats` / `Registry` / `GameState`），
##    绝不反过来改游戏状态；写盘失败也不阻断玩法（只 push_warning + 返回 false）——
##    它是一份诊断日志，不是存档，玩家不关心它成没成。
##
## ⚠️⚠️ **静态状态在进程内存活**：`begin_run()` 必须清零，否则上一局的击杀 / 伤害
##    会静默计进下一局的第一波（数字看着都正常，只是全部偏大）。
## ⚠️ 冒烟测试走 `set_storage_root_for_tests()` 换根目录（与 `SaveRun` 同款），
##    避免污染正式 `user://balance_log.json`。
## ⚠️ 数值一律**取运行时的同一份真值**：武器的射程 / 弹速走 `player.weapon_reach()`
##    （内部调 `_weapon_runtime_cfg()`，与开火路径同一个函数），
##    因此日志里的数字就是实机在用的数字（含角色特性 / 道具加成），不会与代码脱节。

const VERSION := 1
const FILE := "balance_log.json"
## 逐波紧凑历史保留条数（无尽模式会跑很久，超出的丢最早的）
const HISTORY_MAX := 120

## 紧凑历史里逐波抽出来画曲线的属性（全量 stats 只存在 `latest` 里，控体积）
const CURVE_STATS := [
	"max_hp", "regen", "armor", "dodge", "dmg_mult", "as_mult",
	"crit_ch", "crit_mult", "speed_mult", "lifesteal",
	"pickup_range", "harvesting", "status_chance", "status_dmg_mult",
]

static var _root := "user://"
static var _active := false

## ---- 本波起点快照（算「本波增量」用；`commit` 后更新为「上一波结束」状态）----
static var _wave := 0
static var _start := {}
static var _wall_ms := 0

## ---- 本波累计 ----
static var _dealt := 0.0
static var _taken := 0.0
static var _heal := 0.0
static var _hp_min := 0.0
static var _spawned := 0
static var _event := ""
static var _by_source := {}

## ---- 落盘内容 ----
static var _latest := {}
static var _history: Array = []

# ------------------------------------------------------------
# 生命周期
# ------------------------------------------------------------

## 直接调用本模块的静态方法前，必须先 `begin_run()` —— 否则 `_active == false`，
## 所有累计接口都是空操作（这是刻意的：菜单 / 图鉴 / 冒烟里跑到的战斗代码不该写盘）。
static func is_active() -> bool:
	return _active

static func begin_run(keep_history := false) -> void:
	_active = true
	_wave = 0
	_start = {}
	_wall_ms = 0
	_reset_wave_counters()
	if keep_history:
		if _history.is_empty():
			_adopt_existing()
	else:
		_latest = {}
		_history = []

## 回主菜单 / 结束本局：停止累计（不清盘 —— 日志就是留给玩家看的分析产物）
static func close_run() -> void:
	_active = false

## 冒烟 / 自动化测试隔离：把日志写进临时目录
static func set_storage_root_for_tests(path: String) -> void:
	_root = path.trim_suffix("/")

static func reset_storage_root_after_tests() -> void:
	_root = "user://"

static func path() -> String:
	return _root.path_join(FILE)

# ------------------------------------------------------------
# 每波累计
# ------------------------------------------------------------

static func begin_wave(w: int) -> void:
	if not _active:
		return
	_wave = w
	_reset_wave_counters()
	_start = {
		"kills": GameState.kills,
		"materials": GameState.materials,
		"run_time": GameState.run_time,
		"level": GameState.level,
		"xp": GameState.xp,
	}
	_wall_ms = Time.get_ticks_msec()

## 伤害来源标签（`enemy.take_damage` 的第 5 参）：
##   · 武器   → 武器 id（`player._roll_damage` 写进 roll 的 `wtype`）
##   · 其余   → "trait" / "skill" / "status" / "other"
## 这样日志能回答「这一波谁在输出」，而不只是总量。
static func add_damage_dealt(v: float, src := "") -> void:
	if not _active or v <= 0.0 or not is_finite(v):
		return
	_dealt += v
	var key := src if src != "" else "other"
	_by_source[key] = float(_by_source.get(key, 0.0)) + v

static func add_damage_taken(v: float) -> void:
	if not _active or v <= 0.0 or not is_finite(v):
		return
	_taken += v

## 只统计走 `player.heal()` 的即时治疗（不含被动回血 / 吸血 / 事件直达 hp 的写法）。
## 口径写在这里，免得以后看到「回复量偏低」以为是漏记。
static func add_heal(v: float) -> void:
	if not _active or v <= 0.0 or not is_finite(v):
		return
	_heal += v

static func note_hp(hp: float) -> void:
	if not _active or not is_finite(hp):
		return
	_hp_min = hp if _hp_min <= 0.0 else minf(_hp_min, hp)

static func note_spawn(n := 1) -> void:
	if not _active:
		return
	_spawned += n

## 事件波类型（宝箱 / 狩猎 / 流星雨）—— 由 wave_manager 抽中时写入
static func note_event(kind: String) -> void:
	if not _active:
		return
	_event = kind

static func _reset_wave_counters() -> void:
	_dealt = 0.0
	_taken = 0.0
	_heal = 0.0
	_hp_min = 0.0
	_spawned = 0
	_event = ""
	_by_source = {}

# ------------------------------------------------------------
# 落盘
# ------------------------------------------------------------

## outcome: "shop"（正常收波）/ "death" / "victory"
static func commit(wave: int, player: Node, outcome := "shop") -> bool:
	if not _active:
		return false
	if wave <= 0 or player == null or not is_instance_valid(player):
		return false
	var snap: Dictionary = player.balance_snapshot()
	var play_dur := maxf(0.0, GameState.run_time - float(_start.get("run_time", 0.0)))
	var wall_dur := maxf(0.0, float(Time.get_ticks_msec() - _wall_ms) / 1000.0)
	var kills := maxi(0, GameState.kills - int(_start.get("kills", 0)))
	var mats := GameState.materials - int(_start.get("materials", 0))
	var dps := _dealt / play_dur if play_dur > 0.001 else 0.0
	var at := Time.get_datetime_string_from_system(false, true)
	var wave_data := {
		# `duration` = 本波**战斗时长**（run_time 只在 PLAYING 累加 → 不含 intro / 商店）；
		# `duration_wall` = 上一波落盘到本波落盘的墙钟时长（含 intro / 商店 / 升级选择）
		"duration": play_dur,
		"duration_wall": wall_dur,
		"kills": kills,
		"spawned": _spawned,
		"materials_gained": mats,
		"damage_dealt": _dealt,
		"damage_taken": _taken,
		"heal": _heal,
		"dps": dps,
		"hp_min": _hp_min,
		"hp_end": float(snap.hp),
		"by_source": _by_source.duplicate(),
		"boss_wave": Config.is_boss_wave(wave),
		"event": _event,
	}
	_latest = {
		"version": VERSION,
		"updated_at": at,
		"wave": wave,
		"outcome": outcome,
		"run": _run_block(),
		"wave_data": wave_data,
		"player": snap,
	}
	_history.append(_history_entry(wave, outcome, at, wave_data, snap, dps))
	if _history.size() > HISTORY_MAX:
		_history = _history.slice(_history.size() - HISTORY_MAX)
	var ok := _write(at)
	_start = {
		"kills": GameState.kills,
		"materials": GameState.materials,
		"run_time": GameState.run_time,
		"level": GameState.level,
		"xp": GameState.xp,
	}
	_wall_ms = Time.get_ticks_msec()
	return ok

static func _run_block() -> Dictionary:
	var d: Dictionary = Registry.get_difficulty(GameState.difficulty_id)
	var ch: Dictionary = Registry.get_character(GameState.character_id)
	return {
		"difficulty": GameState.difficulty_id,
		"difficulty_name": String(d.get("name", "")),
		"character": GameState.character_id,
		"character_name": String(ch.get("name", "")),
		"endless": GameState.endless,
		"daily": GameState.daily,
		"run_time": GameState.run_time,
		"level": GameState.level,
		"xp": GameState.xp,
		"materials": GameState.materials,
		"kills": GameState.kills,
		"score": GameState.score,
		"map_theme": GameState.map_theme,
		"area_element": GameState.area_element,
		# 自定义开局规则一起存：否则「这局为什么这么肉 / 这么脆」在日志里查不到原因
		"run_rules": RunRules.to_save(),
	}

## 逐波紧凑条目：够画曲线（等级 / 血量 / 输出 / 材料 / 构筑），不存全量属性
static func _history_entry(wave: int, outcome: String, at: String,
		wave_data: Dictionary, snap: Dictionary, dps: float) -> Dictionary:
	var st: Dictionary = snap.get("stats", {})
	var curve := {}
	for k in CURVE_STATS:
		curve[k] = float(st.get(k, 0.0))
	# 同化度是五行体系的主轴，必须逐波可见（全量 stats 只在 latest 里）
	for eid in Config.ELEMENTS:
		var ak := "assim_" + String(eid)
		curve[ak] = float(st.get(ak, 0.0))
	var wl: Array = []
	for w in snap.get("weapons", []):
		wl.append(String((w as Dictionary).get("id", "")))
	var il: Array = []
	for it in snap.get("items", []):
		il.append(String((it as Dictionary).get("id", "")))
	var al: Array = []
	for a in snap.get("artifacts", []):
		al.append(String((a as Dictionary).get("id", "")))
	return {
		"wave": wave,
		"outcome": outcome,
		"at": at,
		"duration": float(wave_data.duration),
		"run_time": GameState.run_time,
		"level": GameState.level,
		"xp": GameState.xp,
		"kills": int(wave_data.kills),
		"spawned": int(wave_data.spawned),
		"materials": GameState.materials,
		"materials_gained": int(wave_data.materials_gained),
		"hp": float(snap.get("hp", 0.0)),
		"hp_min": float(wave_data.hp_min),
		"hp_max": float(st.get("max_hp", 0.0)),
		"damage_dealt": float(wave_data.damage_dealt),
		"damage_taken": float(wave_data.damage_taken),
		"heal": float(wave_data.heal),
		"dps": dps,
		"by_source": (wave_data.by_source as Dictionary).duplicate(),
		"weapons": wl,
		"items": il,
		"artifacts": al,
		"stats": curve,
	}

## 写盘：先写 `.tmp` 再替换正式文件 —— 中途崩了不会留下半截 JSON。
## 与 `SaveRun._write_json_atomic` 相比刻意少了 `.bak` 轮转：日志不需要备份，
## 保留上一版只会让目录里多一份同样会过期的文件。
static func _write(at: String) -> bool:
	var dir_err := DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(_root.trim_suffix("/")))
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		push_warning("BalanceLog: 无法创建目录 " + _root)
		return false
	var target := path()
	var tmp := target + ".tmp"
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("BalanceLog: 无法写入 " + tmp)
		return false
	f.store_string(JSON.stringify({
		"version": VERSION,
		"updated_at": at,
		"latest": _latest,
		"waves": _history,
	}, "\t"))
	f.flush()
	var werr := f.get_error()
	f.close()
	if werr != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
		push_warning("BalanceLog: 写入失败 " + tmp)
		return false
	var target_abs := ProjectSettings.globalize_path(target)
	var tmp_abs := ProjectSettings.globalize_path(tmp)
	if FileAccess.file_exists(target) and DirAccess.remove_absolute(target_abs) != OK:
		push_warning("BalanceLog: 无法替换旧日志 " + target)
		return false
	if DirAccess.rename_absolute(tmp_abs, target_abs) != OK:
		push_warning("BalanceLog: 无法落盘 " + target)
		return false
	return true

## 续档：把盘上已有的逐波历史读回来（解析失败就当没有 —— 日志坏了不该拦住游戏）
static func _adopt_existing() -> void:
	var p := path()
	if not FileAccess.file_exists(p):
		return
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var d: Dictionary = parsed
	if int(d.get("version", 0)) != VERSION:
		return
	if typeof(d.get("waves")) == TYPE_ARRAY:
		_history = (d.waves as Array).duplicate()
	if typeof(d.get("latest")) == TYPE_DICTIONARY:
		_latest = (d.latest as Dictionary).duplicate()
