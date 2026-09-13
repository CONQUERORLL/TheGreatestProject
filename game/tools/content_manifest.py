# -*- coding: utf-8 -*-
"""
内容调参清单生成器（开发期工具，不参与游戏运行时）

数据源（直接解析源码，刻意不 hardcode）：
  · game/scripts/core/config.gd    —— WEAPONS / ITEMS / UPGRADES / STATUS / *_UNLOCKS
  · game/scripts/core/registry.gd  —— characters（角色 = stats 差异 + trait + skill）

输出：docs/内容调参清单.md

为什么不手写清单：
  角色 12 + 武器 28 + 道具 57 = 97 条内容，每条还有 5~15 个数值。手抄一次就过期，
  而且「文档说 52 件道具、代码里 57 件」这种漂移正是本项目踩过的坑。
  改成解析同一份真值后，重跑即同步（与 tools/dps_audit.py 同一套做法）。

用法（仓库根或任意目录均可）：
  python game/tools/content_manifest.py
"""

import re
import sys
from pathlib import Path

GAME = Path(__file__).resolve().parent.parent          # .../game
REPO = GAME.parent                                     # 仓库根
CFG = GAME / "scripts" / "core" / "config.gd"
REG = GAME / "scripts" / "core" / "registry.gd"
OUT = REPO / "docs" / "内容调参清单.md"

# 武器家族展示顺序（Config 里按「攻击类型 + 元素」混排，清单里按家族聚一下更好读）
FAMILY_ORDER = ["gun", "blade", "element", "heavy"]
FAMILY_NAME = {
    "gun": "枪械 gun", "blade": "刀剑 blade",
    "element": "元素 element", "heavy": "重武器 heavy",
}
RARITY_ORDER = ["common", "rare", "epic", "mythic", "legendary"]
RARITY_CN = {
    "common": "普通", "rare": "稀有", "epic": "史诗",
    "mythic": "神话", "legendary": "传说",
}
ATK_CN = {"projectile": "远程", "melee": "近战"}
STATUS_CN = {
    "burn": "燃烧", "poison": "中毒", "bleed": "流血",
    "freeze": "冰冻", "slow": "减速", "stun": "眩晕",
}
KIND_CN = {
    "stats": "属性注入", "aura": "光环", "thorns": "荆棘反击", "momentum": "战意",
}
SKILL_CN = {
    "buff": "限时增益", "burst_damage": "范围爆发", "nova_status": "范围施状态",
    "self_heal": "自我回复", "grant_materials": "获取材料",
}
# 特性 / 技能的非属性参数（radius、interval 这类结构参数）
PARAM_CN = {
    "status": "施加状态", "radius_mult": "半径倍率", "interval": "触发间隔(s)",
    "dmg": "每次伤害", "power": "状态强度", "stacks": "施加层数",
    "per_kills": "每 N 击杀", "per_stack": "每层增伤", "max_bonus": "增伤上限",
    "duration": "持续(s)", "radius": "半径", "mult": "伤害倍率",
    "materials": "获得材料", "momentum_stacks": "战意层数",
    "stun_radius": "眩晕半径", "stun_dur": "眩晕时长(s)", "heal_pct": "回复比例",
    "cd": "冷却(s)",
}
PARAM_PCT = {"per_stack", "heal_pct", "max_bonus"}

