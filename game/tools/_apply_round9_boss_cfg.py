# -*- coding: utf-8 -*-
"""第 9 轮 · 需求 4：config.gd 的 BOSS 判定 / 中间 BOSS 血量与限时 / 地形区域纯函数。

跑法：
    python.exe game/tools/_apply_round9_boss_cfg.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path  # noqa: E402

CFG = game_path("scripts", "core", "config.gd")

OLD_BOSS_WAVE = """## 是否 BOSS 波：标准模式 = 最后一波；无尽炼狱 = 每 10 波一轮。
## 自定义规则下"最后一波"由 RunRules 的波次总数决定（默认 20 → 与 BOSS_WAVE 一致）。
static func is_boss_wave(w: int) -> bool:
\tif GameState.endless:
\t\treturn w % 10 == 0
\treturn w == RunRules.wave_total(BOSS_WAVE)
"""

NEW_BOSS_WAVE = """## 是否 BOSS 波（第 9 轮 · 用户需求 4「每四关一个 boss」）。
##   · 标准 / 每日 / 自定义 = **每 `BLOCK_WAVES`(4) 波一个**，最后一波恒为 BOSS。
##     刻意复用 `BLOCK_WAVES` 而不是写死 4：区块划分（每 4 波换景 / 换区域元素）与
##     BOSS 节奏由此**同一处真值**驱动 —— 以后改区块长度，BOSS 节奏自动跟上。
##   · 无尽炼狱 = 每 10 波一轮（**保持不变**，既有平衡与冒烟断言都建立在它上面）。
##
## ⚠️ `w < 1` 必须挡在最前面：`0 % 4 == 0` → 不挡的话 `is_boss_wave(0)` 会变成 true，
##    而 `is_event_wave` / `wave_composition` 都可能用 0 号波做兜底查询。
static func is_boss_wave(w: int) -> bool:
\tif w < 1:
\t\treturn false
\tif GameState.endless:
\t\treturn w % 10 == 0
\treturn w >= RunRules.wave_total(BOSS_WAVE) or w % BLOCK_WAVES == 0

## 是否**最终** BOSS 波（打不过就通不了关的那一波）= 标准 / 每日 / 自定义局的最后一波。
## 无尽局恒 false —— 无尽的 BOSS 只是"更深的一波"，不承担通关语义。
##
## ⚠️ 这是「BOSS 击破后怎么收尾」的**唯一分叉口**，两处消费：
##     · `main._on_boss_killed`：最终 → 通关结算（VICTORY / 日报榜）；中间 → 只发法宝盒子。
##     · `wave_manager._on_boss_killed`：最终 → **不做波次收尾**；中间 → 发 wave_ended → 商店。
##    两边必须读同一个函数 —— 一边按"最终"、另一边按"中间"处理会同时踩到
##    「通关面板底下又开了商店」和「中间 BOSS 打完直接通关」两个相反的坑。
static func is_final_boss_wave(w: int) -> bool:
\tif GameState.endless:
\t\treturn false
\treturn w >= RunRules.wave_total(BOSS_WAVE)

## 是否**中间** BOSS 波（改版后标准局的 W4 / W8 / W12 / W16）。
## 与最终 BOSS 的三点差别（全部有对应的消费点）：
##   ① **限时** `midboss_duration()` —— 时间到未击杀 = BOSS 退场且**不掉落**（用户明确要求）；
##   ② 击破只给「法宝盒子」（`GameState.boss_boxes`），波末开盒三选一，不进通关结算；
##   ③ 血量按 `MIDBOSS_HP_FRAC` 压缩 —— 限时战不能照搬"无限时消耗战"的标定。
## ⚠️ 无尽 BOSS **不是**中间 BOSS：它既不限时、也不换掉"击杀直掉法宝"的既有口径。
static func is_mid_boss_wave(w: int) -> bool:
\treturn not GameState.endless and is_boss_wave(w) and not is_final_boss_wave(w)

