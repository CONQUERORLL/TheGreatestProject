# -*- coding: utf-8 -*-
"""第 8 轮记忆同步（非幂等：重跑只会安全失败，不会二次污染）。

改 2 个文件：
  1) .workbuddy/memory/MEMORY.md     —— 修正被第 7/8 轮改旧的武器尺度表 + 补第 8 轮事实
  2) .workbuddy/memory/2026-09-17.md —— 追加第 8 轮工作日志

规则：每处 (old, new) 断言 old 在全文命中恰好 1 次，全部通过才写盘。
"""
import os, sys, io

ROOT = r"D:\code\firstProject-ai\TheGreatestProject"
MEM = os.path.join(ROOT, ".workbuddy", "memory", "MEMORY.md")
LOG = os.path.join(ROOT, ".workbuddy", "memory", "2026-09-17.md")


def rd(p):
    with io.open(p, encoding="utf-8") as f:
        return f.read()


def apply(text, edits, tag):
    for i, (old, new) in enumerate(edits):
        n = text.count(old)
        if n != 1:
            print("FAIL %s #%d 命中 %d 次（要求 1）" % (tag, i, n))
            print("   old[:120]=%r" % (old[:120],))
            return None
        text = text.replace(old, new, 1)
        print("  ok %s #%d" % (tag, i))
    return text


# ---------------------------------------------------------------- MEMORY.md
mem_edits = []

# (1) 武器尺度表的 5 行数据：第 7 轮全局 dmg ×0.5 + 第 8 轮喷火枪 splash 75→40
mem_edits.append((
    "| `knife` 金剑 | 31.1 | +8.71 | **39.82** | 95 | 95 | **−225** | 11,814（150° 扇形，**打扇形内全部敌人**）|\n"
    "| `flamethrower` 喷火枪 | **30.0** | +5.40 | **35.40** | 110 | **185** | **−135** | 17,671（splash 75）|\n"
    "| `thunder_gong` 土炸弹 | 22.2 | 0 | 22.2 | 400 | **495** | +175 | **28,353**（splash 95）|\n"
    "| `frost_staff` 水枪 | 23.3 | 0 | 23.3 | 642 | 642 | +322 | 0（slow 60%）|\n"
    "| `blight_bow` 木弓 | 24.0 | 0 | 24.0 | 708 | 708 | +388 | 0（纯距离安全）|\n",
    "> 下表 = **2026-09-17 冒烟 `BALANCE` 实测**（第 7 轮全局 dmg ×0.5 之后、第 8 轮喷火枪削 splash 之后）。\n"
    "> ⚠️ 第 2~6 轮记的 31.1 / 30.0 / 22.2 … 是**减半前**的旧值，别照抄（减半是全局同比，**关系不变**）。\n\n"
    "| `knife` 金剑 | 15.56 | +4.36 | **19.91** | 95 | 95 | **−225** | 11,814（150° 扇形，**打扇形内全部敌人**）|\n"
    "| `flamethrower` 喷火枪 | **15.0** | +2.70 | **17.70** | 110 | **150** | **−170** | **5,027**（splash 40）|\n"
    "| `thunder_gong` 土炸弹 | 11.11 | 0 | 11.11 | 400 | **495** | +175 | **28,353**（splash 95）|\n"
    "| `frost_staff` 水枪 | 11.67 | 0 | 11.67 | 642 | 642 | +322 | 0（slow 60%）|\n"
    "| `blight_bow` 木弓 | 12.0 | 0 | 12.0 | 708 | 708 | +388 | 0（纯距离安全）|\n",
))

