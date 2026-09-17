# -*- coding: utf-8 -*-
"""第 9 轮 · 需求 4：smoke_test.gd 新增用例 + 两条过期注释。

跑法：
    python.exe game/tools/_apply_round9_boss_smoke.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path  # noqa: E402

SMOKE = game_path("tests", "smoke_test.gd")

OLD_COMMENT = """\t# 通关成就（clear_20）与无尽成就（endless_20）**必须不同源**：
\t# 标准局 best_wave 最高只到 19 —— BOSS 波不派发 wave_ended，W20 直接走通关分支，
\t# 所以 best_wave 永远够不到 20，endless_20 只在无尽成立。
"""

NEW_COMMENT = """\t# 通关成就（clear_20）与无尽成就（endless_20）**必须不同源**：
\t# 标准局 best_wave 最高只到 19 —— 第 9 轮改版后中间 BOSS（W4/8/12/16）会正常派发
\t# wave_ended，但**最终 BOSS（W20）不派发**（它直接走通关分支），
\t# 所以 best_wave 永远够不到 20，endless_20 只在无尽成立。
"""

OLD_CALL = """\t_check_boss_death_skills()
\t_check_boss_skills()
\t_check_unlocks()
"""

NEW_CALL = """\t_check_boss_death_skills()
\t_check_boss_skills()
\t_check_round9_boss_terrain()
\t_check_unlocks()
"""

OLD_FN_HEAD = """## BOSS 死亡技能：数据完整性 / 凤凰涅槃拦截 / 死亡技能确实产生弹幕
func _check_boss_death_skills() -> void:
"""

NEW_FN_HEAD = '''## 第 9 轮 · 需求 4：每 4 波一个 BOSS + 场景属性地形区域。
## 覆盖三块最容易静默出错的地方：①标准/自定义/无尽三态的 BOSS 波判定与"最终 vs 中间"分流；
## ②地形区域必须是**纯函数**（读档/每日挑战全服一致）且不覆盖出生点；
## ③临时同化度必须**进出可逆**（不可逆 = 把一片地的加成永久镀进存档，且完全不报错）。
func _check_round9_boss_terrain() -> void:
\t# ⚠️ 本用例对波次总数有硬期望（标准局 20 波），而 `is_boss_wave` 会读
\t#    `RunRules.wave_total()` —— 上游只要有任何一处把自定义规则泄漏出来，
\t#    断言的失败面就会变成"每 4 波判定坏了"。先复位、用例结束再还原。
\tvar rules_ctx := { "active": RunRules.active, "values": RunRules.values.duplicate(true) }
\tvar endless_bak: bool = GameState.endless
\tRunRules.active = false
\tGameState.endless = false
\tvar total := RunRules.wave_total(Config.WAVES_TOTAL)
\t# ---- 1. 标准局：每 BLOCK_WAVES 波一个 BOSS，最后一波恒为 BOSS ----
\tif not Config.is_boss_wave(4) or not Config.is_boss_wave(8) \\
\t\t\tor not Config.is_boss_wave(12) or not Config.is_boss_wave(16):
\t\t_fail("标准局未按每 %d 波出 BOSS（W4/8/12/16）" % Config.BLOCK_WAVES)
\t\treturn
\tif Config.is_boss_wave(1) or Config.is_boss_wave(5) or Config.is_boss_wave(19):
\t\t_fail("标准局把非 %d 倍数的波误判为 BOSS 波" % Config.BLOCK_WAVES)
\t\treturn
\tif not Config.is_boss_wave(total):
\t\t_fail("标准局最后一波（%d）必须是 BOSS 波" % total)
\t\treturn
\t# `0 % 4 == 0` 的坑：0 / 负数波次不许被判成 BOSS 波
\tif Config.is_boss_wave(0) or Config.is_boss_wave(-4):
\t\t_fail("is_boss_wave 把 0 / 负数波次误判为 BOSS（0 %% %d == 0 的坑）" % Config.BLOCK_WAVES)
\t\treturn
\t# ---- 2. 最终 vs 中间的分叉（这是"W4 打完直接通关"的唯一闸门）----
\tif not Config.is_final_boss_wave(total) or Config.is_final_boss_wave(4):
\t\t_fail("is_final_boss_wave 判定错误（只有最后一波才是最终 BOSS）")
\t\treturn
\tif not Config.is_mid_boss_wave(4) or Config.is_mid_boss_wave(total):
\t\t_fail("is_mid_boss_wave 判定错误（最后一波不是中间 BOSS）")
\t\treturn
\t# ---- 3. 无尽不受影响：仍是每 10 波，且**不**被当成中间 BOSS（否则会被限时）----
\tGameState.endless = true
\tif not Config.is_boss_wave(30) or Config.is_boss_wave(4) or Config.is_boss_wave(28):
\t\t_fail("无尽 BOSS 节奏被改坏（应仍是每 10 波）")
\t\treturn
\tif Config.is_mid_boss_wave(30) or Config.is_final_boss_wave(30):
\t\t_fail("无尽 BOSS 被误判为中间/最终 BOSS（会被限时或直接通关）")
\t\treturn
\tGameState.endless = false
\t# ---- 4. 血量随波次成长 + 最终波锚点 1.0（既有 W20 平衡不变）+ 中间 BOSS 有时限 ----
\tif not is_equal_approx(Config.boss_hp_scale(total), 1.0):
\t\t_fail("最终 BOSS 血量锚点应为 1.0（= 改动前的值），实为 %.3f" % Config.boss_hp_scale(total))
\t\treturn
\tvar s4 := Config.boss_hp_scale(4)
\tvar s8 := Config.boss_hp_scale(8)
\tvar s16 := Config.boss_hp_scale(16)
\tif not (s4 > 0.0 and s4 < s8 and s8 < s16 and s16 < 1.0):
\t\t_fail("中间 BOSS 血量未随波次成长（W4=%.3f W8=%.3f W16=%.3f）" % [s4, s8, s16])
\t\treturn
\tif Config.midboss_duration(4) <= Config.wave_duration(4):
\t\t_fail("中间 BOSS 限时未比同波普通波宽（%.1f vs %.1f）"
\t\t\t% [Config.midboss_duration(4), Config.wave_duration(4)])
\t\treturn
\t# ---- 5. 地形区域：属性跟随本区区域元素 / 圆心是纯函数 / 不覆盖出生点 ----
\tvar z5: Dictionary = Config.terrain_zone_for_wave("wood", 5)
\tvar z5b: Dictionary = Config.terrain_zone_for_wave("wood", 5)
\tif z5.is_empty() \\
\t\t\tor String(z5.get("element", "")) != Config.wave_area_element("wood", 5):
\t\t_fail("地形区域属性未跟随本区区域元素（%s）" % str(z5.get("element", "<空>")))
\t\treturn
\tif Vector2(z5.get("center", Vector2.ZERO)) != Vector2(z5b.get("center", Vector2.ONE)):
\t\t_fail("地形区域圆心不是纯函数（同参数两次调用结果不同）")
\t\treturn
\t# 同一区块四波必须完全一致：玩家要能记住"这片地在这"，否则它退化成随机踩点
\tvar z7: Dictionary = Config.terrain_zone_for_wave("wood", 7)
\tif Vector2(z7.get("center", Vector2.ZERO)) != Vector2(z5.get("center", Vector2.ONE)) \\
\t\t\tor String(z7.get("element", "")) != String(z5.get("element", "")):
\t\t_fail("同一区块内地形区域发生漂移（W5 与 W7 应完全一致）")
\t\treturn
\t# 换区必须换位置/属性（否则"每 4 波一个新地形"名存实亡）
\tvar z6: Dictionary = Config.terrain_zone_for_wave("wood", 6)
\tif Vector2(z6.get("center", Vector2.ZERO)) == Vector2(z5.get("center", Vector2.ONE)) \\
\t\t\tand String(z6.get("element", "")) == String(z5.get("element", "")):
\t\t_fail("换区后地形区域未发生变化（属性与位置都相同）")
\t\treturn
\tvar arena_center := Vector2(Config.WORLD.w, Config.WORLD.h) * 0.5
\tif arena_center.distance_to(Vector2(z5.get("center", Vector2.ZERO))) \\
\t\t\t<= float(z5.get("radius", 0.0)):
\t\t_fail("地形区域覆盖了玩家出生点（开局白送一档同化度）")
\t\treturn
\t# ---- 6. 玩家侧临时同化度：进出必须可逆（不可逆 = 静默镀金）----
\tvar p2: Node2D = _main.get_node("Player")
\tvar elem := String(z5.get("element", ""))
\tvar akey := "assim_" + elem
\tvar base := float(p2.stats.get(akey, 0.0))
\tp2.set_zone_assim(elem, Config.TERRAIN_ZONE_BONUS)
\tvar mid := float(p2.stats.get(akey, 0.0))
\tif mid <= base:
\t\t_fail("站进地形区未获得同化度（%.3f → %.3f）" % [base, mid])
\t\treturn
\tp2.set_zone_assim("", 0.0)
\tif not is_equal_approx(float(p2.stats.get(akey, 0.0)), base):
\t\t_fail("离开地形区后同化度未复原（%.3f → %.3f，期望 %.3f）"
\t\t\t% [base, float(p2.stats.get(akey, 0.0)), base])
\t\treturn
\t# 顶到上限时也必须只撤「实际生效量」：按"想要写的量"撤会把玩家的固有同化度吃掉
\tp2.stats[akey] = 2.0
\tp2.set_zone_assim(elem, Config.TERRAIN_ZONE_BONUS)
\tp2.set_zone_assim("", 0.0)
\tif not is_equal_approx(float(p2.stats.get(akey, 0.0)), 2.0):
\t\t_fail("同化度已到上限时进出地形区吃掉了固有值（%.3f，期望 2.000）"
\t\t\t% float(p2.stats.get(akey, 0.0)))
\t\treturn
\tp2.stats[akey] = base
\tp2.set_zone_assim("", 0.0)
\t# ---- 7. 怪物侧地形加成进 mob_resist 的加法项，且被 cap 吃掉（"不超过上限"）----
\tif absf(Config.mob_resist(1, 0.0, 0.0, 0.0, 0.75, Config.TERRAIN_ZONE_BONUS)
\t\t\t- Config.TERRAIN_ZONE_BONUS) > 1e-6:
\t\t_fail("地形加成未进入 mob_resist 的加法项")
\t\treturn
\tif not is_equal_approx(
\t\t\tConfig.mob_resist(20, 0.75, 0.0, 0.0, 0.75, Config.TERRAIN_ZONE_BONUS), 0.75):
\t\t_fail("地形加成未被 mob_resist 的 cap 约束（噩梦 W20 普通怪仍应 ≤ 0.75）")
\t\treturn
\t# ---- 8. 集成：中间 BOSS 击破**只发盒子、不进通关**（"W4 打完直接通关"的唯一闸门）----
\tvar wm_b: Node = _main.get_node("WaveManager")
\tvar wave_bak: int = wm_b.wave
\tvar boxes_bak: int = GameState.boss_boxes
\tvar phase_bak = GameState.phase
\twm_b.wave = 4
\tGameState.boss_boxes = boxes_bak
\t_main._on_boss_killed()
\tvar got_box: bool = GameState.boss_boxes == boxes_bak + 1
\tvar not_won: bool = GameState.phase != GameState.Phase.VICTORY
\tvar now_boxes: int = GameState.boss_boxes
\t# 现场还原（**必须**）：这场"BOSS"没真的打过，不许它改到下游用例的状态
\tGameState.boss_boxes = boxes_bak
\tGameState.phase = phase_bak
\twm_b.wave = wave_bak
\tGameState.endless = endless_bak
\tRunRules.active = bool(rules_ctx.get("active", false))
\tRunRules.values = (rules_ctx.get("values", {}) as Dictionary).duplicate(true)
\tif not got_box:
\t\t_fail("中间 BOSS 击破未发放法宝盒子（%d → %d）" % [boxes_bak, now_boxes])
\t\treturn
\tif not not_won:
\t\t_fail("中间 BOSS 击破误入通关结算（第 4 波就会 VICTORY）")
\t\treturn
\tprint("SMOKE: 第 9 轮 每 %d 波 BOSS（中间/最终分流 · 血量随波成长 · 限时）+ 地形区域"
\t\t% Config.BLOCK_WAVES + "（纯函数圆 · 加成可逆且不越上限）OK")


## BOSS 死亡技能：数据完整性 / 凤凰涅槃拦截 / 死亡技能确实产生弹幕
func _check_boss_death_skills() -> void:
'''

OLD_MSG = """\t\t_fail("is_boss_wave 标准模式判定错误（应只有第 %d 波是 BOSS）" % Config.BOSS_WAVE)
"""

NEW_MSG = """\t\t_fail("is_boss_wave 标准模式判定错误（第 %d 波必须是 BOSS，且 19 / 10 都不是）"
\t\t\t% Config.BOSS_WAVE)
"""


def main():
    ok = apply_file(SMOKE, [
        (OLD_COMMENT, NEW_COMMENT),
        (OLD_CALL, NEW_CALL),
        (OLD_FN_HEAD, NEW_FN_HEAD),
        (OLD_MSG, NEW_MSG),
    ], "r9-smoke")
    if not ok:
        sys.exit(1)
    print("ALL OK")


if __name__ == "__main__":
    main()
