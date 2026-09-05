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

func is_running() -> bool:
	return phase == Phase.PLAYING or phase == Phase.INTRO

func reset_run() -> void:
	materials = 0
	kills = 0
	run_time = 0.0
	level = 1
	xp = 0
	level_queue = 0
	touch_move = Vector2.ZERO

func start_run() -> void:
	reset_run()
	set_phase(Phase.PLAYING)
	EventBus.run_started.emit()