## BOSS 血量倍率（第 9 轮 · 用户要求「血量随波次成长」）。
##   · 无尽：沿用既有曲线（W10 = 1.0，每深一波 +30%）—— **不动它**。
##   · 标准：最终波 = 1.0（与改动前**完全一致**，W20 的既有平衡不受影响）；
##     中间 BOSS 查 `MIDBOSS_HP_FRAC`，是"随波次成长"的那条腿。
static func boss_hp_scale(w: int) -> float:
\tif GameState.endless:
\t\treturn 1.0 + 0.30 * float(maxi(0, w - 10))
\tif w >= RunRules.wave_total(WAVES_TOTAL):
\t\treturn 1.0
\tvar blk := block_of(w)
\treturn float(MIDBOSS_HP_FRAC[clampi(blk - 1, 0, MIDBOSS_HP_FRAC.size() - 1)])

## 中间 BOSS 的限时时长（秒）。最终 BOSS / 无尽 BOSS 都不走这里（它们不限时）。
static func midboss_duration(w: int) -> float:
\treturn wave_duration(w) * MIDBOSS_TIME_MULT
"""

OLD_CONST = """const WAVES_TOTAL := 20
const BOSS_WAVE := 20
const ENDLESS_MAX_WAVE := 9999   # 无尽模式波次上限（防溢出的护栏值）
const ENEMY_HARD_CAP := 240      # 同屏敌人绝对上限（大规模敌群性能护栏）
"""

NEW_CONST = """const WAVES_TOTAL := 20
const BOSS_WAVE := 20
const ENDLESS_MAX_WAVE := 9999   # 无尽模式波次上限（防溢出的护栏值）
const ENEMY_HARD_CAP := 240      # 同屏敌人绝对上限（大规模敌群性能护栏）

## ---- 中间 BOSS（第 9 轮 · 用户需求 4）----
## 改版后标准局共 5 个 BOSS 波：W4 / W8 / W12 / W16（中间，限时）+ W20（最终，不限时）。
##
## 【为什么中间 BOSS 的血量**不能**按最终 BOSS 的比例缩】
##   最终 BOSS 的 56~90 万血量是按**无限时消耗战**标定的（打多久都行，靠 `dmg_cap_pct`
##   兜住爆发）。而中间 BOSS 必须能在限时内打完 —— 否则「时间到没有击杀则不掉落」
##   会变成常态，法宝盒子永远拿不到，功能等于没做。两者刻意**不共用一条曲线**。
##
## ⚠️ 本表是**首次落地的估价，待墙钟实测校准**。偏肉的症状很好认：
##    「时间到 BOSS 还剩一大半血」。修法是先降本表，**不要去拉长限时** ——
##    限时拉长会让「没击杀就不掉落」这条规则失去意义。
const BOSS_BOX_CHOICES := 3          # 法宝盒子开出的候选数（三选一）

## 中间 BOSS 血量占该 BOSS **基础血量**的比例，下标 = 区块 - 1（W4/W8/W12/W16 → 0..3）。
const MIDBOSS_HP_FRAC := [0.03, 0.07, 0.14, 0.25]

## 中间 BOSS 限时 = 同波普通波时长 × 本倍率。比普通波宽（要边躲弹幕边打），
## 但**必须有**限时 —— 它正是「时间到不掉落」的前提。
const MIDBOSS_TIME_MULT := 2.5
"""

OLD_MOB_RESIST = """static func mob_resist(wave: int, resist_mult: float, block_bias: float = 0.0,
\t\taura: float = 0.0, cap: float = 0.75) -> float:
\tvar w_growth := clampf(float(wave - 1) / RESIST_WAVE_GROWTH_DENOM, 0.0, 1.0)
\treturn clampf(w_growth * resist_mult + block_bias + aura, 0.0, cap)
"""

NEW_MOB_RESIST = """## `zone` = 地形区域加成（第 9 轮 · 需求 4）：怪站在本区地形内且元素与本区相同时由
## `enemy.zone_bonus` 传入。与 block_bias / aura 同一个加法项 —— 因此它**天然受 `cap` 约束**，
## 这正是用户要的「加成不超过上限」（普通怪 0.75、同属 BOSS 0.90）。
## ⚠️ 参数追加在**最后**且带默认值：既有的位置调用（含 5 条冒烟断言）一字不用改。
static func mob_resist(wave: int, resist_mult: float, block_bias: float = 0.0,
\t\taura: float = 0.0, cap: float = 0.75, zone: float = 0.0) -> float:
\tvar w_growth := clampf(float(wave - 1) / RESIST_WAVE_GROWTH_DENOM, 0.0, 1.0)
\treturn clampf(w_growth * resist_mult + block_bias + aura + zone, 0.0, cap)
"""

OLD_AREA = """const AREA_BONUS := 0.10
"""

NEW_AREA = """const AREA_BONUS := 0.10

