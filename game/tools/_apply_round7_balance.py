# -*- coding: utf-8 -*-
"""S8 第 7 轮数值改动（2026-09-17，用户拍板）。

口径（逐条对应用户指令）：
  ① 所有武器数值减半 —— 内置 10 把（5 基础五行 + 5 进化形态）的 `dmg` 一律 ×0.5。
     ⚠️ 进化倍数 2.0× 是「进化体 dmg == 基础体 dmg × 2」的口径，两边同时减半后
        该关系恒等保持 → 不改进化倍数、只改两边绝对值。
  ② 攻速 / 暴击率加成都减半 —— 凡是 `as_mult` / `crit_ch` 的**增量**一律 ÷2，
     来源覆盖：道具 / 升级 / 事件卡 / 武器族共鸣 / 法宝叠层 / 角色 stats 与 trait.effects / 角色技能 buff。
     ⚠️ `as_mult` 在角色 stats 里是**倍率**（基线 1.0），所以减半的是 `值 - 1.0` 那部分；
        `crit_ch` 是加法量，直接 ÷2。
     ⚠️ 唯一不动的：`Config.PLAYER` 表里的基线（as_mult=1.0 / crit_ch=0.05）——
        那是「白板角色的起点」，不是加成。

每处替换都断言「该行存在且 old 恰好出现一次」，任一处不符立刻中止，不留半改状态。
"""
import io
import sys

ROOT = r"d:\code\firstProject-ai\TheGreatestProject\game"

