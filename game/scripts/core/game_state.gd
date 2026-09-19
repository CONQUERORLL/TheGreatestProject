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
var loadout_weapon := Config.FALLBACK_WEAPON   # 初始武器（"" = 用角色默认）
var loadout_item := ""           # 开局道具（"" = 无）

var touch_move := Vector2.ZERO   # 移动端虚拟摇杆输入（模拟量，TouchControls 写入）
var mouse_move := Vector2.ZERO   # 桌面鼠标点触移动输入（模拟量，MouseMove 写入）

## ⚠️⚠️ 确定性物理帧计数（**不要用 `Engine.get_physics_frames()` 做战斗判据**）。
## 引擎的绝对帧号包含**启动期消耗的物理帧**，而那段帧数**每次运行都不同**
## （实测同 seed 两次跑到同一游戏状态时，绝对帧号差了 2 帧：1365 vs 1363）。
## 任何拿它做「本帧缓存是否有效」「隔帧错峰」的判据都会让战局不可复现 ——
## autoplay 的 A/B 对照因此失效过。这个计数器由 `main._physics_process` 递增，
## 从 `reset_run()` 起算，固定 seed 下完全确定。
var phys_frames := 0

var endless := false   # 无尽炼狱模式（每 10 波 BOSS，波次无上限，积分排行）
var score := 0         # 无尽模式积分（击杀 / BOSS 击破 / 清波奖励）
var daily := false     # 每日挑战（当日日期做种子，全服同局：同角色/难度/商店/BOSS）
var daily_date := ""   # 每日挑战绑定的日期（YYYY-MM-DD，跨天防护）

## ---- 江湖奇遇事件卡（Phase 4）----
var event_card_count := 0    # 本局已触发次数
var event_card_cap := 4      # 本局上限（reset_run 时在 EVENT_CARD_MIN~MAX 间随机）
var events_seen: Array = []  # 本局已出现过的卡 id（不重复抽，保证 10 张都能见到）
var next_wave_elite := 0     # 下一波开始时额外生成的精英数量（事件风险选项写入）

## ---- 法宝盒子（第 9 轮 · 需求 4）----
## 中间 BOSS（W4/8/12/16）击破 +1，波末由 main 开盒三选一；开一个 -1。
## ⚠️ 刻意**不落存档**：它的消费点（开盒）被安排在"最后一次写档之前"（见 main._finish_evolve_flow），
##    所以正常情况下不存在"盒子里还留着东西就存档"的时刻。若玩家在开盒界面直接退出，
##    因为这次存档根本没发生，读档会回到本波开始 —— 盒子跟着重新拿，不会丢。
var boss_boxes := 0

## 当前地图主题（Phase 5，Config.MAP_THEMES 的键）
## 刻意不落存档：主题是波次的纯函数（Config.map_theme_for_wave），
## 读档恢复 wave 时主题自然一致，避免为一个可推导的值改存档格式
var map_theme := "bamboo"

## ---- 区块与区域元素（五行体系 §5.5.3 · S3.5）----
## 本区区域元素（玩家相关：Config.wave_area_element(player.element, wave)）。
## 同样不落存档 —— 它是「波次 + 玩家元素」的纯函数，读档恢复 wave 后自然一致。
## 用途：横幅显示、区块偏置、BOSS 元素、出怪加权。
var area_element := ""
## 已经发过区域加成的区块号（1 起；0 = 一个都还没发）。
## ⚠️ 必须有这个护栏：区域加成是「进新区一次性 +永久属性增益」
##    （第 16 轮 · 需求 6 从同化度改来，见 `Config.area_bonus_player`），而读档会重新走
##    `start_wave(restored_wave)`。没有它，反复读同一档就能反复白拿属性。
##    不落存档，由 main 在 _ready 里按 restored_wave 反推（见 main._ready）。
var area_bonus_block := 0

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
	phys_frames = 0   # 确定性物理帧计数（见字段注释）
	score = 0   # endless 为本局开局选定/存档恢复的配置，不在重置之列
	# 奇遇：每局上限随机 3~5 次，已见卡清空（与每日挑战/无尽无关，本局独立）
	event_card_count = 0
	event_card_cap = GameRng.range_i(Config.EVENT_CARD_MIN, Config.EVENT_CARD_MAX)
	events_seen = []
	next_wave_elite = 0
	boss_boxes = 0

func start_run() -> void:
	reset_run()
	set_phase(Phase.PLAYING)
	EventBus.run_started.emit()
