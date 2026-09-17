# -*- coding: utf-8 -*-
"""第 7 轮补做：「金/红物品唯一」机制落地。

用户拍板口径：**升级 + 道具 + 事件卡，凡是 mythic(金)/legendary(红) 的，
本局取到一件后即从抽取池剔除**（与法宝 artifacts_owned 同款语义）。

落地要点：
  1. Config 新增 is_unique_rarity / unique_pool_ok 两个静态闸门（策略单一来源）
  2. player 新增 upgrades_owned 记账（升级过去**没有**记账）+ apply_item/apply_upgrade 硬闸门
  3. 4 类抽取来源全部加闸门：商店(_rarity_pool/_ensure_affinity_goods)、
     升级三选一(level_up_ui ×3 处)、事件按品阶发道具(_grant_random_item)、宝箱波(wave_manager)
  4. 存档：upgrades_owned 必须落盘（否则续档唯一性静默失效）

⚠️ 每处断言 old 恰好命中 1 次，不符即中止（防「改错地方」）。
⚠️ tab 由 \\t 显式给出，不手打（沿用 _apply_round7_balance.py 的做法）。
"""
import sys

ROOT = r"D:/code/firstProject-ai/TheGreatestProject/game/"

CFG = ROOT + "scripts/core/config.gd"
PLR = ROOT + "scripts/characters/player.gd"
SHOP = ROOT + "scripts/ui/shop_ui.gd"
LVL = ROOT + "scripts/ui/level_up_ui.gd"
MAIN = ROOT + "scripts/main.gd"
WAVE = ROOT + "scripts/systems/wave_manager.gd"
SAVE = ROOT + "scripts/core/save_run.gd"

PATCHES = []

# ---------------------------------------------------------------- config.gd
PATCHES.append((CFG,
	'\t\t"epic": w *= 1.0 + 0.06 * t\n\treturn w\n',
	'\t\t"epic": w *= 1.0 + 0.06 * t\n\treturn w\n'
	'\n'
	'## ---- 「唯一件」闸门（2026-09-17 第 7 轮）----\n'
	'## 金（mythic）/ 红（legendary）= **唯一件**：本局每种最多 1 件，取到后即从所有抽取池剔除。\n'
	'## 这与法宝**同款语义**（`Registry.artifact_pool` 早就用 `artifacts_owned` 做同一件事），\n'
	'## 区别只是这一层过去**只盖住了法宝** —— 同一件金道具能叠到 10 层，全库也没有 `unique` 字段。\n'
	'##\n'
	'## ⚠️ **闸门必须盖住全部 4 类来源**，漏一处就等于没做：\n'
	'##   1. 商店 `_rarity_pool`（升级 + 道具两路都走它）\n'
	'##   2. 商店亲和保底 `_ensure_affinity_goods`\n'
	'##   3. 升级三选一 `level_up_ui`（抽取 + 亲和保底 + 均匀兜底，共 3 处）\n'
	'##   4. 事件「按品阶发道具」`main._grant_random_item` + 宝箱波战利品 `wave_manager`\n'
	'## 事件卡**本身**不需要加：`event_card_pool` 已用 `GameState.events_seen` 排重（每张每局一次）。\n'
	'## 最后还有 `player.apply_item` / `apply_upgrade` 里的**硬闸门**兜底 ——\n'
	'## 池子过滤只是「让玩家看不到」，mod / 调试面板等旁路绕过池子，只有硬闸门拦得住。\n'
	'static func is_unique_rarity(rarity: String) -> bool:\n'
	'\treturn rarity == "mythic" or rarity == "legendary"\n'
	'\n'
	'## 抽取闸门：唯一件已在 `owned` 里 → 返回 false（该条目应被剔出池）。\n'
	'## `owned` 传「当前持有表」（Dictionary，键 = 条目 id）；非唯一品阶恒 true。\n'
	'## 判据刻意用「当前持有」而非「曾经获得」—— 与法宝一致：卖掉后可以再刷到\n'
	'## （只能 50% 折价卖出、原价买回，净亏一半，不构成刷取漏洞）。\n'
	'static func unique_pool_ok(entry: Dictionary, owned: Dictionary) -> bool:\n'
	'\tif not is_unique_rarity(String(entry.get("rarity", "common"))):\n'
	'\t\treturn true\n'
	'\treturn not owned.has(String(entry.get("id", "")))\n'))

