extends Node
## 平台成就桥：把 EventBus.achievement_unlocked 转发给 Steam（或未来的其他平台）
## - 未安装平台 SDK 时静默降级：成就判定与精华奖励仍由 CodexData 本地生效
## - 接入 GodotSteam（GDExtension / 模块版）后自动识别名为 Steam 的单例，无需改业务代码
## - 平台不可用时把成就 id 落盘排队，下次启动检测到平台后自动补发

const SAVE_PATH := "user://steam_pending.json"
const CONFIG_PATH := "res://config/steam_achievements.json"

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
var _steam_defs: Dictionary = {}
var _config_valid := false
var _steam_app_id := 0
var _steam_initialized := false
var _steam_stats_ready := false
var _steam_init_attempted := false
var _steam_next_init_ms := 0
var _steam_init_error := ""
var _steam_signal_connected := false
var _test_backend := false
var _stats_request_pending := false
var _steam_next_stats_ms := 0
var _steam_next_flush_ms := 0

const STEAM_INIT_RETRY_MS := 5000
const STEAM_FLUSH_RETRY_MS := 5000

func _ready() -> void:
	EventBus.achievement_unlocked.connect(_on_achievement_unlocked)
	_load_steam_config()
	_load_pending()
	_backend = _detect_backend()
	if is_available():
		_initialize_steam()

func _process(_delta: float) -> void:
	if not _test_backend and _backend == "":
		var detected := _detect_backend()
		if detected != "":
			_backend = detected
			_initialize_steam()
	if _test_backend or _backend != "steam":
		return
	var steam = _steam_instance()
	if steam == null:
		return
	if _steam_initialized and steam.has_method("run_callbacks"):
		steam.run_callbacks()
	var now := Time.get_ticks_msec()
	if _steam_stats_ready and not _pending.is_empty() and now >= _steam_next_flush_ms:
		_flush_pending()
	elif _steam_initialized and not _steam_stats_ready \
			and now >= _steam_next_stats_ms:
		_stats_request_pending = false
		_request_current_stats(steam)
	if not _steam_initialized and not _steam_init_attempted \
			and now >= _steam_next_init_ms:
		_initialize_steam()

# ---------------- 查询 ----------------

## 当前平台后端：""（未接入）/ "steam"
func backend_name() -> String:
	return _backend

func is_available() -> bool:
	return _backend != ""

## Steam SDK 已初始化且当前用户统计已返回，可安全调用成就接口
func steam_stats_ready() -> bool:
	return _steam_stats_ready

## 当前 Steam 桥状态，供开发者面板和实机排查使用
func steam_status() -> String:
	if _backend != "steam":
		return "未接入"
	if _test_backend:
		return "测试就绪"
	if _steam_init_error != "":
		return _steam_init_error
	if not _steam_initialized:
		return "待初始化"
	if not _steam_stats_ready:
		return "等待统计"
	return "已就绪"

func forwarded_count() -> int:
	return _forwarded.size()

func pending_count() -> int:
	return _pending.size()

## 测试观测：转发到平台的实际调用（[方法, 参数]）
func test_calls() -> Array:
	return _test_calls.duplicate()

## Steamworks 配置是否与 CodexData / STEAM_IDS 完整对齐
func steam_config_valid() -> bool:
	return _config_valid

## 运行时读取的 Steamworks 成就定义（供 Dev Panel / 自动化测试使用）
func steam_definitions() -> Dictionary:
	return _steam_defs.duplicate(true)

# ---------------- 转发 ----------------

func _detect_backend() -> String:
	# GodotSteam（GDExtension / 模块版）都会注册名为 Steam 的单例
	if not Engine.has_singleton("Steam"):
		return ""
	var steam = Engine.get_singleton("Steam")
	if steam != null and steam.has_method("isSteamRunning") \
			and not bool(steam.isSteamRunning()):
		return ""
	return "steam"

func _steam_instance():
	if not Engine.has_singleton("Steam"):
		return null
	return Engine.get_singleton("Steam")

func _initialize_steam() -> void:
	if _backend != "steam" or _test_backend or _steam_initialized \
			or _steam_init_attempted:
		return
	var steam = _steam_instance()
	if steam == null:
		return
	if _steam_app_id <= 0:
		_steam_init_error = "缺少 App ID"
		_steam_next_init_ms = Time.get_ticks_msec() + STEAM_INIT_RETRY_MS
		return
	_steam_init_attempted = true
	_steam_init_error = ""
	_connect_steam_signals(steam)
	var init_response: Variant
	if steam.has_method("steamInitEx"):
		init_response = steam.call("steamInitEx", _steam_app_id)
	elif steam.has_method("steamInit"):
		# 兼容旧模块版：App ID 由 steam_appid.txt / 启动环境提供。
		init_response = steam.call("steamInit")
	else:
		_steam_init_failed("缺少 steamInitEx")
		return
	if not _steam_init_succeeded(init_response):
		_steam_init_failed("Steam 初始化失败")
		return
	_steam_initialized = true
	_request_current_stats(steam)

