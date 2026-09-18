# -*- coding: utf-8 -*-
"""第 11 轮 · 冒烟暴露的两件事：

① `edge` 留在 rare：`rarity_weight` 按波次压权重（epic ≥W3 / mythic ≥W6，config.gd:1720-1722），
   而商店「亲和保底」要在**任意波次**都能找到契合商品。4 张近战射程道具若全部 ≥epic，
   W1~W2 的近战构筑就没有可保底的条目。
② `shop_ui._ensure_affinity_goods` 的真 bug：池子不按正权重过滤，且 `weighted_pick`
   返回 null 时直接赋给 `Dictionary` → SCRIPT ERROR（不是优雅放弃）。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path

CFG = game_path("scripts", "core", "config.gd")
SHOP = game_path("scripts", "ui", "shop_ui.gd")

CFG_EDITS = [
    ('''\t#      edge +18%→**+11%**（rare→epic）、swordmanual +22%→**+13%**（epic→mythic）、
\t#      whetstone +35%→**+21%**（epic→mythic）、swordcase +35%→**+21%**（epic→mythic）。
\t#      ⚠️ 提到 mythic = 金「**唯一件**」（本局每种最多 1 件）+ 池权重更低 → 双重「更难刷出来」。''',
     '''\t#      edge +18%→**+11%**（**保持 rare**）、swordmanual +22%→**+13%**（epic→mythic）、
\t#      whetstone +35%→**+21%**（epic→mythic）、swordcase +35%→**+21%**（epic→mythic）。
\t#      ⚠️ 提到 mythic = 金「**唯一件**」（本局每种最多 1 件）+ 池权重更低 → 双重「更难刷出来」。
\t#      ⚠️⚠️ `edge` **刻意留在 rare**（第 11 轮冒烟实测拦下）：`rarity_weight` 按波次压权重
\t#        （epic 要 progress≥3、mythic ≥6，见本文件 1716-1724），而商店「亲和保底」
\t#        （`shop_ui._ensure_affinity_goods`）要求**任意波次**都能找到一条契合商品。
\t#        4 张近战射程道具若全部 ≥epic，W1~W2 的近战构筑就没有任何可保底条目
\t#        （实测：池非空但全是 0 权重 → weighted_pick 报错返回 null → 撞 SCRIPT ERROR）。
\t#        留最弱的这张在 rare 顶住低波，既当保底锚点，也符合「最弱的那个不必提品」。'''),
    ('{ "id": "edge", "ico": "🗡", "name": "开刃", "desc": "斩击范围 +11%（近战武器）", '
     '"rarity": "epic", "effects": { "melee_range_bonus": 0.11 } }',
     '{ "id": "edge", "ico": "🗡", "name": "开刃", "desc": "斩击范围 +11%（近战武器）", '
     '"rarity": "rare", "effects": { "melee_range_bonus": 0.11 } }'),
]

SHOP_EDITS = [
    ('''		var m := Config.affinity_mult(Config.entry_tags(u), _affinity())
		if m > 1.0:
			pool.append({ "item": u,
				"w": Config.rarity_weight(String(u.get("rarity", "common")), _wave) * m })''',
     '''		var m := Config.affinity_mult(Config.entry_tags(u), _affinity())
		if m > 1.0:
			var uw := Config.rarity_weight(String(u.get("rarity", "common")), _wave) * m
			# ⚠️ 只收**正权重**：`rarity_weight` 会把高品阶按波次压到 0（epic <W3 / mythic <W6）。
			#    0 权重条目留在池里，`GameRng.weighted_pick` 会 push_error 并返回 null ——
			#    池子看着「非空」，实际一条都挑不出来。
			if uw > 0.0:
				pool.append({ "item": u, "w": uw })'''),
    ('''		var m2 := Config.affinity_mult(Config.entry_tags(it), _affinity())
		if m2 > 1.0:
			pool.append({ "item": it,
				"w": Config.rarity_weight(String(it.get("rarity", "common")), _wave) * m2 })''',
     '''		var m2 := Config.affinity_mult(Config.entry_tags(it), _affinity())
		if m2 > 1.0:
			var iw := Config.rarity_weight(String(it.get("rarity", "common")), _wave) * m2
			if iw > 0.0:   # 同上：0 权重不入池
				pool.append({ "item": it, "w": iw })'''),
    ('''	# 注意 GameRng.weighted_pick 返回的是 entry.item（条目本身），不是整条包装 ——
	# 所以 kind 只能靠条目归属反查，别指望从池里带出来
	var e: Dictionary = GameRng.weighted_pick(pool)
	if e.is_empty():
		return''',
     '''	# 注意 GameRng.weighted_pick 返回的是 entry.item（条目本身），不是整条包装 ——
	# 所以 kind 只能靠条目归属反查，别指望从池里带出来
	# ⚠️ 必须用 `Variant` 接：池子万一一条正权重都没有，`weighted_pick` 返回 null，
	#    直接赋给 `Dictionary` 是**运行期 SCRIPT ERROR**（第 11 轮实测踩到），
	#    而不是「保底放弃」——保底失败本该是静默的。
	var picked: Variant = GameRng.weighted_pick(pool)
	if typeof(picked) != TYPE_DICTIONARY:
		return
	var e: Dictionary = picked
	if e.is_empty():
		return'''),
]

ok = apply_file(CFG, CFG_EDITS, "config-r11b")
ok = apply_file(SHOP, SHOP_EDITS, "shop-r11b") and ok
if not ok:
    sys.exit(1)