PATCHES.append((CFG,
	'## 升级池（可重复叠加；effects 键 = player.stats 键，创意工坊数据驱动；\n'
	'## 特例：heal_flat = 最大生命+立即回复同值，heal_pct = 立即回复最大生命百分比）\n',
	'## 升级池（**非金红可重复叠加**；金 mythic / 红 legendary = 「唯一件」，本局每张最多 1 次，\n'
	'## 见 is_unique_rarity —— 闸门在 level_up_ui / shop_ui / player.apply_upgrade 三处；\n'
	'## effects 键 = player.stats 键，创意工坊数据驱动；\n'
	'## 特例：heal_flat = 最大生命+立即回复同值，heal_pct = 立即回复最大生命百分比）\n'))

PATCHES.append((CFG,
	'## 商店道具（被动 = 永久属性；effects 键 = player.stats 键，创意工坊数据驱动；\n'
	'## i-hp 只加上限不立即回血，与原型一致）\n',
	'## 商店道具（被动 = 永久属性；**金 mythic / 红 legendary = 「唯一件」，本局每种最多 1 件**，\n'
	'## 与法宝 artifacts_owned 同款语义，判定见 is_unique_rarity / unique_pool_ok；\n'
	'## effects 键 = player.stats 键，创意工坊数据驱动；\n'
	'## i-hp 只加上限不立即回血，与原型一致）\n'))

# ---------------------------------------------------------------- player.gd
PATCHES.append((PLR,
	'var items_owned: Dictionary = {}   # 已购道具 id -> 数量（暂停/商店展示与出售用）\n',
	'var items_owned: Dictionary = {}   # 已购道具 id -> 数量（暂停/商店展示与出售用）\n'
	'## 本局已获得过的升级 id -> 次数。**升级过去完全没有记账**（apply_upgrade 只改 stats），\n'
	'## 是第 7 轮为「金/红升级唯一」新加的。⚠️ 必须进存档 —— 否则续档后本表归空，\n'
	'## 同一张金升级能再刷一遍，唯一性**静默**失效（不报错，只是不唯一了）。\n'
	'var upgrades_owned: Dictionary = {}\n'))

PATCHES.append((PLR,
	'## 应用升级效果（数据驱动：effects 键 = stats 键，创意工坊自定义升级直接生效）\n'
	'func apply_upgrade(id: String) -> void:\n'
	'\tvar u: Dictionary = Registry.upgrades.get(id, {})\n'
	'\tif u.is_empty():\n'
	'\t\treturn\n'
	'\tCodexData.unlock("upgrade", id)\n'
	'\tapply_effects(u.get("effects", {}))\n',
	'## 应用升级效果（数据驱动：effects 键 = stats 键，创意工坊自定义升级直接生效）\n'
	'## ⚠️ 金/红升级 = 「唯一件」（Config.is_unique_rarity）：已获得过则**直接拒绝**。\n'
	'##    池子侧（level_up_ui / shop_ui）只负责「让玩家看不到」，这里才是不可绕过的硬闸门\n'
	'##    —— mod / 调试面板等旁路也会经过它。返回 true = 本次生效。\n'
	'func apply_upgrade(id: String) -> bool:\n'
	'\tvar u: Dictionary = Registry.upgrades.get(id, {})\n'
	'\tif u.is_empty():\n'
	'\t\treturn false\n'
	'\tif Config.is_unique_rarity(String(u.get("rarity", "common"))) and upgrades_owned.has(id):\n'
	'\t\tvar pu := get_parent()\n'
	'\t\tif pu != null:\n'
	'\t\t\tFloatingText.spawn(pu, global_position + Vector2(0.0, -28.0),\n'
	'\t\t\t\t"%s 已获得过 · 本局唯一" % String(u.get("name", id)), Color("ffd24a"))\n'
	'\t\treturn false\n'
	'\tCodexData.unlock("upgrade", id)\n'
	'\tupgrades_owned[id] = int(upgrades_owned.get(id, 0)) + 1\n'
	'\tapply_effects(u.get("effects", {}))\n'
	'\treturn true\n'))