# (2) 「喷火枪已闭环」段 → 第 8 轮用户点名削弱
mem_edits.append((
    "- ✅ **`flamethrower` 已闭环（第 5~6 轮）**：`splash` 60→75 / `price` 52→42（第 3 轮）、`dmg` 2.5→**3.0**（用户拍板）。\n"
    "  ⚠️ 第 6 轮补账后**别再给它加价**：185px 仍 < 270 → 它是「暴露更短的贴脸档」，**不是**远程档。\n"
    "  总账 35.40 < 金剑 39.82 合理（安全 90px）；> 后排 22~24 也合理（那三把站火力圈外）。\n"
    "  要让它真正「变中距离」应动 `bullet_life`（0.28→0.40 即 `reach_eff` 221px），**不是 dmg**。\n",
    "- ⚠️ **`flamethrower` 第 8 轮被用户点名削弱**（原话「喷火器范围好像也有问题，太远了」）：\n"
    "  `splash` 75→**40** → `reach_eff` 185→**150**、AOE 17,671→**5,027**（−71%）；连带**火焰锥改画到有效射程**\n"
    "  （`_ignite_flame_jet`）→ 从此「看到的 = 打到的」（此前视觉只画 110px，实际打到 185px，用户看到的是这个错位）。\n"
    "  进化体 `flamethrower_ex` 同步 105→**56**。⚠️ 这是**用户明确要求的削弱**，别因「金剑反而更强」加回去。\n"
    "  它现在定位 = **高频单体 + 小范围溅射**，不再是全场第二大 AOE；要变中距离动 `bullet_life`，**不是 dmg**。\n",
))

# (3) DoT 三条：数值同步
mem_edits.append((
    "  ③喷火枪燃烧按**被溅射到的敌人数**线性放大 → 5.40 只是「1 只怪」的下限。",
    "  ③喷火枪燃烧按**被溅射到的敌人数**线性放大 → 2.70 只是「1 只怪」的下限。",
))

# (4) §14 观察点的绝对值随全局减半
mem_edits.append((
    "  ③§14 观察点未触发：木+土+满 **72.2**，第 5 轮名次 15→**17** —— **绝对值没动**，只是被抬高的\n"
    "  喷火枪列挤下去，**别把「名次掉」读成「变弱」**。不加输出侧 cap。全场极差 1.65×\n",
    "  ③§14 观察点未触发：木+土+满 **36.11**（= 减半前 72.2 ÷2），第 5 轮名次 15→**17** ——\n"
    "  减半是**全局同比**，名次/极差关系不变，**别把「名次掉」读成「变弱」**。不加输出侧 cap。全场极差 1.65×\n",
))

# (5) 陷阱 9：喷火枪 reach_eff 的当前值
mem_edits.append((
    "   半径内**全额伤害**。旧口径只报弹体飞行距离 → 喷火枪 110 实为 **185**、土炸弹 400 实为 **495**，",
    "   半径内**全额伤害**。旧口径只报弹体飞行距离 → 喷火枪 110 实为 **150**（第 8 轮 splash 40）、土炸弹 400 实为 **495**，",
))

# (6) 陷阱追加 11 / 12
mem_edits.append((
    "    `slow`/`stun`/`freeze` 的 `dot_scale = 0`（纯控场，DoT 必须恰好 0）。\n",
    "    `slow`/`stun`/`freeze` 的 `dot_scale = 0`（纯控场，DoT 必须恰好 0）。\n"
    "11. **`get_meta(key, null)` 在 key 不存在时会刷 `ERR_FAIL` ERROR**（Godot 内部判 `p_default != Variant()`，\n"
    "    `null` 恰好命中）→ 一律**先 `has_meta` 再 `get_meta`**（第 8 轮 `hint_bubble.gd` 暂停面板每帧重建时踩爆，\n"
    "    表象只是「刷日志」，不会让冒烟变红）。\n"
    "12. **弹速/射程类加成按 `proj_kind` 分流**（第 8 轮）：`bullet` 吃 `bullet_speed_bonus`/`bullet_range_bonus`，\n"
    "    投掷物 `thrown`（土炸弹两态）只吃 `throw_speed_bonus`/`throw_range_bonus`。⚠️ 新武器忘标 `proj_kind`\n"
    "    会被**隐式当成 `bullet`** 吃满弹速加成 —— **不报错**，只是射程 / AOE 悄悄膨胀。\n",
))

