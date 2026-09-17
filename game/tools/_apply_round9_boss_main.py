# -*- coding: utf-8 -*-
"""第 9 轮 · 需求 4：main.gd（地形区域挂载 / 中间 BOSS 分流 / 法宝盒子）+ game_state.gd。

跑法：
    python.exe game/tools/_apply_round9_boss_main.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path  # noqa: E402

MAIN = game_path("scripts", "main.gd")
GS = game_path("scripts", "core", "game_state.gd")

# ============================================================
# game_state.gd —— 法宝盒子计数器
# ============================================================
G_VAR_OLD = """var next_wave_elite := 0     # 下一波开始时额外生成的精英数量（事件风险选项写入）
"""

G_VAR_NEW = """var next_wave_elite := 0     # 下一波开始时额外生成的精英数量（事件风险选项写入）

## ---- 法宝盒子（第 9 轮 · 需求 4）----
## 中间 BOSS（W4/8/12/16）击破 +1，波末由 main 开盒三选一；开一个 -1。
## ⚠️ 刻意**不落存档**：它的消费点（开盒）被安排在"最后一次写档之前"（见 main._finish_evolve_flow），
##    所以正常情况下不存在"盒子里还留着东西就存档"的时刻。若玩家在开盒界面直接退出，
##    因为这次存档根本没发生，读档会回到本波开始 —— 盒子跟着重新拿，不会丢。
var boss_boxes := 0
"""

G_RESET_OLD = """	next_wave_elite = 0
"""

G_RESET_NEW = """	next_wave_elite = 0
	boss_boxes = 0
"""

# ============================================================
# main.gd —— 声明
# ============================================================
M_VAR_OLD = """var evolve_choose_ui: Control = null
var _pending_evolve_choices: Array = []   # 待选择的进化选项队列（逐个弹出）
var _pending_evolve_wave := 0             # 进化流程结束后要写入存档的波次（0 = 无）
"""

M_VAR_NEW = """var evolve_choose_ui: Control = null
var _pending_evolve_choices: Array = []   # 待选择的进化选项队列（逐个弹出）
var _pending_evolve_wave := 0             # 进化流程结束后要写入存档的波次（0 = 无）

## 法宝盒子三选一（第 9 轮 · 需求 4）：中间 BOSS 的战利品
var boss_box_ui: Control = null
var _box_choices: Array = []      # 当前盒子的候选法宝 id（测试观测用）

## 场景属性地形区域（第 9 轮 · 需求 4）：每波重建一片圆形地形，见 fx/terrain_zone.gd
var _terrain_zone: Node2D = null
"""

M_READY_OLD = """	evolve_choose_ui = preload("res://scenes/ui/evolve_choose.tscn").instantiate()
	$UI.add_child(evolve_choose_ui)
	evolve_choose_ui.evolved.connect(_on_evolve_choice)
"""

M_READY_NEW = """	evolve_choose_ui = preload("res://scenes/ui/evolve_choose.tscn").instantiate()
	$UI.add_child(evolve_choose_ui)
	evolve_choose_ui.evolved.connect(_on_evolve_choice)
	# 法宝盒子三选一（第 9 轮 · 需求 4）
	boss_box_ui = preload("res://scenes/ui/boss_box.tscn").instantiate()
	$UI.add_child(boss_box_ui)
	boss_box_ui.player = player
	boss_box_ui.picked.connect(_on_boss_box_pick)
"""

M_WSTART_OLD = """func _on_wave_started(w: int) -> void:
	BalanceLog.begin_wave(w)   # 逐波平衡日志（第 8 轮）：从本波起点开始累计增量
	Music.play_track(Music.track_for_wave(w), 0.35)
	_apply_map_theme(GameState.map_theme)
	_grant_area_bonus(w)
	if player != null and is_instance_valid(player):
		player.on_wave_start()   # 角色特性：战意按"本波击杀"重新累积
"""

M_WSTART_NEW = """func _on_wave_started(w: int) -> void:
	BalanceLog.begin_wave(w)   # 逐波平衡日志（第 8 轮）：从本波起点开始累计增量
	Music.play_track(Music.track_for_wave(w), 0.35)
	_apply_map_theme(GameState.map_theme)
	_grant_area_bonus(w)
	_setup_terrain_zone(w)     # 场景属性地形区域（第 9 轮 · 需求 4）
	if player != null and is_instance_valid(player):
		player.on_wave_start()   # 角色特性：战意按"本波击杀"重新累积
