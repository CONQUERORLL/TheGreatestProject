# -*- coding: utf-8 -*-
"""第 11 轮 · 修 `_check_spread_channel` 的假红。

冒烟实测：
  SMOKE: FAIL - 第11轮：proj_spread_mult = 0 时不该 duplicate 武器字典
根因**不是实现错**，是断言没把自己的变量摘干净：
  本用例排在几十条用例之后，玩家身上留着别人施加的武器加成
  （`_check_balance_log` 早在第 8 轮就写明实测残留 melee_range_bonus 0.18 / aoe_radius_bonus 0.20）。
  那些加成会让 `_weapon_runtime_cfg` 走 duplicate 分支 → 反向对照假红，
  而且红得像「实现错了」。这正是断言纪律里「租的变量要先摘掉、用完还回去」那一条。

修法（与 `_check_balance_log` 同款）：进用例先把**全部武器加成键**归零、记下原值，
所有退出路径都原样还回去；并把「同一字典」的判据从 `!=` 换成 `is_same()`
（`!=` 对 Dictionary 的语义随版本摇摆，`is_same()` 明确比的是同一实例）。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path

SMK = game_path("tests", "smoke_test.gd")

OLD = '''\tvar p: Node2D = _main.get_node("Player")
\tvar cfg: Dictionary = Registry.weapons[spread_wid]
\tvar base_spread := float(cfg.get("spread", 0.0))
\tvar old_v := float(p.stats.get("proj_spread_mult", 0.0))
\t# 反向对照：0 值必须原样复用原字典（`_weapon_runtime_cfg` 的早退约定）
\tp.stats["proj_spread_mult"] = 0.0
\tif p._weapon_runtime_cfg(cfg) != cfg:
\t\t_fail("第11轮：proj_spread_mult = 0 时不该 duplicate 武器字典")
\t\tp.stats["proj_spread_mult"] = old_v
\t\treturn
\tif not is_equal_approx(float(p._weapon_runtime_cfg(cfg).get("spread", 0.0)), base_spread):
\t\t_fail("第11轮：无加成时 spread 被改动（应恒为 %.4f）" % base_spread)
\t\tp.stats["proj_spread_mult"] = old_v
\t\treturn
\t# 正向：收窄 / 扩散都必须真的改到 spread，且严格等于 base × (1+m)
\tp.stats["proj_spread_mult"] = hi
\tvar got_hi := float(p._weapon_runtime_cfg(cfg).get("spread", 0.0))
\tp.stats["proj_spread_mult"] = mh
\tvar got_mh := float(p._weapon_runtime_cfg(cfg).get("spread", 0.0))
\tif not (got_hi < base_spread and got_mh > base_spread):
\t\t_fail("第11轮：喷嘴没改到 spread（base=%.4f 收窄=%.4f 扩散=%.4f）"
\t\t\t% [base_spread, got_hi, got_mh])
\t\tp.stats["proj_spread_mult"] = old_v
\t\treturn
\tif absf(got_hi - base_spread * (1.0 + hi)) > 1e-6 \\
\t\t\tor absf(got_mh - base_spread * (1.0 + mh)) > 1e-6:
\t\t_fail("第11轮：spread 缩放与 (1 + proj_spread_mult) 不一致")
\t\tp.stats["proj_spread_mult"] = old_v
\t\treturn
\t# ③ 表现层同源：火焰锥末端宽度必须跟着同一倍率走
\tp.stats["proj_spread_mult"] = 0.0
\tp._ignite_flame_jet(cfg, 0.0)
\tvar w0 := float(p._ensure_flame_jet().width)
\tp.stats["proj_spread_mult"] = mh
\tp._ignite_flame_jet(cfg, 0.0)
\tvar w1 := float(p._ensure_flame_jet().width)
\tp.stats["proj_spread_mult"] = old_v
\tp._sanitize_stats()
\tif w0 <= 0.0 or absf(w1 - w0 * (1.0 + mh)) > 1e-4:
\t\t_fail("第11轮：火焰锥宽度没跟着 proj_spread_mult 缩放（%.2f → %.2f）" % [w0, w1])
\t\treturn'''

NEW = '''\tvar p: Node2D = _main.get_node("Player")
\tvar cfg: Dictionary = Registry.weapons[spread_wid]
\tvar base_spread := float(cfg.get("spread", 0.0))
\t# ⚠️⚠️ 本用例排在几十条用例之后，玩家身上**已经有别人留下的武器加成**。
\t#    实测（第 11 轮第一次跑就假红）：残留会让 `_weapon_runtime_cfg` 走 duplicate 分支，
\t#    于是「全 0 时不该 duplicate」这条反向对照必红，**且红得像「实现错了」**。
\t#    与 `_check_balance_log` 同款纪律：进用例先把武器加成键全摘掉，所有退出路径原样还回去。
\tvar keep := {}
\tfor k in ["bullet_speed_bonus", "bullet_range_bonus", "throw_speed_bonus",
\t\t\t"throw_range_bonus", "melee_range_bonus", "aoe_radius_bonus", "proj_spread_mult"]:
\t\tkeep[String(k)] = float(p.stats.get(String(k), 0.0))
\t\tp.stats[String(k)] = 0.0
\t# 反向对照：武器加成**全部归零**后必须原样复用原字典（`_weapon_runtime_cfg` 的早退约定）。
\t# ⚠️ 用 `is_same()` 而不是 `!=`：Dictionary 的 `!=` 语义随版本摇摆，
\t#    `is_same()` 明确比的是「同一个实例」，正是这里要测的东西。
\tif not is_same(p._weapon_runtime_cfg(cfg), cfg):
\t\t_restore_stat_keys(p, keep)
\t\t_fail("第11轮：全部武器加成归零时不该 duplicate 武器字典")
\t\treturn
\tif not is_equal_approx(float(p._weapon_runtime_cfg(cfg).get("spread", 0.0)), base_spread):
\t\t_restore_stat_keys(p, keep)
\t\t_fail("第11轮：无加成时 spread 被改动（应恒为 %.4f）" % base_spread)
\t\treturn
\t# 正向：收窄 / 扩散都必须真的改到 spread，且严格等于 base × (1+m)
\tp.stats["proj_spread_mult"] = hi
\tvar got_hi := float(p._weapon_runtime_cfg(cfg).get("spread", 0.0))
\tp.stats["proj_spread_mult"] = mh
\tvar got_mh := float(p._weapon_runtime_cfg(cfg).get("spread", 0.0))
\tif not (got_hi < base_spread and got_mh > base_spread):
\t\t_restore_stat_keys(p, keep)
\t\t_fail("第11轮：喷嘴没改到 spread（base=%.4f 收窄=%.4f 扩散=%.4f）"
\t\t\t% [base_spread, got_hi, got_mh])
\t\treturn
\tif absf(got_hi - base_spread * (1.0 + hi)) > 1e-6 \\
\t\t\tor absf(got_mh - base_spread * (1.0 + mh)) > 1e-6:
\t\t_restore_stat_keys(p, keep)
\t\t_fail("第11轮：spread 缩放与 (1 + proj_spread_mult) 不一致")
\t\treturn
\t# ③ 表现层同源：火焰锥末端宽度必须跟着同一倍率走
\tp.stats["proj_spread_mult"] = 0.0
\tp._ignite_flame_jet(cfg, 0.0)
\tvar w0 := float(p._ensure_flame_jet().width)
\tp.stats["proj_spread_mult"] = mh
\tp._ignite_flame_jet(cfg, 0.0)
\tvar w1 := float(p._ensure_flame_jet().width)
\t_restore_stat_keys(p, keep)
\tif w0 <= 0.0 or absf(w1 - w0 * (1.0 + mh)) > 1e-4:
\t\t_fail("第11轮：火焰锥宽度没跟着 proj_spread_mult 缩放（%.2f → %.2f）" % [w0, w1])
\t\treturn'''

HELPER_OLD = '''## 第 11 轮：喷射散布角通道（喷嘴类道具）。'''
HELPER_NEW = '''## 原样还回一批 stats 键并重新净化 —— 「租的变量要还」的公共写法。
## 起因见 `_check_spread_channel` 与 `_check_balance_log` 里关于**残留加成**的长注释。
func _restore_stat_keys(p: Node2D, keep: Dictionary) -> void:
\tfor k in keep:
\t\tp.stats[String(k)] = float(keep[k])
\tp._sanitize_stats()


## 第 11 轮：喷射散布角通道（喷嘴类道具）。'''

ok = apply_file(SMK, [(OLD, NEW), (HELPER_OLD, HELPER_NEW)], "smoke-r11-spreadfix")
if not ok:
    sys.exit(1)
