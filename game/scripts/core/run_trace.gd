extends Node
## 整局运行轨迹日志（2026-09-18 · 第 13 轮 · 排障用）
##
## 目的：把「一整局发生了什么 + 机器状态怎么变的」落成**纯文本时间线**，
## 让「玩着玩着突然卡死」这类问题**事后可读**。为什么 `balance_log.json` 不够用：
## 它只在**每波结束**落一次快照，粒度是「波」；而变卡是**秒级**发生的，
## 波级快照既看不到过程，也定位不到卡死瞬间。
##
## ---- 三条设计口径（改代码前先读）----
## 1. **必须增量落盘**：卡死时**日志的最后一行就是现场**。
##    所以缓冲最多攒 1 秒（FLUSH_SEC）就写一次，绝不只在局末一次性 dump。
## 2. 时间轴用**真实时间**（Time.get_ticks_msec 差值），不受 `Engine.time_scale`
##    影响 —— 顿帧 / 慢动作不会把时间轴压扁，卡死前的采样间隔仍然可信。
## 3. **高频信号只累数不逐条**：受伤 / 元素反应 / 状态触发 在真机上每秒可达几十次，
##    逐条记会既撑爆文件又反过来拖慢游戏。它们按采样窗口聚合成 `+hit/+dmg/+react/+sts`。
##    离散事件（波次 / 升级 / 购买 / BOSS / 死亡 …）才逐条记 `E` 行。
##
## ---- 存储量（实测口径，别拍脑袋调参）----
## 采样 2.0s 一行 ≈ 110 B：15 分钟一局 ≈ 450 行 ≈ 50 KB
## 离散事件一局数百~数千条 ≈ 70 B/条 ≈ 数十~两百 KB
## 合计约 **0.1~0.3 MB/局**，只保留最近 KEEP_FILES(5) 局 → 目录上限约 1.5 MB。
## ⚠️ 若把 SAMPLE_SEC 改成每帧（≈0.016），一局会到 5 万行 ≈ 6 MB，
##    且采样本身（get_nodes_in_group 逐个分配数组）会成为新的性能瓶颈。
##
## ---- 行格式 ----
##   `#` 表头/注释    `S` 周期采样    `E` 离散事件
## ⚠️ 本项目**零侵入**：全部由 EventBus / GameState 信号驱动，main.gd 不用改一行。
## ⚠️ 纯读不写：只读运行时真值，写盘失败只 push_warning，绝不阻断玩法。

const SAMPLE_SEC := 2.0    # 采样周期（真实时间秒）
const FLUSH_SEC := 1.0     # 缓冲落盘周期：卡死时最多丢 1 秒
const KEEP_FILES := 5      # 目录里只保留最近几局
const MAX_BUF := 64        # 缓冲行数上限，到量立即落盘
const DEFAULT_DIR := "user://run_trace/"

var enabled := true
var _dir := DEFAULT_DIR
var _path := ""
var _buf: Array[String] = []
var _t0 := 0
var _next_sample := 0.0
var _next_flush := 0.0
var _player_ref: Node = null
var _wm_ref: Node = null
var _header_done := false

## 高频信号的窗口聚合计数（每个采样周期清零）
var _n_hit := 0
var _sum_dmg := 0.0
var _n_kill := 0
var _n_react := 0
var _n_sts := 0

## ---------------------------------------------------------------- 生命周期

func _ready() -> void:
	_t0 = Time.get_ticks_msec()
	DirAccess.make_dir_recursive_absolute(_dir)
	_connect()
	# ⚠️ 刻意**不在 _ready 里建文件**：autoload 的 _ready 早于冒烟的
	# set_dir_for_tests()，立刻 _ensure_file() 会把表头写进正式 user://run_trace/
	# （实测残留 3 个只有表头的空文件）。改为惰性：真正有内容要写时才建文件。

func _connect() -> void:
	EventBus.run_started.connect(_on_run_started)
	EventBus.run_ended.connect(_on_run_ended)
	EventBus.wave_started.connect(_on_wave_started)
	EventBus.wave_ended.connect(_on_wave_ended)
	EventBus.boss_killed.connect(_on_boss_killed)
	EventBus.leveled_up.connect(_on_leveled_up)
	EventBus.item_purchased.connect(_on_item_purchased)
	EventBus.artifact_acquired.connect(_on_artifact_acquired)
	EventBus.event_card_triggered.connect(_on_event_card)
	EventBus.achievement_unlocked.connect(_on_achievement)
	EventBus.player_died.connect(_on_player_died)
	EventBus.player_damaged.connect(_on_player_damaged)
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.element_reaction.connect(_on_element_reaction)
	EventBus.status_applied.connect(_on_status_applied)
	GameState.phase_changed.connect(_on_phase_changed)

