extends Node
## 平台成就桥：把 EventBus.achievement_unlocked 转发给 Steam（或未来的其他平台）
## - 未安装平台 SDK 时静默降级：成就判定与精华奖励仍由 CodexData 本地生效
## - 接入 GodotSteam（GDExtension / 模块版）后自动识别名为 Steam 的单例，无需改业务代码
## - 平台不可用时把成就 id 落盘排队，下次启动检测到平台后自动补发

const SAVE_PATH := "user://steam_pending.json"

## 成就 id -> Steamworks 后台的 API Name（按需改名即可）
const STEAM_IDS := {
	"first_blood": "ACH_FIRST_BLOOD",
	"slayer_100": "ACH_SLAYER_100",
	"slayer_1000": "ACH_SLAYER_1000",
	"survivor_5": "ACH_SURVIVOR_5",
	"clear_10": "ACH_CLEAR_10",
	"boss_hunter": "ACH_BOSS_HUNTER",
	"boss_10": "ACH_BOSS_10",
	"evolver": "ACH_EVOLVER",
	"status_master": "ACH_STATUS_MASTER",
	"shopper": "ACH_SHOPPER",
	"veteran": "ACH_VETERAN",
	"endless_20": "ACH_ENDLESS_20",
}

var _backend := ""          # ""（未接入）/ "steam"
var _forwarded: Array = []  # 测试观测：已收到的成就 id
var _pending: Array = []    # 待上报队列（落盘，跨启动保留）
var _test_calls: Array = [] # 测试观测：无 SDK 时记录的转发调用
var _path := SAVE_PATH

func _ready() -> void:
	EventBus.achievement_unlocked.connect(_on_achievement_unlocked)
	_load_pending()
	_backend = _detect_backend()
	if is_available() and not _pending.is_empty():
		_flush_pending()

# ---------------- 查询 ----------------

## 当前平台后端：""（未接入）/ "steam"
func backend_name() -> String:
	return _backend

func is_available() -> bool:
	return _backend != ""

func forwarded_count() -> int:
	return _forwarded.size()

func pending_count() -> int:
	return _pending.size()

## 测试观测：转发到平台的实际调用（[方法, 参数]）
func test_calls() -> Array:
	return _test_calls.duplicate()

# ---------------- 转发 ----------------

func _detect_backend() -> String:
	# GodotSteam（GDExtension / 模块版）都会注册名为 Steam 的单例
	if Engine.has_singleton("Steam"):
		return "steam"
	return ""

func _on_achievement_unlocked(id: String) -> void:
	if not _forwarded.has(id):
		_forwarded.append(id)
	if not is_available():
		if not _pending.has(id):
			_pending.append(id)
			_save_pending()
		return
	_push_achievement(id)

func _flush_pending() -> void:
	if not is_available():
		return   # 后端仍不可用：保留队列，等下次检测到 SDK 再补发
	var queue := _pending.duplicate()
	_pending.clear()
	_save_pending()
	for id in queue:
		_push_achievement(String(id))

func _push_achievement(id: String) -> void:
	if _backend != "steam":
		return
	var api_name := String(STEAM_IDS.get(id, id.to_upper()))
	var steam = Engine.get_singleton("Steam") if Engine.has_singleton("Steam") else null
	if steam == null:
		# 仅在测试注入后端时走到这里：记录调用意图，便于无 SDK 验证转发链路
		_test_calls.append(["setAchievement", api_name])
		return
	if not steam.has_method("setAchievement"):
		push_warning("PlatformAchievements: Steam 单例缺少 setAchievement，跳过 " + api_name)
		return
	steam.setAchievement(api_name)
	if steam.has_method("storeStats"):
		steam.storeStats()
	_test_calls.append(["setAchievement", api_name])

# ---------------- 持久化 ----------------

## 仅供自动化测试：改用隔离路径并清空内存态
func set_storage_path_for_tests(path: String) -> void:
	_path = path

func reset_storage_path_after_tests() -> void:
	_path = SAVE_PATH

func reset_for_tests() -> void:
	_forwarded = []
	_pending = []
	_test_calls = []

## 仅供自动化测试：注入后端（"" / "steam"），用于验证无 SDK 时的转发链路
func set_backend_for_tests(name: String) -> void:
	_backend = name
	_test_calls = []

func _load_pending() -> void:
	_pending = []
	if not FileAccess.file_exists(_path):
		return
	var f := FileAccess.open(_path, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	var parse_err := json.parse(f.get_as_text())
	f.close()
	if parse_err != OK or typeof(json.data) != TYPE_DICTIONARY:
		return
	var raw: Variant = (json.data as Dictionary).get("pending", [])
	if typeof(raw) != TYPE_ARRAY:
		return
	for id in raw:
		if typeof(id) == TYPE_STRING and not _pending.has(id):
			_pending.append(String(id))

func _save_pending() -> void:
	var dir := _path.get_base_dir()
	var dir_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		return
	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({ "pending": _pending }))
	f.close()
