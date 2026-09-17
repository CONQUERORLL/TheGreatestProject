# -*- coding: utf-8 -*-
"""第 9 轮：往唯一施工图里追加 §12.13 回填清单（CRLF 自适应）。

跑法：
    python.exe game/tools/_apply_round9_doc.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, root  # noqa: E402

DOC = os.path.join(root(), "docs", "plans", "五行体系重设计_规划.md")

ANCHOR = """这是同一个坑第三次踩（前两次：岩肤符 `high_hp_armor`、`CodexData.stat("clear_<char>")`）。

---

## 13. 验收标准 & 冒烟测试新增断言
"""

NEW = """这是同一个坑第三次踩（前两次：岩肤符 `high_hp_armor`、`CodexData.stat("clear_<char>")`）。

---

### 12.13 第 9 轮：浮动布局 / 连升合并 / 商店刷新倾向 / 每 4 波 BOSS + 地形区域（2026-09-17 回填 · `SMOKE: PASS`）

> 本轮是**用户需求驱动**（4 条），不是五行主线的推进；但需求 4 动到了 BOSS 波的根本判定，
> 所以单独回填一节。**本节结论优先于正文**（正文 §8.2 / §8.3 / §8.5-B / §13 BGM / §附二 有若干处已被推翻）。

#### 需求 1 · UI 浮动布局（菜单两列 / 商店换行 / 属性固定视图 + 滚动条）

- **菜单首页**（`main_menu.gd`）：新增 `HOME_BTN_H` / `HOME_BTN_GAP` / `HOME_RESERVE_H` 三个常量
  与 `_home_one_column_fits(n)` / `_home_avail_h()`；「桌面一列装不下」时按钮宿主由单列改为
  `GridContainer columns = 2`，**平均分两列**。判据与按钮尺寸读**同一个常量**，不会各改各的。
- **商店**（`shop_ui.gd`）：`_goods_box` 由 `HBoxContainer` 改为 `GridContainer`。
  `_goods_grid()` 的思路与菜单首页一致：先按可用宽度算**最大列数** → `ceil(n / max_cols)` 得行数 →
  `ceil(n / rows)` 反推平均列数（6 格在「最多 4 列」的宽度下得到 **3+3**，而不是 4+2 留一张孤卡）。
  卡尺寸由行列与可用区域反推（`_good_card_size()`），不再固定 150×238（那是旧版硬溢出的根源）。
- **属性 / 道具查看 = 固定视图 + 滚动条**：商店左栏与暂停页左栏各包一层 `ScrollContainer`
  （原先超出只会被**裁掉**，看不到最后几行且没有任何提示）；`hint_bubble.gd` 新增
  `show_docked()`：宽度固定成 `DOCK_W`、位置固定成「右侧垂直居中」，**点击详情走它**，悬浮提示仍跟随鼠标。
- ⚠️ **踩坑 1**：`GridContainer` **没有** `alignment`（那是 `BoxContainer` 的属性）。
  写成 `_goods_box.alignment = ...` 是**运行期** `Invalid assignment of property`，
  并且会**中断整个 `_build()`** → 后面所有控件（含 reroll / heal / next 三个按钮）全是 null，
  商店整体不可用。`--import` 解析门禁**抓不到**，只有跑冒烟才暴露 → 居中只能靠 `SIZE_SHRINK_CENTER`。
- ⚠️ **踩坑 2**：`hint_bubble` 的滚动节点是**复用**的。长文把 `custom_minimum_size.y` 顶到 ~300 之后
  不复位，下一条**短**提示也会撑出同样一大片空白（现象是"气泡忽然变很高"）。两个分支都要显式复位。

#### 需求 2 · 开局反复弹升级卡：根因诊断 + 修

- **根因（已查清，不是随机）**：`xp_need(l) = 4 + 3(l−1)` → 1→2 级只要 **4 点**，
  而 W1 小怪给 2~3 点 XP、一波 10+ 只 ⇒ **一波就能跨 2~3 级**；旧逻辑是**每个等级各弹一次三选一**，
  且每次**重新抽三张** ⇒ 连升 3 级要点 3 次。波末又会自动拾取整波 XP，所以「开局那几波」尤其密集。
- **修法**：连升 N 级**合并成一次**选择，选中的那张**生效 N 次**（收益不减，点击 N → 1）。
  `Config.LEVEL_MERGE_CAP = 3`（封顶 3：叠 N 次对 `dmg_mult` 这类**乘法**效果是复利），
  溢出级数折材料 `Config.LEVEL_MERGE_OVERFLOW_MAT = 12`；`level_up_ui._choose()` 末尾一次性清零 `level_queue`。
- **冒烟**：把原来「单次跨两级要重抽」的断言改成「合并成一次选择、收益 ×2」，
  钉 `merged_count() == 2`，且 `want_times` 由被测数据算（防金红唯一件造成的假红）。

#### 需求 3 · 商店刷新的三条倾向（全在 `shop_ui` 抽取路径，不改任何结算）

