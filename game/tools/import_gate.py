# -*- coding: utf-8 -*-
"""解析门禁（第 9 轮）：真正编译全部脚本，只报「带行号的 Parse Error / 脚本编译错误」。

为什么不用 `--check-only --script`：那条路不加载 autoload，会刷一屏
`Identifier not found: UiMetrics/Registry/...` 噪音，看不出真错（第 8 轮踩过）。
`--headless --import` 会真正导入并编译 res:// 下所有脚本 —— 有真错必然带 `行号`。

用法：python.exe game/tools/import_gate.py [额外要跑的 godot 参数...]
退出码：0 = 无解析错误。
"""
import os
import re
import subprocess
import sys

ROOT = r"D:\code\firstProject-ai\TheGreatestProject"
GODOT = r"D:\code\godot\Godot_v4.7.2-stable_win64_console.exe"
GAME = os.path.join(ROOT, "game")
LOG = os.path.join(ROOT, "game", "tools", "_import_gate.log")

BAD = re.compile(
    r"(Parse Error|Could not parse|Expected |Identifier \"[^\"]+\" not declared"
    r"|Cannot infer the type|Cannot find member|Too many arguments|Invalid call"
    r"|Function \"[^\"]+\" not found|SCRIPT ERROR|Failed to load script)",
)


def main() -> int:
    args = [GODOT, "--headless", "--path", GAME]
    args += sys.argv[1:] if len(sys.argv) > 1 else ["--import"]
    env = dict(os.environ)
    p = subprocess.run(args, cwd=GAME, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=600, env=env)
    text = (p.stdout or "") + "\n" + (p.stderr or "")
    with open(LOG, "w", encoding="utf-8") as f:
        f.write(text)
    hits = []
    for line in text.split("\n"):
        s = line.strip()
        if not s or not BAD.search(s):
            continue
        # autoload 噪音（--check-only 才有，这里只是兜底过滤）
        if "Identifier not found: UiMetrics" in s or "Identifier not found: Registry" in s:
            continue
        hits.append(s)
    print("IMPORT GATE: %s" % ("PASS" if not hits else "FAIL (%d 行)" % len(hits)))
    for h in hits[:60]:
        print("   " + h[:240])
    print("（完整日志：%s；Godot 退出码 %d）" % (LOG, p.returncode))
    return 0 if not hits else 1


if __name__ == "__main__":
    sys.exit(main())
