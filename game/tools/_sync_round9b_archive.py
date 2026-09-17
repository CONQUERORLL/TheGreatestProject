# -*- coding: utf-8 -*-
"""第 9 轮补丁 A 的归档：施工图 §12.13b + MEMORY.md + 新建 2026-09-18.md。"""
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path, load, save  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DOC = os.path.join(ROOT, "docs", "plans", "五行体系重设计_规划.md")
LONG = os.path.join(ROOT, ".workbuddy", "memory", "MEMORY.md")
DAILY = os.path.join(ROOT, ".workbuddy", "memory", "2026-09-18.md")

ANCHOR = "- **20 波墙钟仍未重跑**（第 8 轮遗留 + 本轮多出 4 场 BOSS 战，半小时预算需要重新核算）。"

ADDENDUM = ANCHOR + """

#### ⚠️ 12.13b 补丁（2026-09-18 · 接线 P0 修复 · `SMOKE: PASS`）

**发现**：`Config.boss_hp_scale()` 当时**只被写进 Config、没有任何游戏代码调用它**（唯一引用者
是冒烟对纯函数的断言）。而 `enemy.gd::setup()` 的 BOSS 分支 `hp_s` 在标准局恒为 `1.0`
（注释「BOSS 不吃常规波次缩放」）、`wave_manager.spawn()` 也不改 BOSS 血量
⇒ **标准局 BOSS 血量 = `cfg.hp`（56 万~90 万），与波次完全无关**。

后果比「估价偏肉」严重得多：

- 中间 BOSS（W4/8/12/16）与最终 BOSS 血量**一模一样**，却额外背 105/135/165/195s 限时
  ⇒ **必然打不死** ⇒「时间结束没有击杀则不掉落」成为常态、**法宝盒子永远拿不到**（该需求等于死内容）。
- 用户需求 4 明写的「**血量随波次成长**」**根本没实现** —— 本节上文那句「中间 BOSS 查
  `MIDBOSS_HP_FRAC`」当时与代码不符（违反铁律 1「代码是唯一真值」）。

量化（6 只 BOSS 平均 731,333、区间 56 万~90 万；普通难度 `hp_mult = 1.0`；限时 = `wave_duration(w) × 2.5`）：

| 波 | 限时 | frac | 实际 HP（修复前）| 应有 HP | 修复前所需 DPS | 修复后所需 DPS |
|---|---|---|---|---|---|---|
| W4 | 105s | 0.03 | 731,333 | 21,940 | **6,965** | 209 |
| W8 | 135s | 0.07 | 731,333 | 51,193 | **5,417** | 379 |
| W12 | 165s | 0.14 | 731,333 | 102,387 | **4,432** | 621 |
| W16 | 195s | 0.25 | 731,333 | 182,833 | **3,750** | 938 |
| W20 | 无限 | 1.00 | 731,333 | 731,333 | — | — |

**修法**（两处，不引入任何新数值）：

1. `Config.boss_hp_scale()` 自己**只在真正的 BOSS 波**压缩（非 BOSS 波返 1.0）。
   ⚠️ 这不是洁癖：测试 / 工具会在**任意波次**（如 W10）造 BOSS 验技能与 `dmg_cap`，
   那里若也按 frac 缩，`dmg_cap = max_hp × 0.005` 跟着变小，`_check_boss_skills` 里
   `take_damage(1000)` 期望掉血 800 的断言会被**静默截断**成 430 而报红。
2. `enemy.gd::setup()` BOSS 分支改为 `hp_s = Config.boss_hp_scale(wave)` ——
   无尽曲线（`1 + 0.30(w−10)`）与标准最终波（`1.0`）**逐字不变**，只有中间 BOSS 变。

**冒烟新增 §4b「消费点」断言**（本节的真正教训）：`_check_round9_boss_terrain()` 现在**真的实例化**
W4 中间 BOSS 与 W20 最终 BOSS，断言 ① `max_hp == cfg.hp × frac × diff.hp_mult`；
② 中间 **必须轻于** 最终（**反向对照** —— 否则 frac 恰为 1.0 时「空操作」也能假绿）；
③ 非 BOSS 波（W10）造出的 BOSS **不受**压缩影响。
⚠️ 原先那几条只断言**纯函数返回值**，**抓不到「声明了没人读」** —— 正是 §13 第 19 条警告过的缺陷类型。"""