func _process(_delta: float) -> void:
	if not enabled:
		return
	var now := _now()
	if _next_sample == 0.0:
		_next_sample = now + SAMPLE_SEC
		_next_flush = now + FLUSH_SEC
		return
	if now >= _next_sample:
		_next_sample = now + SAMPLE_SEC
		_sample(now)
	if now >= _next_flush or _buf.size() >= MAX_BUF:
		_next_flush = now + FLUSH_SEC
		_flush()

func _notification(what: int) -> void:
	# 进程退出（含被强杀前的正常退出路径）也要把缓冲写完：
	# 卡死场景里这最后一段往往就是最接近现场的数据
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_flush()

## ---------------------------------------------------------------- 对外接口

## 测试隔离：冒烟里切到 `user://tests/run_trace/`，避免污染正式日志目录
func set_dir_for_tests(p: String) -> void:
	_flush()
	# ⚠️ 恒以 "/" 结尾（与 BalanceLog._root 同款硬约束）：调用方传的
	# TEST_SAVE_ROOT 不带斜杠，直接拼接会变成 "...smoke_runrun_trace/"
	_dir = p if p.ends_with("/") else p + "/"
	_path = ""
	_header_done = false   # 换了目录，表头要重新写
	DirAccess.make_dir_recursive_absolute(_dir)

func path() -> String:
	return _path

## 新开一局：换文件 + 轮转。由 EventBus.run_started 驱动，外部无需调用
func begin_run() -> void:
	_flush()
	_rotate()
	_path = ""
	_ensure_file()
	_reset_counters()
	_push("# ---- 新局 %s ----" % Time.get_datetime_string_from_system())

## ---------------------------------------------------------------- 采样

func _sample(now: float) -> void:
	var tr := get_tree()
	var p := _player()
	_push("S t=%.1f fps=%d obj=%d node=%d mem=%.1f phase=%d lv=%d xp=%d mat=%d kills=%d w=%d enemy=%d loot=%d fx=%d amb=%d pb=%d eb=%d pool=%d ts=%.2f hp=%.0f +hit=%d +dmg=%.0f +kill=%d +react=%d +sts=%d" % [
		now,
		int(Engine.get_frames_per_second()),
		int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		OS.get_static_memory_usage() / 1048576.0,
		int(GameState.phase), GameState.level, GameState.xp, GameState.materials,
		GameState.kills,
		_int_of(_wm(), "wave"),
		tr.get_nodes_in_group("enemies").size(),
		tr.get_nodes_in_group("loot").size(),
		tr.get_nodes_in_group("fx").size(),
		tr.get_nodes_in_group("ambient_fx").size(),
		tr.get_nodes_in_group("player_bullets").size(),
		tr.get_nodes_in_group("enemy_bullets").size(),
		ObjectPool.idle_count(),
		Engine.time_scale,
		(float(p.get("hp")) if p != null else -1.0),
		_n_hit, _sum_dmg, _n_kill, _n_react, _n_sts,
	])
	_reset_counters()

func _reset_counters() -> void:
	_n_hit = 0
	_sum_dmg = 0.0
	_n_kill = 0
	_n_react = 0
	_n_sts = 0

## ---------------------------------------------------------------- 事件

func _on_run_started() -> void:
	begin_run()

func _on_run_ended(victory: bool) -> void:
	_event("run_ended", "victory=%s" % ("1" if victory else "0"))

func _on_wave_started(w: int) -> void:
	_event("wave_started", "w=%d" % w)

func _on_wave_ended(w: int) -> void:
	_event("wave_ended", "w=%d" % w)

func _on_boss_killed() -> void:
	_event("boss_killed", "")

func _on_leveled_up(lv: int) -> void:
	_event("leveled_up", "lv=%d queue=%d" % [lv, GameState.level_queue])

func _on_item_purchased(good_id: String) -> void:
	_event("item_purchased", good_id)

func _on_artifact_acquired(aid: String) -> void:
	_event("artifact_acquired", aid)

func _on_event_card(card_id: String, choice_id: String) -> void:
	_event("event_card", "%s/%s" % [card_id, choice_id])