"""

M_AREA_TAIL_OLD = """	EventBus.banner_requested.emit(
		"第 %d 区块 · %s" % [block, Config.map_theme_name(GameState.map_theme)],
		"区域加成：%s同化度 +%d%%" % [String(Config.ELEMENT_NAME.get(area, area)),
			int(round(Config.AREA_BONUS * 100.0))], 2.2)
"""

M_AREA_TAIL_NEW = """	EventBus.banner_requested.emit(
		"第 %d 区块 · %s" % [block, Config.map_theme_name(GameState.map_theme)],
		"区域加成：%s同化度 +%d%%" % [String(Config.ELEMENT_NAME.get(area, area)),
			int(round(Config.AREA_BONUS * 100.0))], 2.2)

## 场景属性地形区域（第 9 轮 · 需求 4）：每波开始时按 `Config.terrain_zone_for_wave`
## 重建一片圆形地形。换区（每 4 波）会换属性与位置；同一区块内四波位置不变。
##
## ⚠️ 销毁旧区必须**同步**撤销玩家身上的临时同化度（`zone.clear()`），不能只靠 `_exit_tree()`：
##    `queue_free()` 的 `_exit_tree` 要等到本帧末才跑，而新区的第一次扫描可能在本帧内
##    就把加成再写一遍 —— 旧区迟到的撤销会把新区的加成一并抹掉（表现为"站进区里没加成"）。
##
## ⚠️ 节点必须插成**第一个子节点**且 `z_index = 0`：它是地面装饰，
##    必须压在敌人 / 掉落物 / 玩家之下（铁律 3：新视觉元素必须显式声明 z_index 与预算组）。
##    它刻意不进 `fx` 组也不吃特效预算 —— 它是常驻地面，不是一次性特效。
func _setup_terrain_zone(w: int) -> void:
	_clear_terrain_zone()
	if player == null or not is_instance_valid(player):
		return
	var z: Dictionary = Config.terrain_zone_for_wave(String(player.element), w)
	if z.is_empty():
		return
	var zone: Node2D = TerrainZone.new()
	zone.name = "TerrainZone"
	zone.z_index = 0
	zone.player = player
	add_child(zone)
	move_child(zone, 0)
	if not zone.configure(z):
		zone.queue_free()
		return
	_terrain_zone = zone

## 撤掉当前地形区域：**同步**撤销它给玩家/怪物加的临时加成，然后销毁节点。
## 消费点必须包含**所有"本波结束 / 即将写档"的路径**（main._on_wave_ended /
## main._on_boss_killed / main._on_player_died）—— 少一处的后果是那片地的临时同化度
## 被 `SaveRun.save()` 当成永久值写进档，**且完全不报错**。
func _clear_terrain_zone() -> void:
	if _terrain_zone == null or not is_instance_valid(_terrain_zone):
		_terrain_zone = null
		return
	_terrain_zone.clear()
	_terrain_zone.queue_free()
	_terrain_zone = null
"""

M_WEND_OLD = """func _on_wave_ended(w: int) -> void:
	if GameState.endless or GameState.daily:
		GameState.add_score(Config.wave_clear_score(w))
	shop_ui.open(w)
"""

M_WEND_NEW = """func _on_wave_ended(w: int) -> void:
	# 地形区域必须在**任何存档/结算之前**撤掉（第 9 轮 · 需求 4）：
	# 它是临时加成，而本波结束后的 `_finish_evolve_flow` 会把 stats 写进存档 ——
	# 不撤的话这一片地会被**永久烙进存档**，且完全不报错。
	_clear_terrain_zone()
	if GameState.endless or GameState.daily:
		GameState.add_score(Config.wave_clear_score(w))
	shop_ui.open(w)
"""

M_FINISH_OLD = """func _finish_evolve_flow() -> void:
	var w := _pending_evolve_wave
	_pending_evolve_wave = 0
"""

M_FINISH_NEW = """func _finish_evolve_flow() -> void:
	# 法宝盒子（第 9 轮 · 需求 4）：中间 BOSS 给的盒子必须在**进化结算之后、写档之前**开完，
	# 否则玩家选的那件法宝不会进档（读档后凭空消失，且不报错）。
	# 这里不自增任何计数器，只是把"开盒"插进流程中间；开完会再次回到本函数。
	if GameState.boss_boxes > 0:
		_open_boss_box()
		return
	var w := _pending_evolve_wave
	_pending_evolve_wave = 0
"""

M_COMMIT_OLD = """	if w > 0:
		BalanceLog.commit(w, player, "shop")
"""

M_COMMIT_NEW = """	if w > 0:
		BalanceLog.commit(w, player, "shop")