LONG_EDITS = [
    (
        "- 血量 `boss_hp_scale`：最终波锚点 **1.0**（W20 既有平衡不动）；中间 `MIDBOSS_HP_FRAC=[0.03,0.07,0.14,0.25]`（**估价**）。",
        "- 血量 `boss_hp_scale`：最终波锚点 **1.0**（W20 既有平衡不动）；中间 `MIDBOSS_HP_FRAC=[0.03,0.07,0.14,0.25]`（**估价**）。\n"
        "  ⚠️ **2026-09-18 补丁**：该函数当时**零调用点**（没接线）→ 中间 BOSS 与最终 BOSS 同血量\n"
        "  却多背限时、必然打不死。已改为 `enemy.gd::setup()` BOSS 分支直接读它，且函数自己\n"
        "  只在**真 BOSS 波**压缩（非 BOSS 波返 1.0，保护测试里任意波次造的 BOSS）。见 §12.13b。",
    ),
    (
        "- ⚠️ 未闭环：`MIDBOSS_HP_FRAC` 是估价（偏肉先降此表、**别拉长限时**）；中间 BOSS 波无区块元素加权；20 波墙钟仍未重跑。",
        "- ⚠️ 未闭环：`MIDBOSS_HP_FRAC` 仍是**估价**（现在**终于真的生效**，但数值待实测；偏肉先降此表、**别拉长限时**）；\n"
        "  中间 BOSS 波无区块元素加权；**20 波墙钟仍需人玩**（无整局机器人：五道 UI 闸门）。",
    ),
    (
        "   商店整体不可用）。`--import` 解析门禁**抓不到**，只有跑冒烟才暴露。居中只能用 `SIZE_SHRINK_CENTER`。\n\n## ⚠️ 断言纪律",
        "   商店整体不可用）。`--import` 解析门禁**抓不到**，只有跑冒烟才暴露。居中只能用 `SIZE_SHRINK_CENTER`。\n"
        "17. **新加的公式 / 字段必须确认「有消费点」**（第 9 轮补丁 · **P0**，`boss_hp_scale`）：\n"
        "    函数写好了、纯函数断言也绿，**但没有任何游戏代码调用它** → 中间 BOSS 血量从未被压缩，\n"
        "    与最终 BOSS 同值却多背限时，**必然打不死**（法宝盒子永远拿不到）。\n"
        "    **只断言纯函数返回值 = 没断言「有人读」**。加公式/字段后先 `Grep` 调用点：\n"
        "    若只在 `Config` 与 `tests/` 里出现，就是**没接上**。\n\n## ⚠️ 断言纪律",
    ),
]