# 数值键 → 中文（角色 stats / 道具 effects / 升级 effects 共用的一套）
STAT_CN = {
    "max_hp": "最大生命", "heal_flat": "立即回复", "heal_pct": "按比例回复",
    "regen": "生命回复", "armor": "护甲", "dodge": "闪避", "lifesteal": "击杀回复",
    "dmg_mult": "伤害", "as_mult": "攻速", "crit_ch": "暴击率", "crit_mult": "暴击伤害",
    "speed_mult": "移速", "pickup_range": "拾取范围", "harvesting": "材料获取",
    "status_chance": "异常命中", "status_dmg_mult": "状态伤害",
    "status_dur_mult": "异常持续", "status_spread": "中毒扩散",
    "melee_range_bonus": "斩击范围", "bullet_range_bonus": "弹丸射程",
    "bullet_speed_bonus": "子弹速度", "aoe_radius_bonus": "爆炸范围",
    "low_hp_dmg_bonus": "残血增伤", "momentum_dmg_bonus": "战意增伤",
    "on_hit_burn": "命中点燃", "on_hit_poison": "命中中毒", "on_hit_bleed": "命中流血",
    "on_hit_freeze": "命中冰冻", "on_hit_slow": "命中减速", "on_hit_stun": "命中眩晕",
    "iframes": "受击无敌", "touch_tick": "接触伤害间隔",
}
# 这些键的数值是「比例」（0.20 = 20%），展示时换算成百分比更直观。
# 注意 lifesteal 不在其中 —— 它是「每击杀回复 N 点生命」的绝对值（enemy.gd 里 `hp + lifesteal`），
# 曾经显示成「吸血 200%」是硬伤：吸血鬼的 lifesteal=2.0 其实是击杀回 2 血。
PCT_KEYS = {
    "crit_ch", "dodge", "heal_pct",
    "harvesting", "status_chance", "status_dmg_mult", "status_dur_mult",
    "status_spread", "melee_range_bonus", "bullet_range_bonus",
    "bullet_speed_bonus", "aoe_radius_bonus", "low_hp_dmg_bonus",
    "on_hit_burn", "on_hit_poison", "on_hit_bleed", "on_hit_freeze",
    "on_hit_slow", "on_hit_stun",
}
# 加法语义下按百分比展示的键（道具/升级的 dmg_mult=0.14 就是「伤害 +14%」）
ADD_PCT_KEYS = PCT_KEYS | {"dmg_mult", "as_mult", "speed_mult", "crit_mult"}
# 乘算键：角色的 stats 里是**覆盖值**（player.gd: `stats[k] = ch.stats[k]`），
# 所以 1.25 要读成「×1.25」而不是「+25%」——写成后者会让「0.92（削弱）」看起来像增强
OVERRIDE_MULT_KEYS = {"dmg_mult", "as_mult", "speed_mult", "crit_mult"}


# ------------------------------------------------------------------
# 解析：GDScript 字面量 → Python 数据结构
# ------------------------------------------------------------------

def strip_comments(src: str) -> str:
    """逐字符去掉字符串外的 # 注释。

    必须这么做而不能按行 split("#")：表里有 "#e8b84b" 这类颜色值，
    粗暴切分会把字符串从中间截断。
    """
    out = []
    in_str = False
    esc = False
    i = 0
    while i < len(src):
        c = src[i]
        if in_str:
            out.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
                out.append(c)
            elif c == "#":
                j = src.find("\n", i)
                if j < 0:
                    break
                out.append("\n")
                i = j
            else:
                out.append(c)
        i += 1
    return "".join(out)


def match_block(src: str, start: int) -> str:
    """src[start] 是 { 或 [，返回配对的内部文本"""
    open_c = src[start]
    close_c = "}" if open_c == "{" else "]"
    depth = 0
    for j in range(start, len(src)):
        if src[j] == open_c:
            depth += 1
        elif src[j] == close_c:
            depth -= 1
            if depth == 0:
                return src[start + 1:j]
    raise SystemExit("括号不闭合：起始位置 %d" % start)


def const_body(src: str, name: str) -> str:
    m = re.search(r"const\s+" + re.escape(name) + r"\s*:=\s*([\{\[])", src)
    if not m:
        raise SystemExit("找不到常量 " + name)
    return match_block(src, m.start(1))


def assign_body(src: str, name: str) -> str:
    """解析 `名字 = { ... }`（registry.gd 里的成员变量，不是 const）"""
    m = re.search(r"(?m)^[ \t]*" + re.escape(name) + r"[ \t]*=[ \t]*([\{\[])", src)
    if not m:
        raise SystemExit("找不到赋值 " + name)
    return match_block(src, m.start(1))


def sub_block(src: str, key: str) -> str:
    """取 `"key": { ... }` 的内部文本（找不到返回空串）"""
    m = re.search(r'"' + re.escape(key) + r'"\s*:\s*\{', src)
    if not m:
        return ""
    return match_block(src, m.end() - 1)


_VAL = (r'(-?[0-9]+(?:\.[0-9]+)?'
        r'|"(?:[^"\\]|\\.)*"'
        r'|\[[^\]]*\]'
        r'|\{[^{}]*\}'
        r'|true|false)')
_FIELD = re.compile(r'"([A-Za-z_][A-Za-z0-9_]*)"\s*:\s*' + _VAL)