PATCHES.append((PLR,
	'## 应用商店道具被动效果（数据驱动：effects 键 = stats 键，可叠加；i-hp 只加上限不回血，与原型一致）\n'
	'func apply_item(id: String) -> void:\n'
	'\tif not Registry.items.has(id):\n'
	'\t\treturn\n'
	'\tCodexData.unlock("item", id)\n'
	'\titems_owned[id] = int(items_owned.get(id, 0)) + 1\n'
	'\tvar it: Dictionary = Registry.items[id]\n'
	'\tfor k in it.get("effects", {}):\n'
	'\t\tstats[k] = stats.get(k, 0.0) + float(it.effects[k])\n'
	'\t_sanitize_stats()\n'
	'\tqueue_redraw()\n',
	'## 应用商店道具被动效果（数据驱动：effects 键 = stats 键，可叠加；i-hp 只加上限不回血，与原型一致）\n'
	'## ⚠️ 金/红道具 = 「唯一件」（Config.is_unique_rarity）：已持有则**拒绝第二次**，\n'
	'##    与法宝 apply_artifact 的重复分支同款。返回 true = 本次生效。\n'
	'func apply_item(id: String) -> bool:\n'
	'\tif not Registry.items.has(id):\n'
	'\t\treturn false\n'
	'\tvar it: Dictionary = Registry.items[id]\n'
	'\tif Config.is_unique_rarity(String(it.get("rarity", "common"))) and items_owned.has(id):\n'
	'\t\tvar pi := get_parent()\n'
	'\t\tif pi != null:\n'
	'\t\t\tFloatingText.spawn(pi, global_position + Vector2(0.0, -28.0),\n'
	'\t\t\t\t"%s 已持有 · 本局唯一" % String(it.get("name", id)), Color("ffd24a"))\n'
	'\t\treturn false\n'
	'\tCodexData.unlock("item", id)\n'
	'\titems_owned[id] = int(items_owned.get(id, 0)) + 1\n'
	'\tfor k in it.get("effects", {}):\n'
	'\t\tstats[k] = stats.get(k, 0.0) + float(it.effects[k])\n'
	'\t_sanitize_stats()\n'
	'\tqueue_redraw()\n'
	'\treturn true\n'))

# ---------------------------------------------------------------- shop_ui.gd
PATCHES.append((SHOP,
	'func _rarity_pool(entries: Array) -> Array:\n'
	'\tvar aff := _affinity()\n'
	'\tvar pool: Array = []\n'
	'\tfor e in entries:\n'
	'\t\tif not Config.entry_weapon_relevant(e, player.weapons):\n'
	'\t\t\tcontinue\n'
	'\t\tvar w: float = Config.rarity_weight(String(e.get("rarity", "common")), _wave) \\\n'
	'\t\t\t* Config.affinity_mult(Config.entry_tags(e), aff)\n'
	'\t\tpool.append({ "item": e, "w": w })\n'
	'\treturn pool\n',
	'## `owned` 传该池对应的「当前持有表」（升级 → upgrades_owned，道具 → items_owned），\n'
	'## 用于剔除金/红「唯一件」（Config.unique_pool_ok）—— 取表见 _owned_for。\n'
	'func _rarity_pool(entries: Array, owned: Dictionary) -> Array:\n'
	'\tvar aff := _affinity()\n'
	'\tvar pool: Array = []\n'
	'\tfor e in entries:\n'
	'\t\tif not Config.entry_weapon_relevant(e, player.weapons):\n'
	'\t\t\tcontinue\n'
	'\t\tif not Config.unique_pool_ok(e, owned):\n'
	'\t\t\tcontinue   # 金/红唯一件已持有 → 不再出现\n'
	'\t\tvar w: float = Config.rarity_weight(String(e.get("rarity", "common")), _wave) \\\n'
	'\t\t\t* Config.affinity_mult(Config.entry_tags(e), aff)\n'
	'\t\tpool.append({ "item": e, "w": w })\n'
	'\treturn pool\n'
	'\n'
	'## 唯一件闸门要用的「当前持有表」：升级看 upgrades_owned，道具看 items_owned。\n'
	'## 法宝不在此列 —— 它一直走 Registry.artifact_pool(artifacts_owned, …) 的独立通道。\n'
	'func _owned_for(kind: String) -> Dictionary:\n'
	'\treturn player.upgrades_owned if kind == "upgrade" else player.items_owned\n'))

PATCHES.append((SHOP,
	'\t\tvar u: Dictionary = GameRng.weighted_pick(_rarity_pool(Registry.upgrade_list()))\n',
	'\t\tvar u: Dictionary = GameRng.weighted_pick(\n'
	'\t\t\t_rarity_pool(Registry.upgrade_list(), player.upgrades_owned))\n'))

