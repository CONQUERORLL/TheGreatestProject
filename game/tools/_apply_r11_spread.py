# -*- coding: utf-8 -*-
"""第 11 轮 · 用户需求 3：给喷火枪补「攻击范围道具」——高压喷嘴（增距减角）/ 多孔喷嘴（增角减伤）。

背景（用户原话）：
  「喷火枪需要攻击范围道具：高压喷嘴（增距减角）、多孔喷嘴（增角减伤）」
  「喷火枪距离太近、剑能加距离而喷火枪不能，易被金剑替代」

查证后的**真实缺口**：
  · 射程通道其实早就有（`bullet_range_bonus`，喷火枪是默认 `proj_kind="bullet"`，
    `i-longbarrel` +35% 对它是生效的）。它「加不动」的感觉来自**基数太小**：
    110px × (1+35%) = 148px，绝对增量只有 38px，而近战 88 × (1+11%) ≈ 98。
  · 真正**零道具消费**的是 `spread`（扇形随机散布角，`player.gd` 的 `try_fire`）——
    整个内容池里没有任何一件道具能碰它。于是「火焰锥的胖瘦」完全没有构筑维度。

本脚本新增一条**有符号**通道 `proj_spread_mult`：
  `spread_eff = spread_base × clamp(1 + proj_spread_mult, 0.15, 4.0)`
  ⚠️ 它是全表唯一不做 `maxf(0, …)` 的武器加成通道（负 = 收窄）。

三处必须一起改，少一处就是「不报错、只是算错」：
  ① 数据层 `config.gd`（道具 + 标签 + 相关度 + 印记）
  ② 通道层 `registry.gd`（STAT_LIMITS / EFFECT_LIMITS —— 不在 EFFECT_LIMITS 里，
     `_valid_effects` 会**直接拒登整条道具**，且只 push_warning）
  ③ 消费层 `player.gd`（stats 初值 / 净化 / 运行时配置 / 火焰锥视觉同源）+ 存档净化副本
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path

CFG = game_path("scripts", "core", "config.gd")
REG = game_path("scripts", "core", "registry.gd")
P1 = game_path("scripts", "characters", "player.gd")
TXT = game_path("scripts", "ui", "entry_text.gd")
SAV = game_path("scripts", "core", "save_run.gd")
SMK = game_path("tests", "smoke_test.gd")

# ============================================================
# config.gd —— 数据层
# ============================================================
CFG_EDITS = [
    # ---- ① 两件喷嘴道具：插在「武器向道具」组的铳匠长管之后 ----
    ('''\t{ "id": "i-longbarrel", "ico": "🔩", "name": "铳匠长管", "desc": "弹丸射程 +35%：火焰喷射距离、弹药飞行距离同步拉长", "price": 62, "rarity": "epic", "effects": { "bullet_range_bonus": 0.35 } },''',
     '''\t{ "id": "i-longbarrel", "ico": "🔩", "name": "铳匠长管", "desc": "弹丸射程 +35%：火焰喷射距离、弹药飞行距离同步拉长", "price": 62, "rarity": "epic", "effects": { "bullet_range_bonus": 0.35 } },
\t# ---- 喷射散布角通道（第 11 轮新增）：喷嘴类道具 ----
\t# 用户反馈喷火枪「加不动距离、容易被金剑替代」。查证：射程通道本来就有
\t# （`bullet_range_bonus`），真正的空白是 **`spread`（扇形随机散布角）零道具消费** ——
\t# 火焰锥的「胖瘦」此前完全没有构筑维度。这两件把它补上，一收一放：
\t#   · 高压喷嘴：再加 25% 射程，同时把锥体**收窄 40%** → 单点更集中、更像一束火矛
\t#   · 多孔喷嘴：锥体**扩散 60%**（覆盖面更广、更容易同时撩到多只），代价是伤害 -10%
\t# ⚠️ `proj_spread_mult` 是**有符号**的（负 = 收窄），与其余武器加成通道不同。
\t# ⚠️ 品质口径沿用「阈值制副作用」：`i-multihole` 是 rare 且单条 +60% → 必须带代价；
\t#    `i-highpressure` 是 epic，其内部取舍（覆盖角变窄）已写在 desc 里，不另加代价。
\t{ "id": "i-highpressure", "ico": "🔻", "name": "高压喷嘴", "desc": "喷射距离 +25%、火焰锥收窄 40%（喷火枪类）：单点更集中；代价：同时覆盖的角度变窄", "price": 64, "rarity": "epic", "effects": { "bullet_range_bonus": 0.25, "proj_spread_mult": -0.40 } },
\t{ "id": "i-multihole", "ico": "🔱", "name": "多孔喷嘴", "desc": "火焰锥扩散 60%（喷火枪类）：覆盖面更广、更易同时灼烧多只；代价：伤害 -10%", "price": 46, "rarity": "rare", "effects": { "proj_spread_mult": 0.60, "dmg_mult": -0.10 } },'''),
    # ---- ② 效果键 → 标签 ----
    ('''\t\t"aoe_radius_bonus":
\t\t\tout.append("aoe")''',
     '''\t\t"proj_spread_mult":
\t\t\t# 第 11 轮：喷射散布角。只对「有 spread 的武器」有意义（当前仅喷火枪一族），
\t\t\t# 与 range（飞多远）/ aoe（爆多大）都不同族，单列一个标签。
\t\t\tout.append("spread")
\t\t"aoe_radius_bonus":
\t\t\tout.append("aoe")'''),
    # ---- ③ 效果键 → 印记 ----
    ('''\t\t"bullet_range_bonus": "swift",
\t\t"throw_speed_bonus": "blast",''',
     '''\t\t"bullet_range_bonus": "swift",
\t\t"proj_spread_mult": "swift",
\t\t"throw_speed_bonus": "blast",'''),
    # ---- ④ 相关度闸门：文档注释 + 三个改动点 ----
    ('''##   - aoe_radius_bonus 需要至少一把带溅射（splash）的武器
## 其余通用属性（伤害/攻速/生命/暴击等）无条件保留。''',
     '''##   - aoe_radius_bonus 需要至少一把带溅射（splash）的武器
##   - proj_spread_mult 需要至少一把**带喷射散布**（spread>0）的武器（第 11 轮，当前仅喷火枪一族）
## 其余通用属性（伤害/攻速/生命/暴击等）无条件保留。'''),
    ('''\tvar has_bullet := false
\tvar has_thrown := false''',
     '''\tvar has_bullet := false
\tvar has_thrown := false
\tvar has_spread := false   # 第 11 轮：有喷射散布的武器（喷嘴类道具只对它有意义）'''),
    ('''\t\tif float(wcfg.get("splash", 0.0)) > 0.0:
\t\t\thas_aoe = true''',
     '''\t\tif float(wcfg.get("splash", 0.0)) > 0.0:
\t\t\thas_aoe = true
\t\tif float(wcfg.get("spread", 0.0)) > 0.0:
\t\t\thas_spread = true'''),
    ('''\t\t\t"aoe_radius_bonus":
\t\t\t\tif not has_aoe:
\t\t\t\t\treturn false
\treturn true''',
     '''\t\t\t"aoe_radius_bonus":
\t\t\t\tif not has_aoe:
\t\t\t\t\treturn false
\t\t\t"proj_spread_mult":
\t\t\t\tif not has_spread:
\t\t\t\t\treturn false
\treturn true'''),
]

# ============================================================
# registry.gd —— 通道层（不进这张表 = 整条道具被静默拒登）
# ============================================================
REG_EDITS = [
    ('''\t"melee_range_bonus": Vector2(0.0, 10.0), "aoe_radius_bonus": Vector2(0.0, 10.0),''',
     '''\t"melee_range_bonus": Vector2(0.0, 10.0), "aoe_radius_bonus": Vector2(0.0, 10.0),
\t# 第 11 轮：喷射散布角倍率增量。⚠️ **可为负**（负 = 收窄）——
\t#    这是全表唯一下限不是 0 的武器加成通道，别照抄上面的 `maxf(0.0, …)`。
\t"proj_spread_mult": Vector2(-0.8, 4.0),'''),
    ('''\t"aoe_radius_bonus": 10.0, "low_hp_dmg_bonus": 5.0, "momentum_dmg_bonus": 5.0,''',
     '''\t"aoe_radius_bonus": 10.0, "low_hp_dmg_bonus": 5.0, "momentum_dmg_bonus": 5.0,
\t"proj_spread_mult": 0.8,   # 第 11 轮：单条喷嘴道具的散布改动上限（绝对值）'''),
]

# ============================================================
# player.gd —— 消费层
# ============================================================
P1_EDITS = [
    # ---- ① stats 初值 ----
    ('''\t\t"melee_range_bonus": 0.0,    # 近战斩击半径
\t\t"aoe_radius_bonus": 0.0,     # 爆炸 / 溅射半径''',
     '''\t\t"melee_range_bonus": 0.0,    # 近战斩击半径
\t\t"aoe_radius_bonus": 0.0,     # 爆炸 / 溅射半径
\t\t# ╭─ 2026-09-18（第 11 轮）喷射散布角 ─╮
\t\t# 用户反馈「喷火枪需要攻击范围道具：高压喷嘴（增距减角）、多孔喷嘴（增角减伤）」。
\t\t# 射程通道本来就有（`bullet_range_bonus` 对喷火枪生效），真正零消费的是
\t\t# **`spread`（扇形随机散布角）** —— 火焰锥的胖瘦此前没有任何构筑维度。
\t\t# ⚠️ **有符号**（负 = 收窄），是本文件唯一不做 `maxf(0, …)` 的武器加成键。
\t\t"proj_spread_mult": 0.0,     # 喷射散布角倍率增量（负=收窄 / 正=扩散）
\t\t# ╰──────────────────────────────╯'''),
    # ---- ② 净化：有符号，夹在 (-0.8, 4.0) ----
    ('''\tstats.aoe_radius_bonus = maxf(0.0, float(stats.aoe_radius_bonus))''',
     '''\tstats.aoe_radius_bonus = maxf(0.0, float(stats.aoe_radius_bonus))
\t# 第 11 轮：喷射散布角 —— ⚠️ **有符号**，不能套上面的 `maxf(0.0, …)`（会把收窄抹平）。
\t# 用 `.get()` 兜旧档：老存档的 stats 里没有这个键（`stats.k` 读缺失键会拿到 null）。
\tstats["proj_spread_mult"] = clampf(float(stats.get("proj_spread_mult", 0.0)), -0.8, 4.0)'''),
    # ---- ③ 运行时配置：加散布缩放 ----
    ('''\tvar ab := float(stats.aoe_radius_bonus)
\tif sb <= 0.0 and rb <= 0.0 and ab <= 0.0:
\t\treturn c''',
     '''\tvar ab := float(stats.aoe_radius_bonus)
\t# 第 11 轮：喷射散布角（喷嘴类道具）。**有符号** —— 负 = 收窄、正 = 扩散。
\tvar sm := float(stats.get("proj_spread_mult", 0.0))
\tif sb <= 0.0 and rb <= 0.0 and ab <= 0.0 and is_zero_approx(sm):
\t\treturn c'''),
    ('''\tif ab > 0.0 and c.has("splash"):
\t\twc["splash"] = float(c.get("splash", 0.0)) * (1.0 + ab)
\treturn wc''',
     '''\tif ab > 0.0 and c.has("splash"):
\t\twc["splash"] = float(c.get("splash", 0.0)) * (1.0 + ab)
\tif not is_zero_approx(sm) and c.has("spread"):
\t\twc["spread"] = float(c.get("spread", 0.0)) * proj_spread_scale()
\treturn wc


## 喷射散布倍率（第 11 轮）：`1 + proj_spread_mult`。
## 下限 0.15 = 防止叠满后变成「0 度雷射」（散布角归零就不叫喷射了）；
## 上限 4.0 = 防止叠满后变成纯随机乱射（那样连索敌都没意义了）。
## ⚠️ **火焰锥的视觉宽度必须同源调用它**（见 `_ignite_flame_jet`）——
##    表现与判定分家的后果就是用户第 8 轮报的「喷火器范围好像有问题」。
func proj_spread_scale() -> float:
\treturn clampf(1.0 + float(stats.get("proj_spread_mult", 0.0)), 0.15, 4.0)'''),
    # ---- ④ 开火：散布角必须读 wc（运行时配置），读 c 等于道具失效 ----
    ('''\t\tvar spread := maxf(0.0, float(c.get("spread", 0.0)))''',
     '''\t\t# ⚠️ 散布角必须读 **wc**（叠加了道具的运行时配置）而不是 c（原始数值表）——
\t\t#    喷嘴类道具只改 `wc.spread`，读 c 就等于道具静默失效（不报错、只是没效果）。
\t\tvar spread := maxf(0.0, float(wc.get("spread", 0.0)))'''),
    # ---- ⑤ 火焰锥视觉宽度同源 ----
    ('''\tvar eff := reach + float(wc.get("splash", 0.0))
\t_ensure_flame_jet().ignite(ang, maxf(20.0, eff - 18.0), 26.0)''',
     '''\tvar eff := reach + float(wc.get("splash", 0.0))
\t# ⚠️ 第 11 轮：锥体末端宽度**随喷射散布角同步缩放** —— 喷嘴改的是判定散布，
\t#    视觉不同步就又变成「看到的 ≠ 打到的」（第 8 轮刚修过同一类问题）。
\tvar cone_w := 26.0 * proj_spread_scale()
\t_ensure_flame_jet().ignite(ang, maxf(20.0, eff - 18.0), cone_w)'''),
]

# ============================================================
# entry_text.gd / save_run.gd —— 展示与存档净化（两份 _sanitize_stats 必须同步）
# ============================================================
TXT_EDITS = [
    ('''\t\t\t"bullet_range_bonus": out.append("弹丸射程 +%d%%（弹幕武器）" % roundi(v * 100.0))''',
     '''\t\t\t"bullet_range_bonus": out.append("弹丸射程 +%d%%（弹幕武器）" % roundi(v * 100.0))
\t\t\t# 第 11 轮：散布角是**有符号**的，正负要分别读得懂（扩散 / 收窄）
\t\t\t"proj_spread_mult": out.append("喷射散布角 %s%d%%（喷火枪类）"
\t\t\t\t% ["扩散 " if v > 0.0 else "收窄 ", roundi(absf(v) * 100.0)])'''),
]
SAV_EDITS = [
    ('''\tstats.throw_speed_bonus = maxf(0.0, float(stats.throw_speed_bonus))
\tstats.throw_range_bonus = maxf(0.0, float(stats.throw_range_bonus))''',
     '''\tstats.throw_speed_bonus = maxf(0.0, float(stats.throw_speed_bonus))
\tstats.throw_range_bonus = maxf(0.0, float(stats.throw_range_bonus))
\t# 第 11 轮：喷射散布角 —— 与 player._sanitize_stats 保持一致的**副本**。
\t# ⚠️ 这一键是**有符号**的（负 = 收窄），不能抄上面的 `maxf(0.0, …)`：
\t#    抹平负值 = 玩家买的「高压喷嘴」读档后静默消失（不报错，只是少一截）。
\tstats["proj_spread_mult"] = clampf(float(stats.get("proj_spread_mult", 0.0)), -0.8, 4.0)'''),
]

# ============================================================
# smoke_test.gd —— 消费点断言（改完必须能证明「有人读」）
# ============================================================
CHK_FUNC = '''## 第 11 轮：喷射散布角通道（喷嘴类道具）。
## 加「新字段」的老坑是**零消费点**（`boss_hp_scale` 那次），所以三侧一起断言：
##   ① 道具真的注册进来（不在 EFFECT_LIMITS 的键会让 registry 整条拒登，只 push_warning）
##   ② 通道真的被 `_weapon_runtime_cfg` 消费，且 0 值时**原样复用原字典**（反向对照）
##   ③ 表现层同源：火焰锥宽度随同一倍率缩放（否则就是「看到的 ≠ 打到的」）
##   + 相关度闸门两侧都测（有喷射武器才刷、没有就别刷）
func _check_spread_channel() -> void:
\tvar ids := ["i-highpressure", "i-multihole"]
\tfor iid in ids:
\t\tif not Registry.items.has(iid):
\t\t\t_fail("第11轮：喷嘴道具 %s 未注册（`proj_spread_mult` 不在 EFFECT_LIMITS 会整条被拒登）" % iid)
\t\t\treturn
\t\tif not Registry.items[iid].get("effects", {}).has("proj_spread_mult"):
\t\t\t_fail("第11轮：喷嘴道具 %s 没有 proj_spread_mult 效果" % iid)
\t\t\treturn
\t# 反向对照：两件喷嘴方向必须相反 —— 否则「收窄 / 扩散」只有一头能用，
\t# 而只测正向的话，把两件都写成 +60% 也会判绿。
\tvar hi := float(Registry.items["i-highpressure"].effects.proj_spread_mult)
\tvar mh := float(Registry.items["i-multihole"].effects.proj_spread_mult)
\tif not (hi < 0.0 and mh > 0.0):
\t\t_fail("第11轮：两件喷嘴方向必须相反（高压=%.2f / 多孔=%.2f）" % [hi, mh])
\t\treturn
\t# ② 消费点前置：内置武器里必须**存在**带 spread 的，否则通道写了没人吃
\tvar spread_wid := ""
\tfor wid in Config.WEAPONS:
\t\tif float(Config.WEAPONS[wid].get("spread", 0.0)) > 0.0:
\t\t\tspread_wid = String(wid)
\t\t\tbreak
\tif spread_wid == "":
\t\t_fail("第11轮：内置武器里没有带 spread 的 —— proj_spread_mult 零消费点")
\t\treturn
\tvar p: Node2D = _main.get_node("Player")
\tvar cfg: Dictionary = Registry.weapons[spread_wid]
\tvar base_spread := float(cfg.get("spread", 0.0))
\tvar old_v := float(p.stats.get("proj_spread_mult", 0.0))
\t# 反向对照：0 值必须原样复用原字典（`_weapon_runtime_cfg` 的早退约定）
\tp.stats["proj_spread_mult"] = 0.0
\tif p._weapon_runtime_cfg(cfg) != cfg:
\t\t_fail("第11轮：proj_spread_mult = 0 时不该 duplicate 武器字典")
\t\tp.stats["proj_spread_mult"] = old_v
\t\treturn
\tif not is_equal_approx(float(p._weapon_runtime_cfg(cfg).get("spread", 0.0)), base_spread):
\t\t_fail("第11轮：无加成时 spread 被改动（应恒为 %.4f）" % base_spread)
\t\tp.stats["proj_spread_mult"] = old_v
\t\treturn
\t# 正向：收窄 / 扩散都必须真的改到 spread，且严格等于 base × (1+m)
\tp.stats["proj_spread_mult"] = hi
\tvar got_hi := float(p._weapon_runtime_cfg(cfg).get("spread", 0.0))
\tp.stats["proj_spread_mult"] = mh
\tvar got_mh := float(p._weapon_runtime_cfg(cfg).get("spread", 0.0))
\tif not (got_hi < base_spread and got_mh > base_spread):
\t\t_fail("第11轮：喷嘴没改到 spread（base=%.4f 收窄=%.4f 扩散=%.4f）"
\t\t\t% [base_spread, got_hi, got_mh])
\t\tp.stats["proj_spread_mult"] = old_v
\t\treturn
\tif absf(got_hi - base_spread * (1.0 + hi)) > 1e-6 \\
\t\t\tor absf(got_mh - base_spread * (1.0 + mh)) > 1e-6:
\t\t_fail("第11轮：spread 缩放与 (1 + proj_spread_mult) 不一致")
\t\tp.stats["proj_spread_mult"] = old_v
\t\treturn
\t# ③ 表现层同源：火焰锥末端宽度必须跟着同一倍率走
\tp.stats["proj_spread_mult"] = 0.0
\tp._ignite_flame_jet(cfg, 0.0)
\tvar w0 := float(p._ensure_flame_jet().width)
\tp.stats["proj_spread_mult"] = mh
\tp._ignite_flame_jet(cfg, 0.0)
\tvar w1 := float(p._ensure_flame_jet().width)
\tp.stats["proj_spread_mult"] = old_v
\tp._sanitize_stats()
\tif w0 <= 0.0 or absf(w1 - w0 * (1.0 + mh)) > 1e-4:
\t\t_fail("第11轮：火焰锥宽度没跟着 proj_spread_mult 缩放（%.2f → %.2f）" % [w0, w1])
\t\treturn
\t# 相关度闸门两侧都测：用**非喷射弹幕武器**做反向对照（这样其它键都过得去，
\t# 只有 proj_spread_mult 那一关该拦下它）
\tif Config.entry_weapon_relevant(Registry.items["i-highpressure"], [{ "type": "frost_staff" }]):
\t\t_fail("第11轮：没有喷射武器时仍判定喷嘴相关（会给一屋子废属性）")
\t\treturn
\tif not Config.entry_weapon_relevant(Registry.items["i-highpressure"], [{ "type": spread_wid }]):
\t\t_fail("第11轮：持有喷射武器时喷嘴却被判无关")
\t\treturn
\tprint("SMOKE: 第11轮 喷射散布角通道（喷嘴道具注册 / 1±proj_spread_mult 缩放 / 火焰锥同源 / 相关度闸门）OK")


'''

SMK_EDITS = [
    ('''\t_check_reach_safety()
\t_check_balance_log()''',
     '''\t_check_reach_safety()
\t_check_spread_channel()
\t_check_balance_log()'''),
    ('''\tprint("SMOKE: S8 综合战力（reach / AOE 面积 / %d 只内置远程怪 keep_dist %.0f~%.0f）OK"
\t\t% [n_shooter, shooter_min, shooter_max])


## 单把武器在「白板 + 单体 + 非暴击」下的**稳态 DoT DPS**。''',
     '''\tprint("SMOKE: S8 综合战力（reach / AOE 面积 / %d 只内置远程怪 keep_dist %.0f~%.0f）OK"
\t\t% [n_shooter, shooter_min, shooter_max])


''' + CHK_FUNC + '''## 单把武器在「白板 + 单体 + 非暴击」下的**稳态 DoT DPS**。'''),
]

ok = apply_file(CFG, CFG_EDITS, "config-r11-spread")
ok = apply_file(REG, REG_EDITS, "registry-r11-spread") and ok
ok = apply_file(P1, P1_EDITS, "player-r11-spread") and ok
ok = apply_file(TXT, TXT_EDITS, "entrytext-r11-spread") and ok
ok = apply_file(SAV, SAV_EDITS, "saverun-r11-spread") and ok
ok = apply_file(SMK, SMK_EDITS, "smoke-r11-spread") and ok
if not ok:
    sys.exit(1)