def to_value(v: str):
    if v.startswith('"'):
        return v[1:-1]
    if v in ("true", "false"):
        return v == "true"
    if v.startswith("[") or v.startswith("{"):
        return v
    f = float(v)
    return int(f) if ("." not in v and f.is_integer()) else f


def parse_fields(src: str) -> dict:
    """解析扁平的 `"k": v` 序列。

    注意：`"effects": { ... }` 这种**单层**嵌套字典会被整体捕获成字符串
    （正则里的 \\{[^{}]*\\} 允许跨行，但不允许再嵌一层）——
    两层嵌套（角色 trait 里的 trait.effects）需要先 sub_block 再 parse_fields。
    """
    return {m.group(1): to_value(m.group(2)) for m in _FIELD.finditer(src)}


def top_level_only(src: str) -> str:
    """丢掉所有 {...} / [...] 嵌套块，只留这一层的 `"k": v`。

    为什么需要：角色条目里 `"trait"` 与 `"skill"` 各自也有 `"name"` / `"ico"`，
    而 trait/skill 因为内部还嵌着 effects，整块**无法**被 FIELD 正则一次吃掉 ——
    于是它们的内部键会混进顶层解析里，后出现的 skill 名字把角色名覆盖掉
    （清单里「土豆勇者」显示成了技能名「丰收鼓舞」）。这里先切掉嵌套块即可根治。
    """
    out = []
    i = 0
    n = len(src)
    while i < n:
        if src[i] in "{[":
            inner = match_block(src, i)
            i += len(inner) + 2
            continue
        out.append(src[i])
        i += 1
    return "".join(out)


def split_entries(body: str) -> list:
    """把 `{ ... } { ... }` 或者 `"key": { ... }` 的顶层条目切开，返回 [(key, 内部文本)]"""
    out = []
    i = 0
    n = len(body)
    while i < n:
        if body[i] == "{":
            km = re.search(r'(?:"([A-Za-z0-9_\-]+)"\s*:\s*)?$', body[:i])
            key = km.group(1) if km and km.group(1) else ""
            inner = match_block(body, i)
            out.append((key, inner))
            i += len(inner) + 2
        else:
            i += 1
    return out


def parse_dict_block(src: str, name: str) -> dict:
    """`const NAME := { "id": { ... }, ... }` → {id: {fields}}"""
    out = {}
    for key, inner in split_entries(const_body(src, name)):
        if key:
            out[key] = parse_fields(inner)
    return out


def parse_list_block(src: str, name: str) -> list:
    """`const NAME := [ { "id": ... }, ... ]` → [{fields}, ...]（按源码顺序）"""
    body = const_body(src, name)
    out = []
    for _key, inner in split_entries(body):
        if inner.strip():
            out.append(parse_fields(inner))
    return out


def parse_branch_list(raw) -> list:
    """evolve_branches 的原始字符串 '["smg", "shotgun"]' → ["smg", "shotgun"]"""
    if not isinstance(raw, str):
        return []
    return re.findall(r'"([^"]+)"', raw)


def parse_characters() -> dict:
    """registry.gd 的 characters 表：每个角色 = 元信息 + stats 差异 + trait + skill"""
    src = strip_comments(REG.read_text(encoding="utf-8"))
    chars = {}
    for cid, inner in split_entries(assign_body(src, "characters")):
        if not cid:
            continue
        meta = parse_fields(top_level_only(inner))   # 只看顶层，避开 trait/skill 的同名键
        # stats / trait / skill 都是嵌套块，各自单独取（top_level_only 会把它们整块丢掉）
        stats_src = sub_block(inner, "stats")
        trait_src = sub_block(inner, "trait")
        skill_src = sub_block(inner, "skill")
        chars[cid] = {
            "id": meta.get("id", cid),
            "name": meta.get("name", cid),
            "ico": meta.get("ico", ""),
            "desc": meta.get("desc", ""),
            "stats": parse_fields(stats_src),
            "trait": parse_fields(trait_src),
            "trait_effects": parse_fields(sub_block(trait_src, "effects")),
            "skill": parse_fields(skill_src),
            "skill_effects": parse_fields(sub_block(skill_src, "effects")),
        }
    return chars


# ------------------------------------------------------------------
# 展示：数值 → 人类可读
# ------------------------------------------------------------------

def fmt_num(v) -> str:
    if isinstance(v, bool):
        return "是" if v else "否"
    if isinstance(v, float):
        return ("%.2f" % v).rstrip("0").rstrip(".")
    return str(v)


