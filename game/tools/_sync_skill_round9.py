# -*- coding: utf-8 -*-
"""第 9 轮：修订 `.workbuddy/skills/godot-smoke-test/SKILL.md`。

修的是**已过期/写错**的既有内容（本轮实地核实的真值），不是加新章节凑数：
  · `run_smoke_direct.py` 的超时 **300 → 600**（300 会卡在上限，脚本注释已写明）
  · 日志落点 **项目根/zz_smoke.txt → `game/tools/_smoke_run.log`**；只回显**最后 8000 字符**
  · 整轮耗时 **40~60s / ~100s → ≈35~40s**（2026-09-17 实测 38s）
  · 补 `import_gate.py` 作为**第一道门**（`--check-only` 只报 autoload 噪音，看不出真错）
  · 补「验证通过后必重导 exe」与 `_edit_util.py`（CRLF/LF 混用的批量替换器）
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import load, save, apply_edits  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SKILL = os.path.join(ROOT, ".workbuddy", "skills", "godot-smoke-test", "SKILL.md")

EDITS = [
    # ---- 1) 方式 A：脚本内部行为（超时 / 日志落点 / 截断 / 耗时）全部核准
    (
        """脚本内部做的事（见 `game/tools/run_smoke_direct.py`）：
1. `subprocess.run([GODOT, "--headless", "--path", <project>, "res://tests/smoke_test.tscn"], timeout=300)`
2. stdout/stderr 合并重定向到日志文件
3. 打印日志尾部 + `EXIT CODE`""",
        """脚本内部做的事（见 `game/tools/run_smoke_direct.py`，2026-09-17 实地核实）：
1. `subprocess.run([GODOT, "--headless", "--path", <project>, "res://tests/smoke_test.tscn"], timeout=600)`
   ⚠️ `timeout=600` 是**熔断上限、不是预期耗时**。真跑到 600s = **故障**（脚本加载失败 → 场景起不来
   → 什么都不打印 → 挂到被 Python 杀掉），不是「冒烟跑得慢」。
2. stdout/stderr 合并重定向到 **`game/tools/_smoke_run.log`**（**不是**项目根、也不是 `zz_smoke.txt`）
3. 只回显日志**最后 8000 字符** + `EXIT CODE` → 控制台看着「从中间开始」是**截断**，
   要核对检查条目就**读完整日志文件**
4. 正常整轮 **≈35~40 秒**（2026-09-17 实测 38s）""",
    ),
    # ---- 2) 方式 B 内联版超时同步
    (
        "stderr=subprocess.STDOUT, timeout=300)",
        "stderr=subprocess.STDOUT, timeout=600)",
    ),
    # ---- 3) 耗时数字
    (
        "> 正常整轮耗时约 **40~60 秒**（`perf` 段最重）。若超过 2 分钟没动静，",
        "> 正常整轮耗时 **≈35~40 秒**（2026-09-17 实测 38s）。若超过 2 分钟没动静，",
    ),
    (
        "整轮冒烟要 ~100 秒，而**语法/作用域错误在 2 秒内就能暴露**。",
        "整轮冒烟要 **35~40 秒**，而**语法/作用域错误在 2 秒内就能暴露**。",
    ),
    # ---- 4) 补第一道门（--import 真编译）
    (
        "## 改完冒烟脚本先跑「2 秒语法预检」（强烈建议）",
        """## 第一道门：`--headless --import` 真编译（比 `--check-only` 强）

`--check-only --script` **只报 autoload 噪音、看不出真错** —— 第 8 轮 `codex.gd` 的残留 `return out`
让**整脚本解析失败并连锁拖垮所有引用它的脚本**，而 `--check-only` 什么都没说。
**改动量稍大就先跑导入门禁**（真编译全部脚本，只报**带行号**的 `Parse Error`）：