DAILY_BODY = """# 2026-09-18 工作日志

## 第 9 轮收尾 + 中间 BOSS 血量 P0 修复（✅ SMOKE: PASS · 已重导 exe）

### 前一段：第 9 轮收尾（00:20）
- 重导 `export/BrotatoLite.exe`（110,692,624 / md5 `f5d33e42…`），包内确认含
  `terrain_zone.gdc` / `boss_box.gdc` / `boss_box.tscn.remap`（第 9 轮新文件确已进包）。
- 记忆归档：`2026-09-17.md` 追加第 9 轮段（24,168 → 29,909 字符）；`MEMORY.md` 补第 9 轮条目 + 4 条静默陷阱。
- 修订 `godot-smoke-test` 技能里若干**过期内容**（`timeout=300`→600、日志落点写成 `zz_smoke.txt`
  实为 `game/tools/_smoke_run.log`、耗时 40~60s/100s→≈38s），并补 `import_gate.py` 第一道门与
  `_edit_util.py`（CRLF/LF 混用的批量替换器）。顺手清掉 `game/tools/__pycache__` 与残留 `zz_smoke.txt`。

### 本轮：用户「好」→ 原计划跑 20 波墙钟，查实机数据时**先挖出 P0**
- 现场：`%APPDATA%\\Godot\\app_userdata\\BrotatoLite\\` 下**无 `balance_log.json`**（逐波日志投用后
  还没跑过完整局），**但有真实对局存档** `save_run.json`（09-17 23:04）：`wood_adept` / 普通难度 /
  **W8** / 55 级 / 1010 杀 / `run_time=294s` / 5 格满（`blight_bow`×2 + `flamethrower`×2 + `thunder_gong`）。
- 先确认「能不能自动跑局」：武器**自动索敌开火**（`Combat.nearest_enemy`），玩家只需走位 ——
  但冒烟只有 `_wait_wave_end()`，**没有整局机器人**；且 20 波之间卡着
  **商店 / 升级三选一 / 进化选择 / 事件卡 / 法宝盒子**五道 UI 闸门
  → 真·墙钟 20 波**需要人玩**（或另建一套交互机器人，属独立工程）。
- 于是先做**确定性核算**，结果挖到 **P0**：`Config.boss_hp_scale()` **零调用点** →
  `enemy.gd::setup()` 的 BOSS 分支 `hp_s` 标准局恒 `1.0`（「BOSS 不吃常规波次缩放」）
  → **标准局 BOSS 血量 = `cfg.hp`（56~90 万），与波次无关** → 中间 BOSS 与最终 BOSS 同血量
  却多背 105~195s 限时 → **必然打不死** → 法宝盒子永远拿不到；
  用户需求 4 明写的「血量随波次成长」**根本没实现**（且与 §12.13 文档冲突）。
- 量化：修复前中间 BOSS 所需 DPS = W4 6,965 / W8 5,417 / W12 4,432 / W16 3,750（平均血量口径）；
  接线后降到 209 / 379 / 621 / 938 —— 回到合理区间。
- 修复（`_apply_round9_midboss_wire.py`）：① `boss_hp_scale` 只在**真 BOSS 波**压缩
  （非 BOSS 波 1.0 —— 保护测试里在 W10 等任意波次造的 BOSS，否则 `dmg_cap` 被连带压小，
  `_check_boss_skills` 的 `take_damage(1000)` 期望 800 会被静默截断成 430 而报红）；
  ② `enemy.gd` BOSS 分支改读它（无尽曲线与 W20 最终波**逐字不变**）；
  ③ 冒烟补 §4b **消费点**断言（真实例化 W4/W20 BOSS 比对 + 反向对照 + 非 BOSS 波不受影响）。
- ✅ `IMPORT GATE: PASS`；`SMOKE: PASS`（85 条 `SMOKE:` / 11 条 `BALANCE` / **0 条 FAIL**，退出码 0）。
- ✅ 重导 `export/BrotatoLite.exe`（**110,694,240** 字节 / md5 `94e9d179293a9e182eff4d9cfcac3edd` / 00:29），
  启动自检 `--quit-after 90` 退出码 0、`已加载 3 条自定义内容`。
- 文档：施工图追加 **§12.13b**（含量化表与被推翻结论）。`MEMORY.md` 补静默陷阱第 17 条。
- ⚠️ 未闭环（不变）：`MIDBOSS_HP_FRAC` 仍是**估价**（现在终于真的生效，数值待实测）；
  中间 BOSS 波无区块元素加权；**20 波墙钟仍需人玩或造机器人**。
- 备注（次要，未动）：`wave_manager._pick_boss_id()` 用 `round_idx = wave / 10` 做轮换，
  对 W4/W8（→0）与 W12/W16（→1）会**各自取到同一只 BOSS**；标准局改成每 4 波后这个索引不再对齐。
"""


def main():
    ok = True
    ok = apply_file(DOC, [(ANCHOR, ADDENDUM)], "§12.13b") and ok
    ok = apply_file(LONG, LONG_EDITS, "MEMORY") and ok
    # 新建当日日志（append-only 语义：文件不存在才建，存在则追加）
    if os.path.exists(DAILY):
        text, crlf = load(DAILY)
        save(DAILY, text.rstrip("\r\n") + ("\r\n" if crlf else "\n") + "\n" + DAILY_BODY)
        print("日志追加: %d -> %d chars" % (len(text), len(text) + len(DAILY_BODY)))
    else:
        with io.open(DAILY, "w", encoding="utf-8", newline="") as f:
            f.write(DAILY_BODY)
        print("日志新建:", DAILY, len(DAILY_BODY), "chars")
    print("RESULT:", "OK" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