# (相对路径, 1-based 行号, old, new, 备注)
EDITS = [
    # ============ ① 武器 dmg 减半 ============
    ("scripts/core/config.gd", 561, '"dmg": 14.0', '"dmg": 7.0', "knife"),
    ("scripts/core/config.gd", 582, '"dmg": 3.0', '"dmg": 1.5', "flamethrower"),
    ("scripts/core/config.gd", 583, '"dmg": 7.0', '"dmg": 3.5', "frost_staff"),
    ("scripts/core/config.gd", 584, '"dmg": 30.0', '"dmg": 15.0', "thunder_gong"),
    ("scripts/core/config.gd", 584, "单体 DPS 22.2", "单体 DPS 11.1", "thunder_gong desc"),
    ("scripts/core/config.gd", 585, '"dmg": 18.0', '"dmg": 9.0', "blight_bow"),
    ("scripts/core/config.gd", 587, '"dmg": 28.0', '"dmg": 14.0', "knife_ex"),
    ("scripts/core/config.gd", 590, '"dmg": 6.0', '"dmg": 3.0', "flamethrower_ex"),
    ("scripts/core/config.gd", 591, '"dmg": 14.0', '"dmg": 7.0', "frost_staff_ex"),
    ("scripts/core/config.gd", 592, '"dmg": 60.0', '"dmg": 30.0', "thunder_gong_ex"),
    ("scripts/core/config.gd", 593, '"dmg": 36.0', '"dmg": 18.0', "blight_bow_ex"),
    ("scripts/core/config.gd", 593, "单发 36、reach 770px", "单发 18、reach 770px", "blight_bow_ex desc"),

    # ============ ② 攻速 / 暴击加成减半 ============
    # 武器族共鸣（gun）——注释里的示例数字也要同步
    ("scripts/core/config.gd", 607, "共鸣 2 层 = 攻速 +16%、暴击 +4%",
     "共鸣 2 层 = 攻速 +8%、暴击 +2%", "gun 族注释"),
    ("scripts/core/config.gd", 609, '"as_mult": 0.08, "crit_ch": 0.02',
     '"as_mult": 0.04, "crit_ch": 0.01', "gun 族共鸣"),
    # 升级池
    ("scripts/core/config.gd", 847, "攻击速度 +8%", "攻击速度 +4%", "upgrade as desc"),
    ("scripts/core/config.gd", 847, '"as_mult": 0.08', '"as_mult": 0.04', "upgrade as"),
    ("scripts/core/config.gd", 849, "暴击率 +6%", "暴击率 +3%", "upgrade crit desc"),
    ("scripts/core/config.gd", 849, '"crit_ch": 0.06', '"crit_ch": 0.03', "upgrade crit"),
    ("scripts/core/config.gd", 857, "暴击率 +12%", "暴击率 +6%", "upgrade precision desc"),
    ("scripts/core/config.gd", 857, '"crit_ch": 0.12', '"crit_ch": 0.06', "upgrade precision"),
    ("scripts/core/config.gd", 859, "攻击速度 +18%", "攻击速度 +9%", "upgrade frenzy desc"),
    ("scripts/core/config.gd", 859, '"as_mult": 0.18', '"as_mult": 0.09', "upgrade frenzy"),
    ("scripts/core/config.gd", 861, "攻速 +25%，暴击伤害 +40%", "攻速 +12.5%，暴击伤害 +40%",
     "upgrade overdrive desc"),
    ("scripts/core/config.gd", 861, '"as_mult": 0.25', '"as_mult": 0.125', "upgrade overdrive"),
    # 道具池
    ("scripts/core/config.gd", 895, "攻速 +12%", "攻速 +6%", "i-as desc"),
    ("scripts/core/config.gd", 895, '"as_mult": 0.12', '"as_mult": 0.06', "i-as"),
    ("scripts/core/config.gd", 897, "暴击率 +10%", "暴击率 +5%", "i-crit desc"),
    ("scripts/core/config.gd", 897, '"crit_ch": 0.10', '"crit_ch": 0.05', "i-crit"),
    ("scripts/core/config.gd", 914, "伤害 +25%，攻速 +15%", "伤害 +25%，攻速 +7.5%", "i-goldcore desc"),
    ("scripts/core/config.gd", 914, '"as_mult": 0.15', '"as_mult": 0.075', "i-goldcore"),
    ("scripts/core/config.gd", 917, "暴击率 +15%，暴击伤害 +80%", "暴击率 +7.5%，暴击伤害 +80%",
     "i-bladesoul desc"),
    ("scripts/core/config.gd", 917, '"crit_ch": 0.15', '"crit_ch": 0.075', "i-bladesoul"),
    ("scripts/core/config.gd", 919, "移速 +35%，攻速 +30%，闪避 +10%",
     "移速 +35%，攻速 +15%，闪避 +10%", "i-gale desc"),
    ("scripts/core/config.gd", 919, '"as_mult": 0.30', '"as_mult": 0.15', "i-gale"),
    ("scripts/core/config.gd", 921, "伤害 +15%，攻速 +15%，暴击 +8%，暴伤 +50%",
     "伤害 +15%，攻速 +7.5%，暴击 +4%，暴伤 +50%", "i-crown desc"),
    ("scripts/core/config.gd", 921, '"as_mult": 0.15', '"as_mult": 0.075', "i-crown as"),
    ("scripts/core/config.gd", 921, '"crit_ch": 0.08', '"crit_ch": 0.04', "i-crown crit"),
    ("scripts/core/config.gd", 924, "暴击率 +7%，移速 +5%", "暴击率 +3.5%，移速 +5%", "i-hunter desc"),
    ("scripts/core/config.gd", 924, '"crit_ch": 0.07', '"crit_ch": 0.035', "i-hunter"),
    ("scripts/core/config.gd", 928, "攻速 +20%；代价：伤害 -8%", "攻速 +10%；代价：伤害 -8%", "i-focus desc"),
    ("scripts/core/config.gd", 928, '"as_mult": 0.20', '"as_mult": 0.10', "i-focus"),
    ("scripts/core/config.gd", 949, "斩击范围 +35%，暴击率 +6%", "斩击范围 +35%，暴击率 +3%",
     "i-swordcase desc"),
    ("scripts/core/config.gd", 949, '"crit_ch": 0.06', '"crit_ch": 0.03', "i-swordcase"),
    ("scripts/core/config.gd", 962, "伤害 +50%，暴击伤害 +100%，攻速 +20%",
     "伤害 +50%，暴击伤害 +100%，攻速 +10%", "i-dragonsoul desc"),
    ("scripts/core/config.gd", 962, '"as_mult": 0.20', '"as_mult": 0.10', "i-dragonsoul"),
    # 法宝叠层（断刃锋）
    ("scripts/core/config.gd", 1056, "击杀流血中的敌人 +4% 暴击率", "击杀流血中的敌人 +2% 暴击率",
     "art_notch_blade desc"),
    ("scripts/core/config.gd", 1058, '"per_stack": 0.04', '"per_stack": 0.02', "art_notch_blade"),
    # 事件卡
    ("scripts/core/config.gd", 1160, "暴击率 +8%", "暴击率 +4%", "ev_ghost_lantern hint"),
    ("scripts/core/config.gd", 1160, '"crit_ch": 0.08', '"crit_ch": 0.04', "ev_ghost_lantern"),
    ("scripts/core/config.gd", 1180, "攻速 +15% · 移速 +6%", "攻速 +7.5% · 移速 +6%", "ev_iron_abbot hint"),
    ("scripts/core/config.gd", 1180, '"as_mult": 0.15', '"as_mult": 0.075', "ev_iron_abbot"),
    ("scripts/core/config.gd", 1207, "暴击 +10%", "暴击 +5%", "ev_dragon_gate hint"),
    ("scripts/core/config.gd", 1208, '"crit_ch": 0.10', '"crit_ch": 0.05', "ev_dragon_gate"),
    ("scripts/core/config.gd", 1220, "攻速 +18% · 伤害 +12%", "攻速 +9% · 伤害 +12%", "ev_origin_dao hint"),
    ("scripts/core/config.gd", 1220, '"as_mult": 0.18', '"as_mult": 0.09', "ev_origin_dao"),
    # 内置角色（registry.gd）
    ("scripts/core/registry.gd", 976, "伤害 / 攻速 / 移速 +5%，材料获取 +10%",
     "伤害 +5% / 攻速 +2.5% / 移速 +5%，材料获取 +10%", "potato trait desc"),
    ("scripts/core/registry.gd", 987, '"as_mult": 0.05', '"as_mult": 0.025', "potato trait effects"),
    ("scripts/core/registry.gd", 991, "8 秒内伤害 +25%、攻速 +25%、移速 +15%",
     "8 秒内伤害 +25%、攻速 +12.5%、移速 +15%", "potato skill desc"),
    ("scripts/core/registry.gd", 993, '"as_mult": 0.25', '"as_mult": 0.125', "potato skill effects"),
    ("scripts/core/registry.gd", 1022, '"crit_ch": 0.06', '"crit_ch": 0.03', "metal_adept stats"),
    ("scripts/core/registry.gd", 1022, '"as_mult": 1.06', '"as_mult": 1.03', "metal_adept stats"),
    ("scripts/core/registry.gd", 1027, '"crit_ch": 0.04', '"crit_ch": 0.02', "metal_adept trait"),
]


def main() -> int:
    cache = {}
    for rel, lineno, old, new, note in EDITS:
        path = ROOT + "\\" + rel.replace("/", "\\")
        if path not in cache:
            with io.open(path, "r", encoding="utf-8", newline="") as fh:
                cache[path] = fh.read()
        text = cache[path]
        lines = text.split("\n")
        if lineno < 1 or lineno > len(lines):
            print("ABORT 行号越界 %s:%d (%s)" % (rel, lineno, note))
            return 1
        line = lines[lineno - 1]
        cnt = line.count(old)
        if cnt != 1:
            print("ABORT %s:%d 期望 old 恰好 1 次，实为 %d 次 (%s)\n    old=%s\n    line=%s"
                  % (rel, lineno, cnt, note, old, line.strip()[:220]))
            return 1
        lines[lineno - 1] = line.replace(old, new)
        cache[path] = "\n".join(lines)
        print("OK  %-22s :%-5d %s" % (rel, lineno, note))

    for path, text in cache.items():
        with io.open(path, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
    print("\nWROTE %d file(s)" % len(cache))
    return 0


if __name__ == "__main__":
    sys.exit(main())
