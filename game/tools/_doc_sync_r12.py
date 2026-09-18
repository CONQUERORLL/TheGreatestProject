"""第 12 轮 · 回填施工图 §12.15（拾取范围保留 / 经验减半 / 连升改回一级一选）。"""
import io, sys

P = "docs/plans/五行体系重设计_规划.md"
ANCHOR = "## 13. 验收标准 & 冒烟测试新增断言"

SEC = """### 12.15 第 12 轮：拾取范围**保留** / 经验获取减半 / 连升改回「一级选一次」（2026-09-18 回填 · `SMOKE: PASS`）

> 三条都来自用户反馈。第 ① 条经核实后**不删**——用户给的判据是「逻辑还在就保留」。

#### ① 拾取范围：`pickup_range` **保留，不删**

用户原话是「删掉拾取范围，因为现在好像是掉落后直接会拾取」。核实结论：**没有「落地即入账」这条路径**，
掉落物仍完整地走「弹出 → 磁吸 → 接触结算」，因此 `pickup_range` 是有实际作用的，按用户判据保留：

- 弹出：`enemy.gd:1100/1105` `ObjectPool.acquire("loot", …)` 带初速，摩擦 `exp(-6dt)` 减速（`loot.gd:64`）。
- 磁吸：`loot.gd:66-69` —— `d < player.stats.pickup_range` 时施加 `f = 1800×(1 - d/pr + 0.2)` 的吸力，**半径就是 `pickup_range`**（基础 95）。
- 接触结算：`loot.gd:75` —— `d < Config.PLAYER.radius + 12.0` 才 `settle()`。
- 波末兜底：`main.gd:883`（`_on_wave_ended`）对 `group("loot")` 全场 `settle()`，没捡到的也不丢。

→ 所以「磁力🧲 / 大磁铁🧲 / 丰饶祭 / 财神金蟾 / 磁极核心 / 聚宝囊」等 `pickup_range` 条目**全部保留**。
玩家感觉「瞬间拾取」是因为磁吸半径 95 + 强吸力，不是因为范围属性失效。

#### ② 经验获取速度减半：改**升级所需经验 ×2**

```gdscript
const XP_NEED_MULT := 2.0
static func xp_need(level: int) -> int:
	return int(round((4 + (level - 1) * 3) * XP_NEED_MULT))   # 8 / 14 / 20 / 26 …
```

⚠️ 用「需求翻倍」而不是「掉落 ×0.5」：mob 的 `xp` 是 **2~3 点的小整数**，`×0.5` 会被 `int` 截断
（3 → 1），实际减速约 **1/3** 而非 1/2；需求翻倍才是**精确减半**，且 `xp_need` 是升级节奏的唯一口径，
改一处即可（冒烟里所有期望都由 `Config.xp_need()` 现算，不硬编码）。

#### ③ 连升改回「一级选一次」（撤回第 9 轮的合并）

- 删除 `Config.LEVEL_MERGE_CAP` / `LEVEL_MERGE_OVERFLOW_MAT`，以及 `level_up_ui` 的
  `_merged` 字段、`merged_count()`、标题「连升 N 级」后缀、「溢出折材料」分支。
- `_choose` 改回 `e600854`（第 9 轮之前）的实现：**队列只 -1，仍有积压就 `open()` 重新抽三张**。

⚠️⚠️ **最大的坑：只把 `LEVEL_MERGE_CAP` 改成 1 是错的** —— 合并版 `_choose` 是把
`GameState.level_queue` **整个清零**、并把超出部分折成材料。那样「连升 3 级」只会弹 1 次、**白丢 2 级**。
必须同时改 `_choose` 的递减逻辑，两处是一个整体。

#### 冒烟判据：改用**弹卡次数**（`pops`）

跨两级时：第 9 轮合并版只弹 **1** 次，逐级版必须弹 **2** 次 —— 比比较 `upgrades_owned` 增量更硬
（金/红唯一件会被 `apply_upgrade` 硬闸门拦下，增量本就不确定）。实测打印：
`SMOKE: per-level level-up OK（跨两级弹了 2 次）`。

---

"""

with io.open(P, "r", encoding="utf-8") as f:
    s = f.read()

n = s.count(ANCHOR)
if n != 1:
    print("FAIL: 锚点匹配 %d 次" % n)
    sys.exit(1)
s = s.replace(ANCHOR, SEC + ANCHOR, 1)

with io.open(P, "w", encoding="utf-8") as f:
    f.write(s)
print("施工图已插入 §12.15（+%d 字符）" % len(SEC))
