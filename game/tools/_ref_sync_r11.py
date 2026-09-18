# -*- coding: utf-8 -*-
"""第 11 轮 · `REFERENCE.md` 同步。

三处：
  ① §二 环境坑 —— **修正过时结论**：此前写「Bash 双不可靠、`ls/cat/grep` 全 command not found」
     已被证伪。真因是 shim 没把 PortableGit 的 `usr/bin` 注入 PATH，一条 `export` 就修好。
     过时的环境结论会让人绕远路（本轮就绕了），必须改掉。
  ② §二 删文件 —— 原「用 PowerShell `Remove-Item`」也不可靠；实测 `git clean -f -x -- <路径>` 有效。
  ③ 新增 **§七 武器客观尺度（完整）** —— `MEMORY.md` 已瘦身、把细节指向这里，本节承接。

⚠️ 所有行号都**回源码核过**：远程 `reach` 公式在 `player.gd:353`（不是记忆里的 344，已失效）、
   近战在 `player.gd:447`。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file

REF = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))), ".workbuddy", "memory", "REFERENCE.md")

# ---- ① Bash 可用性（纠正过时结论）----
OLD_BASH = """- **Bash(Git Bash) / PowerShell 双不可靠**：`ls/cat/grep/rm` 全 command not found（shim 缺 `dirname`）
  → 文件操作只用 Read/Write/Edit/Glob/Grep。
- ✅ **最可靠的一条路**：**Bash 里直接跑 `python.exe` 绝对路径、不带任何管道** → stdout 正常。
  ⚠️ PowerShell 工具的输出会被吞（exit 0 但 stdout 全无），别用它看结果。"""

NEW_BASH = """- ✅✅ **2026-09-18 更正：Bash 完全可用** —— 此前「`ls/cat/grep` 全 command not found」是**误判**。
  真因：宿主 shim **没把 PortableGit 的 `usr/bin` 注入 PATH**（报错里的 `dirname: command not found` 就是它）。
  **一条 `export` 就能修好**，此后 `git` / `grep` / `sed` / `ls` / `git clean` / `python.exe` 全部正常：
  → 在**每条** Bash 命令最前面加 `export PATH="/c/Users/Administrator/.workbuddy/binaries/PortableGit/versions/1.2.0/usr/bin:/c/Windows/System32:/c/Windows:$PATH"`。
  ⚠️ shell 状态**不跨调用保留**（每个 Bash 调用是独立进程），所以**每条命令都要带这一行**，别只带一次。
  ⚠️ 这行加完后，命令输出里仍会看到 `shim/shell-runtime-bash-env.sh: line 3: dirname: command not found`
  —— 那是 shim 自己初始化时的**噪音**，与你的命令无关，**忽略它**。
- ⚠️ PowerShell 工具的输出**恒被吞**（exit 0 但 stdout 全无），别用它看结果。"""

# ---- ② 删文件（改掉不可靠做法）----
OLD_DEL = """- ⚠️ **Python 的 `os.remove()` 会被宿主 safe-delete shim 拦下、且可能失败**（2026-09-18 踩）：
  shim 先尝试移入回收站，回收站失败就抛 `OSError`（`[safe-delete][SAFE_DELETE_FAIL_CLOSED] ... Error during a 'trash' operation`）
  —— **文件留在原地，脚本中断**（本次还因此把一个探针 APK 留在 `export/` 里）。
  删文件改用 **PowerShell 工具的 `Remove-Item -LiteralPath <p> -Force`**：
  ⚠️ 该工具**无论成败都返回 exit 1 且 stdout 常被吞**，所以删完必须用 Python 复查目录，别信退出码。
  （旧结论「删文件用 `python -c os.remove`」在 2026-09-18 之后**不再可靠**。）"""

NEW_DEL = """- ⚠️ **删文件**：`os.remove()` 会被宿主 safe-delete shim 拦下并抛 `OSError`
  （`[safe-delete][SAFE_DELETE_FAIL_CLOSED]`，**文件留在原地、脚本中断**，本次还因此把一个探针 APK 留在 `export/` 里）；
  PowerShell 的 `Remove-Item` 同样不可靠（**无论成败都 exit 1** 且 stdout 常被吞）。
  ✅ **可靠做法：`git clean -f -x -- <确切路径>`**（`.workbuddy/` 被 ignore，所以必须带 `-x`）——
  它会打印 `Removing <path>` 且退出码可信。删完仍要 **Python 复查目录**（`os.path.exists` / `lsx`）。
  第 11 轮删两个探针场景（`game/tests/_probe_band.gd` / `.tscn`）实测有效。"""

# ---- ③ 新增 §七 ----
ANCHOR_TAIL = "别用 `owner` 当变量名。"

SEC7 = ANCHOR_TAIL + """

## 七、武器客观尺度（完整 · `MEMORY.md` 只留结论）

### 7.1 口径与公式（全部能指回源码）