1. **倾向已有武器**：已持有同名武器权重 ×`Config.SHOP_OWNED_WEAPON_MULT`(3.0)（进化要 3 把同名）。
   只在商店侧加权，**不动 `Registry.shop_weapon_pool()`** —— 事件卡送武器也走那个函数。
2. **同化度保底**：某次刷新整店没出同化度 → 下次其权重 ×`(1 + 0.35 × 连续落空店数)`（倍率封顶 3 档）；
   连续落空 ≥`SHOP_ASSIM_FORCE_AT`(3) 时**硬塞一格**；刷到一次立刻归零重算。
3. **武器侧饱和**：满槽（买了会被 `buy()` 拦 = 死格）/ 武器侧全进化 → 武器概率降到
   `WEAPON_CHANCE_SLOTS_FULL` / `WEAPON_CHANCE_SATURATED`。**关键不在降到多少，而在让出的份额去哪**：
   腾出的比例**全部并进升级池**（`_roll_one` 的 `wch` / `uch`）—— 这才是「道具挤占核心构筑件」的根治点。

- **同化度的唯一稳定判据**走 `Config.is_assim_entry()`：认 `effects` 里的 `assim_*` 键，
  **不认 id 前缀** —— 同化度横跨 `i-assim-*`（道具）与 `wu_*`（升级）两套命名，按前缀判会**静默漏掉升级那一支**。
- **两个保底互斥**：同化度保底与亲和保底都抢「最后一格」，后跑的会把前一个刚塞进去的换掉
  （现象是"保底明明该触发却没生效"）。顺序：同化度保底优先。

#### 需求 4 · 每 4 波一个 BOSS + 场景属性地形区域

- **BOSS 节奏**（`Config.is_boss_wave`）：标准 / 每日 / 自定义局改为
  `w >= wave_total or w % BLOCK_WAVES == 0` → **W4 / W8 / W12 / W16 / W20**。
  刻意**复用 `BLOCK_WAVES`**(4) 而不是写死 4：区块划分与 BOSS 节奏同一处真值。
  **无尽仍然是 `w % 10 == 0`**（既有平衡与断言都建立在它上面）。
  ⚠️ `w < 1` 必须挡在最前面：`0 % 4 == 0` → 不挡的话 `is_boss_wave(0)` 会变成 true。
- **一对分叉口**（本轮新增）：`is_final_boss_wave` / `is_mid_boss_wave`。
  ⚠️ `main._on_boss_killed` 与 `wave_manager._on_boss_killed` **必须读同一个函数** ——
  一边按"最终"、另一边按"中间"会同时踩到「通关面板底下又开了商店」和「中间 BOSS 打完直接通关」两个相反的坑。
- **中间 BOSS 限时**：`Config.midboss_duration = wave_duration × MIDBOSS_TIME_MULT`(2.5)。
  时间到未击杀 → BOSS 与干扰怪一起退场、**不掉落**、本波照常收尾进商店（用户明确要求：
  「如果时间结束没有击杀则不掉落」）。**最终 BOSS / 无尽 BOSS 不限时**（前者是通关条件，后者是既有口径）。
- **血量随波次成长**（`Config.boss_hp_scale`）：标准局**最终波锚点 = 1.0**（W20 既有平衡一字未动），
  中间 BOSS 查 `MIDBOSS_HP_FRAC = [0.03, 0.07, 0.14, 0.25]`；无尽沿用既有 `1 + 0.30 × (w − 10)`。
  ⚠️ 中间 BOSS 的血量**不能**按最终 BOSS 的比例缩：56~90 万是按**无限时消耗战**标定的，
  而中间 BOSS 必须能在限时内打完，否则「时间到不掉落」变成常态、法宝盒子永远拿不到。
- **掉宝**：无尽前的中间 BOSS **只掉「法宝盒子」**（`GameState.boss_boxes`），波末开盒**三选一**
  （`scenes/ui/boss_box.tscn` + `scripts/ui/boss_box.gd`，池空时折材料不弹空盒子）；
  **最终 BOSS 与无尽 BOSS 保持直掉法宝**（前者随即通关、盒子没处开）。
- **地形区域**：`Config.terrain_zone_for_wave(player_element, wave)` 返回圆形区域 ——
  属性 = 本区区域元素，圆心是 `(玩家元素, 区块号)` 的**哈希纯函数**（不用 `GameRng`，
  读档 / 每日挑战全服一致），同一区块四波位置**固定**（换区才挪，玩家能记住"这片地在这"），
  且距出生点 ≥ 半径（开局不会白送一档同化度）。
  `fx/terrain_zone.gd` 以 0.35s 低频扫描：玩家进区 `player.set_zone_assim()`、区内**同元素**怪
  `enemy.set_zone_bonus()`，**离区即撤销**。
- **上限**（用户要求「加成不超过上限」）：怪侧并入 `Config.mob_resist` 的**加法项** `zone`
  → 天然被 `_resist_cap()`（普通 0.75 / 同属 BOSS 0.90）吃掉；玩家侧受 `_sanitize_stats` 的
  assim ≤ 2.0 与 `apply_hit_mult` 的逐关系 cap 约束。

