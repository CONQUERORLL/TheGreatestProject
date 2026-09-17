"""一次性自检：用合成日志跑 balance_report.py，确认不会崩、输出可读。

（不是游戏逻辑的一部分，跑完即弃；保留它是为了让「日志结构一改就发现报告脚本挂了」。）
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable
OUT = os.path.join(os.environ.get("TEMP", "."), "_synthetic_balance_log.json")

STATS = {
    "max_hp": 120.0, "regen": 1.2, "armor": 3.0, "dodge": 0.08, "dmg_mult": 1.25,
    "as_mult": 1.10, "crit_ch": 0.15, "crit_mult": 1.60, "speed_mult": 1.05,
    "lifesteal": 0.03, "pickup_range": 90.0, "harvesting": 0.0,
    "status_chance": 0.10, "status_dmg_mult": 0.20,
    "assim_metal": 0.25, "assim_fire": 0.10, "assim_water": 0.0,
}
WEAPONS = [
    {"id": "knife", "name": "金剑", "count": 2, "evolved": False, "element": "metal",
     "family": "blade", "attack_type": "melee", "proj_kind": "bullet", "dmg": 7.0, "cd": 0.45,
     "cd_effective": 0.409, "reach": 95.0, "splash": 0.0, "pellets": 1, "status": "bleed",
     "price": 28, "desc": ""},
    {"id": "thunder_gong", "name": "土质炸弹", "count": 1, "evolved": False, "element": "earth",
     "family": "element", "attack_type": "projectile", "proj_kind": "thrown", "dmg": 15.0,
     "cd": 1.35, "cd_effective": 1.227, "reach": 495.0, "splash": 95.0, "pellets": 1,
     "status": "stun", "price": 54, "desc": ""},
]
ITEMS = [{"id": "i-hp", "name": "疗伤丹", "count": 2, "rarity": "common", "effects": {"max_hp": 10}}]
ARTS = [{"id": "a-hammer", "name": "刑天斧", "stacks": 0, "desc": ""}]


def entry(w, level, kills, spawned, dps, dealt, taken, heal, hp_min, hp_max,
          mats, gained, dur, weapons, by_source):
    return {
        "wave": w, "outcome": "shop", "at": f"2026-09-17T23:0{w}:00",
        "duration": dur, "run_time": 10.0 * w, "level": level, "xp": 3,
        "kills": kills, "spawned": spawned, "materials": mats, "materials_gained": gained,
        "hp": hp_max * 0.7, "hp_min": hp_min, "hp_max": hp_max,
        "damage_dealt": dealt, "damage_taken": taken, "heal": heal, "dps": dps,
        "by_source": by_source, "weapons": weapons, "items": ["i-hp"], "artifacts": [],
        "stats": STATS,
    }


def main() -> int:
    waves = [
        entry(1, 3, 18, 24, 42.0, 1800, 60, 12, 95, 120, 120, 90, 43.0, ["knife", "knife"],
              {"knife": 1500, "trait": 300}),
        entry(2, 5, 26, 30, 61.0, 2600, 120, 30, 88, 130, 210, 95, 42.0,
              ["knife", "knife"], {"knife": 2100, "trait": 300, "other": 200}),
        entry(3, 7, 31, 36, 55.0, 2200, 260, 10, 26, 140, 300, 120, 40.0,
              ["knife", "knife", "thunder_gong"],
              {"knife": 1200, "thunder_gong": 800, "trait": 200}),
    ]
    latest = {
        "version": 1, "updated_at": "2026-09-17T23:13:00", "wave": 3, "outcome": "shop",
        "run": {"difficulty": "normal", "difficulty_name": "简单", "character": "wood",
                "character_name": "青木道人", "endless": False, "daily": False,
                "run_time": 210.0, "level": 7, "xp": 3, "materials": 300, "kills": 75,
                "score": 0, "map_theme": "bamboo", "area_element": "metal", "run_rules": {}},
        "wave_data": {"duration": 40.0, "duration_wall": 62.0, "kills": 31, "spawned": 36,
                      "materials_gained": 120, "damage_dealt": 2200.0, "damage_taken": 260.0,
                      "heal": 10.0, "dps": 55.0, "hp_min": 26.0, "hp_end": 98.0,
                      "by_source": {"knife": 1200.0, "thunder_gong": 800.0, "trait": 200.0},
                      "boss_wave": False, "event": ""},
        "player": {"hp": 98.0, "max_hp": 140.0, "element": "wood", "sigil": "mote",
                   "char_trait": {"id": "wood_growth", "name": "生生不息", "kind": "stats"},
                   "skill": {"id": "none"}, "stats": STATS, "weapons": WEAPONS,
                   "items": ITEMS, "artifacts": ARTS, "upgrades": ["u-dmg", "u-as"],
                   "family_synergy": {"dmg_mult": 0.1}},
    }
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump({"version": 1, "updated_at": latest["updated_at"],
                   "latest": latest, "waves": waves}, fh, ensure_ascii=False)
    proc = subprocess.run([PY, os.path.join(HERE, "balance_report.py"), OUT],
                          capture_output=True, text=True, encoding="utf-8")
    print(proc.stdout)
    if proc.returncode != 0:
        print(proc.stderr)
        print("!! 报告脚本退出码 %d" % proc.returncode)
        return 1
    if "逐波" not in proc.stdout and "波" not in proc.stdout:
        print("!! 输出里没有波次表")
        return 1
    print("=== 自检通过（退出码 0，输出非空）===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
