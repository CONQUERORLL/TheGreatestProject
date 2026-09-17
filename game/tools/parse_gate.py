"""语法门禁包装器：2 秒内暴露 GDScript 解析错误，而不是等 10 分钟整轮冒烟。

为什么需要：
    修冒烟断言时，最常见的错误是缩进/作用域/符号名（Parse Error）。
    完整冒烟一轮 10 分钟以上，拿它当语法检查器成本不可接受。
    这个包装器跑 parse_gate.gd（只 load 冒烟脚本、不执行任何用例），
    然后扫日志里的 Parse Error 关键字。

⚠️ 退出码不可信：Godot 解析失败仍可能 exit 0（见 parse_gate.gd 注释），
    所以判定一律基于日志文本，不看 returncode。

用法：
    python.exe game/tools/parse_gate.py
"""

import os
import re
import subprocess
import sys

GODOT = r"D:/code/godot/Godot_v4.7.2-stable_win64_console.exe"
PROJECT = r"D:/code/firstProject-ai/TheGreatestProject/game"
LOG = os.path.join(PROJECT, "tools", "_parse_gate.log")

FAIL_PATTERNS = [
    re.compile(r"Parse Error"),
    re.compile(r"Failed to load script"),
    re.compile(r"Compile Error"),
]


def main() -> int:
    with open(LOG, "w", encoding="utf-8") as fh:
        subprocess.run(
            [GODOT, "--headless", "--path", PROJECT, "--script", "res://tools/parse_gate.gd"],
            stdout=fh,
            stderr=subprocess.STDOUT,
            timeout=180,
        )

    text = open(LOG, encoding="utf-8", errors="replace").read()

    hits = [ln for ln in text.splitlines() if any(p.search(ln) for p in FAIL_PATTERNS)]
    if hits:
        print("PARSE GATE: FAIL")
        for ln in hits:
            print("   ", ln.strip())
        return 1

    print("PARSE GATE: PASS (无解析错误)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
