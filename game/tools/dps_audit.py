# -*- coding: utf-8 -*-
"""
武器 DPS 体检表（一次性分析脚本，不参与游戏运行时）

数据源：直接解析 game/scripts/core/config.gd 的 WEAPONS 表 ——
price / shop_weight 已内联（A3 合并后单表真值），刻意不 hardcode，
避免表改了脚本不同步。

DPS 口径：
    远程： dmg * pellets / cd      （pellets 默认 1；arc/spread 视为散布，不改变总输出）
    近战： dmg / cd                （一次性扇形判定，swing_arc 覆盖视为全命中）

同时输出「每点伤害的单价」（price / DPS）用于核对定价是否与强度单调一致。
"""

import re
import sys
import os
from pathlib import Path

CFG = Path(__file__).resolve().parent.parent / "scripts" / "core" / "config.gd"

# 内层字段： key 可能带引号（"dmg": 12.0），也可能不带（mod 数据），统一允许
#   键名：[A-Za-z_]\w*          值：字符串 / 数组 / 数字 / 布尔
FIELD_RE = (r'"?([A-Za-z_][A-Za-z0-9_]*)"?\s*:\s*'
            r'("(?:[^"\\]|\\.)*"|\[[^\]]*\]|[-+]?[0-9.]+|true|false)')


def parse_block(text, const_name):
    """从 config.gd 里抠出 `const NAME := { ... }` 的内容，返回 {id: {k: v}}"""
    m = re.search(r"const\s+" + const_name + r"\s*:=\s*\{", text)
    if not m:
        raise SystemExit("找不到常量 " + const_name)
    i = m.end() - 1  # 指向 '{'
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                body = text[i + 1:j]
                break
    else:
        raise SystemExit("常量 " + const_name + " 括号不闭合")

    out = {}
    # body 是 WEAPONS 花括号内部的内容，因此每个 item 的 '{' 在 body 内是 depth 0→1。
    # 用一个显式的小型状态机逐字符扫描：遇到 '{' 进入 item，遇到匹配的 '}' 结束 item。
    i = 0
    n = len(body)
    while i < n:
        if body[i] == "{":
            # 从 '{' 往前找最近的 "key": 作为武器 id
            km = re.search(r'"([A-Za-z0-9_]+)"\s*:\s*$', body[:i])
            if not km:
                i += 1
                continue
            wid = km.group(1)
            # 找到与当前 '{' 配对的 '}'
            depth = 0
            j = i
            while j < n:
                if body[j] == "{":
                    depth += 1
                elif body[j] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            inner = body[i + 1:j]
            fields = {}
            for fm in re.finditer(FIELD_RE, inner):
                k, v = fm.group(1), fm.group(2)
                if v.startswith('"'):
                    fields[k] = v[1:-1]
                elif v.startswith("["):
                    fields[k] = v
                elif v in ("true", "false"):
                    fields[k] = (v == "true")
                else:
                    try:
                        fields[k] = float(v)
                    except ValueError:
                        fields[k] = v
            if "cd" in fields or "attack_type" in fields:
                out[wid] = fields
            i = j + 1
        else:
            i += 1
    return out


def parse_flat_dict(text, const_name):
    """解析 `const NAME := { "a": 1, "b": 2 }` 这类单层标量字典"""
    m = re.search(r"const\s+" + const_name + r"\s*:=\s*\{([^}]*)\}", text)
    if not m:
        raise SystemExit("找不到常量 " + const_name)
    out = {}
    for km in re.finditer(r'"([A-Za-z0-9_]+)"\s*:\s*([-+]?[0-9.]+)', m.group(1)):
        out[km.group(1)] = float(km.group(2))
    return out


