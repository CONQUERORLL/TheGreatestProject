"""直接调用 Godot 运行冒烟测试（绕过不可用的 PowerShell / Git Bash）。

用法（绝对路径）：
    C:/Users/Administrator/.workbuddy/binaries/python/versions/3.13.12/python.exe \
        game/tools/run_smoke_direct.py

为什么必须用 .tscn 场景方式：`-s` 脚本模式下 autoload 不加载，
所有 `EventBus` / `SaveRun` / `UiMetrics` 都会 Identifier not found。
"""
import subprocess
import sys
from pathlib import Path

GODOT = r"D:\code\godot\Godot_v4.7.2-stable_win64_console.exe"
PROJECT = r"D:\code\firstProject-ai\TheGreatestProject\game"
SCENE = "res://tests/smoke_test.tscn"
# 日志落在 tools/ 下，与 parse_gate 的 `_parse_gate.log` 一致。
# （以前写项目根 `smoke_run.log`，会让根目录反复积一个几 KB 的临时文件。）
LOG = Path(PROJECT) / "tools" / "_smoke_run.log"

def main() -> int:
    log = LOG.resolve()
    # 超时 600s：冒烟里有「等首杀（16s）+ 等整波（含 45s 波时）」这类真实计时等待，
    # 不是纯计算。S2 把首杀窗口从 8s 放宽到 16s 后，300s 会卡在上限（实测）。
    with open(log, "w", encoding="utf-8") as fh:
        proc = subprocess.run(
            [GODOT, "--headless", "--path", PROJECT, SCENE],
            stdout=fh, stderr=subprocess.STDOUT, timeout=600,
        )
    text = log.read_text(encoding="utf-8", errors="replace")
    print(text[-8000:])
    print(f"---- EXIT CODE: {proc.returncode} ----")
    return proc.returncode

if __name__ == "__main__":
    sys.exit(main())