func _request_current_stats(steam) -> void:
	if not steam.has_method("requestCurrentStats"):
		_steam_init_failed("缺少 requestCurrentStats")
		return
	var stats_response: Variant = steam.call("requestCurrentStats")
	if not _steam_call_succeeded(stats_response):
		_stats_request_pending = false
		_steam_stats_ready = false
		_steam_init_error = "请求 Steam 统计失败"
		_steam_next_stats_ms = Time.get_ticks_msec() + STEAM_INIT_RETRY_MS
		return
	_stats_request_pending = true
	_steam_init_error = ""
	_steam_next_stats_ms = Time.get_ticks_msec() + STEAM_INIT_RETRY_MS
	if not _has_stats_signal(steam):
		_steam_init_failed("缺少 Steam 统计回调")

func _has_stats_signal(steam) -> bool:
	return steam.has_signal("current_stats_received") \
			or steam.has_signal("user_stats_received")

func _connect_steam_signals(steam) -> void:
	if _steam_signal_connected:
		return
	var callback := Callable(self, "_on_current_stats_received")
	if steam.has_signal("current_stats_received"):
		if not steam.is_connected("current_stats_received", callback):
			steam.connect("current_stats_received", callback)
		_steam_signal_connected = true
	elif steam.has_signal("user_stats_received"):
		# 兼容较早 GodotSteam 版本的同义回调。
		if not steam.is_connected("user_stats_received", callback):
			steam.connect("user_stats_received", callback)
		_steam_signal_connected = true

func _on_current_stats_received(game_id: int, result: int, _user_id: int) -> void:
	if _steam_app_id > 0 and game_id > 0 and game_id != _steam_app_id:
		return
	if not _steam_result_ok(result):
		_steam_stats_ready = false
		_stats_request_pending = false
		_steam_init_error = "Steam 统计回调失败（%d）" % result
		_steam_next_stats_ms = Time.get_ticks_msec() + STEAM_INIT_RETRY_MS
		return
	_stats_request_pending = false
	_steam_stats_ready = true
	_steam_init_error = ""
	_flush_pending()

func _steam_init_failed(reason: String) -> void:
	_steam_initialized = false
	_steam_stats_ready = false
	_steam_init_error = reason
	_steam_init_attempted = false
	_stats_request_pending = false
	_steam_next_init_ms = Time.get_ticks_msec() + STEAM_INIT_RETRY_MS

func _steam_init_succeeded(response: Variant) -> bool:
	if response == null:
		return true
	if typeof(response) == TYPE_DICTIONARY:
		var status := int((response as Dictionary).get("status", -1))
		return status == 0
	if typeof(response) == TYPE_BOOL:
		return bool(response)
	if typeof(response) == TYPE_INT or typeof(response) == TYPE_FLOAT:
		# 旧版 steamInit() 返回 0 表示成功。
		return int(response) == 0
	return true

func _steam_call_succeeded(response: Variant) -> bool:
	if response == null:
		return true
	if typeof(response) == TYPE_BOOL:
		return bool(response)
	if typeof(response) == TYPE_INT or typeof(response) == TYPE_FLOAT:
		return int(response) != 0
	return true

func _steam_result_ok(result: int) -> bool:
	# Steam EResult 的 k_EResultOK 为 1；GodotSteam 未暴露常量时仍可判断。
	return result == 1

func _on_achievement_unlocked(id: String) -> void:
	if not _forwarded.has(id):
		_forwarded.append(id)
	if not is_available() or not _config_valid:
		if not _pending.has(id):
			_pending.append(id)
			_save_pending()
		return
	if not _steam_stats_ready:
		if not _pending.has(id):
			_pending.append(id)
			_save_pending()
		return
	if not _push_achievement(id) and not _pending.has(id):
		_pending.append(id)
		_save_pending()
		_steam_next_flush_ms = Time.get_ticks_msec() + STEAM_FLUSH_RETRY_MS

