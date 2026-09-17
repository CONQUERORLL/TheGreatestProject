# -*- coding: utf-8 -*-
"""第 9 轮 · 需求 4：player / enemy / wave_manager / artifact_system 的 BOSS+地形补丁。

跑法：
    python.exe game/tools/_apply_round9_boss_code.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path  # noqa: E402

PLAYER = game_path("scripts", "characters", "player.gd")
ENEMY = game_path("scripts", "enemies", "enemy.gd")
WAVE = game_path("scripts", "systems", "wave_manager.gd")
ARTI = game_path("scripts", "systems", "artifact_system.gd")

# ============================================================
# player.gd —— 地形区域的临时同化度（进出可逆）
# ============================================================
P_VARS_OLD = """var _skill_buff_effects: Dictionary = {}   # 技能临时增益的效果（结束后撤销）
"""

P_VARS_NEW = """var _skill_buff_effects: Dictionary = {}   # 技能临时增益的效果（结束后撤销）
# ---- 地形区域临时同化度（第 9 轮 · 用户需求 4）----
# 记的是「**实际写进 stats 的量**」，而不是「想要写的量」—— 见 set_zone_assim 的长注释。
var _zone_assim_element := ""
var _zone_assim_applied := 0.0
"""

P_FUNC_OLD = """func _sanitize_stats() -> void:
"""

P_FUNC_NEW = """## 地形区域：站在区内时对 `elem` 临时 +`v` 同化度；离开时传 `("", 0.0)` 撤销。
## 由 `fx/terrain_zone.gd` 每 0.35s 扫描写入（波次切换会换元素，所以**每次扫描都写一遍**，
## 由本函数自己判断"要不要撤销上一次"）。
##
## ⚠️⚠️ 这里必须记「**实际生效量**」而不是「想要写的量」：
##     `_sanitize_stats()` 会把 assim clamp 到 2.0。若玩家本来已经 1.95，
##     写入 0.20 实际只生效 0.05；撤销时按 0.20 减就会**把玩家自己的同化度吃掉 0.15**——
##     不报错、只是数值悄悄变少（正是本项目最怕的那类静默算错）。
##     `after - before` 天然免疫这个上限，也免疫「同帧多来源同时写入」的重叠。
##
## ⚠️ 撤销走 `maxf(0.0, ...)`：读档会把 stats 整体覆盖（SaveRun.restore），
##     此时残留的"已应用量"若照减可能变负 —— 宁可少减，也不许把同化度压成负数。
func set_zone_assim(elem: String, v: float) -> void:
\tif _zone_assim_element != "" and _zone_assim_applied != 0.0:
\t\tvar old_key := "assim_" + _zone_assim_element
\t\tstats[old_key] = maxf(0.0, float(stats.get(old_key, 0.0)) - _zone_assim_applied)
\t_zone_assim_element = ""
\t_zone_assim_applied = 0.0
\tif elem == "" or v <= 0.0:
\t\treturn
\tvar key := "assim_" + elem
\tvar before := float(stats.get(key, 0.0))
\tstats[key] = before + v
\t_sanitize_stats()
\tvar after := float(stats.get(key, 0.0))
\t_zone_assim_element = elem
\t_zone_assim_applied = after - before

func _sanitize_stats() -> void:
"""

# ============================================================
# enemy.gd —— 地形区域抗性加成
# ============================================================
E_VAR_OLD = """var block_bias := 0.0
## ---- 五行机制字段（§12-S3），全部来自 cfg，setup 时快照 ----
"""

E_VAR_NEW = """var block_bias := 0.0
## 地形区域加成（第 9 轮 · 需求 4）：站在本区地形圆内、且元素与本区相同时 R +该值。
## 由 `fx/terrain_zone.gd` 每 0.35s 低频扫描写入（与 BOSS 光环同一口径）；离开圆即归零。
## 与 block_bias / aura_bonus 进同一个加法项 → 天然被 `_resist_cap()` 压住（普通 0.75）。
var zone_bonus := 0.0
## ---- 五行机制字段（§12-S3），全部来自 cfg，setup 时快照 ----
"""

E_CALC_OLD = """\treturn Config.mob_resist(spawn_wave, float(diff.get("resist_mult", 0.0)),
\t\tblock_bias, aura_bonus, _resist_cap())
"""

E_CALC_NEW = """\treturn Config.mob_resist(spawn_wave, float(diff.get("resist_mult", 0.0)),
\t\tblock_bias, aura_bonus, _resist_cap(), zone_bonus)
"""

E_REFRESH_OLD = """func refresh_element_resist() -> void:
\telement_resist = _calc_element_resist()
"""

E_REFRESH_NEW = """func refresh_element_resist() -> void:
\telement_resist = _calc_element_resist()

