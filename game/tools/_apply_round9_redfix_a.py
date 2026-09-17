# -*- coding: utf-8 -*-
"""第 9 轮 · 冒烟修红（1/2）：需求 1 遗留的 GridContainer.alignment + W4 变 BOSS 波后的 BGM 期望表。

跑法：
    python.exe game/tools/_apply_round9_redfix_a.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path  # noqa: E402

SHOP = game_path("scripts", "ui", "shop_ui.gd")
SMOKE = game_path("tests", "smoke_test.gd")

# ---- 1. shop_ui：GridContainer 没有 alignment（那是 BoxContainer 的属性）----
S_OLD = """	_goods_box.columns = Config.SHOP_SLOTS
	_goods_box.alignment = BoxContainer.ALIGNMENT_CENTER
"""

S_NEW = """	_goods_box.columns = Config.SHOP_SLOTS
	# ⚠️ GridContainer **没有** `alignment`（那是 BoxContainer 的属性）——
	#    写错了不是静默失败而是运行期 `Invalid assignment of property`，
	#    并且会**中断整个 `_build()`**，导致后面所有控件（含 reroll/heal/next 三个按钮）
	#    全是 null，商店直接不可用。居中只能用 size_flags。
	_goods_box.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
"""

# ---- 2. smoke：BGM 期望表不允许再放 W4/W8/W12/W16 ----
M_OLD = """	# BGM 分波次：按**区块**升级（区块 1 battle / 区块 2 battle_mid / 区块 3+ battle_late）。
	# 断言覆盖每个区块的首尾两波 —— 只测区块中段会漏掉 `block_of` 的边界写错。
	var bgm_expect := { 1: "battle", 4: "battle", 5: "battle_mid", 8: "battle_mid",
		9: "battle_late", 19: "battle_late" }
	for bw in bgm_expect:
		if Music.track_for_wave(int(bw)) != String(bgm_expect[bw]):
			_fail("BGM 分波次映射错误（W%d → %s，期望 %s）"
				% [int(bw), Music.track_for_wave(int(bw)), String(bgm_expect[bw])])
			return
	if Music.track_for_wave(Config.BOSS_WAVE) != "boss":
		_fail("最终 BOSS 波未切 BOSS 曲（W%d → %s）"
			% [Config.BOSS_WAVE, Music.track_for_wave(Config.BOSS_WAVE)])
		return
"""

M_NEW = """	# BGM 分波次：按**区块**升级（区块 1 battle / 区块 2 battle_mid / 区块 3+ battle_late）。
	# 断言覆盖每个区块的首尾两波 —— 只测区块中段会漏掉 `block_of` 的边界写错。
	# ⚠️ 这张表里**只能放非 BOSS 波**：第 9 轮起区块末波（W4/8/12/16）也是 BOSS 波，
	#    它们的曲子交给下面的循环统一校验；写进这张表会立刻以"BGM 映射错了"报红。
	var bgm_expect := { 1: "battle", 3: "battle", 5: "battle_mid", 7: "battle_mid",
		9: "battle_late", 19: "battle_late" }
	for bw in bgm_expect:
		if Music.track_for_wave(int(bw)) != String(bgm_expect[bw]):
			_fail("BGM 分波次映射错误（W%d → %s，期望 %s）"
				% [int(bw), Music.track_for_wave(int(bw)), String(bgm_expect[bw])])
			return
	# BOSS 波（含第 9 轮新增的中间 BOSS）必须一律切 BOSS 曲。
	# ⚠️ 期望集**从被测数据算**（`Config.is_boss_wave`），不写死 4/8/12/16 ——
	#    否则以后调整 BOSS 节奏（每 4 波 → 每 5 波）时会以"BGM 坏了"的面目报红。
	for bw2 in range(1, Config.WAVES_TOTAL + 1):
		if not Config.is_boss_wave(bw2):
			continue
		if Music.track_for_wave(bw2) != "boss":
			_fail("BOSS 波未切 BOSS 曲（W%d → %s）" % [bw2, Music.track_for_wave(bw2)])
			return
"""


def main():
    ok = True
    ok = apply_file(SHOP, [(S_OLD, S_NEW)], "r9-redfix-shop") and ok
    ok = apply_file(SMOKE, [(M_OLD, M_NEW)], "r9-redfix-bgm") and ok
    if not ok:
        sys.exit(1)
    print("ALL OK")


if __name__ == "__main__":
    main()
