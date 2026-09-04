extends Node
## 设置 autoload：分辨率 / 窗口模式 / 帧率 / 主音量 / 按键绑定
## 持久化到 user://settings.cfg；启动时自动应用。重绑定即时生效并写入磁盘。

const CFG_PATH := "user://settings.cfg"

const MODE_WINDOWED := 0     # 窗口
const MODE_BORDERLESS := 1   # 无边框窗口
const MODE_FULLSCREEN := 2   # 全屏

const RESOLUTIONS := [
	Vector2i(1280, 720), Vector2i(1600, 900),
	Vector2i(1920, 1080), Vector2i(2560, 1440),
]
const FPS_OPTIONS := [0, 30, 60, 120, 144]   # 0 = 不限

const ACTION_ORDER := ["move_up", "move_down", "move_left", "move_right",
	"ui_accept", "ui_cancel", "pause", "toggle_mute"]
const ACTION_LABELS := {
	"move_up": "向上移动", "move_down": "向下移动",
	"move_left": "向左移动", "move_right": "向右移动",
	"ui_accept": "确认", "ui_cancel": "返回 / 取消",
	"pause": "暂停", "toggle_mute": "静音切换",
}

const JOY_BTN_NAMES := {
	0: "A", 1: "B", 2: "X", 3: "Y", 4: "Back(View)", 5: "Guide(西瓜键)",
	6: "Start(Menu)", 7: "左摇杆按下", 8: "右摇杆按下",
	9: "LB", 10: "RB", 11: "十字键↑", 12: "十字键↓",
	13: "十字键←", 14: "十字键→",
}

## 内置默认绑定描述符（重置时恢复；与 project.godot 一致）
const DEFAULT_BINDS := {
	"move_up": [
		{ "t": "key", "code": 87 }, { "t": "key", "code": 4194320 },
		{ "t": "jmot", "axis": 1, "val": -1.0 }, { "t": "jbtn", "b": 11 }],
	"move_down": [
		{ "t": "key", "code": 83 }, { "t": "key", "code": 4194322 },
		{ "t": "jmot", "axis": 1, "val": 1.0 }, { "t": "jbtn", "b": 12 }],
	"move_left": [
		{ "t": "key", "code": 65 }, { "t": "key", "code": 4194319 },
		{ "t": "jmot", "axis": 0, "val": -1.0 }, { "t": "jbtn", "b": 13 }],
	"move_right": [
		{ "t": "key", "code": 68 }, { "t": "key", "code": 4194321 },
		{ "t": "jmot", "axis": 0, "val": 1.0 }, { "t": "jbtn", "b": 14 }],
	"ui_accept": [
		{ "t": "key", "code": 4194309 }, { "t": "key", "code": 32 },
		{ "t": "jbtn", "b": 0 }],
	"ui_cancel": [
		{ "t": "key", "code": 4194305 }, { "t": "jbtn", "b": 1 }],
	"pause": [
		{ "t": "key", "code": 4194305 }, { "t": "key", "code": 80 },
		{ "t": "jbtn", "b": 6 }],
	"toggle_mute": [
		{ "t": "key", "code": 77 }, { "t": "jbtn", "b": 4 }],
}

var res_w := 1280
var res_h := 720
var mode := MODE_WINDOWED
var fps := 60
var master_vol := 1.0
var _binds := {}   # action -> Array[描述符 Dictionary]

func _ready() -> void:
	load_config()
	apply_all()

# ---------------- 持久化 ----------------

func load_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) != OK:
		return
	res_w = int(cfg.get_value("display", "res_w", 1280))
	res_h = int(cfg.get_value("display", "res_h", 720))
	mode = int(cfg.get_value("display", "mode", MODE_WINDOWED))
	fps = int(cfg.get_value("game", "fps", 60))
	master_vol = clampf(float(cfg.get_value("audio", "master", 1.0)), 0.0, 1.0)
	_binds.clear()
	if cfg.has_section("input"):
		for action in ACTION_ORDER:
			var raw: String = cfg.get_value("input", action, "")
			if raw == "":
				continue
			var parsed: Variant = JSON.parse_string(raw)
			if typeof(parsed) == TYPE_ARRAY:
				_binds[action] = parsed

func save_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("display", "res_w", res_w)
	cfg.set_value("display", "res_h", res_h)
	cfg.set_value("display", "mode", mode)
	cfg.set_value("game", "fps", fps)
	cfg.set_value("audio", "master", master_vol)
	for action in _binds:
		cfg.set_value("input", action, JSON.stringify(_binds[action]))
	cfg.save(CFG_PATH)

# ---------------- 应用 ----------------

func apply_all() -> void:
	apply_display()
	apply_fps()
	apply_audio()
	apply_input()

func apply_display() -> void:
	if DisplayServer.get_name() == "headless":
		return
	match mode:
		MODE_FULLSCREEN:
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		MODE_BORDERLESS:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
			DisplayServer.window_set_size(Vector2i(res_w, res_h))
		_:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			DisplayServer.window_set_size(Vector2i(res_w, res_h))

func apply_fps() -> void:
	Engine.max_fps = fps