## ---- 场景属性地形区域（第 9 轮 · 用户需求 4）----
## 每 4 波（= 一个区块）换一片**圆形**地形，属性 = 本区区域元素（`wave_area_element`）。
##   · 玩家站进区内 → 对该元素的**同化度临时 +`TERRAIN_ZONE_BONUS`**；
##   · 区内且元素与本区相同的**怪** → 抗性临时 +同值；
##   · 离区即撤销（进出可逆）→ 它是"站位收益"，不是"进区奖励"。
##
## 【与 `AREA_BONUS` 的分工，刻意并存】`AREA_BONUS` 是**进区首波一次性、永久**的养成轴
##   （选择在哪个区深耕）；本机制是**区块内一片有边界的临时区域**（这四波你要不要站进去）。
##   硬合并会同时破坏「一次性发放的幂等」与「站进去才有用」两条规则。
##
## 【圆心是纯函数】圆心只由 `(玩家元素, 区块号)` 哈希得出，**不用 GameRng** ——
##   读档重进同一波、每日挑战全服，看到的都是同一片区域（与商店/BOSS 的确定性口径一致）。
##   刻意**不使用波次**：同一区块四波位置固定，玩家才能记住"这片地在这"并据此规划走位；
##   每波换位置只会让它退化成随机踩点。
##
## 【上限】玩家侧：增量本身夹到 `TERRAIN_ZONE_CAP`，最终仍受 `_sanitize_stats` 的 assim ≤ 2.0
##   与 `apply_hit_mult` 的逐关系 cap 约束；怪物侧：并入 `mob_resist` 的加法项，受其 cap 约束。
const TERRAIN_ZONE_BONUS := 0.20
const TERRAIN_ZONE_CAP := 0.30
const TERRAIN_ZONE_RADIUS := 260.0

static func terrain_zone_for_wave(player_element: String, wave: int) -> Dictionary:
\tvar elem := wave_area_element(player_element, wave)
\tif elem == "":
\t\treturn {}
\tvar blk := block_of(wave)
\tvar h: int = absi(hash("terrain|%s|%d" % [player_element, blk]))
\tvar ang := float(h % 360) * PI / 180.0
\t# 距场地中心 300~479：既保证玩家出生点（场地正中）**永远不在区内**，
\t# 又保证整片圆都落在世界边界内（479 + 260 < 800）。
\tvar dist := 300.0 + float((h / 360) % 180)
\tvar center := Vector2(WORLD.w, WORLD.h) * 0.5 + Vector2.from_angle(ang) * dist
\treturn {
\t\t"element": elem,
\t\t"center": center,
\t\t"radius": TERRAIN_ZONE_RADIUS,
\t\t"bonus": TERRAIN_ZONE_BONUS,
\t\t"cap": TERRAIN_ZONE_CAP,
\t}
"""


def main():
    ok = apply_file(CFG, [
        (OLD_BOSS_WAVE, NEW_BOSS_WAVE),
        (OLD_CONST, NEW_CONST),
        (OLD_MOB_RESIST, NEW_MOB_RESIST),
        (OLD_AREA, NEW_AREA),
    ], "round9-config")
    if not ok:
        sys.exit(1)
    print("ALL OK")


if __name__ == "__main__":
    main()
