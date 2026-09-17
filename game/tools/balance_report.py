"""逐波平衡日志阅读器（配套 `game/scripts/systems/balance_log.gd`）。

用法：
    C:/Users/Administrator/.workbuddy/binaries/python/versions/3.13.12/python.exe \
        game/tools/balance_report.py                # 自动定位 user://balance_log.json
    ... game/tools/balance_report.py <path.json>    # 指定日志文件

它只做两件事：
  1. 打印**逐波曲线**（等级 / DPS / 承伤 / 最低血量 / 材料 / 构筑），一眼看出哪一波开始掉队；
  2. 打印**最新一波**的明细（全量属性、每把武器的实战参数、伤害来源拆分）。

⚠️ 数据口径全部来自日志本身，本脚本**不复算任何游戏公式**（射程 / 冷却都由游戏写进日志）。
   `dps` = 该波伤害总量 ÷ 该波战斗时长（不含 intro / 商店），所以它天然包含走位、空枪与溢出伤害。
"""
import json
import os
import sys
import unicodedata

DEFAULT_NAME = "balance_log.json"
APP_NAME = "BrotatoLite"

# 统计键的中文名（与 hud.gd 的属性名表同源；这里只列曲线里出现的那些）
STAT_CN = {
    "max_hp": "生命上限", "regen": "回血", "armor": "护甲", "dodge": "闪避",
    "dmg_mult": "伤害", "as_mult": "攻速", "crit_ch": "暴击率", "crit_mult": "暴击伤害",
    "speed_mult": "移速", "lifesteal": "吸血", "pickup_range": "拾取范围",
    "harvesting": "收获", "status_chance": "状态概率", "status_dmg_mult": "状态伤害",
}
ELEM_CN = {"metal": "金", "wood": "木", "water": "水", "fire": "火", "earth": "土"}

# 曲线表列：(键, 表头, 宽, 是否右对齐, 小数位)
COLS = [
    ("wave", "波", 3, 1, 0), ("level", "等级", 4, 1, 0),
    ("kills", "击杀", 4, 1, 0), ("spawned", "出怪", 4, 1, 0),
    ("dps", "DPS", 6, 1, 0), ("damage_dealt", "总伤害", 7, 1, 0),
    ("damage_taken", "承伤", 6, 1, 0), ("heal", "回复", 5, 1, 0),
    ("hp_pct", "最低血%", 7, 1, 0), ("materials", "材料", 5, 1, 0),
    ("materials_gained", "本波材料", 8, 1, 0), ("duration", "时长", 5, 1, 0),
]


def dw(s: str) -> int:
    """显示宽度：CJK / 全角记 2 列，其余 1 列 —— 否则中文表头会整体错位。"""
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in str(s))


def pad(s, width: int, right: bool = False) -> str:
    gap = " " * max(0, width - dw(s))
    return (gap + str(s)) if right else (str(s) + gap)


def find_log() -> str:
    """自动定位：先找 %APPDATA%/Godot/app_userdata/<项目名>/，再退到脚本同级目录。"""
    appdata = os.environ.get("APPDATA", "")
    cand = []
    if appdata:
        cand.append(os.path.join(appdata, "Godot", "app_userdata", APP_NAME, DEFAULT_NAME))
        # 导出模板里 config/name 可能带后缀，宽松匹配一下
        root = os.path.join(appdata, "Godot", "app_userdata")
        if os.path.isdir(root):
            for d in os.listdir(root):
                if APP_NAME.lower() in d.lower():
                    cand.append(os.path.join(root, d, DEFAULT_NAME))
    here = os.path.dirname(os.path.abspath(__file__))
    cand.append(os.path.join(here, DEFAULT_NAME))
    cand.append(os.path.join(here, "..", "..", DEFAULT_NAME))
    for p in cand:
        if os.path.isfile(p):
            return p
    return ""