# (7) 删除已过期的「📦 打包 Windows exe」整节（与「环境坑」里的打包条目重复，且内容已错：
#     说 mods/ 两个包都是故意的，实际 brotato_lite_core 已移进 mods_disabled/）
mem_edits.append((
    "## 📦 打包 Windows exe（2026-09-17 起）\n"
    "```bash\n"
    "\"D:/code/godot/Godot_v4.7.2-stable_win64_console.exe\" --headless --path game \\\n"
    "  --export-release \"Windows\" \"<abs>/export/BrotatoLite.exe\"\n"
    "```\n"
    "预设 `export_presets.cfg` `[preset.0] name=\"Windows\"`；模板在\n"
    "`%APPDATA%\\Godot\\export_templates\\4.7.2.stable\\`。`embed_pck=true` → **单文件 ~105 MB**、无 `.pck`；\n"
    "release 档**不产** `.console.exe`（那只在 debug 档）。耗时约 **11s**。\n"
    "实测 `BrotatoLite.exe --headless --quit-after 90` → 退出码 0 + `Registry: 已加载 37 条自定义内容`。\n"
    "- ⚠️⚠️ **首次启动会触发旧档迁移**（`save_slot_1.json` → `save_run.json`，**旧文件被删**）。\n"
    "  **别拿真实档裸试启动**，先备份 `%APPDATA%\\Godot\\app_userdata\\BrotatoLite\\`。\n"
    "- ⚠️ **`application/icon=\"\"` 是空的** → exe 用 Godot 默认图标（项目图标只有 `game/icon.svg`，需转 `.ico`）。\n"
    "- ⚠️ `export_filter=\"all_resources\"` → 包里含 `tests/smoke_test.gd` / `tools/parse_gate.gd`（无害白带体积）。\n"
    "- ✅ `mods/` 两个包都是故意的：`brotato-lite-core`（冻结内容）+ `example_mod`（工坊样例）。\n\n",
    "> 打包细节统一看下面「环境坑」段（本节原内容与那里重复，且写于 brotato_lite_core 移入 `mods_disabled/` 之前，已过时）。\n\n",
))

# (8) 文档清单补逐波平衡日志
mem_edits.append((
    "- `开工前*.md` = 开工前**预测账本**，行号已失效、别当代码真值。`五行核心玩法改造_规划.md` 待归档。",
    "- `开工前*.md` = 开工前**预测账本**，行号已失效、别当代码真值。`五行核心玩法改造_规划.md` 待归档。\n"
    "- `docs/逐波平衡日志.md` = 第 8 轮逐波日志（`user://balance_log.json`）的字段说明 + 怎么读；\n"
    "  配套阅读器 `game/tools/balance_report.py`（自动定位 `%APPDATA%/Godot/app_userdata/BrotatoLite/`）。",
))

# (9) 新增「第 8 轮」小节
round8 = (
    "## ⭐ 第 8 轮（2026-09-17）：交互入口 + 投掷通道 + 逐波平衡日志\n"
    "- **需求 1 退出入口**：全屏菜单与暂停面板都补了「退出」；`main._goto_main_menu()` 开头 `BalanceLog.close_run()`。\n"
    "- **需求 2 悬浮/点击说明**：商店 + 暂停面板支持「悬浮看属性说明、点道具名看加成/描述」，暂停时可翻图鉴。\n"
    "- **需求 3 投掷通道**（土炸弹吃子弹攻速太狠）：新增武器字段 **`proj_kind`**（默认 `\"bullet\"`，土炸弹两态 `\"thrown\"`）；\n"
    "  `player._weapon_runtime_cfg()` 按它分流 —— `bullet` 吃 `bullet_speed_bonus`/`bullet_range_bonus`，\n"
    "  `thrown` 只吃 **`throw_speed_bonus`/`throw_range_bonus`（新通道）**。⚠️ 土炸弹原本**没写 `bullet_life`**，\n"
    "  一直吃 `bullet.gd` 默认 1.1 → 射程是「隐式」的，所以才会被弹速类道具按同一套公式放大到 731px。\n"
    "- **需求 4 逐波平衡日志**：`scripts/systems/balance_log.gd` 是**静态工具类、不是 autoload**；落盘\n"
    "  `user://balance_log.json`（`latest` = 最新一波明细，`waves[]` 存 ≤120 波曲线）。\n"
    "  ⭐ **钉在存档点**（`main.gd:_finish_evolve_flow` 紧跟 `SaveRun.save`）→ **日志状态 ≡ 读档状态**，同源同刻；\n"
    "  与存档**独立文件**，阵亡/通关都保留。口径与开火路径同源（`player.weapon_reach()` / `_weapon_runtime_cfg()`），\n"
    "  **刻意不写预估 DPS**，避免和体检表分出第二个真值。\n"
    "  ⚠️ 伤害按来源拆分靠 `enemy.take_damage()` 的**第 5 参 `src`** 逐级透传（`bullet`/`explosion`/`artifact`/`trait`/`skill`），\n"
    "  **只喂日志、不进任何结算**。冒烟 `_check_balance_log()` 用一个 `TEST_SAVE_ROOT` 换根隔离真档。\n"
    "  ⚠️ 本轮连带修掉两个「不报错」的真 bug：`codex.gd:_effect_lines` 的残留 `return out`（**整脚本解析失败**，\n"
    "  连锁让引用它的脚本一起加载失败）与 `hint_bubble.gd` 的 `get_meta(_, null)` ERROR。\n\n"
)
mem_edits.append((
    "## ⭐ 五行进化形态（S8 第 4 轮补做 · 见体检表 §10）",
    round8 + "## ⭐ 五行进化形态（S8 第 4 轮补做 · 见体检表 §10）",
))