PATCHES.append((SHOP,
	'\tvar it: Dictionary = GameRng.weighted_pick(_rarity_pool(Registry.item_list()))\n',
	'\tvar it: Dictionary = GameRng.weighted_pick(\n'
	'\t\t_rarity_pool(Registry.item_list(), player.items_owned))\n'))

PATCHES.append((SHOP,
	'\tfor u in Registry.upgrade_list():\n'
	'\t\tif taken.has(String(u.get("id", ""))):\n'
	'\t\t\tcontinue\n'
	'\t\tif not Config.entry_weapon_relevant(u, player.weapons):\n'
	'\t\t\tcontinue\n',
	'\tfor u in Registry.upgrade_list():\n'
	'\t\tif taken.has(String(u.get("id", ""))):\n'
	'\t\t\tcontinue\n'
	'\t\tif not Config.unique_pool_ok(u, player.upgrades_owned):\n'
	'\t\t\tcontinue   # 金/红唯一件已持有 → 不再出现\n'
	'\t\tif not Config.entry_weapon_relevant(u, player.weapons):\n'
	'\t\t\tcontinue\n'))

PATCHES.append((SHOP,
	'\tfor it in Registry.item_list():\n'
	'\t\tif taken.has(String(it.get("id", ""))):\n'
	'\t\t\tcontinue\n'
	'\t\tif not Config.entry_weapon_relevant(it, player.weapons):\n'
	'\t\t\tcontinue\n',
	'\tfor it in Registry.item_list():\n'
	'\t\tif taken.has(String(it.get("id", ""))):\n'
	'\t\t\tcontinue\n'
	'\t\tif not Config.unique_pool_ok(it, player.items_owned):\n'
	'\t\t\tcontinue   # 金/红唯一件已持有 → 不再出现\n'
	'\t\tif not Config.entry_weapon_relevant(it, player.weapons):\n'
	'\t\t\tcontinue\n'))

PATCHES.append((SHOP,
	'\tif g.kind == "artifact" and player.artifacts_owned.has(String(g.id)):\n'
	'\t\tg.sold = true\n'
	'\t\t_refresh()\n'
	'\t\treturn\n',
	'\tif g.kind == "artifact" and player.artifacts_owned.has(String(g.id)):\n'
	'\t\tg.sold = true\n'
	'\t\t_refresh()\n'
	'\t\treturn\n'
	'\t# 同理：金/红「唯一件」在商店开着期间已从掉落 / 事件拿到 → 同样标售罄且不扣钱，\n'
	'\t# 否则玩家会为一件已持有的金/红件付全价，只换回 apply_item 的拒绝\n'
	'\tif g.kind in ["upgrade", "item"] and not Config.unique_pool_ok(g, _owned_for(String(g.kind))):\n'
	'\t\tg.sold = true\n'
	'\t\t_refresh()\n'
	'\t\treturn\n'))

# ---------------------------------------------------------------- level_up_ui.gd
PATCHES.append((LVL,
	'\tvar aff := Config.affinity_tags(GameState.character_id, wps, arts)\n'
	'\tvar weighted: Array = []\n'
	'\tfor u in Registry.upgrade_list():\n'
	'\t\tif not Config.entry_weapon_relevant(u, wps):\n'
	'\t\t\tcontinue   # 过滤「对当前武器无用」的武器专属强化（纯枪构筑不出近战范围加成）\n',
	'\tvar aff := Config.affinity_tags(GameState.character_id, wps, arts)\n'
	'\t# 金/红升级 = 「唯一件」：已获得过的不再出现在三选一里\n'
	'\t# （闸门本体在 player.apply_upgrade，这里只是不把它摆到台面上）\n'
	'\tvar up_owned: Dictionary = {}\n'
	'\tif player != null and is_instance_valid(player):\n'
	'\t\tup_owned = player.upgrades_owned\n'
	'\tvar weighted: Array = []\n'
	'\tfor u in Registry.upgrade_list():\n'
	'\t\tif not Config.unique_pool_ok(u, up_owned):\n'
	'\t\t\tcontinue\n'
	'\t\tif not Config.entry_weapon_relevant(u, wps):\n'
	'\t\t\tcontinue   # 过滤「对当前武器无用」的武器专属强化（纯枪构筑不出近战范围加成）\n'))

