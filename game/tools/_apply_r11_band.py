# -*- coding: utf-8 -*-
"""第 11 轮 · 用户需求 7：分段难度曲线 + 波段怪构成。

用户原话：
  「难度曲线分段计划：W1-4 难、W4-8 易、W10-12 远程多、W12-16 小精英、W16-20 渐肉」
经确认口径：**分段 + 波段怪构成都做**（不是只调 HP 曲线）。

探针实测（`tests/_probe_band.tscn`）拿到的两条硬事实，决定了实现形态：
  ① `block_of` 的区块划分 = **W1-4 / W5-8 / W9-12 / W13-16 / W17-20**，
     与用户要的五段**天然一一对应** → 波段直接绑区块，不另造一套分界。
  ② 冒烟钉死了「**区块内出怪池完全一致**」这条不变量（W10 == W11 必须成立、
     W8 ≠ W9 必须成立，判据见 `smoke_test.gd:_check_element_engine`）。
     ⇒ 波段倍率**只能按区块给常量**，任何逐波变化的写法都会破坏它。

实现：
  · 难度曲线：控制点 + 线性插值（`WAVE_HP_CURVE` / `WAVE_DMG_CURVE`）。
    端点保持（W1 = 1.0、W20 与改动前基本持平），把「难 / 易」做成**曲线内部的重新分配** ——
    区块 1 每波增量最陡、区块 2 最平，这才叫「先难后易」而不是「整体调高」。
  · 波段构成：`WAVE_BAND_WEIGHTS[区块]` 给出 `ranged / elite / trash` 三个倍率，
    `_apply_band_weights` 按名单给权重打折或加权。**只改权重、不改条目集合** ——
    否则「区块 5 必须含全部阵营怪」那条断言会挂。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path

CFG = game_path("scripts", "core", "config.gd")
SMK = game_path("tests", "smoke_test.gd")

# ============================================================
# ① 难度曲线：控制点 + 线性插值
# ============================================================
CURVE_OLD = '''static func wave_hp_scale(w: int) -> float:
\treturn 1.0 + 0.30 * (w - 1)

static func wave_dmg_scale(w: int) -> float:
\treturn 1.0 + 0.18 * (w - 1)'''

CURVE_NEW = '''## ---- 分段难度曲线（第 11 轮 · 用户需求 7）----
## 用户原话：「难度曲线分段计划：W1-4 难、W4-8 易、W10-12 远程多、W12-16 小精英、W16-20 渐肉」。
##
## 形态选**控制点 + 线性插值**而不是继续叠系数：分段曲线的全部意义在「哪一段陡、哪一段平」，
## 控制点把这件事写成可读的一张表，斜率一眼看得出来；写成 `1 + a(w-1) + b·max(0,w-4)…`
## 就没人能再核对它。
##
## ⚠️ 控制点与区块边界**对齐**（W1/4/8/12/16/20）—— 区块划分正是
##    W1-4 / W5-8 / W9-12 / W13-16 / W17-20（`block_of`），与用户要的五段天然一一对应。
##    对齐之后「这一段的难度斜率」和「这一段的怪构成」说的是同一件事。
##
## ⚠️ **端点刻意不动**：W1 = 1.0（开局基准）、W20 与旧的线性公式基本持平
##    （HP 6.70 / DMG 4.42）—— 「难 / 易」是**曲线内部的重新分配**，不是整体调高。
##    否则等于把整局难度抬了一档，而用户要的是节奏变化。
##
## 各段斜率（HP，每波增量）：W1→4 **0.383**（难）｜W4→8 0.175（易）｜
##                          W8→12 0.313｜W12→16 0.338（小精英）｜W16→20 0.313（渐肉 + 构成变肉）
const WAVE_HP_CURVE := [
\t[1, 1.00], [4, 2.15], [8, 2.85], [12, 4.10], [16, 5.45], [20, 6.70],
]
const WAVE_DMG_CURVE := [
\t[1, 1.00], [4, 1.60], [8, 2.05], [12, 2.90], [16, 3.70], [20, 4.42],
]

## 控制点查表 + 波间线性插值。越界按端点夹取（无尽局 W21+ 沿用末段斜率继续涨，
## 见下面的 `_curve_slope` 分支）。
## 纯函数：只读常量，无任何运行局状态 —— 冒烟 / 图鉴 / 存档校验都直接调它。
static func curve_at(points: Array, w: int) -> float:
\tvar wave := maxi(1, w)
\tvar first: Array = points[0]
\tif wave <= int(first[0]):
\t\treturn float(first[1])
\tfor i in range(1, points.size()):
\t\tvar lo: Array = points[i - 1]
\t\tvar hi: Array = points[i]
\t\tif wave <= int(hi[0]):
\t\t\tvar span := maxf(1.0, float(int(hi[0]) - int(lo[0])))
\t\t\tvar t := float(wave - int(lo[0])) / span
\t\t\treturn lerpf(float(lo[1]), float(hi[1]), t)
\t# 超出最后一个控制点：按**末段斜率**外推（无尽局靠这条继续变难，而不是撞上限）
\tvar last: Array = points[points.size() - 1]
\tvar prev: Array = points[points.size() - 2]
\tvar last_span := maxf(1.0, float(int(last[0]) - int(prev[0])))
\tvar slope := (float(last[1]) - float(prev[1])) / last_span
\treturn float(last[1]) + slope * float(wave - int(last[0]))


static func wave_hp_scale(w: int) -> float:
\treturn curve_at(WAVE_HP_CURVE, w)

static func wave_dmg_scale(w: int) -> float:
\treturn curve_at(WAVE_DMG_CURVE, w)'''

# ============================================================
# ② 波段怪构成：名单 + 每区块倍率
# ============================================================
BAND_CONST_OLD = '''const ELEMENT_MOB_BLOCK_WEIGHT := [0.0, 0.03, 0.04, 0.05, 0.05, 0.06]'''

BAND_CONST_NEW = '''const ELEMENT_MOB_BLOCK_WEIGHT := [0.0, 0.03, 0.04, 0.05, 0.05, 0.06]

## ---- 波段怪构成（第 11 轮 · 用户需求 7）----
## 用户原话里的三段构成要求：「W10-12 远程多」「W12-16 小精英」「W16-20 渐肉」。
##
## ⚠️ 倍率必须**按区块**给常量，不能逐波变化：冒烟钉死了「区块内出怪池完全一致」
##    （W10 == W11 必须成立、W8 ≠ W9 必须成立，见 `_check_element_engine`）。
##    区块划分（`block_of`）= W1-4 / W5-8 / W9-12 / W13-16 / W17-20，与用户要的五段一一对应，
##    所以「按区块给」不但合规，还正好是用户要的分段。
##
## 三张名单**必须两两不相交**：同一只怪同时命中两张名单会吃到两次倍率
##    （典型症状是「小精英」段里远程精英被平方放大）。冒烟有断言守住。
##
## ⚠️ 名单是**手写**的（`wave_composition` 是纯波次函数，不能去读 `Registry.enemies` 的 ai ——
##    那会让图鉴 / 存档校验这些调用点依赖注册表就绪）。防漂移靠冒烟：
##    断言「Registry 里所有 ai=="shooter" 的内置怪都在 `BAND_RANGED_MOB_IDS` 里」
##    且「名单里的 id 都存在」—— 两边任一侧漏了就红。

## 远程怪（`ai == "shooter"`，6 只，`keep_dist` 270~320 —— 见 `_check_reach_safety`）
const BAND_RANGED_MOB_IDS := ["shooter", "wizard", "fire_caster", "fire_shaman",
\t"water_nymph", "ice_witch"]
## 精英怪：高生命 / 高护甲的「硬目标」（`guard` 120 / `stone_titan` 140 / `earth_bulwark` 80 …）
const BAND_ELITE_MOB_IDS := ["tank", "guard", "stone_titan", "earth_bulwark",
\t"earth_golem", "metal_puppet", "metal_guard"]
## 杂兵：数量型，构成变「精英化」时要把它们的份额让出来
const BAND_TRASH_MOB_IDS := ["grunt", "swarm", "runner", "bomber", "shadow",
\t"wood_sprite", "fire_imp", "vine_beast", "blade_monk", "wood_healer", "water_splitter"]

## 下标 = 区块号（1 起）。空字典 = 该区块不做构成偏移。
##   · 区块 1（W1-4）**难**：难度全交给 HP/DMG 曲线的前段陡升 ——
##     开局武器只有 95px 近战，构成上再堆远程会把新手直接卡死（首杀窗口本就 16s）。
##   · 区块 2（W5-8）**易**：曲线回落，构成也不加压 —— 这是玩家把构筑搭起来的窗口。
##   · 区块 3（W9-12）**远程多**：远程权重 ×2.2（占比约 21% → 37%）。
##   · 区块 4（W13-16）**小精英**：精英 ×2.0、杂兵 ×0.70 —— 两头都动，
##     否则「全都乘 2」看起来也像生效了（冒烟用**份额**断言，正是一对反向对照）。
##   · 区块 5（W17-20）**渐肉**：精英 ×1.7、杂兵 ×0.85，配合曲线末段继续涨。
const WAVE_BAND_WEIGHTS := [
\t{},
\t{},
\t{ "ranged": 2.2 },
\t{ "elite": 2.0, "trash": 0.70 },
\t{ "elite": 1.7, "trash": 0.85 },
]

## 给一张出怪池按波段倍率改写权重。**只改 `w`、不改条目集合** ——
## 「区块 5 必须含全部阵营怪」那条断言靠条目集合，动集合会挂。
## 未命中任何名单的 id（mod 新加的敌人）一律保持原权重，不被静默改动。
static func _apply_band_weights(pool: Array, block: int) -> Array:
\tvar b := clampi(block, 1, WAVE_BAND_WEIGHTS.size())
\tvar band: Dictionary = WAVE_BAND_WEIGHTS[b - 1]
\tif band.is_empty():
\t\treturn pool
\tvar out: Array = []
\tfor e in pool:
\t\tvar d: Dictionary = (e as Dictionary).duplicate()
\t\tvar mid := String(d.get("item", ""))
\t\tvar mult := 1.0
\t\tif BAND_RANGED_MOB_IDS.has(mid):
\t\t\tmult *= float(band.get("ranged", 1.0))
\t\tif BAND_ELITE_MOB_IDS.has(mid):
\t\t\tmult *= float(band.get("elite", 1.0))
\t\tif BAND_TRASH_MOB_IDS.has(mid):
\t\t\tmult *= float(band.get("trash", 1.0))
\t\tif not is_equal_approx(mult, 1.0):
\t\t\td["w"] = float(d.get("w", 0.0)) * mult
\t\tout.append(d)
\treturn out'''

# ============================================================
# ③ 接进出怪路径
# ============================================================
WIRE_OLD = '''\tfor mid in ids:
\t\tout.append({ "item": String(mid), "w": ew })
\t# ⚠️ 「W2 白名单 ∩ 闸门」可能为空（简单档区块 1 只放「我克」）：本波就不出元素怪，'''

WIRE_NEW = '''\tfor mid in ids:
\t\tout.append({ "item": String(mid), "w": ew })
\t# 第四层：波段怪构成（第 11 轮 · 用户需求 7）。
\t# 放在闸门**之前**（闸门只按元素整条剔除、不动权重，两处顺序等价）——
\t# 这样本函数的输入永远是完整的四层池，便于断言「只改权重不改条目集合」。
\tout = _apply_band_weights(out, block)
\t# ⚠️ 「W2 白名单 ∩ 闸门」可能为空（简单档区块 1 只放「我克」）：本波就不出元素怪，'''

CFG_EDITS = [
    (CURVE_OLD, CURVE_NEW),
    (BAND_CONST_OLD, BAND_CONST_NEW),
    (WIRE_OLD, WIRE_NEW),
]

# ============================================================
# ④ 冒烟断言
# ============================================================
SMK_CHK = '''## 第 11 轮 · 用户需求 7：分段难度曲线 + 波段怪构成。
## 三条链路各测正向与反向：
##   ① 曲线：端点不漂移 + 单调不减 + 「先难后易 / 渐肉」真的体现在**斜率**上
##   ② 构成：远程段远程份额涨、精英段精英份额涨**且**杂兵份额跌（两头都断言，
##     否则「全都乘 2」这种错实现照样判绿）
##   ③ 名单防漂移：与 `Registry` 的 `ai=="shooter"` 双向核对 + 三张名单两两不相交
func _check_wave_bands() -> void:
\t# ---- ① 曲线 ----
\tvar prev_hp := 0.0
\tfor w in range(1, Config.WAVES_TOTAL + 1):
\t\tvar hp := Config.wave_hp_scale(w)
\t\tvar dm := Config.wave_dmg_scale(w)
\t\tif hp < prev_hp - 1e-6:
\t\t\t_fail("难度曲线非单调：W%d HP 倍率 %.3f 低于 W%d 的 %.3f" % [w, hp, w - 1, prev_hp])
\t\t\treturn
\t\tif hp <= 0.0 or dm <= 0.0:
\t\t\t_fail("难度曲线出现非正倍率（W%d：HP %.3f / DMG %.3f）" % [w, hp, dm])
\t\t\treturn
\t\tprev_hp = hp
\tif not is_equal_approx(Config.wave_hp_scale(1), 1.0) \\
\t\t\tor not is_equal_approx(Config.wave_dmg_scale(1), 1.0):
\t\t_fail("W1 难度倍率必须恒为 1.0（开局基准，改动它会连坐首杀窗口）")
\t\treturn
\t# 端点不许失控漂移：W20 落在合理带内即可，不写死精确值（那是设计值不是实现细节）
\tvar hp20 := Config.wave_hp_scale(Config.WAVES_TOTAL)
\tif hp20 < 6.0 or hp20 > 7.5:
\t\t_fail("W20 HP 倍率 %.2f 超出合理带 [6.0, 7.5] —— 分段改动把端点带跑了" % hp20)
\t\treturn
\t# 「先难后易」：区块 1（W1-4）的每波增量必须**严格大于**区块 2（W4-8）的。
\t# 这是用户需求的直接翻译；只断言「W20 变大」的话，整条曲线抬高也能过。
\tvar slope1 := (Config.wave_hp_scale(4) - Config.wave_hp_scale(1)) / 3.0
\tvar slope2 := (Config.wave_hp_scale(8) - Config.wave_hp_scale(4)) / 4.0
\tif slope1 <= slope2:
\t\t_fail("「W1-4 难 / W4-8 易」没体现：区块1 斜率 %.3f 未大于区块2 的 %.3f"
\t\t\t% [slope1, slope2])
\t\treturn
\t# 「渐肉」：末段（W16-20）斜率必须 ≥ 区块 2（易）—— 否则后段成了第二个休息区
\tvar slope5 := (Config.wave_hp_scale(20) - Config.wave_hp_scale(16)) / 4.0
\tif slope5 < slope2:
\t\t_fail("「W16-20 渐肉」没体现：末段斜率 %.3f 低于区块2 的 %.3f" % [slope5, slope2])
\t\treturn
\t# ---- ③ 名单防漂移（先测这个：后面②要用它的数据）----
\tvar ranged_truth: Array = []
\tfor eid in Registry.enemies:
\t\tvar ec: Dictionary = Registry.enemies[eid]
\t\tif ec.has("source"):
\t\t\tcontinue                      # mod 条目不参与内置构成的名单核对
\t\tif String(ec.get("ai", "")) == "shooter":
\t\t\tranged_truth.append(String(eid))
\tfor rid in Config.BAND_RANGED_MOB_IDS:
\t\tif not Registry.enemies.has(String(rid)):
\t\t\t_fail("BAND_RANGED_MOB_IDS 含未注册敌人 %s" % String(rid))
\t\t\treturn
\t\tif not ranged_truth.has(String(rid)):
\t\t\t_fail("BAND_RANGED_MOB_IDS 里的 %s 在 Registry 里并非 shooter AI —— 名单写错了" % String(rid))
\t\t\treturn
\tfor tid in ranged_truth:
\t\tif not (Config.BAND_RANGED_MOB_IDS as Array).has(String(tid)):
\t\t\t_fail("Registry 里的 shooter 怪 %s 不在 BAND_RANGED_MOB_IDS 里 —— 名单漏了它，" % String(tid)
\t\t\t\t+ "「远程多」这一段就悄悄漏一只")
\t\t\treturn
\tfor eid2 in Config.BAND_ELITE_MOB_IDS + Config.BAND_TRASH_MOB_IDS:
\t\tif not Registry.enemies.has(String(eid2)):
\t\t\t_fail("波段名单含未注册敌人 %s" % String(eid2))
\t\t\treturn
\t# 三张名单两两不相交：同时命中两张会吃到两次倍率（远程精英被平方放大）
\tvar all_band: Array = []
\tfor grp in [Config.BAND_RANGED_MOB_IDS, Config.BAND_ELITE_MOB_IDS, Config.BAND_TRASH_MOB_IDS]:
\t\tfor mid_x in grp:
\t\t\tif all_band.has(String(mid_x)):
\t\t\t\t_fail("波段名单重复收录 %s —— 会吃到两次倍率" % String(mid_x))
\t\t\t\treturn
\t\t\tall_band.append(String(mid_x))
\t# ---- ② 构成：用**份额**（占比）而不是绝对权重，天然免疫「整体缩放」这种假实现 ----
\tvar share_w10 := _band_share(10, Config.BAND_RANGED_MOB_IDS)
\tvar share_w6 := _band_share(6, Config.BAND_RANGED_MOB_IDS)
\tif share_w10 <= share_w6:
\t\t_fail("区块 3（W9-12）「远程多」未生效：W10 远程份额 %.3f ≤ W6 的 %.3f"
\t\t\t% [share_w10, share_w6])
\t\treturn
\tvar elite_w10 := _band_share(10, Config.BAND_ELITE_MOB_IDS)
\tvar elite_w14 := _band_share(14, Config.BAND_ELITE_MOB_IDS)
\tvar trash_w10 := _band_share(10, Config.BAND_TRASH_MOB_IDS)
\tvar trash_w14 := _band_share(14, Config.BAND_TRASH_MOB_IDS)
\tif elite_w14 <= elite_w10:
\t\t_fail("区块 4（W13-16）「小精英」未生效：W14 精英份额 %.3f ≤ W10 的 %.3f"
\t\t\t% [elite_w14, elite_w10])
\t\treturn
\tif trash_w14 >= trash_w10:
\t\t_fail("「小精英」只抬了精英、没让出杂兵份额（W14 杂兵 %.3f ≥ W10 的 %.3f）——"
\t\t\t% [trash_w14, trash_w10] + " 这不是构成变化，是整体缩放")
\t\treturn
\t# 「渐肉」在**构成**侧的体现 = 末段仍是精英主导（相对中段），强度由 HP 曲线末段斜率承担
\t# （上面 slope5 已断言）。⚠️ 这里**刻意不写「精英份额一路递增到区块 5」**：
\t# 区块 5 的精英倍率(1.7)本就低于区块 4(2.0) ——「小精英」是区块 4 的峰值，
\t# 区块 5 改为靠 HP 变厚 + 整池上移继续加压。把「递增」硬钉进断言会让
\t# **完全正确的实现也红**（份额实算：W18 精英 ≈0.402 < W14 ≈0.440，那是设计不是 bug）。
\t# 故这里只断言「末段精英主导 / 杂兵让位」这两个与区块 3 的对照 —— 方向与区块 4 一致。
\tvar elite_w18 := _band_share(18, Config.BAND_ELITE_MOB_IDS)
\tvar trash_w18 := _band_share(18, Config.BAND_TRASH_MOB_IDS)
\tif elite_w18 <= elite_w10:
\t\t_fail("区块 5（W17-20）「渐肉」的精英份额 %.3f 不高于中段（区块3）的 %.3f"
\t\t\t% [elite_w18, elite_w10])
\t\treturn
\tif trash_w18 >= trash_w10:
\t\t_fail("区块 5 的杂兵份额 %.3f 未低于中段（区块3）的 %.3f —— 末段回到杂兵海了"
\t\t\t% [trash_w18, trash_w10])
\t\treturn
\t# 区块 1/2 刻意不做构成偏移（空表）→ 份额必须保持「未加工」的水平，
\t# 即低于区块 3 的远程份额与区块 4 的精英份额。这是反向对照：
\t# 若有人把倍率表整体前移，这三条会同时红。
\tif _band_share(4, Config.BAND_RANGED_MOB_IDS) >= share_w10:
\t\t_fail("区块 1（W1-4「难」）不该在构成上堆远程 —— 难度应由 HP/DMG 曲线承担")
\t\treturn
\t# 权重必须恒 > 0（w<=0 的条目会让 weighted_pick 报错并返回 null）
\tfor w2 in range(1, Config.WAVES_TOTAL + 1):
\t\tfor entry_w in Config.wave_composition(w2):
\t\t\tif float((entry_w as Dictionary).get("w", 0.0)) <= 0.0:
\t\t\t\t_fail("波段加权把权重压到 ≤ 0（W%d / %s）" % [w2, String((entry_w as Dictionary).get("item", ""))])
\t\t\t\treturn
\tprint("SMOKE: 第11轮 分段难度曲线 + 波段怪构成（端点不漂移 / 先难后易 / 远程多·小精英·渐肉 / 名单防漂移）OK")


## 某波段名单在 W 波出怪池里的**权重份额**（占比）。
## 用份额而不是绝对权重：整体缩放（全都 ×2）不会改变份额 —— 那正是要拦的假实现。
func _band_share(w: int, ids: Array) -> float:
\tvar total := 0.0
\tvar hit := 0.0
\tfor e in Config.wave_composition(w):
\t\tvar d: Dictionary = e
\t\tvar wv := float(d.get("w", 0.0))
\t\ttotal += wv
\t\tif ids.has(String(d.get("item", ""))):
\t\t\thit += wv
\treturn 0.0 if total <= 0.0 else hit / total


'''

SMK_EDITS = [
    ('''\t_check_reach_safety()
\t_check_spread_channel()
\t_check_buff_display()
\t_check_balance_log()''',
     '''\t_check_reach_safety()
\t_check_spread_channel()
\t_check_buff_display()
\t_check_wave_bands()
\t_check_balance_log()'''),
    ('''## 第 11 轮：喷射散布角通道（喷嘴类道具）。''',
     SMK_CHK + '''## 第 11 轮：喷射散布角通道（喷嘴类道具）。'''),
]

ok = apply_file(CFG, CFG_EDITS, "config-r11-band")
ok = apply_file(SMK, SMK_EDITS, "smoke-r11-band") and ok
if not ok:
    sys.exit(1)