def fmt_effect(k: str, v, mode: str = "add") -> str:
    """一条属性 → 人类可读。

    两种语义必须分开，否则会写出误导性的数字：
      · mode="add"      —— 特性生效值 / 道具 / 升级：全部是**加法增量**，1.14 表示 +14%
      · mode="override" —— 角色 stats：player.gd 直接 `stats[k] = ch.stats[k]` **覆盖**，
                            所以 dmg_mult 0.92 是「×0.92（削弱）」而不是「-8%」
    """
    label = STAT_CN.get(k, k)
    numeric = isinstance(v, (int, float)) and not isinstance(v, bool)
    if not numeric:
        return "%s %s" % (label, fmt_num(v))
    if mode == "override":
        if k in OVERRIDE_MULT_KEYS:
            return "%s ×%s" % (label, fmt_num(v))
        if k in PCT_KEYS:
            return "%s %s%%" % (label, fmt_num(v * 100.0))
        return "%s %s" % (label, fmt_num(v))
    if k in ADD_PCT_KEYS:
        return "%s %+.0f%%" % (label, v * 100.0)
    # 加法语义的绝对值也带符号：写成「最大生命 20」看不出是加成还是绝对值
    return "%s %s%s" % (label, "+" if v > 0 else "", fmt_num(v))


def fmt_effects(d: dict, mode: str = "add") -> str:
    if not d:
        return "—"
    return "、".join(fmt_effect(k, v, mode) for k, v in d.items())


def fmt_params(d: dict) -> str:
    """特性 / 技能的结构参数（半径、间隔、层数…）—— 键名对不上 STAT_CN，单独一张表"""
    parts = []
    for k, v in d.items():
        label = PARAM_CN.get(k, k)
        if k == "status":
            v = STATUS_CN.get(str(v), v)
        elif k in PARAM_PCT and isinstance(v, (int, float)) and not isinstance(v, bool):
            v = "%s%%" % fmt_num(v * 100.0)
        parts.append("%s %s" % (label, fmt_num(v)))
    return "、".join(parts)


def esc(s) -> str:
    """表格单元格里的 | 会破坏 Markdown 表格"""
    return str(s).replace("|", "\\|").replace("\n", " ")


def table(headers: list, rows: list) -> str:
    out = ["| " + " | ".join(headers) + " |",
           "|" + "|".join(["---"] * len(headers)) + "|"]
    for r in rows:
        out.append("| " + " | ".join(esc(c) for c in r) + " |")
    return "\n".join(out) + "\n"


def family_of(w: dict) -> str:
    return str(w.get("family", "")) or "(未标家族)"


def item_tags(effects: dict) -> list:
    """道具定位标签：靠 effects 键自动归类，不额外维护一份分类表"""
    tags = []
    if any(k.startswith("on_hit_") for k in effects):
        tags.append("状态附魔")
    if any(k in effects for k in ("melee_range_bonus", "bullet_range_bonus",
                                 "bullet_speed_bonus", "aoe_radius_bonus")):
        tags.append("武器向")
    if any(k in effects for k in ("status_dmg_mult", "status_dur_mult",
                                 "status_chance", "status_spread")):
        tags.append("异常流")
    if any(k in effects for k in ("harvesting", "pickup_range")):
        tags.append("经济")
    if any(k in effects for k in ("max_hp", "armor", "dodge", "regen",
                                 "lifesteal", "heal_flat", "heal_pct")):
        tags.append("生存")
    return tags or ["泛用"]


# ------------------------------------------------------------------
# 主流程
# ------------------------------------------------------------------