func _on_achievement(id: String) -> void:
	_event("achievement", id)

func _on_player_died() -> void:
	_event("player_died", "wave=%d" % _int_of(_wm(), "wave"))

func _on_phase_changed(p: int) -> void:
	_event("phase_changed", "phase=%d" % p)

## 以下三条只累数（真机高频）
func _on_player_damaged(amount: float) -> void:
	_n_hit += 1
	_sum_dmg += amount

func _on_enemy_killed(_t: String) -> void:
	_n_kill += 1

func _on_element_reaction(_rid: String, _pos: Vector2, _tg: Array) -> void:
	_n_react += 1

func _on_status_applied(_id: String, _stacks: int, _pos: Vector2) -> void:
	_n_sts += 1

## ---------------------------------------------------------------- 落盘

func _event(kind: String, detail: String) -> void:
	_push("E t=%.1f %s %s" % [_now(), kind, detail])

func _push(line: String) -> void:
	if not _header_done:
		_ensure_file()
		_header_done = true
		_write_header()
	_buf.append(line)

func _write_header() -> void:
	_buf.append("# RunTrace v1  sample=%.1fs flush=%.1fs keep=%d"
		% [SAMPLE_SEC, FLUSH_SEC, KEEP_FILES])
	_buf.append("# S t= fps= obj= node= mem=MB phase= lv= xp= mat= kills= w= enemy= loot= fx= amb= pb= eb= pool= ts= hp= +hit= +dmg= +kill= +react= +sts=")
	_buf.append("# E t= <kind> <detail>")

func _flush() -> void:
	if _buf.is_empty() or _path == "":
		return
	var text := ""
	for l in _buf:
		text += l + "\n"
	_buf.clear()
	if not _append_file(_path, text):
		push_warning("[RunTrace] 写盘失败：" + _path)

func _ensure_file() -> void:
	if _path != "":
		return
	_path = _dir + "run_" + Time.get_datetime_string_from_system().replace(":", "-") + ".log"

func _rotate() -> void:
	var d := DirAccess.open(_dir)
	if d == null:
		return
	var files: Array[String] = []
	for f in d.get_files():
		if f.begins_with("run_") and f.ends_with(".log"):
			files.append(f)
	files.sort()
	while files.size() > KEEP_FILES:
		# 显式标 String：Array.pop_front() 在绑定里返回 Variant，用 := 会触发推断警告
		var old: String = files.pop_front()
		DirAccess.remove_absolute(_dir + old)

## 追加写：本版本没有 FileAccess.WRITE_APPEND，用 READ_WRITE + seek_end 代替
static func _append_file(p: String, text: String) -> bool:
	var f: FileAccess
	if FileAccess.file_exists(p):
		f = FileAccess.open(p, FileAccess.READ_WRITE)
		if f != null:
			f.seek_end()
	else:
		f = FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return true

## ---------------------------------------------------------------- 工具

func _now() -> float:
	return (Time.get_ticks_msec() - _t0) / 1000.0

func _player() -> Node:
	if _player_ref != null and is_instance_valid(_player_ref):
		return _player_ref
	_player_ref = _scene_node("Player")
	return _player_ref

func _wm() -> Node:
	if _wm_ref != null and is_instance_valid(_wm_ref):
		return _wm_ref
	_wm_ref = _scene_node("WaveManager")
	return _wm_ref

func _scene_node(p: String) -> Node:
	# 显式标 Node：SceneTree.current_scene 在绑定里是 Variant，
	# 用 := 推断会触发「从 Variant 推断类型」警告（本项目当错误）
	var cs: Node = get_tree().current_scene
	var n: Node = null if cs == null else cs.get_node_or_null(p)
	if n == null:
		# 兜底：冒烟里 current_scene 是用例场景而非 main.tscn，
		# 直接 get_node 会取空（实测 w=-1 / hp=-1）。全树按名字找一次。
		n = get_tree().root.find_child(p, true, false)
	return n

## 字段可能不存在（如 WaveManager.wave 命名变动）：取不到就记 -1，不让日志拖崩游戏
static func _int_of(obj: Object, key: String) -> int:
	if obj == null or not is_instance_valid(obj):
		return -1
	# 不落中间变量：obj.get() 返回 Variant，赋给 var 会触发「从 Variant 推断类型」警告，
	# 而本项目把该警告当错误（warnings treated as error），会直接 Parse Error
	return int(obj.get(key)) if obj.get(key) != null else -1
