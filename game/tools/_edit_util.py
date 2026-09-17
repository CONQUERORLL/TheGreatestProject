# -*- coding: utf-8 -*-
"""批量改脚本的共用工具（第 9 轮新增）。

为什么需要它：本项目**同一目录下混着 CRLF 与 LF 两种换行**（实测：`main_menu.gd` /
`level_up_ui.gd` / `event_card.gd` / `run_rules.gd` / `loot.gd` 是 CRLF，
`shop_ui.gd` / `main.gd` / `config.gd` / `enemy.gd` / `player.gd` 是 LF）。
锚点里写死 `\\n` 会在 CRLF 文件上**命中 0 次**（脚本安全失败，但会白跑一轮）。

用法：
    from _edit_util import load, save, apply_edits
    text, crlf = load(path)
    out = apply_edits(text, [(old, new), ...], "tag", crlf)
    if out is None: sys.exit(1)
    save(path, out)

规则（沿用本项目既有做法，效果很好）：
  · 每处 (old, new) 断言 old 在全文**命中恰好 1 次** —— 命中 0 次说明锚点过期，
    命中 2 次说明锚点不够特化（曾拦下过 `p2.weapons = []` 这类会写坏文件的改动）
  · **全部通过才写盘**（原子性），任一失败则整文件不动
  · 写回时保持原文件的换行风格
"""
import io
import os
import sys


def load(path):
    """返回 (text, is_crlf)。newline='' 保证不把 \\r\\n 折叠掉。"""
    with io.open(path, encoding="utf-8", newline="") as f:
        text = f.read()
    return text, ("\r\n" in text)


def save(path, text):
    with io.open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def to_eol(s, crlf):
    """把裸 \\n 锚点/新文本转成目标文件的换行风格（已是 \\r\\n 的不重复转）。"""
    if not crlf:
        return s.replace("\r\n", "\n")
    return s.replace("\r\n", "\n").replace("\n", "\r\n")


def apply_edits(text, edits, tag, crlf, verbose=True):
    """逐条替换，全部成功才返回新文本；任一失败返回 None 并停在原地。"""
    for i, (old, new) in enumerate(edits):
        o = to_eol(old, crlf)
        n = to_eol(new, crlf)
        cnt = text.count(o)
        if cnt != 1:
            print("FAIL %s #%d 命中 %d 次（要求 1）" % (tag, i, cnt))
            print("   old[:200]=%r" % (o[:200],))
            return None
        text = text.replace(o, n, 1)
        if verbose:
            print("  ok %s #%d" % (tag, i))
    return text


def apply_file(path, edits, tag, verbose=True):
    """读写一条龙。成功返回 True。"""
    text, crlf = load(path)
    out = apply_edits(text, edits, tag, crlf, verbose)
    if out is None:
        print("%s NOT WRITTEN（文件保持原样）" % tag)
        return False
    save(path, out)
    print("%s: %d -> %d chars (已写盘, %s)" % (tag, len(text), len(out), "CRLF" if crlf else "LF"))
    return True


def root():
    """项目根目录（本文件固定放在 game/tools/ 下）。"""
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def game_path(*parts):
    return os.path.join(root(), "game", *parts)
