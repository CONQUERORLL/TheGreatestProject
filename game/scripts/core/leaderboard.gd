extends Node
## 无尽炼狱排行榜（本地持久化 user://leaderboard.json，Top 10）
## 记录无尽模式的最高积分挑战成绩；标准模式不计入。
## record() 返回名次（1 起），未进 Top 10 返回 0。

const MAX_ENTRIES := 10
const DEFAULT_PATH := "user://leaderboard.json"

var entries: Array = []   # [{score, wave, char_name, kills, run_time, date}] 按分数降序
var _path := DEFAULT_PATH

func _ready() -> void:
	_load()

## 仅供自动化测试隔离 user:// 正式排行榜
func set_storage_root_for_tests(root: String) -> void:
	_path = root.trim_suffix("/").path_join("leaderboard.json")
	entries = []
	_load()

func reset_storage_root_after_tests() -> void:
	_path = DEFAULT_PATH
	entries = []
	_load()

func get_list() -> Array:
	return entries

func best_score() -> int:
	return int(entries[0].score) if not entries.is_empty() else 0

## 记录一局成绩；返回名次（1 起），未进 Top 10 返回 0（分数须 > 0）
func record(score: int, wave: int, char_name: String, kills: int, run_time: float) -> int:
	if score <= 0:
		return 0
	var entry := {
		"score": maxi(0, score), "wave": maxi(1, wave), "char_name": char_name.substr(0, 32),
		"kills": maxi(0, kills), "run_time": maxf(0.0, run_time),
		"date": Time.get_date_string_from_system(),
	}
	entries.append(entry)
	entries.sort_custom(func(a, b) -> bool: return int(a.score) > int(b.score))
	if entries.size() > MAX_ENTRIES:
		entries = entries.slice(0, MAX_ENTRIES)
	_save()
	var rank := entries.find(entry) + 1
	return rank if rank > 0 else 0

# ---------------- 内部 ----------------

func _load() -> void:
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
	var raw: Variant = json.data.get("entries", [])
	if typeof(raw) != TYPE_ARRAY:
		return
	for e in raw:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		if not _int_in(e.get("score"), 0, 2_000_000_000) \
				or not _int_in(e.get("wave"), 1, 99_999) \
				or not _int_in(e.get("kills"), 0, 2_000_000_000):
			continue
		entries.append({
			"score": int(e.score), "wave": int(e.wave),
			"char_name": String(e.get("char_name", "?")).substr(0, 32),
			"kills": int(e.kills),
			"run_time": maxf(0.0, float(e.get("run_time", 0.0))),
			"date": String(e.get("date", "")).substr(0, 19),
		})
	entries.sort_custom(func(a, b) -> bool: return int(a.score) > int(b.score))

func _save() -> void:
	var dir_err := DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(_path.get_base_dir()))
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		push_warning("Leaderboard: 无法创建目录 " + _path.get_base_dir())
		return
	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f == null:
		push_warning("Leaderboard: 无法写入 " + _path)
		return
	f.store_string(JSON.stringify({ "entries": entries }))
	f.close()

func _int_in(value: Variant, minimum: int, maximum: int) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) \
		and is_finite(float(value)) and float(value) == floorf(float(value)) \
		and float(value) >= float(minimum) and float(value) <= float(maximum)