## 开一个法宝盒子（第 9 轮 · 需求 4）：3 件**未持有**法宝三选一。
## 与武器进化流程同构（`_show_next_evolve_choice` → 玩家选择 → 回到收尾），
## 所以两者可以叠加：先进化、再开盒、最后统一存档。
##
## 池空（15 件全持有）时**不弹空盒子**，直接折材料 —— 与 BOSS 直掉法宝的兜底同口径。
func _open_boss_box() -> void:
	if GameState.boss_boxes <= 0 or boss_box_ui == null:
		GameState.boss_boxes = 0
		_finish_evolve_flow()
		return
	var ids: Array = artifact_system.pick_artifact_choices(Config.BOSS_BOX_CHOICES)
	if ids.is_empty():
		var boxes: int = GameState.boss_boxes
		GameState.boss_boxes = 0
		var mat: int = Config.ARTIFACT_DUP_MATERIALS * Config.BOSS_BOX_CHOICES * boxes
		GameState.add_materials(mat)
		EventBus.banner_requested.emit("法宝已集齐",
			"%d 个盒子折算为 %d ◆" % [boxes, mat], 2.6)
		shop_ui._refresh()
		_finish_evolve_flow()
		return
	_box_choices = ids
	boss_box_ui.open(ids)

## 玩家选定盒子里的一件法宝。`id == ""` = 放弃（当前 UI 不提供该入口，留作安全网）。
func _on_boss_box_pick(id: String) -> void:
	GameState.boss_boxes = maxi(0, GameState.boss_boxes - 1)
	if id != "" and player != null and is_instance_valid(player):
		player.apply_artifact(id)
		Sfx.play("level_up")
		shop_ui._refresh()
	_open_boss_box()   # 还有盒子就接着开；开完自动回到 _finish_evolve_flow → 存档
"""

M_BOSSKILL_OLD = """func _on_boss_killed() -> void:
	if GameState.endless:
		# 无尽：积分与波次收尾由 wave_manager 处理（wave_ended → 商店 → 下一波）
"""

M_BOSSKILL_NEW = """func _on_boss_killed() -> void:
	# 地形区域是**临时**加成，BOSS 一死本波就可能立刻结算/存档 → 先撤（第 9 轮 · 需求 4）
	_clear_terrain_zone()
	if GameState.endless:
		# 无尽：积分与波次收尾由 wave_manager 处理（wave_ended → 商店 → 下一波）
"""

M_MID_OLD = """	if GameState.daily:
		# 每日挑战：通关结算入今日榜（BOSS 击破加分 ×2）
"""

M_MID_NEW = """	# 中间 BOSS（W4/8/12/16）：只给法宝盒子，波末开盒三选一。
	# ⚠️ 必须排在这里（无尽之后、每日/通关之前）—— 它是阻止"第 4 波 BOSS 一死就通关"
	#    的唯一闸门。少了这一步，标准局会在 W4 直接进 VICTORY。
	if Config.is_mid_boss_wave(wave_manager.wave):
		GameState.boss_boxes += 1
		Haptics.rumble(0.4, 0.15, 0.2)
		Sfx.play("victory")
		EventBus.banner_requested.emit("BOSS 击破！",
			"获得法宝盒子 ×1 · 波末开箱三选一", 2.6)
		return
	if GameState.daily:
		# 每日挑战：通关结算入今日榜（BOSS 击破加分 ×2）
"""

M_DIED_OLD = """func _on_player_died() -> void:
	Music.play_track("defeat", 0.6)
"""

M_DIED_NEW = """func _on_player_died() -> void:
	_clear_terrain_zone()   # 同上：别把地形临时加成镀进逐波平衡日志
	Music.play_track("defeat", 0.6)
"""


def main():
    ok = True
    ok = apply_file(GS, [(G_VAR_OLD, G_VAR_NEW), (G_RESET_OLD, G_RESET_NEW)], "r9-gamestate") and ok
    ok = apply_file(MAIN, [
        (M_VAR_OLD, M_VAR_NEW),
        (M_READY_OLD, M_READY_NEW),
        (M_WSTART_OLD, M_WSTART_NEW),
        (M_AREA_TAIL_OLD, M_AREA_TAIL_NEW),
        (M_WEND_OLD, M_WEND_NEW),
        (M_FINISH_OLD, M_FINISH_NEW),
        (M_COMMIT_OLD, M_COMMIT_NEW),
        (M_BOSSKILL_OLD, M_BOSSKILL_NEW),
        (M_MID_OLD, M_MID_NEW),
        (M_DIED_OLD, M_DIED_NEW),
    ], "r9-main") and ok
    if not ok:
        sys.exit(1)
    print("ALL OK")


if __name__ == "__main__":
    main()