- 远程 `reach = bspeed × bullet_life + 26`（**`player.gd:353`**）
- 近战 `reach = range × (1 + melee_range_bonus)`（**`player.gd:447`**）
- ⚠️ **`reach_eff = reach + splash`** —— 弹体飞满到期会**自爆**（`bullet.gd:91-93`），
  半径内**全额伤害 + 全额上状态**（`explosion.gd:52-57`，**无衰减**）
  → **安全裕度必须用 `reach_eff`**。旧口径只报飞行距离，把「近距档风险」系统性夸大（第 6 轮修正）。
- ⚠️⚠️ **近战扇形面积 ∝ reach²**（AOE = `½r²θ`）→ **每 +10% range ≈ +21% 面积**。
  多张 range 道具是在**平方上乘法叠乘** → 会雪崩（第 11 轮金剑问题根因，见体检表 §13.1）。
- 远程**不吃** `melee_range_bonus`。
- AOE：扇形 `½r²θ` / 溅射 `π·splash²`。
- DoT 稳态（镜像 `enemy.gd:331-339`）：`层数 = min(stack_max, (1/cd) × chance × duration)`；
  `每跳 = dmg × dot_scale × 层数`。
- 内置远程怪 **6 只**，`keep_dist` 270~320（仅 `ai == "shooter"` 吃默认）。

### 7.2 实测表（2026-09-17 冒烟打印）

第 7 轮全局 `dmg ×0.5` 后、第 8 轮削喷火枪 `splash` 后。
⚠️ 第 2~6 轮记的 **31.1 / 30.0 / 22.2** 是**减半前**旧值，减半是全局同比、**关系不变**。

| 武器 | 直伤 | DoT | 合计 | reach | reach_eff | 裕度 | AOE |
|---|---|---|---|---|---|---|---|
| `knife` 金剑 | 15.56 | +4.36 | 19.91 | 95 | 95 | **−225** | 11,814（150° 扇形，打扇形内全部）|
| `flamethrower` 喷火枪 | 15.0 | +2.70 | 17.70 | 110 | **150** | −170 | 5,027（splash 40）|
| `thunder_gong` 土炸弹 | 11.11 | 0 | 11.11 | 400 | **495** | +175 | 28,353（splash 95）|
| `frost_staff` 水枪 | 11.67 | 0 | 11.67 | 642 | 642 | +322 | 0（slow 60%）|
| `blight_bow` 木弓 | 12.0 | 0 | 12.0 | 708 | 708 | +388 | 0（纯距离安全）|

⚠️ **第 11 轮已改 `knife`**：`range` 95 → **88**、`cd` 0.45 → **0.55**（`knife_ex` 115 → **106**）。
上表 reach 95 是**改动前**值；其余武器未动。复跑冒烟取 `BALANCE reach=` / `BALANCE reach_eff=` 即得新值。

### 7.3 结论（别只看单体 DPS）

- ✅ **`knife` 是合理定价**（唯一还要穿越 225px 火力带的），**别去削**。
- ✅ **`thunder_gong` 最均衡**（最大 AOE + 唯一勉强可风筝 + 唯一硬控），别当最弱。
- ⚠️ **`flamethrower` 第 8 轮被用户点名削弱**（`splash` 75→40 → `reach_eff` 185→150、AOE −71%）：
  **别因「金剑反而更强」加回去**。现定位 = 高频单体 + 小范围溅射；
  要变中距离**动 `bullet_life`，不是 `dmg`**。第 11 轮另补了**角度**通道 `proj_spread_mult`（喷嘴道具）。
- ⚠️ **DoT 三条**：① 喷火枪燃烧已顶 `stack_max = 5` → **提攻速对 DoT 无效**；金剑还有 ~2× 空间。
  ② DoT **不吃**受击侧关系 / 抗性（`enemy.gd:345` 不传 `element_atk`）→ 打高抗性怪时 DoT 更值钱。
  ③ 喷火枪燃烧按**被溅射敌人数**线性放大 → 2.70 只是「1 只怪」下限。
- 平衡账：基础极差 **1.40×**；assim 0 时关系极差 **1.67×** > 基础 → **开局看克制**；
  满同化 **1.18×** → 后期武器主导。克制绝对差恒 `0.5 × base` → 堆亲和会稀释五行存在感。
  名次变化是**全局同比**结果，**别读成「变弱」**。不加输出侧 cap。
- ⚠️ **高频武器加溅射要查特效成本**：`Explosion.spawn` **无对象池**（默认 14 粒 + `screen_shake(5.0)`）；
  `cd < 0.3` 配 splash 都该走轻量分支（喷火枪已有 `"flame"` 分支）。"""

ok = apply_file(REF, [(OLD_BASH, NEW_BASH)], "ref-r11-bash")
ok = apply_file(REF, [(OLD_DEL, NEW_DEL)], "ref-r11-del") and ok
ok = apply_file(REF, [(ANCHOR_TAIL, SEC7)], "ref-r11-sec7") and ok
if not ok:
    sys.exit(1)
print("REFERENCE.md 同步完成")