func apply_audio() -> void:
	if AudioServer.get_bus_count() <= 0:
		return
	AudioServer.set_bus_mute(0, master_vol <= 0.0001)
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(master_vol, 0.0001)))

func apply_input() -> void:
	for action in _binds:
		if not InputMap.has_action(action):
			continue
		InputMap.action_erase_events(action)
		for d in _binds[action]:
			var ev: InputEvent = dict_to_event(d)
			if ev != null:
				InputMap.action_add_event(action, ev)

# ---------------- 设置项变更（UI 调用，即时应用 + 存盘） ----------------

func set_resolution(idx: int) -> void:
	var r: Vector2i = RESOLUTIONS[clampi(idx, 0, RESOLUTIONS.size() - 1)]
	res_w = r.x
	res_h = r.y
	save_config()
	apply_display()

func set_mode(m: int) -> void:
	mode = m
	save_config()
	apply_display()

func set_fps(value: int) -> void:
	fps = value
	save_config()
	apply_fps()

func set_master(v: float) -> void:
	master_vol = clampf(v, 0.0, 1.0)
	save_config()
	apply_audio()

# ---------------- 按键重绑定 ----------------

## 捕获到输入事件后绑定到 action；同类设备事件替换（键盘替换键盘，手柄保留）
func bind_action(action: String, ev: InputEvent) -> void:
	var d := event_to_dict(ev)
	if d.is_empty():
		return
	if not _binds.has(action):
		# 首次绑定：快照当前 InputMap 事件（保证未改的设备绑定不丢）
		_binds[action] = []
		for e in InputMap.action_get_events(action):
			var ed := event_to_dict(e)
			if not ed.is_empty():
				_binds[action].append(ed)
	var arr: Array = _binds[action]
	for i in range(arr.size() - 1, -1, -1):
		if _same_class(arr[i], d):
			arr.remove_at(i)
	arr.append(d)
	_binds[action] = arr
	_apply_action_events(action, arr)
	save_config()

## 恢复默认绑定
func reset_action(action: String) -> void:
	_binds.erase(action)
	var defs: Array = DEFAULT_BINDS.get(action, [])
	_apply_action_events(action, defs)
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) == OK:
		cfg.erase_section_key("input", action)
		cfg.save(CFG_PATH)

func _apply_action_events(action: String, descriptors: Array) -> void:
	if not InputMap.has_action(action):
		return
	InputMap.action_erase_events(action)
	for d in descriptors:
		var ev: InputEvent = dict_to_event(d)
		if ev != null:
			InputMap.action_add_event(action, ev)

## 当前绑定的人类可读文本（读实时 InputMap）
func binding_text(action: String) -> String:
	var parts: Array = []
	for ev in InputMap.action_get_events(action):
		var t := event_text(ev)
		if t != "":
			parts.append(t)
	return " / ".join(parts) if not parts.is_empty() else "（未绑定）"

# ---------------- 事件序列化 / 文本 ----------------

func event_to_dict(ev: InputEvent) -> Dictionary:
	if ev is InputEventKey:
		var code: int = ev.physical_keycode if ev.physical_keycode != 0 else ev.keycode
		if code == 0:
			return {}
		return { "t": "key", "code": code }
	if ev is InputEventJoypadButton:
		return { "t": "jbtn", "b": ev.button_index }
	if ev is InputEventJoypadMotion:
		return { "t": "jmot", "axis": ev.axis, "val": ev.axis_value }
	return {}

func dict_to_event(d: Dictionary) -> InputEvent:
	match String(d.get("t", "")):
		"key":
			var e := InputEventKey.new()
			e.physical_keycode = int(d.code)
			return e
		"jbtn":
			var b := InputEventJoypadButton.new()
			b.button_index = int(d.b)
			return b
		"jmot":
			var m := InputEventJoypadMotion.new()
			m.axis = int(d.axis)
			m.axis_value = float(d.val)
			return m
	return null

## 同类判定：键盘一组；手柄按钮一组；摇杆按轴分组
func _same_class(a: Dictionary, b: Dictionary) -> bool:
	if a.get("t", "") != b.get("t", ""):
		return false
	if a.t == "jmot":
		return int(a.axis) == int(b.axis)
	return true

func event_text(ev: InputEvent) -> String:
	if ev is InputEventKey:
		var code: int = ev.physical_keycode if ev.physical_keycode != 0 else ev.keycode
		return OS.get_keycode_string(code) if code != 0 else "?"
	if ev is InputEventJoypadButton:
		return "手柄 " + String(JOY_BTN_NAMES.get(ev.button_index, "按键%d" % ev.button_index))
	if ev is InputEventJoypadMotion:
		var axis_name := "左摇杆" if ev.axis < 2 else "右摇杆"
		var dir := ""
		match ev.axis:
			0: dir = "→" if ev.axis_value > 0.0 else "←"
			1: dir = "↓" if ev.axis_value > 0.0 else "↑"
			2: dir = "→" if ev.axis_value > 0.0 else "←"
			3: dir = "↓" if ev.axis_value > 0.0 else "↑"
		return "手柄 %s%s" % [axis_name, dir]
	return ""
