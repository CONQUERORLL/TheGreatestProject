# -*- coding: utf-8 -*-
"""把「`-c` 双引号字符串里的反引号会被 bash 吃掉」这条坑记进 MEMORY.md 的『环境坑』。"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file  # noqa: E402

LONG = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))), ".workbuddy", "memory", "MEMORY.md")

ANCHOR = "- ✅ **最可靠的一条路**：**Bash 里直接跑 `python.exe` 绝对路径、不带任何管道** → stdout 正常。"

NEW = """- ⚠️⚠️ **含反引号 / 双引号的文本绝不能塞进 `python -c \"...\"`**（2026-09-18 踩爆）：
  bash 会把反引号当**命令替换**、把内层 `\"` 当字符串结束 → 内容被**静默改写**
  （被反引号包起来的标识符整段消失，如 `pc` / `4ff3794` / `.gitignore`），
  而 python 照常打印「写成功」。症状 = **写成功了，但文件里少了所有反引号里的东西**。
  修法：**把内容写进 .py 文件再 `python <file>` 跑**（Write 工具不经 shell，无解析风险）；
  提交信息则走 `git commit -F <文件>`。
""" + ANCHOR

if __name__ == "__main__":
    ok = apply_file(LONG, [(ANCHOR, NEW)], "MEMORY-trap")
    print("RESULT:", "OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)