def main():
    text = CFG.read_text(encoding="utf-8")
    weapons = parse_block(text, "WEAPONS")
    prices = {wid: w["price"] for wid, w in weapons.items() if "price" in w}
    weights = {wid: w["shop_weight"] for wid, w in weapons.items() if "shop_weight" in w}

    rows = []
    for wid, w in weapons.items():
        atk = w.get("attack_type", "projectile")
        cd = float(w.get("cd", 1.0))
        dmg = float(w.get("dmg", 0.0))
        pellets = int(w.get("pellets", 1) or 1)
        # 溅射期望：把 splash 半径折算成「等效额外命中数」是不靠谱的（取决于敌群密度），
        # 这里只标注 splash 存在，不虚增 DPS，避免给出虚假的精确感。
        splash = float(w.get("splash", 0.0) or 0.0)
        dps = dmg * pellets / cd if cd > 0 else 0.0
        price = prices.get(wid)
        weight = weights.get(wid)
        rows.append({
            "id": wid, "name": w.get("name", wid), "atk": atk,
            "rarity": w.get("rarity", "?"), "family": w.get("family", "?"),
            "cd": cd, "dmg": dmg, "pellets": pellets, "splash": splash,
            "dps": dps, "price": price, "weight": weight,
            "status": w.get("status", ""),
            "no_price": price is None, "no_weight": weight is None,
        })

    rows.sort(key=lambda r: -r["dps"])

    print("=" * 118)
    print("%-14s %-8s %-9s %-6s %6s %6s %5s %8s %7s %7s %8s" % (
        "id", "name", "atk", "rar", "cd", "dmg", "pel", "DPS", "price", "weight", "价/DPS"))
    print("=" * 118)
    for r in rows:
        price_s = "-" if r["price"] is None else "%.0f" % r["price"]
        w_s = "-" if r["weight"] is None else "%.2f" % r["weight"]
        ppd = "-" if (r["price"] is None or r["dps"] <= 0) else "%.2f" % (r["price"] / r["dps"])
        flag = " ⚠缺价" if r["no_price"] else (" ⚠缺权重" if r["no_weight"] else "")
        print("%-14s %-8s %-9s %-6s %6.2f %6.1f %5d %8.1f %7s %7s %8s%s" % (
            r["id"], r["name"], r["atk"], r["rarity"], r["cd"], r["dmg"],
            r["pellets"], r["dps"], price_s, w_s, ppd, flag))

    print()
    print("--- 定价 vs 强度：按「每点 DPS 的单价」排序（越低 = 性价比越高）---")
    priced = [r for r in rows if r["price"] is not None and r["dps"] > 0]
    priced.sort(key=lambda r: r["price"] / r["dps"])
    for r in priced:
        print("  %-14s %-8s 价 %4.0f  DPS %6.1f  →  %5.2f ◆/DPS   [%s/%s%s]" % (
            r["id"], r["name"], r["price"], r["dps"], r["price"] / r["dps"],
            r["rarity"], r["family"], " +splash" if r["splash"] > 0 else ""))

    print()
    print("--- 稀有度 × DPS 分布 ---")
    by_rar = {}
    for r in rows:
        by_rar.setdefault(r["rarity"], []).append(r["dps"])
    for rar in ["common", "rare", "epic", "mythic", "legendary"]:
        if rar not in by_rar:
            continue
        v = sorted(by_rar[rar])
        print("  %-10s n=%d  DPS %.1f ~ %.1f  (中位 %.1f)" % (
            rar, len(v), v[0], v[-1], v[len(v) // 2]))

    # 一致性检查：DPS 排名与价格排名是否单调
    print()
    print("--- 一致性检查 ---")
    by_price = sorted(priced, key=lambda r: r["price"])
    bad = 0
    for i in range(len(by_price) - 1):
        a, b = by_price[i], by_price[i + 1]
        if b["dps"] < a["dps"] * 0.6:
            bad += 1
            print("  ⚠ 价格更高的 %s(DPS %.1f) 明显弱于 %s(DPS %.1f)" % (
                b["id"], b["dps"], a["id"], a["dps"]))
    if bad == 0:
        print("  价格与 DPS 大体单调，无严重倒挂")
    else:
        print("  共 %d 处疑似倒挂" % bad)

    # 商店权重与强度
    print()
    print("--- 出货权重 vs DPS（权重高的应多为入门武器）---")
    pool = [r for r in rows if r["weight"] is not None and r["weight"] > 0]
    pool.sort(key=lambda r: -r["weight"])
    for r in pool:
        print("  w=%.2f  %-14s %-8s DPS %6.1f  价 %s" % (
            r["weight"], r["id"], r["name"], r["dps"],
            "-" if r["price"] is None else "%.0f" % r["price"]))

    return 0


if __name__ == "__main__":
    sys.exit(main())