PATCHES.append((LVL,
	'\t\tvar candidates: Array = Registry.upgrade_list().duplicate()\n'
	'\t\twhile _choices.size() < 3 and not candidates.is_empty():\n',
	'\t\tvar candidates: Array = []\n'
	'\t\tfor u2 in Registry.upgrade_list():\n'
	'\t\t\tif Config.unique_pool_ok(u2, up_owned):\n'
	'\t\t\t\tcandidates.append(u2)\n'
	'\t\twhile _choices.size() < 3 and not candidates.is_empty():\n'))

PATCHES.append((LVL,
	'\tvar pool: Array = []\n'
	'\tvar wps2: Array = player.weapons if player != null and is_instance_valid(player) else []\n'
	'\tfor u in Registry.upgrade_list():\n'
	'\t\tif taken.has(String(u.get("id", ""))):\n'
	'\t\t\tcontinue\n'
	'\t\tif not Config.entry_weapon_relevant(u, wps2):\n'
	'\t\t\tcontinue\n',
	'\tvar pool: Array = []\n'
	'\tvar wps2: Array = player.weapons if player != null and is_instance_valid(player) else []\n'
	'\tvar up_owned2: Dictionary = player.upgrades_owned if player != null and is_instance_valid(player) else {}\n'
	'\tfor u in Registry.upgrade_list():\n'
	'\t\tif taken.has(String(u.get("id", ""))):\n'
	'\t\t\tcontinue\n'
	'\t\tif not Config.unique_pool_ok(u, up_owned2):\n'
	'\t\t\tcontinue\n'
	'\t\tif not Config.entry_weapon_relevant(u, wps2):\n'
	'\t\t\tcontinue\n'))

# ---------------------------------------------------------------- main.gd
PATCHES.append((MAIN,
	'\tvar pool: Array = []\n'
	'\tfor it in Registry.item_list():\n'
	'\t\tif String(it.get("rarity", "common")) == rarity \\\n'
	'\t\t\t\tand Config.entry_weapon_relevant(it, player.weapons):\n'
	'\t\t\tpool.append({ "item": it, "w": 1.0 })\n'
	'\tif pool.is_empty():\n'
	'\t\tfor it2 in Registry.item_list():\n'
	'\t\t\tif not Config.entry_weapon_relevant(it2, player.weapons):\n'
	'\t\t\t\tcontinue\n'
	'\t\t\tpool.append({ "item": it2,\n'
	'\t\t\t\t"w": Config.rarity_weight(String(it2.get("rarity", "common")), wave_manager.wave) })\n'
	'\tif pool.is_empty():\n'
	'\t\treturn\n'
	'\tvar picked: Dictionary = GameRng.weighted_pick(pool)\n'
	'\tvar id := String(picked.get("id", ""))\n'
	'\tif id == "":\n'
	'\t\treturn\n'
	'\tplayer.apply_item(id)\n',
	'\tvar pool: Array = []\n'
	'\t# ⚠️ 金/红「唯一件」已持有的一律不进池 —— 否则「供奉兵器」这类选项会白吞一次奖励\n'
	'\tfor it in Registry.item_list():\n'
	'\t\tif String(it.get("rarity", "common")) == rarity \\\n'
	'\t\t\t\tand Config.entry_weapon_relevant(it, player.weapons) \\\n'
	'\t\t\t\tand Config.unique_pool_ok(it, player.items_owned):\n'
	'\t\t\tpool.append({ "item": it, "w": 1.0 })\n'
	'\tif pool.is_empty():\n'
	'\t\tfor it2 in Registry.item_list():\n'
	'\t\t\tif not Config.entry_weapon_relevant(it2, player.weapons) \\\n'
	'\t\t\t\t\tor not Config.unique_pool_ok(it2, player.items_owned):\n'
	'\t\t\t\tcontinue\n'
	'\t\t\tpool.append({ "item": it2,\n'
	'\t\t\t\t"w": Config.rarity_weight(String(it2.get("rarity", "common")), wave_manager.wave) })\n'
	'\tif pool.is_empty():\n'
	'\t\treturn\n'
	'\tvar picked: Dictionary = GameRng.weighted_pick(pool)\n'
	'\tvar id := String(picked.get("id", ""))\n'
	'\tif id == "":\n'
	'\t\treturn\n'
	'\tif not player.apply_item(id):\n'
	'\t\t# 池已过滤，正常到不了这里；真撞上（同一件唯一件被别的路径先拿到）也不吞奖励，\n'
	'\t\t# 转材料补偿（与法宝重复获得的处理同口径）\n'
	'\t\tGameState.add_materials(Config.ARTIFACT_DUP_MATERIALS)\n'
	'\t\treturn\n'))