**⚠️⚠️ 需求 4 的三个静默陷阱（本轮全部写进注释 + 冒烟断言）**：

1. **信号顺序**：`boss_killed` 的监听里 `wave_manager` **先于** `main`（子节点 `_ready` 早于父节点），
   而前者紧接着 `emit wave_ended` → 商店 + 进化流程 + **写存档**。盒子若发在 `main` 那侧就
   **晚一整波**（本波末不开盒、要等下一波末才弹，横幅也会盖在商店上）。
   → 发放点移到 `wave_manager._on_boss_killed`，并用探针断言「wave_ended 触发**那一刻**盒子已存在」。
2. **临时加成必须可逆**：`player.set_zone_assim` 记的是**实际生效量**（`after − before`）而不是
   「想要写的量」—— 同化度有 2.0 上限，若按想要量撤，会把玩家**固有**的同化度吃掉（不报错，只是变少）。
   地形区域还必须在**所有「本波结束 / 即将写档」的路径**上 `clear()`
   （`_on_wave_ended` / `_on_boss_killed` / `_on_player_died`）—— 少一处就把那片地的加成
   **永久烙进存档**（`SaveRun.save()` 会把 stats 原样写走）。
3. `queue_free()` 的 `_exit_tree` 要等**本帧末**才跑 → 换波时旧区迟到的撤销会把新区的加成一起抹掉
   （表现为"站进区里没加成"）。所以销毁前**同步** `clear()`，并用 `_cleared` 标志防重复撤销。

- **冒烟新增 `_check_round9_boss_terrain()`**：三态 BOSS 判定（标准 / 自定义 18 波 / 无尽）·
  中间 vs 最终分流 · 血量锚点与单调 · 限时宽于普通波 · 圆的纯函数性与「不覆盖出生点」·
  同区块不漂移 / 跨区块必变 · 临时同化度**可逆**（含「已到上限时不许吃固有值」这一反向对照）·
  怪侧加成进 `mob_resist` 且被 cap 吃掉 · 直调两个处理函数验证「盒子早于 wave_ended」与
  「中间 BOSS 不进 VICTORY」（**现场全部还原**，且临时摘掉 `wave_ended` 监听以免把假进度写进真实存档槽）。

#### ⚠️ 本轮推翻了正文的这几处（正文未逐字改，以此节为准）

| 正文位置 | 原口径 | 现在 |
|---|---|---|
| §8.2 表 · `Config.is_boss_wave` 目标值 | 标准局 = **W20** | 标准局 = **每 4 波 + 最后一波**（W4/8/12/16/20）；无尽不变 |
| §8.3 表 · BOSS 波通过条件 | 「击杀 BOSS 结束，**不走普通波结算**」 | 只对**最终 BOSS** 成立；中间 BOSS 走正常收波（发 `wave_ended` → 商店） |
| §8.5-B 表 · 商店次数 | 19 次（理由：W20 不进商店） | 次数**仍是 19**，但理由变了：中间 BOSS 打完**也进商店**（W4/8/12/16 各一次），W20 不进 |
| §13 · BGM 断言 | 期望表含 W4 / W8 → `battle` / `battle_mid` | 期望表**只放非 BOSS 波**；全部 BOSS 波统一查 `boss`，期望集从 `Config.is_boss_wave` **算**出来 |
| §附二 · 波次结构 | 「BOSS 在 W20」 | 标准局 **5 个 BOSS 波**：W4/8/12/16（中间，限时）+ W20（最终，不限时） |
| §附二 · 关卡通过 | 「BOSS 波：必须击杀」 | 中间 BOSS 未击杀 = **没有掉落但照常收波**；最终 BOSS 仍必须击杀 |
| §12.12 / `smoke_test.gd` 注释 | 「BOSS 波不派发 `wave_ended`，所以 `best_wave` 够不到 20」 | 中间 BOSS **会**派发；够不到 20 的原因只剩「最终 BOSS 不派发」（`clear_20` vs `endless_20` 不同源这条**仍然成立**） |

#### ⚠️ 未闭环（留给实测，别当成已完成）

- `MIDBOSS_HP_FRAC` 与 `MIDBOSS_TIME_MULT` 是**首次落地的估价**（限时战不能照搬"无限时消耗战"的
  56~90 万标定）。偏肉的症状很好认：**「时间到 BOSS 还剩一大半血」**。
  修法是先降 `MIDBOSS_HP_FRAC`，**不要去拉长限时** —— 限时拉长会让「没击杀就不掉落」这条规则失去意义。
- 中间 BOSS 波不跑 `Registry.wave_composition`（沿用写死的干扰怪列表）→ 那 4 波**没有区块元素加权**。
- **20 波墙钟仍未重跑**（第 8 轮遗留 + 本轮多出 4 场 BOSS 战，半小时预算需要重新核算）。

---

## 13. 验收标准 & 冒烟测试新增断言
"""


def main():
    ok = apply_file(DOC, [(ANCHOR, NEW)], "r9-doc")
    if not ok:
        sys.exit(1)
    print("ALL OK")


if __name__ == "__main__":
    main()