src = rd(MEM)
out = apply(src, mem_edits, "MEMORY")
if out is None:
    print("MEMORY NOT WRITTEN")
    sys.exit(1)
with io.open(MEM, "w", encoding="utf-8", newline="\n") as f:
    f.write(out)
print("MEMORY: %d -> %d chars (已写盘)" % (len(src), len(out)))

# ---------------------------------------------------------------- 日志追加
log_add = """
### 第 8 轮（22:50~23:40）：交互入口 + 投掷通道 + 逐波平衡日志
- 需求 1：全屏菜单 / 游戏内暂停面板都补上「退出」入口。
- 需求 2：商店 + 暂停面板的悬浮说明与点击详情（点道具名看加成+描述），暂停时可翻图鉴。
- 需求 3：土炸弹「吃子弹攻速」——新增 `proj_kind` 分流（`thrown` 只吃新开的 `throw_*` 通道，
  与 `bullet_*` 互不串味）；喷火枪 `splash` 75→40（`reach_eff` 185→150，AOE −71%），
  并把**火焰锥改画到有效射程**（此前视觉只画 110px、实际打到 185px，用户看到的「太远」就是这个错位）。
- 需求 4：**逐波平衡日志** —— 新增 `scripts/systems/balance_log.gd`（静态工具类，非 autoload），
  落盘 `user://balance_log.json`；钉在存档点（`main.gd:_finish_evolve_flow` 紧跟 `SaveRun.save`）
  → **日志状态 ≡ 读档状态**；与存档独立文件，阵亡/通关保留。接入 7 个文件共 24 处
  （player 10 / main 6 / enemy 3 / wave_manager 2 / bullet+explosion+artifact_system 各 1）。
- 工具链：`game/tools/balance_report.py`（读日志打印逐波曲线 + 掉队预警 + 最新一波明细）、
  `_selftest_balance_report.py`（合成 JSON 自检）、`_apply_round8_*.py`（批处理改动留痕）、
  文档 `docs/逐波平衡日志.md`。
- ⚠️ 连带修掉两个「不报错」的真 bug：`codex.gd` 的残留 `return out`（整脚本解析失败、连锁拖垮引用者）、
  `hint_bubble.gd` 的 `get_meta(key, null)` 每帧刷 ERROR。**教训：改用 `--headless --import` 当第一道门**
  （`--check-only --script` 只报 autoload 噪音，看不出真错）。
- ✅ 冒烟 `SMOKE: PASS`（日志 19,559 字符；`SMOKE: balance_log OK (waves=2)`、`meta ERROR 出现次数: 0`、
  `FAIL 出现次数: 0`）；`BALANCE base` = knife 15.56 / bow 12.0 / staff 11.67 / flame 15.0 / gong 11.11。
- ✅ 重导出 `export/BrotatoLite.exe`（110,672,048 字节，23:38），打包清单确认含 `balance_log.gdc` /
  `hint_bubble.gdc` / `entry_text.gdc`。
- ⚠️ 未闭环：20 波墙钟**仍未重跑**（第 7 轮的「三重上抬」难度 + 本轮喷火枪削弱叠加，实机看曲线）。
  实机日志落在 `%APPDATA%\\Godot\\app_userdata\\BrotatoLite\\balance_log.json`，用 `balance_report.py` 读。
"""

logsrc = rd(LOG)
if log_add.strip() in logsrc:
    print("LOG: 已存在，跳过（幂等保护）")
else:
    with io.open(LOG, "a", encoding="utf-8") as f:
        f.write(log_add)
    print("LOG: 追加 %d 字符 -> %d" % (len(log_add), len(logsrc) + len(log_add)))

print("DONE")