## 地形区域（第 9 轮 · 需求 4）：由 `fx/terrain_zone.gd` 写入。
## 写前比较（照抄 `_refresh_boss_aura`）—— 距离判定每 0.35s 跑一次、怪又多，
## 不做这个比较就是每次扫描把全场怪的抗性重算一遍，纯白烧 CPU。
func set_zone_bonus(v: float) -> void:
\tif is_equal_approx(zone_bonus, v):
\t\treturn
\tzone_bonus = v
\trefresh_element_resist()
"""

# ============================================================
# wave_manager.gd —— 中间 BOSS 的收尾 + 限时
# ============================================================
W_KILL_OLD = """func _on_boss_killed() -> void:
\tboss = null
\tif not GameState.endless:
\t\treturn
\t# 无尽：BOSS 击破 → 积分入账 → 干扰怪退场 → 进商店 → 挑战更深的波次
\tboss_dead = true
\tGameState.add_score(Config.boss_kill_score(wave))
\tfor e in get_tree().get_nodes_in_group("enemies"):
\t\tif e.flee <= 0.0:
\t\t\te.start_flee()
\t_clear_projectiles()
\tEventBus.wave_ended.emit(wave)
"""

W_KILL_NEW = """## BOSS 击破后的**波次收尾**。
## ⚠️ 分叉口（第 9 轮 · 需求 4）：**只有最终 BOSS 不做收尾** ——
##    它由 `main._on_boss_killed` 走通关结算（VICTORY）。这里若也发 wave_ended，
##    就会在通关面板底下再开一次商店（读档会落到"第 21 波商店"，极难查）。
##    中间 BOSS（W4/8/12/16）与无尽 BOSS 一律走收尾 → 商店 → 下一波。
## ⚠️ `ending_started` 必须一起置位：中间 BOSS 的限时倒计时也在 `_physics_process` 里，
##    它以 `ending_started` 作为"只收尾一次"的闸门；不置位的话 BOSS 死了倒计时还在跑，
##    时限一到会**再发一次 wave_ended**（商店被反复 open，界面一直闪）。
func _on_boss_killed() -> void:
\tboss = null
\tif Config.is_final_boss_wave(wave):
\t\treturn
\tboss_dead = true
\tending_started = true
\tif GameState.endless:
\t\tGameState.add_score(Config.boss_kill_score(wave))
\tfor e in get_tree().get_nodes_in_group("enemies"):
\t\tif e.flee <= 0.0:
\t\t\te.start_flee()
\t_clear_projectiles()
\tEventBus.wave_ended.emit(wave)
"""

W_START_OLD = """\tplayer.velocity = Vector2.ZERO
\tvar is_boss_wave := Config.is_boss_wave(wave)
\tintro_t = 2.6 if is_boss_wave else 2.2
"""

W_START_NEW = """\tplayer.velocity = Vector2.ZERO
\tvar is_boss_wave := Config.is_boss_wave(wave)
\tintro_t = 2.6 if is_boss_wave else 2.2
\t# 中间 BOSS 限时（第 9 轮 · 需求 4）：「时间结束没有击杀则不掉落」的前提是有倒计时。
\t# ⚠️ 只有**中间** BOSS 覆盖 wave_timer。最终 BOSS 不限时（打不过就一直打，它是通关条件）；
\t#    无尽 BOSS 同样不限时（既有口径：不死不休、击杀即进下一波）。
\tif Config.is_mid_boss_wave(wave):
\t\twave_timer = Config.midboss_duration(wave) * RunRules.wave_duration_mult()
"""

W_TICK_OLD = """\t\tspawn_t -= delta
\t\tif not boss_dead and spawn_t <= 0.0 and _alive_count(true) < 16:
"""

W_TICK_NEW = """\t\t# 中间 BOSS 限时（第 9 轮 · 需求 4）：时间到未击杀 → BOSS 与干扰怪一起退场、
\t\t# **不掉落**（用户明确要求），本波照常收尾进商店。
\t\t# ⚠️ `ending_started` 是"只收尾一次"的唯一闸门：BOSS 被击杀时 `_on_boss_killed`
\t\t#    已把它置位，所以击杀后这里的倒计时不会再补发一次 wave_ended。
\t\t# ⚠️ `boss_dead = true` 不是装饰：它同时负责"停止补刷干扰怪"——
\t\t#    少了它，时限到之后干扰怪会继续刷进商店界面。
\t\tif Config.is_mid_boss_wave(wave) and not ending_started:
\t\t\twave_timer -= delta
\t\t\tif wave_timer <= 0.0:
\t\t\t\tending_started = true
\t\t\t\tboss_dead = true
\t\t\t\tfor e in get_tree().get_nodes_in_group("enemies"):
\t\t\t\t\tif e.flee <= 0.0:
\t\t\t\t\t\te.start_flee()
\t\t\t\t_clear_projectiles()
\t\t\t\t_alive_cache = 0
\t\t\t\tEventBus.banner_requested.emit("时间到",
\t\t\t\t\t"BOSS 未在时限内被击破 · 本次没有法宝盒子", 2.6)
\t\t\t\tEventBus.wave_ended.emit(wave)
\t\tspawn_t -= delta
\t\tif not boss_dead and spawn_t <= 0.0 and _alive_count(true) < 16:
"""

# ============================================================
# artifact_system.gd —— 中间 BOSS 只掉盒子 + 候选抽取
# ============================================================
A_KILL_OLD = """func _on_boss_killed() -> void:
\tif player == null or not is_instance_valid(player) or float(player.hp) <= 0.0:
\t\treturn
"""

A_KILL_NEW = """func _on_boss_killed() -> void:
\tif player == null or not is_instance_valid(player) or float(player.hp) <= 0.0:
\t\treturn
\t# 无尽前的**中间** BOSS（W4/8/12/16）只掉「法宝盒子」，三选一在波末（main._open_boss_box）。
\t# 直掉一件 + 再开盒子 = 一次 BOSS 拿两件法宝，与用户口径「无尽前只掉落法宝盒子」不符。
\t# ⚠️ 最终 BOSS（W20）与无尽 BOSS 保持直掉：前者随即通关（盒子没处开），
\t#    后者是无尽的既有保底渠道（用户只说了"无尽前"）。
\tif Config.is_mid_boss_wave(wave):
\t\treturn
"""

A_PICK_OLD = """\treturn String(GameRng.weighted_pick(pool))
"""

A_PICK_NEW = """\treturn String(GameRng.weighted_pick(pool))

