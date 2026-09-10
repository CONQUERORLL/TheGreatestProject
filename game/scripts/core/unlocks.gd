extends Node
## 解锁系统：角色 / 武器的开局选择门槛。
## 解锁条件由 CodexData 的「累计统计」实时推导（解锁即永久，无需单独持久化解锁态）；
## 本单例只负责：① 查询是否解锁 ② 锁定提示 ③ 「解锁达成」的一次性庆祝（toast）。
## 未列入 Config.CHARACTER_UNLOCKS / WEAPON_UNLOCKS 的内容默认已解锁（含 mod）。

const SAVE_PATH := "user://unlocks.json"

var _celebrated: Dictionary = {}   # "kind:id" -> true（已庆祝，防重复 toast）
var _path := SAVE_PATH

func _ready() -> void:
	_load()
	EventBus.run_ended.connect(_on_run_ended)

# ---------------- 查询 ----------------

## 是否解锁：未列入表 = 默认已解锁；否则比较累计统计与阈值
func is_unlocked(kind: String, id: String) -> bool:
	var e: Dictionary = Config.unlock_entry(kind, id)
	if e.is_empty():
		return true
	return CodexData.stat(String(e.get("stat", ""))) >= int(e.get("target", 1))

## 锁定提示文案（未锁定条目返回空串）
func unlock_hint(kind: String, id: String) -> String:
	return String(Config.unlock_entry(kind, id).get("hint", ""))

# ---------------- 解锁庆祝 ----------------

func _on_run_ended(_victory: bool) -> void:
	# 延后到帧末：确保 CodexData 的同步统计（victories / boss_kills 等）先更新完
	call_deferred("check_new")

## 收集本轮新达成的解锁，广播一次并标记已庆祝；返回本轮新解锁数（测试观测用）
func check_new() -> int:
	var fresh: Array = []
	for id in Config.CHARACTER_UNLOCKS:
		_collect("character", String(id), fresh)
	for id in Config.WEAPON_UNLOCKS:
		_collect("weapon", String(id), fresh)
	if not fresh.is_empty():
		_save()
		EventBus.unlocks_achieved.emit(fresh)
	return fresh.size()

func _collect(kind: String, id: String, fresh: Array) -> void:
	var key := kind + ":" + id
	if _celebrated.has(key):
		return
	if not is_unlocked(kind, id):
		return
	_celebrated[key] = true
	fresh.append({ "kind": kind, "id": id })

# ---------------- 持久化 ----------------

func _load() -> void:
	_celebrated = {}
	if not FileAccess.file_exists(_path):
		return
	var f := FileAccess.open(_path, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	var parse_err := json.parse(f.get_as_text())
	f.close()
	if parse_err != OK or typeof(json.data) != TYPE_DICTIONARY:
		push_warning("Unlocks: 存档损坏，已重置")
		return
	var raw: Variant = json.data.get("celebrated", {})
	if typeof(raw) == TYPE_DICTIONARY:
		for key in raw:
			if bool(raw[key]):
				_celebrated[String(key)] = true

func _save() -> void:
	var dir := _path.get_base_dir()
	var dir_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		push_warning("Unlocks: 无法创建目录 " + dir)
		return
	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f == null:
		push_warning("Unlocks: 无法写入 " + _path)
		return
	f.store_string(JSON.stringify({ "celebrated": _celebrated }))
	f.close()

# ---------------- 测试隔离 ----------------

func set_storage_path_for_tests(path: String) -> void:
	_path = path
	_celebrated = {}

func reset_for_tests() -> void:
	_celebrated = {}