func _flush_pending() -> void:
	if not is_available() or not _config_valid \
			or (not _test_backend and not _steam_stats_ready):
		return   # 后端仍不可用：保留队列，等下次检测到 SDK 再补发
	var queue := _pending.duplicate()
	var remaining: Array = []
	for id in queue:
		var achievement_id := String(id)
		if not STEAM_IDS.has(achievement_id) or not _steam_defs.has(achievement_id):
			continue
		if not _push_achievement(achievement_id):
			remaining.append(achievement_id)
	_pending = remaining
	_save_pending()
	_steam_next_flush_ms = Time.get_ticks_msec() \
			+ (STEAM_FLUSH_RETRY_MS if not remaining.is_empty() else 0)

func _push_achievement(id: String) -> bool:
	if _backend != "steam":
		return false
	var api_name := String(STEAM_IDS.get(id, ""))
	if api_name == "" or not _steam_defs.has(id):
		push_warning("PlatformAchievements: 未配置 Steam 成就 " + id)
		return true
	if _test_backend:
		_test_calls.append(["setAchievement", api_name])
		_test_calls.append(["storeStats"])
		return true
	var steam = _steam_instance()
	if steam == null:
		# 仅在测试注入后端时走到这里：记录调用意图，便于无 SDK 验证转发链路
		_test_calls.append(["setAchievement", api_name])
		_test_calls.append(["storeStats"])
		return true
	if not steam.has_method("setAchievement"):
		push_warning("PlatformAchievements: Steam 单例缺少 setAchievement，跳过 " + api_name)
		return false
	var set_response: Variant = steam.call("setAchievement", api_name)
	if not _steam_call_succeeded(set_response):
		push_warning("PlatformAchievements: setAchievement 失败 " + api_name)
		return false
	if not steam.has_method("storeStats"):
		push_warning("PlatformAchievements: Steam 单例缺少 storeStats，跳过 " + api_name)
		return false
	var store_response: Variant = steam.call("storeStats")
	if not _steam_call_succeeded(store_response):
		push_warning("PlatformAchievements: storeStats 失败 " + api_name)
		return false
	_test_calls.append(["setAchievement", api_name])
	_test_calls.append(["storeStats"])
	return true

func _load_steam_config() -> void:
	_steam_defs = {}
	_config_valid = false
	_steam_app_id = 0
	if not FileAccess.file_exists(CONFIG_PATH):
		push_warning("PlatformAchievements: 缺少 " + CONFIG_PATH)
		return
	var file := FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if file == null:
		return
	var json := JSON.new()
	var parse_err := json.parse(file.get_as_text())
	file.close()
	if parse_err != OK or typeof(json.data) != TYPE_DICTIONARY:
		push_warning("PlatformAchievements: Steam 成就配置 JSON 无法解析")
		return
	var config: Dictionary = json.data
	_steam_app_id = int(config.get("app_id", 0))
	var env_app_id := int(OS.get_environment("STEAM_APP_ID"))
	if _steam_app_id <= 0 and env_app_id > 0:
		_steam_app_id = env_app_id
	var raw: Variant = config.get("achievements", [])
	if typeof(raw) != TYPE_ARRAY:
		return
	var seen: Dictionary = {}
	for item in raw:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = item
		var id := String(entry.get("id", ""))
		var api_name := String(entry.get("api_name", ""))
		if id == "" or seen.has(id) or not STEAM_IDS.has(id) \
				or String(STEAM_IDS[id]) != api_name:
			continue
		var local: Dictionary = CodexData.ACHIEVEMENTS.get(id, {})
		if local.is_empty() or String(entry.get("name", "")) != String(local.get("name", "")) \
				or String(entry.get("description", "")) != String(local.get("desc", "")) \
				or String(entry.get("stat", "")) != String(local.get("stat", "")) \
				or int(entry.get("target", 0)) != int(local.get("target", 0)):
			continue
		seen[id] = true
		_steam_defs[id] = entry.duplicate(true)
	_config_valid = _steam_defs.size() == STEAM_IDS.size() \
			and _steam_defs.size() == CodexData.ACHIEVEMENTS.size()

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
	_steam_initialized = false
	_steam_stats_ready = false
	_steam_init_attempted = false
	_steam_init_error = ""
	_steam_signal_connected = false
	_test_backend = false
	_stats_request_pending = false
	_steam_next_stats_ms = 0
	_steam_next_flush_ms = 0

## 仅供自动化测试：注入后端（"" / "steam"），用于验证无 SDK 时的转发链路
func set_backend_for_tests(name: String) -> void:
	_backend = name
	_test_backend = name != ""
	_steam_initialized = name == "steam"
	_steam_stats_ready = name == "steam"
	_steam_init_attempted = name == "steam"
	_steam_init_error = ""
	_stats_request_pending = false
	_steam_next_flush_ms = 0
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
