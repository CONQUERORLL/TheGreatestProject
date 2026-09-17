# -*- coding: utf-8 -*-
"""第 9 轮补丁 A：`MIDBOSS_HP_FRAC` 未接线（P0 静默 bug）。

现场（本轮核实）：
  · `Config.boss_hp_scale()` 在 `game/scripts/` 下**只有定义、零调用点**
    （唯一引用者是 smoke 对纯函数的断言）。
  · `enemy.gd::setup()` 的 BOSS 分支 `hp_s` 在标准局恒为 1.0（注释「BOSS 不吃常规波次缩放」），
    且 `wave_manager.spawn()` 不改 BOSS 血量 → **标准局 BOSS 血量 = cfg.hp**（56 万~90 万），
    **与波次完全无关**。
  · 后果：中间 BOSS（W4/8/12/16）与最终 BOSS 血量**一模一样**，却额外背 105/135/165/195s 限时
    → 必然打不死 →「时间结束没有击杀则不掉落」成为常态、法宝盒子永远拿不到
    → 第 9 轮需求 4 的「血量随波次成长」也**根本没实现**（与 §12.13 文档冲突）。

改法：
  ① `Config.boss_hp_scale` 自己只在**真正的 BOSS 波**压缩（非 BOSS 波返 1.0）。
     理由：测试/工具会在任意波次造 BOSS（如 W10）验技能与 dmg_cap；那里若也按 frac 缩，
     `dmg_cap = max_hp × 0.005` 跟着变小，`_check_boss_skills` 里
     `take_damage(1000)` 期望掉血 800 的断言会被**静默截断**成 430 而报红。
  ② `enemy.gd` BOSS 分支改为读 `Config.boss_hp_scale(wave)`（无尽曲线与标准最终波逐字不变）。
  ③ smoke 补**消费点**断言：真的实例化一个 W4 中间 BOSS，断言 max_hp 按 frac 压缩、
     且**轻于**最终 BOSS（反向对照）、非 BOSS 波不受影响。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path  # noqa: E402

CFG = game_path("scripts", "core", "config.gd")
ENEMY = game_path("scripts", "enemies", "enemy.gd")
SMOKE = game_path("tests", "smoke_test.gd")

# ------------------------------------------------------------------ config.gd
CFG_EDITS = [(
    """## BOSS 血量倍率（第 9 轮 · 用户要求「血量随波次成长」）。
##   · 无尽：沿用既有曲线（W10 = 1.0，每深一波 +30%）—— **不动它**。
##   · 标准：最终波 = 1.0（与改动前**完全一致**，W20 的既有平衡不受影响）；
##     中间 BOSS 查 `MIDBOSS_HP_FRAC`，是"随波次成长"的那条腿。
static func boss_hp_scale(w: int) -> float:
\tif GameState.endless:
\t\treturn 1.0 + 0.30 * float(maxi(0, w - 10))
\tif w >= RunRules.wave_total(WAVES_TOTAL):
\t\treturn 1.0
\tvar blk := block_of(w)
\treturn float(MIDBOSS_HP_FRAC[clampi(blk - 1, 0, MIDBOSS_HP_FRAC.size() - 1)])""",
    """## BOSS 血量倍率（第 9 轮 · 用户要求「血量随波次成长」）。
##   · 无尽：沿用既有曲线（W10 = 1.0，每深一波 +30%）—— **不动它**。
##   · 标准：最终波 = 1.0（与改动前**完全一致**，W20 的既有平衡不受影响）；
##     中间 BOSS 查 `MIDBOSS_HP_FRAC`，是"随波次成长"的那条腿；
##     **非 BOSS 波 = 1.0**（测试/工具会在任意波次造 BOSS，见下）。
##
## ⚠️⚠️ 本函数是 BOSS 血量的**唯一真值**，消费点在 `enemy.gd::setup()` 的 BOSS 分支。
##    第 9 轮踩过一次静默坑：函数写好了、纯函数断言也绿，**但没人调用它**
##    → 中间 BOSS 血量从未被压缩（与最终 BOSS 同值却多背限时，必然打不死）。
##    **只断言纯函数返回值抓不到「声明了没人读」** —— 消费点断言在冒烟 §4b。
static func boss_hp_scale(w: int) -> float:
\tif GameState.endless:
\t\treturn 1.0 + 0.30 * float(maxi(0, w - 10))
\tif w >= RunRules.wave_total(WAVES_TOTAL):
\t\treturn 1.0
\t# 只在**真正的中间 BOSS 波**压缩。非 BOSS 波返 1.0 的两个理由：
\t#   ① 测试 / 工具会在任意波次（如 W10）造 BOSS 验技能与 dmg_cap；那里若也按 frac 缩，
\t#      `dmg_cap = max_hp × 0.005` 会跟着变小，`_check_boss_skills` 里
\t#      `take_damage(1000)` 期望掉血 800 的断言会被**静默截断**成 430 而报红。
\t#   ② `boss_hp_scale(1)` 本无语义，返 frac 会给出「W1 血量 3%」的假事实。
\tif not is_boss_wave(w):
\t\treturn 1.0
\tvar blk := block_of(w)
\treturn float(MIDBOSS_HP_FRAC[clampi(blk - 1, 0, MIDBOSS_HP_FRAC.size() - 1)])""",
)]

# ------------------------------------------------------------------ enemy.gd
ENEMY_EDITS = [(
    """\tif boss_flag:
\t\t# BOSS 不吃常规波次缩放；无尽模式每深 1 波血量 +30%（再叠难度倍率），
\t\t# 防止后期构筑对 BOSS 秒杀
\t\tif GameState.endless and wave > 10:
\t\t\thp_s = 1.0 + 0.30 * float(wave - 10)
\t\tdmg_s = 1.0 + 0.18 * float(wave - 1)""",
    """\tif boss_flag:
\t\t# BOSS 不吃普通怪的 `wave_hp_scale`，血量曲线**唯一真值** = `Config.boss_hp_scale(w)`：
\t\t#   · 无尽 = 1 + 0.30(w−10)（W10 = 1.0，与改动前逐字一致）；
\t\t#   · 标准最终波 = 1.0（W20 既有平衡不受影响）；
\t\t#   · 中间 BOSS（W4/8/12/16）= `MIDBOSS_HP_FRAC` 随区块成长；非 BOSS 波 = 1.0。
\t\t#
\t\t# ⚠️⚠️ 第 9 轮踩过的静默坑（**不报错、冒烟当时也全绿**）：`boss_hp_scale` 当时只写进了
\t\t#    Config 并配了纯函数断言，**这里从没调用过它** —— 于是中间 BOSS 与最终 BOSS 血量
\t\t#    完全相同（56 万~90 万），而中间 BOSS 还额外背 105~195s 限时
\t\t#    → 必然打不死 →「时间结束没有击杀则不掉落」变成常态、法宝盒子永远拿不到。
\t\t#    教训：**新加的公式必须确认它有消费点**；只断言纯函数返回值 = 没断言「有人读」。
\t\thp_s = Config.boss_hp_scale(wave)
\t\tdmg_s = 1.0 + 0.18 * float(wave - 1)""",
)]

# ------------------------------------------------------------------ smoke_test.gd
SMOKE_EDITS = [(
    """\tif Config.midboss_duration(4) <= Config.wave_duration(4):
\t\t_fail("中间 BOSS 限时未比同波普通波宽（%.1f vs %.1f）"
\t\t\t% [Config.midboss_duration(4), Config.wave_duration(4)])
\t\treturn""",
    """\tif Config.midboss_duration(4) <= Config.wave_duration(4):
\t\t_fail("中间 BOSS 限时未比同波普通波宽（%.1f vs %.1f）"
\t\t\t% [Config.midboss_duration(4), Config.wave_duration(4)])
\t\treturn
\t# ---- 4b. ⭐ **消费点**断言：`boss_hp_scale` 必须被真实实例消费，不能只在 Config 里躺着 ----
\t# ⚠️⚠️ 这是第 9 轮的真实教训：本函数当时**没有任何游戏代码调用它** —— 中间 BOSS 与
\t#    最终 BOSS 血量完全相同（56 万~90 万），却多背 105~195s 限时，必然打不死。
\t#    上面 4 那几条只断言纯函数返回值，**抓不到「声明了没人读」**这种缺陷。
\t#    期望值一律从被测数据算（BOSS 基础血量 × 本波 frac × 当前难度 hp_mult），不硬编码。
\tvar bcfg: Dictionary = Registry.enemies.get("boss", {})
\tvar bmult: float = float(Registry.get_difficulty(GameState.difficulty_id).get("hp_mult", 1.0))
\tvar probe_mid: Node2D = preload("res://scenes/enemies/enemy.tscn").instantiate()
\t_main.add_child(probe_mid)
\tprobe_mid.setup("boss", 4)
\tvar want_mid: float = float(bcfg.get("hp", 0.0)) * Config.boss_hp_scale(4) * bmult
\tif not is_equal_approx(probe_mid.max_hp, want_mid):
\t\t_fail("中间 BOSS 血量未按 boss_hp_scale 压缩（实为 %.0f，期望 %.0f）"
\t\t\t% [probe_mid.max_hp, want_mid])
\t\tprobe_mid.queue_free()
\t\treturn
\t# 反向对照：中间 BOSS 必须**真的更轻** —— 否则「压缩」只是没生效的空操作，
\t# 而上面那条 is_equal_approx 在 frac==1.0 时也会假绿。
\tvar probe_final: Node2D = preload("res://scenes/enemies/enemy.tscn").instantiate()
\t_main.add_child(probe_final)
\tprobe_final.setup("boss", total)
\tvar mid_hp: float = probe_mid.max_hp
\tvar final_hp: float = probe_final.max_hp
\tprobe_mid.queue_free()
\tprobe_final.queue_free()
\tif final_hp <= mid_hp:
\t\t_fail("中间 BOSS 未比最终 BOSS 更轻（%.0f vs %.0f）" % [mid_hp, final_hp])
\t\treturn
\t# 反向对照 2：非 BOSS 波（W10）造出来的 BOSS **不受**压缩影响 —— 任意波次造 BOSS 是
\t# 测试/工具的常规做法，那里被压会连带压小 dmg_cap（见 config.boss_hp_scale 注释）。
\tvar probe_off: Node2D = preload("res://scenes/enemies/enemy.tscn").instantiate()
\t_main.add_child(probe_off)
\tprobe_off.setup("boss", 10)
\tvar off_hp: float = probe_off.max_hp
\tprobe_off.queue_free()
\tif not is_equal_approx(off_hp, float(bcfg.get("hp", 0.0)) * bmult):
\t\t_fail("非 BOSS 波（W10）的 BOSS 血量被中间 BOSS 压缩误伤（%.0f）" % off_hp)
\t\treturn""",
)]


def main():
    ok = True
    for path, edits, tag in [
        (CFG, CFG_EDITS, "config"),
        (ENEMY, ENEMY_EDITS, "enemy"),
        (SMOKE, SMOKE_EDITS, "smoke"),
    ]:
        ok = apply_file(path, edits, tag) and ok
    print("RESULT:", "OK" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