def cell(entry: dict, key: str, dec: int) -> str:
    v = entry.get(key)
    if v is None:
        v = 0
    if isinstance(v, float):
        return f"{v:.{dec}f}"
    if isinstance(v, int):
        return f"{v:d}" if dec == 0 else f"{float(v):.{dec}f}"
    return str(v)


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else find_log()
    if not path or not os.path.isfile(path):
        print("找不到平衡日志。先在游戏里打一波（存档点会落盘），或用参数指定 json 路径。")
        return 1
    with open(path, encoding="utf-8") as fh:
        d = json.load(fh)
    run = (d.get("latest") or {}).get("run") or {}
    latest = d.get("latest") or {}
    waves = d.get("waves") or []
    print(f"日志：{path}")
    print(f"更新：{d.get('updated_at', '?')}   版本 v{d.get('version', '?')}")
    print(f"本局：{run.get('character_name', '?')}({run.get('character', '?')}) / "
          f"{run.get('difficulty_name', '?')} / 主题 {run.get('map_theme', '?')} / "
          f"元素 {run.get('area_element', '-') or '-'}"
          + (" / 无尽" if run.get("endless") else "")
          + (" / 每日" if run.get("daily") else ""))
    print(f"最新：第 {latest.get('wave', '?')} 波 · {latest.get('outcome', '?')} · "
          f"共 {len(waves)} 波记录\n")
    if not waves:
        return 0

    # ---------------- 逐波曲线 ----------------
    print("  ".join(pad(COLS[i][1], COLS[i][2], True) for i in range(len(COLS))) + "  武器")
    for w in waves:
        hp_max = float(w.get("hp_max") or 0.0)
        hp_min = float(w.get("hp_min") or 0.0)
        row_src = dict(w)
        row_src["hp_pct"] = (hp_min / hp_max * 100.0) if hp_max > 0 else 0.0
        cells = [pad(cell(row_src, k, dec), width, bool(right))
                 for k, _h, width, right, dec in COLS]
        weapons = ",".join(short_weapon(x) for x in (w.get("weapons") or []))
        print("  ".join(cells) + "  " + weapons)

    # 掉队预警：DPS 不涨 / 承伤飙升 / 最低血量贴地，这三条是「打不过了」的前兆
    flags = []
    for i in range(1, len(waves)):
        a, b = waves[i - 1], waves[i]
        if float(b.get("dps") or 0) < float(a.get("dps") or 0) * 0.85:
            flags.append(f"第 {b.get('wave')} 波 DPS 环比下滑 "
                         f"{float(a.get('dps') or 0):.0f}→{float(b.get('dps') or 0):.0f}")
        if float(b.get("damage_taken") or 0) > float(a.get("damage_taken") or 0) * 1.5 + 1:
            flags.append(f"第 {b.get('wave')} 波承伤环比放大 "
                         f"{float(a.get('damage_taken') or 0):.0f}→{float(b.get('damage_taken') or 0):.0f}")
    for w in waves:
        hp_max = float(w.get("hp_max") or 0.0)
        if hp_max > 0 and float(w.get("hp_min") or 0) / hp_max < 0.25:
            flags.append(f"第 {w.get('wave')} 波最低血量跌破 25%"
                         f"（{float(w.get('hp_min') or 0):.0f}/{hp_max:.0f}）")
    if flags:
        print("\n⚠️ 预警：")
        for f in flags:
            print("   - " + f)

    # ---------------- 最新一波明细 ----------------
    snap = latest.get("player") or {}
    wd = latest.get("wave_data") or {}
    print(f"\n---- 第 {latest.get('wave', '?')} 波明细 ----")
    st = snap.get("stats") or {}
    keys = [k for k in STAT_CN if k in st]
    for i in range(0, len(keys), 4):
        print("   " + "   ".join(
            f"{STAT_CN[k]}: {float(st.get(k) or 0):.2f}" for k in keys[i:i + 4]))
    assims = [f"{ELEM_CN.get(e, e)} {float(st.get('assim_' + e) or 0) * 100:.0f}%"
              for e in ELEM_CN if "assim_" + e in st]
    if assims:
        print("   同化度: " + " / ".join(assims))
    print(f"   血量: {float(snap.get('hp') or 0):.0f}/{float(snap.get('max_hp') or 0):.0f}"
          f"（本波最低 {float(wd.get('hp_min') or 0):.0f}）"
          f"   元素: {snap.get('element') or '无'}   印记: {snap.get('sigil') or '无'}")
    trait = (snap.get("char_trait") or {})
    if trait:
        print(f"   特性: {trait.get('name', '?')} [{trait.get('kind', '?')}]")
    print("   武器:")
    for w in snap.get("weapons") or []:
        extra = ""
        if float(w.get("splash") or 0) > 0:
            extra += f"  溅射 {float(w.get('splash')):.0f}px"
        if int(w.get("pellets") or 1) > 1:
            extra += f"  弹丸×{w.get('pellets')}"
        if w.get("proj_kind") not in (None, "", "bullet"):
            extra += f"  [{w.get('proj_kind')}]"
        print(f"     · {w.get('name')}({w.get('id')}) ×{w.get('count')}"
              f"  {'进化' if w.get('evolved') else '基础'}"
              f"  伤害 {w.get('dmg')}  冷却 {float(w.get('cd_effective') or 0):.2f}s"
              f"  射程 {float(w.get('reach') or 0):.0f}px" + extra)
    items = snap.get("items") or []
    print(f"   道具 ×{sum(int(i.get('count') or 0) for i in items)}: "
          + (", ".join(f"{i.get('name')}×{i.get('count')}" for i in items) or "无"))
    arts = snap.get("artifacts") or []
    print(f"   法宝 ×{len(arts)}: "
          + (", ".join(f"{a.get('name')}" + (f"({a['stacks']}层)" if a.get("stacks") else "")
                       for a in arts) or "无"))
    if snap.get("upgrades"):
        print(f"   升级 ×{len(snap['upgrades'])}")
    src = wd.get("by_source") or {}
    total = sum(float(v) for v in src.values()) or 1.0
    if src:
        print("   伤害来源:")
        for k, v in sorted(src.items(), key=lambda kv: -float(kv[1])):
            print(f"     · {pad(k, 14)}{float(v):>9.0f}  ({float(v) / total * 100:>5.1f}%)")
    print(f"   本波: 时长 {float(wd.get('duration') or 0):.1f}s"
          f"（墙钟 {float(wd.get('duration_wall') or 0):.1f}s）"
          f"  击杀 {wd.get('kills')}/{wd.get('spawned')}"
          f"  DPS {float(wd.get('dps') or 0):.0f}"
          + ("  [BOSS 波]" if wd.get("boss_wave") else "")
          + (f"  [{wd.get('event')}]" if wd.get("event") else ""))
    rules = run.get("run_rules") or {}
    if rules and rules.get("id") not in (None, "", "default", "standard"):
        print(f"   自定义规则: {rules}")
    return 0


def short_weapon(wid) -> str:
    """武器列只求能认出构筑：去下划线取前 5 字符。"""
    return str(wid).replace("_", "")[:5]


if __name__ == "__main__":
    sys.exit(main())
