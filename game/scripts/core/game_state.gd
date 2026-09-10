extends Node
## 本局运行状态 + 阶段机（对应原型的 phase 变量与 G 状态）

enum Phase { MENU, INTRO, PLAYING, LEVEL_UP, SHOP, PAUSED, GAME_OVER, VICTORY }

signal phase_changed(new_phase: Phase)

var phase: Phase = Phase.MENU
var materials: int = 0
var kills: int = 0
var run_time: float = 0.0
var level := 1
var xp := 0
var level_queue := 0   # 待处理升级次数（连升；升级 UI 接入后逐次消耗）

## 主菜单"继续游戏"→ main 场景一次性消费标志（消费后恢复 false）
var continue_pending := false

## 当前局绑定的存档槽（1~3；主菜单选槽后设置，SaveRun 全部操作作用于该槽）
var slot_id := 1

## 局外 run 配置（主菜单选择；Registry 注册表 id）
var difficulty_id := "normal"
var character_id := "potato"
var loadout_weapon := "pistol"   # 初始武器（"" = 用角色默认）
var loadout_item := ""           # 开局道具（"" = 无）

var touch_move := Vector2.ZERO   # 移动端虚拟摇杆输入（模拟量，TouchControls 写入）
var mouse_move := Vector2.ZERO   # 桌面鼠标点触移动输入（模拟量，MouseMove 写入）

var endless := false   # 无尽炼狱模式（每 10 波 BOSS，波次无上限，积分排行）
var score := 0         # 无尽模式积分（击杀 / BOSS 击破 / 清波奖励）
var daily := false     # 每日挑战（当日日期做种子，全服同局：同角色/难度/商店/BOSS）
var daily_date := ""   # 每日挑战绑定的日期（YYYY-MM-DD，跨天防护）

## ---- 江湖奇遇事件卡（Phase 4）----
var event_card_count := 0    # 本局已触发次数
var event_card_cap := 4      # 本局上限（reset_run 时在 EVENT_CARD_MIN~MAX 间随机）
var events_seen: Array = []  # 本局已出现过的卡 id（不重复抽，保证 10 张都能见到）
var next_wave_elite := 0     # 下一波开始时额外生成的精英数量（事件风险选项写入）

func add_score(v: int) -> void:
	score = maxi(0, score + v)

## 加经验并处理连升（原型 settlePickup 的 while 循环）
func gain_xp(v: int) -> void:
	xp += v
	var gained := false
	while xp >= Config.xp_need(level):
		xp -= Config.xp_need(level)
		level += 1
		level_queue += 1
		gained = true
	if gained:
		EventBus.leveled_up.emit(level)

func set_phase(p: Phase) -> void:
	phase = p
	phase_changed.emit(p)

func set_materials(value: int) -> void:
	materials = maxi(0, value)
	EventBus.materials_changed.emit(materials)

func add_materials(delta: int) -> void:
	set_materials(materials + delta)

func is_running() -> bool:
	return phase == Phase.PLAYING

func reset_run() -> void:
	set_materials(0)
	kills = 0
	run_time = 0.0
	level = 1
	xp = 0
	level_queue = 0
	touch_move = Vector2.ZERO
	mouse_move = Vector2.ZERO
	score = 0   # endless 为本局开局选定/存档恢复的配置，不在重置之列
	# 奇遇：每局上限随机 3~5 次，已见卡清空（与每日挑战/无尽无关，本局独立）
	event_card_count = 0
	event_card_cap = GameRng.range_i(Config.EVENT_CARD_MIN, Config.EVENT_CARD_MAX)
	events_seen = []
	next_wave_elite = 0

func start_run() -> void:
	reset_run()
	set_phase(Phase.PLAYING)
	EventBus.run_started.emit()
