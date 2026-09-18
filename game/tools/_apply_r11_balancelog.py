# -*- coding: utf-8 -*-
"""第 11 轮 · P0：修 BalanceLog 建目录失败（balance_log.json 从未落盘）。

根因：`_write()` 里 `ProjectSettings.globalize_path(_root.trim_suffix("/"))`
      —— `_root == "user://"`，trim 后成 `"user:/"`（单斜杠），globalize_path 认不出该 scheme
      会**原样返回**，于是 `make_dir_recursive_absolute("user:/")` 去建名为 `user:` 的目录 → 必失败。
      冒烟把测试根设成无尾斜杠，trim 恰好是空操作 → 一直是绿的。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path

TARGET = game_path("scripts", "systems", "balance_log.gd")

EDITS = [
    (
        'static var _root := "user://"\nstatic var _active := false',
        '## ⚠️⚠️ `_root` **恒以 "/" 结尾**（`"user://"` / `"user://tests/x/"`）—— 这是硬约束。\n'
        '##    写盘前要用 `ProjectSettings.globalize_path(_root)` 取绝对目录，而 Godot 只认 `user://`\n'
        '##    这个 scheme。曾经在这里对 `_root` 做了 `trim_suffix("/")` → `"user://"` 变成 **`"user:/"`**\n'
        '##    （单斜杠）→ `globalize_path` 认不出、**原样返回** → 去建一个名为 `user:` 的目录 → 必失败\n'
        '##    → `_write` 直接 return，正式包里 `balance_log.json` **从未落盘**（每波刷一对 ERROR/WARNING）。\n'
        '##    而冒烟把测试根设成**无尾斜杠**，`trim_suffix` 恰好是空操作 → 一直是绿的。\n'
        '##    ⇒ 教训：**测试根必须与正式根同形**，否则等于没测。\n'
        'static var _root := "user://"\nstatic var _active := false',
    ),
    (
        'static func set_storage_root_for_tests(path: String) -> void:\n\t_root = path.trim_suffix("/")',
        'static func set_storage_root_for_tests(path: String) -> void:\n'
        '\t_root = path.trim_suffix("/") + "/"   # 归一化成与正式根同形（见 _root 的注释）',
    ),
    (
        'static func path() -> String:\n\treturn _root.path_join(FILE)',
        'static func path() -> String:\n\treturn _root.path_join(FILE)\n'
        '\n'
        '## 写盘目录的**绝对**路径。独立成函数只为一件事：让冒烟能直接断言这一行 ——\n'
        '## 本模块曾静默失效整整一轮，就是坏在这个 globalize 的入参形态上。\n'
        'static func abs_dir() -> String:\n\treturn ProjectSettings.globalize_path(_root)\n'
        '\n'
        '## 只读访问器：冒烟用它断言「测试根 == 正式根形态」（尾斜杠这条不变式）。\n'
        'static func storage_root() -> String:\n\treturn _root',
    ),
    (
        '\tvar dir_err := DirAccess.make_dir_recursive_absolute(\n'
        '\t\tProjectSettings.globalize_path(_root.trim_suffix("/")))',
        '\tvar dir_err := DirAccess.make_dir_recursive_absolute(abs_dir())',
    ),
]

if not apply_file(TARGET, EDITS, "balance_log"):
    sys.exit(1)
