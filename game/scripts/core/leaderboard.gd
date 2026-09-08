extends Node
## 排行榜（本地持久化 user://leaderboard.json，各榜 Top 10）
## - 无尽榜：跨日期累计的最高分
## - 每日榜：按日期隔离（date_key = "daily:YYYY-MM-DD"），只保留当日
## record() 返回名次（1 起），未进 Top 10 返回 0。

const MAX_ENTRIES := 10
const DEFAULT_PATH := "user://leaderboard.json"

var entries: Array = []   # [{score, wave, char_name, kills, run_time, date, date_key}] 按分数降序
var _path := DEFAULT_PATH
var _boards: Dictionary = {}   # date_key -> entries（惰性加载的全部榜单）

func _ready() -> void:
	_load()

## 仅供自动化测试隔离 user:// 正式排行榜
func set_storage_root_for_tests(root: String) -> void:
	_path = root.trim_suffix("/").path_join("leaderboard.json")
	_boards = {}
	entries = []
	_load()

func reset_storage_root_after_tests() -> void:
	_path = DEFAULT_PATH
	_boards = {}
	entries = []
	_load()

func get_list() -> Array:
	return entries

## 每日榜列表（传入日期 "YYYY-MM-DD"；未玩过返回空）
func get_daily_list(date_str: String) -> Array:
	return _boards.get("daily:" + date_str, [])

func best_score() -> int:
	return int(entries[0].score) if not entries.is_empty() else 0

## 记录一局成绩；date_key = "" 无尽榜 / "daily:YYYY-MM-DD" 每日榜。
## 返回名次（1 起），未进 Top 10 返回 0（分数须 > 0）
func record(score: int, wave: int, char_name: String, kills: int, run_time: float,
		date_key := "") -> int:
	if score <= 0:
		return 0
	var entry := {
		"score": maxi(0, score), "wave": maxi(1, wave), "char_name": char_name.substr(0, 32),
		"kills": maxi(0, kills), "run_time": maxf(0.0, run_time),
		"date": Time.get_date_string_from_system(), "date_key": date_key,
	}
	var board: Array = _boards.get(date_key, []).duplicate()
	board.append(entry)
	board.sort_custom(func(a, b) -> bool: return int(a.score) > int(b.score))
	if board.size() > MAX_ENTRIES:
		board = board.slice(0, MAX_ENTRIES)
	_boards[date_key] = board
	_save()
	var rank := board.find(entry) + 1
	return rank if rank > 0 else 0

# ---------------- 内部 ----------------

func _load() -> void:
	_boards = {}
	entries = []
	if not FileAccess.file_exists(_path):
		return
	var f := FileAccess.open(_path, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	var parse_err := json.parse(f.get_as_text())
	f.close()
	if parse_err != OK or typeof(json.data) != TYPE_DICTIONARY:
		push_warning("Leaderboard: 排行榜文件损坏，已重置")
		return
	var raw: Variant = json.data.get("boards", json.data.get("entries", []))
	if typeof(raw) != TYPE_ARRAY:
		return
	for e in raw:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		if not _int_in(e.get("score"), 0, 2_000_000_000) \
				or not _int_in(e.get("wave"), 1, 99_999) \
				or not _int_in(e.get("kills"), 0, 2_000_000_000):
			continue
		var entry := {
			"score": int(e.score), "wave": int(e.wave),
			"char_name": String(e.get("char_name", "?")).substr(0, 32),
			"kills": int(e.kills),
			"run_time": maxf(0.0, float(e.get("run_time", 0.0))),
			"date": String(e.get("date", "")).substr(0, 19),
			"date_key": String(e.get("date_key", "")),
		}
		var key := String(entry.date_key)
		if not _boards.has(key):
			_boards[key] = []
		_boards[key].append(entry)
	for key in _boards:
		_boards[key].sort_custom(func(a, b) -> bool: return int(a.score) > int(b.score))
	entries = _boards.get("", [])

func _save() -> void:
	var dir_err := DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(_path.get_base_dir()))
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		push_warning("Leaderboard: 无法创建目录 " + _path.get_base_dir())
		return
	var all: Array = []
	for key in _boards:
		all.append_array(_boards[key])
	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f == null:
		push_warning("Leaderboard: 无法写入 " + _path)
		return
	f.store_string(JSON.stringify({ "boards": all }))
	f.close()

func _int_in(value: Variant, minimum: int, maximum: int) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) \
		and is_finite(float(value)) and float(value) == floorf(float(value)) \
		and float(value) >= float(minimum) and float(value) <= float(maximum)