```bash
C:/Users/Administrator/.workbuddy/binaries/python/versions/3.13.12/python.exe \\
  "D:/code/firstProject-ai/TheGreatestProject/game/tools/import_gate.py"
```

期望输出 `IMPORT GATE: PASS`。另有 `game/tools/parse_gate.py`（扫日志文本 → `PARSE GATE: PASS`）。

## 改完冒烟脚本先跑「2 秒语法预检」（强烈建议）""",
    ),
    # ---- 5) 补收尾：必重导 exe + 批量改代码工具
    (
        "## 路径速查",
        """## 验证通过后的收尾（铁律：改完必重导 exe）

冒烟 `PASS` **不等于**玩家拿到的是新代码 —— exe 是**打包快照**，改了 `.gd` / `.tscn` 必须重导：

```bash
"D:/code/godot/Godot_v4.7.2-stable_win64_console.exe" --headless \\
  --path "D:/code/firstProject-ai/TheGreatestProject/game" --export-release "Windows"
```

- 产物 `export/BrotatoLite.exe`（预设 `[preset.0]` 已写好 `export_path`），约 **8s**、**~105 MB**。
- 校验：比对**字节数 / md5 / mtime** 是否变化，并在**打包进度清单**里确认新脚本 `xxx.gdc`
  （及新 `.tscn.remap`）确实进了包 —— 这是「改动真的进了包」的直接证据。
- 启动自检 `BrotatoLite.exe --headless --quit-after 90` → 期望**退出码 0**；
  `ObjectDB instances were leaked` 是**非失败**噪音（`--verbose` 看是 `AudioStreamWAV` +
  `AudioStreamPlaybackWAV`，即 `Music` autoload 在强制退出时不释放播放流，**与改动无关**）。

## 批量改代码：用 `game/tools/_edit_util.py`

本项目**同一目录混着 CRLF 与 LF**（`main_menu.gd` / `level_up_ui.gd` 是 CRLF，
`main.gd` / `config.gd` / `player.gd` 是 LF）→ 锚点里写死 `\\n` 会在 CRLF 文件上**命中 0 次**。

```python
from _edit_util import load, save, apply_edits
text, crlf = load(path)
out = apply_edits(text, [(old, new), ...], "tag", crlf)   # 每处断言命中「恰好 1 次」
if out is None: sys.exit(1)                              # 全过才写盘（原子）
save(path, out)                                          # 写回保持原换行
```

⚠️ 不要在同一文件上用 Edit 工具**连发两处改动**（会丢写，且两处都报 success）。

## 路径速查""",
    ),
    # ---- 6) 路径速查补行
    (
        "| 运行脚本 | `D:\\code\\firstProject-ai\\TheGreatestProject\\game\\tools\\run_smoke_direct.py` |",
        """| 运行脚本 | `D:\\code\\firstProject-ai\\TheGreatestProject\\game\\tools\\run_smoke_direct.py` |
| 冒烟完整日志 | `D:\\code\\firstProject-ai\\TheGreatestProject\\game\\tools\\_smoke_run.log` |
| 导入门禁 | `D:\\code\\firstProject-ai\\TheGreatestProject\\game\\tools\\import_gate.py` |
| 解析门禁 | `D:\\code\\firstProject-ai\\TheGreatestProject\\game\\tools\\parse_gate.py` |
| 批量改码工具 | `D:\\code\\firstProject-ai\\TheGreatestProject\\game\\tools\\_edit_util.py` |
| 打包产物 | `D:\\code\\firstProject-ai\\TheGreatestProject\\export\\BrotatoLite.exe` |""",
    ),
]


def main():
    text, crlf = load(SKILL)
    out = apply_edits(text, EDITS, "SKILL", crlf)
    if out is None:
        print("SKILL NOT WRITTEN（保持原样）")
        return 1
    save(SKILL, out)
    print("SKILL: %d -> %d chars (已写盘, %s)" % (len(text), len(out), "CRLF" if crlf else "LF"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
