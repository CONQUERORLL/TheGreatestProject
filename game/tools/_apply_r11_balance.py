# -*- coding: utf-8 -*-
"""第 11 轮 · Q1/Q2/Q4：金剑与近战射程道具再平衡 + 阈值制副作用 + 文案/重名。

用户拍板：
  · 金剑 → **只砍数值 + 提品**（不动公式）
  · 副作用 → **阈值制**（单条 ≥20% 或两条合计 ≥30%，且品质 ≤ rare）
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path

TARGET = game_path("scripts", "core", "config.gd")

KNIFE_COMMENT = """\t# ⚠️⚠️ 2026-09-18（第 11 轮）用户反馈：「金剑的加成太离谱，距离加成对金剑的加成太高了，
\t#    搞几关就变的攻击范围很大」。
\t#   查证：**根因是几何**——近战 `reach = range × (1 + melee_range_bonus)`（player.gd:422），
\t#   而扇形 AOE = ½·r²·θ **∝ reach²** → **每 +10% range ≈ +21% 面积**。
\t#   4 张近战 range 道具全叠 = **+110%**（旧：edge+18 / swordmanual+22 / whetstone+35 / swordcase+35）
\t#   → reach 95→199.5、AOE 11,814→**52,098（×4.41）**；再叠铭刻 +12% 就是 ×4.93。
\t#   同期喷火枪堆满 range（+103%）只把 reach 110→223（射程乘算、**splash 不吃 range**）→ AOE 仍 5,027。
\t#   同样「+100% 射程」，一个把面积推到 4.4 倍、一个只是射程 ×2 —— 这才是「被金剑替代」的真机制。
\t# ✅ 修法（用户拍板「**只砍数值 + 提品**，不动公式」）：
\t#   1. 本体：`cd` 0.45→**0.55**（−18% 攻速）、`range` 95→**88**。
\t#      单体 DPS 15.56→12.73；DoT 稳态按 1/cd 算层数 → 也同步下降，合计 19.91→**≈16.3**。
\t#      进化体 `knife_ex` 同步 **cd 0.55 / range 106**（守住「进化 = 基础 2.0×」与面积比 1.69×）。
\t#   2. 4 张近战 range 道具加成量**砍到约 60%** 并**提品**：
\t#      edge +18%→**+11%**（rare→epic）、swordmanual +22%→**+13%**（epic→mythic）、
\t#      whetstone +35%→**+21%**（epic→mythic）、swordcase +35%→**+21%**（epic→mythic）。
\t#      ⚠️ 提到 mythic = 金「**唯一件**」（本局每种最多 1 件）+ 池权重更低 → 双重「更难刷出来」。
\t#   ⚠️ 刻意**没动公式**：改成「加固定 px」能根治雪崩，但会改近战手感，用户选了保守路线。
\t#      所以「堆满仍会雪崩」的形状还在，只是来得更晚、更贵 —— 下次再失衡**先看这一段**。
"""

EDITS = [
    # ---------- Q1/Q2 金剑本体 ----------
    ('\t"knife": { "name": "金剑",',
     KNIFE_COMMENT + '\t"knife": { "name": "金剑",'),
    ('"cd": 0.45, "dmg": 7.0, "range": 95.0, "swing_arc": 2.618',
     '"cd": 0.55, "dmg": 7.0, "range": 88.0, "swing_arc": 2.618'),
    ('"cd": 0.45, "dmg": 14.0, "range": 115.0, "swing_arc": 3.054',
     '"cd": 0.55, "dmg": 14.0, "range": 106.0, "swing_arc": 3.054'),
    ('金剑·进化：reach 115px + 175° 剑域（面积 1.71×）',
     '金剑·进化：reach 106px + 175° 剑域（面积 1.69×）'),

    # ---------- Q2 近战 range 道具：砍到 ~60% + 提品 ----------
    ('{ "id": "edge", "ico": "🗡", "name": "开刃", "desc": "斩击范围 +18%（近战武器）", '
     '"rarity": "rare", "effects": { "melee_range_bonus": 0.18 } }',
     '{ "id": "edge", "ico": "🗡", "name": "开刃", "desc": "斩击范围 +11%（近战武器）", '
     '"rarity": "epic", "effects": { "melee_range_bonus": 0.11 } }'),
    ('"desc": "斩击范围 +22%，暴击伤害 +60（近战构筑）", "rarity": "epic", '
     '"effects": { "melee_range_bonus": 0.22, "crit_mult": 0.60 }',
     '"desc": "斩击范围 +13%，暴击伤害 +60（近战构筑）", "rarity": "mythic", '
     '"effects": { "melee_range_bonus": 0.13, "crit_mult": 0.60 }'),
    ('"desc": "斩击范围 +35%：近战刀光挥得更远，太刀/长剑尤其明显", "price": 58, '
     '"rarity": "epic", "effects": { "melee_range_bonus": 0.35 }',
     '"desc": "斩击范围 +21%：近战刀光挥得更远，太刀/长剑尤其明显", "price": 58, '
     '"rarity": "mythic", "effects": { "melee_range_bonus": 0.21 }'),
    ('"desc": "斩击范围 +35%，暴击率 +3%", "price": 72, "rarity": "epic", '
     '"effects": { "melee_range_bonus": 0.35, "crit_ch": 0.03 }',
     '"desc": "斩击范围 +21%，暴击率 +3%", "price": 72, "rarity": "mythic", '
     '"effects": { "melee_range_bonus": 0.21, "crit_ch": 0.03 }'),

    # ---------- Q4 阈值制副作用：单条 ≥20% 或两条合计 ≥30%，且品质 ≤ rare ----------
    ('"desc": "弹丸射程 +20%（投射武器）", "rarity": "rare", '
     '"effects": { "bullet_range_bonus": 0.20 } }',
     '"desc": "弹丸射程 +20%（投射武器）；代价：攻速 -5%", "rarity": "rare", '
     '"effects": { "bullet_range_bonus": 0.20, "as_mult": -0.05 } }'),
    ('"desc": "子弹速度 +20%，命中更跟手", "rarity": "rare", '
     '"effects": { "bullet_speed_bonus": 0.20 } }',
     '"desc": "子弹速度 +20%，命中更跟手；代价：伤害 -5%", "rarity": "rare", '
     '"effects": { "bullet_speed_bonus": 0.20, "dmg_mult": -0.05 } }'),
    ('"desc": "爆炸范围 +20%（溅射武器：火箭筒 / 冰霜新星 / 震雷法锣…）", "rarity": "rare", '
     '"effects": { "aoe_radius_bonus": 0.20 } }',
     '"desc": "爆炸范围 +20%（溅射武器：火箭筒 / 冰霜新星 / 震雷法锣…）；代价：伤害 -5%", "rarity": "rare", '
     '"effects": { "aoe_radius_bonus": 0.20, "dmg_mult": -0.05 } }'),
    ('"desc": "材料获取 +25%", "price": 32, "rarity": "rare", "effects": { "harvesting": 0.25 } }',
     '"desc": "材料获取 +25%；代价：伤害 -6%", "price": 32, "rarity": "rare", '
     '"effects": { "harvesting": 0.25, "dmg_mult": -0.06 } }'),
    ('"desc": "命中时 20% 概率点燃（伤害随攻击力）", "price": 44, "rarity": "rare", '
     '"effects": { "on_hit_burn": 0.20 } }',
     '"desc": "命中时 20% 概率点燃（伤害随攻击力）；代价：伤害 -4%", "price": 44, "rarity": "rare", '
     '"effects": { "on_hit_burn": 0.20, "dmg_mult": -0.04 } }'),
    ('"desc": "命中时 20% 概率使目标中毒", "price": 44, "rarity": "rare", '
     '"effects": { "on_hit_poison": 0.20 } }',
     '"desc": "命中时 20% 概率使目标中毒；代价：伤害 -4%", "price": 44, "rarity": "rare", '
     '"effects": { "on_hit_poison": 0.20, "dmg_mult": -0.04 } }'),
    ('"desc": "命中时 25% 概率造成流血", "price": 40, "rarity": "rare", '
     '"effects": { "on_hit_bleed": 0.25 } }',
     '"desc": "命中时 25% 概率造成流血；代价：护甲 -1", "price": 40, "rarity": "rare", '
     '"effects": { "on_hit_bleed": 0.25, "armor": -1.0 } }'),
    ('"desc": "投掷物飞行速度 +20%（土质炸弹 / 厚土雷）", "price": 46, "rarity": "rare", '
     '"effects": { "throw_speed_bonus": 0.20 }',
     '"desc": "投掷物飞行速度 +20%（土质炸弹 / 厚土雷）；代价：攻速 -5%", "price": 46, "rarity": "rare", '
     '"effects": { "throw_speed_bonus": 0.20, "as_mult": -0.05 }'),
    ('"desc": "子弹速度 +38%，弹道更直更难被走位躲开", "price": 48, "rarity": "rare", '
     '"effects": { "bullet_speed_bonus": 0.38 }',
     '"desc": "子弹速度 +38%，弹道更直更难被走位躲开；代价：伤害 -6%", "price": 48, "rarity": "rare", '
     '"effects": { "bullet_speed_bonus": 0.38, "dmg_mult": -0.06 }'),
    ('{ "id": "i-venomsac", "ico": "☣", "name": "毒囊", "desc": "爆炸范围 +22%，异常持续时间 +20%", '
     '"price": 44, "rarity": "rare", "effects": { "aoe_radius_bonus": 0.22, "status_dur_mult": 0.20 } }',
     '{ "id": "i-venomsac", "ico": "☣", "name": "毒爆囊", "desc": "爆炸范围 +22%，异常持续时间 +20%；代价：伤害 -5%", '
     '"price": 44, "rarity": "rare", '
     '"effects": { "aoe_radius_bonus": 0.22, "status_dur_mult": 0.20, "dmg_mult": -0.05 } }'),
    ('"desc": "命中时 18% 概率点燃，状态伤害 +20%", "price": 50, "rarity": "rare", '
     '"effects": { "on_hit_burn": 0.18, "status_dmg_mult": 0.20 }',
     '"desc": "命中时 18% 概率点燃，状态伤害 +20%；代价：攻速 -5%", "price": 50, "rarity": "rare", '
     '"effects": { "on_hit_burn": 0.18, "status_dmg_mult": 0.20, "as_mult": -0.05 }'),
    ('"desc": "命中时 18% 概率使目标中毒，异常持续 +20%", "price": 50, "rarity": "rare", '
     '"effects": { "on_hit_poison": 0.18, "status_dur_mult": 0.20 }',
     '"desc": "命中时 18% 概率使目标中毒，异常持续 +20%；代价：攻速 -5%", "price": 50, "rarity": "rare", '
     '"effects": { "on_hit_poison": 0.18, "status_dur_mult": 0.20, "as_mult": -0.05 }'),
    ('"desc": "命中时 20% 概率造成流血，击杀回复 +1.5", "price": 52, "rarity": "rare", '
     '"effects": { "on_hit_bleed": 0.20, "lifesteal": 1.5 }',
     '"desc": "命中时 20% 概率造成流血，击杀回复 +1.5；代价：护甲 -1", "price": 52, "rarity": "rare", '
     '"effects": { "on_hit_bleed": 0.20, "lifesteal": 1.5, "armor": -1.0 }'),
    ('"desc": "濒死时最高 +28% 伤害，闪避 +5%", "price": 54, "rarity": "rare", '
     '"effects": { "low_hp_dmg_bonus": 0.28, "dodge": 0.05 }',
     '"desc": "濒死时最高 +28% 伤害，闪避 +5%；代价：护甲 -1", "price": 54, "rarity": "rare", '
     '"effects": { "low_hp_dmg_bonus": 0.28, "dodge": 0.05, "armor": -1.0 }'),
    ('"desc": "材料获取 +50%，拾取范围 +60", "price": 48, "rarity": "rare", '
     '"effects": { "harvesting": 0.50, "pickup_range": 60.0 }',
     '"desc": "材料获取 +50%，拾取范围 +60；代价：伤害 -8%", "price": 48, "rarity": "rare", '
     '"effects": { "harvesting": 0.50, "pickup_range": 60.0, "dmg_mult": -0.08 }'),

    # ---------- Q4 玄冰类：补「多次获取概率相加」文案 ----------
    ('"desc": "命中时 12% 概率冰冻目标", "price": 58, "rarity": "epic", '
     '"effects": { "on_hit_freeze": 0.12 } }',
     '"desc": "命中时 12% 概率冰冻目标；**重复购买概率相加**（买 2 件 = 24%）", "price": 58, "rarity": "epic", '
     '"effects": { "on_hit_freeze": 0.12 } }'),
    ('"desc": "命中时 12% 概率冻结目标，异常持续 +15%"',
     '"desc": "命中时 12% 概率冻结目标，异常持续 +15%；重复购买概率相加"'),
    ('"desc": "命中时 14% 概率冻结，异常持续 +50%"',
     '"desc": "命中时 14% 概率冻结，异常持续 +50%；重复购买概率相加"'),
    ('"desc": "命中时 10% 概率冻结，异常持续 +45%"',
     '"desc": "命中时 10% 概率冻结，异常持续 +45%；重复获取可叠加（概率相加）"'),

    # ---------- Q4 重名修正（两份清单早已登记这两个「同名不同物」）----------
    ('{ "id": "i-frostcore", "ico": "🧊", "name": "霜核",',
     '{ "id": "i-frostcore", "ico": "🧊", "name": "霜爆核心",'),
    ('/ 霜核（`i-frostcore`）等', '/ 霜爆核心（`i-frostcore`）等'),
]

if not apply_file(TARGET, EDITS, "config-r11"):
    sys.exit(1)