# ---------------------------------------------------------------- wave_manager.gd
PATCHES.append((WAVE,
	'\t\t\tfor it in Registry.item_list():\n'
	'\t\t\t\tvar r := String(it.get("rarity", "common"))\n'
	'\t\t\t\tif r in ["epic", "mythic", "legendary"] \\\n'
	'\t\t\t\t\t\tand Config.entry_weapon_relevant(it, player.weapons):\n',
	'\t\t\tfor it in Registry.item_list():\n'
	'\t\t\t\tvar r := String(it.get("rarity", "common"))\n'
	'\t\t\t\tif r in ["epic", "mythic", "legendary"] \\\n'
	'\t\t\t\t\t\tand Config.entry_weapon_relevant(it, player.weapons) \\\n'
	'\t\t\t\t\t\tand Config.unique_pool_ok(it, player.items_owned):\n'))

# ---------------------------------------------------------------- save_run.gd
PATCHES.append((SAVE,
	'\t\t\t"items_owned": player.items_owned.duplicate(),\n',
	'\t\t\t"items_owned": player.items_owned.duplicate(),\n'
	'\t\t\t# 升级记账（第 7 轮新增）：金/红升级「本局唯一」的唯一依据。\n'
	'\t\t\t# 不落盘的话续档后 upgrades_owned 归空 → 同一张金升级能再刷一遍，唯一性静默失效\n'
	'\t\t\t"upgrades_owned": player.upgrades_owned.duplicate(),\n'))

PATCHES.append((SAVE,
	'\t\t\t\tplayer.items_owned[id] = count\n'
	'\t# 法宝：stats 已随存档恢复（叠层加成已含在其中），这里只恢复持有表与层数记录。\n',
	'\t\t\t\tplayer.items_owned[id] = count\n'
	'\t# 升级记账：只恢复「当前 Registry 里还存在」的条目（mod 卸载后存档里的升级失效，\n'
	'\t# 静默丢弃，与 items_owned 同款处理）。旧档没有这个键 → pl.get 取 {}，原地升级，\n'
	'\t# 唯一性从空集开始（唯一性只能往后保证，旧档无法追溯）。\n'
	'\tplayer.upgrades_owned = {}\n'
	'\tvar saved_up: Dictionary = pl.get("upgrades_owned", {})\n'
	'\tfor uid: String in saved_up:\n'
	'\t\tif Registry.upgrades.has(uid):\n'
	'\t\t\tplayer.upgrades_owned[uid] = int(saved_up[uid])\n'
	'\t# 法宝：stats 已随存档恢复（叠层加成已含在其中），这里只恢复持有表与层数记录。\n'))

PATCHES.append((SAVE,
	'\tfor aid in pl.get("artifacts_owned", {}):\n',
	'\tfor uid in pl.get("upgrades_owned", {}):\n'
	'\t\tif typeof(uid) != TYPE_STRING or String(uid).is_empty() or String(uid).length() > 128 \\\n'
	'\t\t\t\tor not _integer_in_range(pl.upgrades_owned[uid], 1, 1_000_000):\n'
	'\t\t\treturn {}\n'
	'\tfor aid in pl.get("artifacts_owned", {}):\n'))


def main() -> int:
	ok = 0
	for path, old, new in PATCHES:
		raw = open(path, "rb").read()
		crlf = b"\r\n" in raw
		src = raw.decode("utf-8")
		nl = "\r\n" if crlf else "\n"
		o = old.replace("\n", nl)
		n = new.replace("\n", nl)
		cnt = src.count(o)
		if cnt != 1:
			print("FAIL %s: old 命中 %d 次（应为 1）" % (path, cnt))
			print("---- old ----")
			print(repr(o[:400]))
			return 1
		out = src.replace(o, n, 1)
		open(path, "w", encoding="utf-8", newline="").write(out)
		ok += 1
		print("OK   %s  (LF=%s)" % (path, "no" if crlf else "yes"))
	print("WROTE %d patch(es)" % ok)
	return 0


if __name__ == "__main__":
	sys.exit(main())