## 法宝盒子（第 9 轮 · 需求 4）：一次抽 `n` 件**互不相同**的未持有法宝给玩家三选一。
## 与 `pick_artifact` 共用一个池（同样的亲和加权 / legendary ×BOSS 倍率）。
## ⚠️ 候选之间必须互斥：把已选中的 id 也标进 `owned` 再抽下一次 ——
##    否则同一件法宝可能占掉两个卡位，玩家实际只在两件里选（不报错，只是选择面缩水）。
## 池不够 n 件时返回实际数量（调用方负责兜底），**不重复凑数**。
func pick_artifact_choices(n: int = 3) -> Array:
\tvar out: Array = []
\tif player == null or not is_instance_valid(player):
\t\treturn out
\tvar aff := Config.affinity_tags(GameState.character_id,
\t\tplayer.weapons, player.artifacts_owned)
\tvar taken: Dictionary = player.artifacts_owned.duplicate()
\tfor _i in maxi(0, n):
\t\tvar pool := Registry.artifact_pool(taken, wave, true, aff)
\t\tif pool.is_empty():
\t\t\tbreak
\t\tvar id := String(GameRng.weighted_pick(pool))
\t\tif id == "":
\t\t\tbreak
\t\tout.append(id)
\t\ttaken[id] = 1
\treturn out
"""


def main():
    ok = True
    ok = apply_file(PLAYER, [(P_VARS_OLD, P_VARS_NEW), (P_FUNC_OLD, P_FUNC_NEW)], "r9-player") and ok
    ok = apply_file(ENEMY, [
        (E_VAR_OLD, E_VAR_NEW), (E_CALC_OLD, E_CALC_NEW), (E_REFRESH_OLD, E_REFRESH_NEW),
    ], "r9-enemy") and ok
    ok = apply_file(WAVE, [
        (W_KILL_OLD, W_KILL_NEW), (W_START_OLD, W_START_NEW), (W_TICK_OLD, W_TICK_NEW),
    ], "r9-wave") and ok
    ok = apply_file(ARTI, [(A_KILL_OLD, A_KILL_NEW), (A_PICK_OLD, A_PICK_NEW)], "r9-artifact") and ok
    if not ok:
        sys.exit(1)
    print("ALL OK")


if __name__ == "__main__":
    main()