def main() -> int:
    cfg = strip_comments(CFG.read_text(encoding="utf-8"))
    weapons = parse_dict_block(cfg, "WEAPONS")
    items = parse_list_block(cfg, "ITEMS")
    upgrades = parse_list_block(cfg, "UPGRADES")
    status = parse_dict_block(cfg, "STATUS")
    char_unlocks = parse_dict_block(cfg, "CHARACTER_UNLOCKS")
    weapon_unlocks = parse_dict_block(cfg, "WEAPON_UNLOCKS")
    chars = parse_characters()

    base = parse_fields(const_body(cfg, "PLAYER"))

    md = []
    md.append("# 内容调参清单（角色 / 武器 / 道具）\n\n")
    md.append("> 本文件由 `game/tools/content_manifest.py` **自动生成，请勿手改**。\n>\n"
              "> 改数值请改 `game/scripts/core/config.gd`（武器 / 道具 / 升级 / 状态）或 "
              "`game/scripts/core/registry.gd` 的 `characters`（角色），然后重跑：\n>\n"
              "> ```bash\n> python game/tools/content_manifest.py\n> ```\n>\n"
              "> 脚本解析的是源码真值，所以清单永远与代码同步。改完记得跑冒烟：`SMOKE: PASS`"
              "（见文末「改完怎么验」）。\n")

    md.append("\n## 内容量总览\n")
    md.append(table(
        ["类别", "数量", "源码位置"],
        [["角色", "%d" % len(chars), "`registry.gd` → `characters`"],
         ["武器", "%d" % len(weapons), "`config.gd` → `WEAPONS`"],
         ["道具", "%d" % len(items), "`config.gd` → `ITEMS`"],
         ["升级", "%d" % len(upgrades), "`config.gd` → `UPGRADES`"],
         ["状态", "%d" % len(status), "`config.gd` → `STATUS`"]]))

    # ---------------- 角色 ----------------
    md.append("\n---\n\n## 一、角色（%d）\n" % len(chars))
    md.append("\n### 1.1 速查总表\n")
    md.append("> 数值列取自角色 `stats`（**只列角色显式写出的项**，没写的沿用基准）。"
              "角色 stats 是**覆盖**语义（`player.gd`: `stats[k] = ch.stats[k]`），"
              "所以 `伤害 ×0.92` 是削弱、`伤害 ×1.25` 是增强；比例类键直接写百分数。\n>\n"
              "> 基准 = `Config.PLAYER`：生命 %s / 伤害 ×%s / 攻速 ×%s / 暴击 %s%% / "
              "暴伤 ×%s / 移速 ×%s / 护甲 %s / 闪避 %s%% / 拾取 %s。\n" % (
                  fmt_num(base.get("max_hp", 0)), fmt_num(base.get("dmg_mult", 1)),
                  fmt_num(base.get("as_mult", 1)), fmt_num(float(base.get("crit_ch", 0)) * 100),
                  fmt_num(base.get("crit_mult", 2)), fmt_num(base.get("speed_mult", 1)),
                  fmt_num(base.get("armor", 0)), fmt_num(float(base.get("dodge", 0)) * 100),
                  fmt_num(base.get("pickup_range", 0))))
    rows = []
    for cid, c in chars.items():
        st = c["stats"]
        t = c["trait"]
        sk = c["skill"]
        rows.append([
            "`%s`" % cid, "%s %s" % (c["ico"], c["name"]),
            fmt_effects(st, "override"),
            "%s（%s）" % (t.get("name", "—"), KIND_CN.get(str(t.get("kind", "")), t.get("kind", ""))),
            "%s（%s）" % (sk.get("name", "—"), SKILL_CN.get(str(sk.get("kind", "")), sk.get("kind", ""))),
            "%ss" % fmt_num(sk.get("cd", 0)),
        ])
    md.append(table(["id", "名称", "初始属性（覆盖语义）", "专属特性", "主动技能", "技能 CD"], rows))

    md.append("\n### 1.2 逐角色明细\n")
    md.append("调数值时按这里改：**初始属性**改 `registry.gd` 里该角色的 `stats`；"
              "**特性**改 `trait`（`stats` 类看 `effects`，`aura` 类看 `status`/`radius_mult`/`interval`/`dmg`，"
              "`thorns` 看 `dmg`/`radius`，`momentum` 看 `per_kills`/`per_stack`/`max_bonus`）；"
              "**技能**改 `skill`。\n")
    for cid, c in chars.items():
        md.append("\n#### `%s` %s %s\n" % (cid, c["ico"], c["name"]))
        md.append("- **定位**：%s\n" % c["desc"])
        un = char_unlocks.get(cid)
        md.append("- **解锁**：%s\n" % (un.get("hint", "") if un else "开局即有（默认解锁）"))
        md.append("- **初始属性**（覆盖在 `Config.PLAYER` 之上）：%s\n" %
                  (fmt_effects(c["stats"], "override") if c["stats"] else "与基准一致"))
        t = c["trait"]
        md.append("- **特性** `%s` %s（kind = `%s`）：%s\n" %
                  (t.get("id", "—"), t.get("name", "—"), t.get("kind", "—"), t.get("desc", "")))
        extra = {k: v for k, v in t.items()
                 if k not in ("id", "name", "ico", "desc", "kind", "sigil", "effects")}
        if c["trait_effects"]:
            md.append("  - 生效数值（加法）：%s\n" % fmt_effects(c["trait_effects"]))
        if extra:
            md.append("  - 参数：%s\n" % fmt_params(extra))
        if "sigil" in t:
            md.append("  - 印记：`%s`%s\n" % (t["sigil"] or "(空)",
                                              " —— 刻意声明无印记" if not t["sigil"] else ""))
        sk = c["skill"]
        md.append("- **技能** %s（kind = `%s`，CD %ss）：%s\n" %
                  (sk.get("name", "—"), sk.get("kind", "—"), fmt_num(sk.get("cd", 0)), sk.get("desc", "")))
        sp = {k: v for k, v in sk.items()
              if k not in ("name", "ico", "desc", "kind", "cd", "effects")}
        if c["skill_effects"]:
            md.append("  - 生效数值（加法）：%s\n" % fmt_effects(c["skill_effects"]))
        if sp:
            md.append("  - 参数：%s\n" % fmt_params(sp))

    # ---------------- 武器 ----------------
    md.append("\n---\n\n## 二、武器（%d）\n" % len(weapons))
    md.append("\n### 2.1 总表（按家族分组，家族内按 DPS 降序）\n")
    md.append("> **DPS 口径**：远程 = `dmg × pellets ÷ cd`；近战 = `dmg ÷ cd`（扇形一次判定）。"
              "溅射（splash）与状态（status）**不折算进 DPS** —— 它们的收益取决于敌群密度与敌人血量，"
              "折算会给出虚假的精确感，只在列里标注存在。完整体检见 `docs/武器DPS体检表.md`。\n")
    for fam in FAMILY_ORDER + sorted({family_of(w) for w in weapons.values()} - set(FAMILY_ORDER)):
        group = [(wid, w) for wid, w in weapons.items() if family_of(w) == fam]
        if not group:
            continue
        group.sort(key=lambda kv: -(float(kv[1].get("dmg", 0)) *
                                   int(kv[1].get("pellets", 1) or 1) /
                                   max(float(kv[1].get("cd", 1) or 1), 1e-6)))
        rows = []
        for wid, w in group:
            cd = float(w.get("cd", 1) or 1)
            dmg = float(w.get("dmg", 0))
            pellets = int(w.get("pellets", 1) or 1)
            dps = dmg * pellets / cd if cd > 0 else 0.0
            price = w.get("price")
            ppd = ("%.2f" % (float(price) / dps)) if (price is not None and dps > 0) else "—"
            st = str(w.get("status", ""))
            st_s = ("%s %.0f%%" % (STATUS_CN.get(st, st), float(w.get("status_chance", 0)) * 100)) \
                if st else "—"
            if w.get("status_stacks"):
                st_s += " ×%s 层" % w["status_stacks"]
            rows.append([
                "`%s`" % wid, w.get("name", wid), ATK_CN.get(str(w.get("attack_type", "")), "?"),
                RARITY_CN.get(str(w.get("rarity", "")), w.get("rarity", "?")),
                fmt_num(cd), fmt_num(dmg), pellets, "%.1f" % dps,
                fmt_num(price) if price is not None else "—", ppd,
                st_s,
                ("%s 半径 %s" % ("溅射", fmt_num(w["splash"]))) if w.get("splash") else "—",
                "、".join(parse_branch_list(w.get("evolve_branches", ""))) or "—",
            ])
        md.append("\n**%s**\n\n" % FAMILY_NAME.get(fam, fam))
        md.append(table(["id", "名称", "类型", "稀有度", "cd", "dmg", "弹数", "DPS",
                         "价格", "价/DPS", "状态", "溅射", "进化分支"], rows))

    md.append("\n### 2.2 进化树\n")
    md.append("> 基础武器持有 `evolve_need` 把（默认 3）后，波末弹出进化选择；"
              "**进化形态 `shop_weight = 0`，不进商店池**，只能靠合成获得。\n")
    evo_rows = []
    for wid, w in weapons.items():
        branches = parse_branch_list(w.get("evolve_branches", ""))
        if not branches:
            continue
        all_free = all(float(weapons.get(b, {}).get("shop_weight", 1) or 0) == 0
                       for b in branches)
        evo_rows.append([
            "`%s` %s" % (wid, w.get("name", "")),
            fmt_num(w.get("evolve_need", 3)),
            "、".join("`%s` %s" % (b, weapons.get(b, {}).get("name", "?")) for b in branches),
            "全部不进商店（只能合成）" if all_free else "部分分支可购买",
        ])
    md.append(table(["基础武器", "需要把数", "进化分支", "进商店？"], evo_rows))

    md.append("\n### 2.3 武器解锁条件\n")
    md.append("> 未列入下表 = 开局即可选。条件由跨局累计统计实时推导（`Config.WEAPON_UNLOCKS`）。\n")
    md.append(table(["id", "名称", "解锁条件"],
                    [["`%s`" % wid, weapons.get(wid, {}).get("name", "?"), u.get("hint", "")]
                     for wid, u in weapon_unlocks.items()]))

    # ---------------- 道具 ----------------
    md.append("\n---\n\n## 三、道具（%d）\n" % len(items))
    md.append("\n### 3.1 总表（按稀有度，稀有度内按价格升序）\n")
    md.append("> 定位标签由 `effects` 自动推导，不额外维护分类表。"
              "带 **负值** 的是「有代价的增益」——调平衡时优先看这些。\n")
    for rar in RARITY_ORDER:
        group = [it for it in items if str(it.get("rarity", "")) == rar]
        if not group:
            continue
        group.sort(key=lambda it: float(it.get("price", 0)))
        rows = []
        for it in group:
            eff = parse_fields(str(it.get("effects", ""))) if isinstance(it.get("effects"), str) else {}
            rows.append([
                "`%s`" % it.get("id", "?"), it.get("name", "?"),
                fmt_num(it.get("price", 0)), fmt_effects(eff),
                "、".join(item_tags(eff)),
                "有" if any(isinstance(v, (int, float)) and not isinstance(v, bool) and v < 0
                           for v in eff.values()) else "",
            ])
        md.append("\n**%s %s**\n\n" % (RARITY_CN.get(rar, rar), rar))
        md.append(table(["id", "名称", "价格", "effects", "定位", "带代价"], rows))

    md.append("\n### 3.2 按定位汇总（构筑时该找哪几件）\n")
    by_tag = {}
    for it in items:
        eff = parse_fields(str(it.get("effects", ""))) if isinstance(it.get("effects"), str) else {}
        for t in item_tags(eff):
            by_tag.setdefault(t, []).append(it.get("name", "?"))
    md.append(table(["定位", "件数", "道具"],
                    [[t, "%d" % len(v), "、".join(v)] for t, v in sorted(by_tag.items())]))

    # ---------------- 附录：升级 ----------------
    md.append("\n---\n\n## 四、附录：升级池（%d）\n" % len(upgrades))
    md.append("> 升级三选一从这里抽（按 `rarity_weight(rarity, 等级)` 加权 + 构筑亲和加权）。"
              "稀有度门槛：epic ≥3 波 / mythic ≥6 波 / legendary ≥9 波才会出现。\n")
    rows = []
    for u in upgrades:
        eff = parse_fields(str(u.get("effects", ""))) if isinstance(u.get("effects"), str) else {}
        rows.append(["`%s`" % u.get("id", "?"), "%s %s" % (u.get("ico", ""), u.get("name", "?")),
                     RARITY_CN.get(str(u.get("rarity", "")), u.get("rarity", "?")),
                     fmt_effects(eff), u.get("desc", "")])
    md.append(table(["id", "名称", "稀有度", "effects", "说明"], rows))

    # ---------------- 数据自检 ----------------
    # 清单只做「结构上一定能查出来」的那几类问题，标注在文档里，避免每次都要人肉扫表。
    dup_rows = []

    def dup_names(entries, label: str) -> None:
        seen = {}
        for e in entries:
            seen.setdefault(str(e.get("name", "")), []).append(str(e.get("id", "")))
        for nm, ids in seen.items():
            if len(ids) > 1:
                dup_rows.append([label, nm, "、".join("`%s`" % i for i in ids)])

    dup_names(list(weapons.values()), "武器")
    dup_names(items, "道具")
    dup_names(upgrades, "升级")

    branch_ids = set()
    for w in weapons.values():
        branch_ids.update(parse_branch_list(w.get("evolve_branches", "")))
    # 进不了商店、又不参与任何进化 → 玩家永远拿不到
    unreachable = ["`%s` %s" % (wid, w.get("name", ""))
                   for wid, w in weapons.items()
                   if float(w.get("shop_weight", 1) or 0) == 0 and wid not in branch_ids]

    md.append("\n---\n\n## 五、数据自检（自动发现）\n")
    md.append("\n> 这几类是「清单能自动扫出来」的配置问题。改完数值后重跑本脚本即可复核。\n")
    md.append("\n### 5.1 重名\n")
    md.append("> 商店 / 升级 / 图鉴都是按名字给玩家认的，重名会让玩家分不清买到的是哪一件"
              "（id 不同但名字一样）。\n\n")
    md.append(table(["类别", "重复的名称", "涉及的 id"], dup_rows) if dup_rows
              else "未发现重名。\n")
    md.append("\n### 5.2 永远拿不到的武器\n")
    md.append("> `shop_weight = 0` 表示不进商店池；若它又**不是任何武器的进化分支**，"
              "那它就只能靠「开局初始武器」拿到（若也不在初始列表里，则是死内容）。\n\n")
    md.append(table(["武器"], [[t] for t in unreachable]) if unreachable
              else "未发现死内容。\n")

    # ---------------- 改完怎么验 ----------------
    md.append("""
---

## 六、改完怎么验（务必按顺序）

### 1. 改哪里

| 想改什么 | 改这里 | 注意 |
|---|---|---|
| 武器数值 / 价格 / 出货权重 | `config.gd` → `WEAPONS` | 单表真值：`price`、`shop_weight` 已内联，只改一处 |
| 道具数值 / 价格 | `config.gd` → `ITEMS` | `effects` 的键必须是 `player.stats` 里存在的键 |
| 升级池 | `config.gd` → `UPGRADES` | 同上 |
| 角色初始属性 / 特性 / 技能 | `registry.gd` → `characters` | `stats` 只写**差异项**，其余沿用 `Config.PLAYER` |
| 全局基准（所有人共享的底子） | `config.gd` → `PLAYER` | 改这里等于改全部角色，谨慎 |
| 状态强度 | `config.gd` → `STATUS` | `dot_scale` / `dot_max_hp_pct` 决定 DoT 收益 |
| 解锁门槛 | `config.gd` → `CHARACTER_UNLOCKS` / `WEAPON_UNLOCKS` | `stat` 必须落在 `UNLOCK_STAT_KEYS` 白名单内 |

### 2. 三条容易踩的坑

1. **数值越界会被静默跳过**。`Registry.STAT_LIMITS` / `EFFECT_LIMITS` 对每个属性键设了安全区间
   （如 `bspeed ≤ 1200`、`crit_ch ∈ (0,1)`），越界只 `push_warning` 然后**丢弃该条**——
   武器会凭空消失。所以改完不能只看 `SMOKE: PASS`，还要在输出里搜 `WARNING: Registry`。
2. **内容量下限由冒烟测试守着**。`smoke_test.gd` 的 `_check_phase3_content()` 会断言各类内容的下限；
   如果新增内容后仍显示旧数量，说明那条被校验拒了（同上，去搜 warning）。
3. **改角色别忘 `Config.DAILY_CHARACTERS`**。新角色不加进这个数组，就永远不会出现在每日挑战里
   （冒烟测试会断言池子覆盖）。

### 3. 验证命令

```
# 数值变化是否落在预期（DPS / 定价倒挂）
python game/tools/dps_audit.py

# 重新生成本清单
python game/tools/content_manifest.py

# 全量回归：改动后必跑，判定看 stdout 有没有 SMOKE: PASS
powershell -NoProfile -ExecutionPolicy Bypass -File game/tools/run_smoke.ps1
```

> 冒烟测试同时会打印 `SMOKE: phase3 counts chars=… weapons=… items=…`，
> 把它和本清单「内容量总览」对照，就能立刻发现「文档写了但代码里没有」的漂移。
""")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("".join(md), encoding="utf-8")
    print("已生成 %s" % OUT)
    print("角色 %d / 武器 %d / 道具 %d / 升级 %d / 状态 %d" %
          (len(chars), len(weapons), len(items), len(upgrades), len(status)))
    return 0


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main())
