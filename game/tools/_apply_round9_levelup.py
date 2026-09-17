# -*- coding: utf-8 -*-
"""第 9 轮 · 需求 2：连升合并成「一次选择」。

根因（已查证，写进 config 注释）：
  `xp_need(level) = 4 + (level-1)*3` → 前期一级只要 4 点，而 W1 的小怪一只给 2~3 点 XP，
  一波 10+ 只 ⇒ 一波跨 2~3 级；旧逻辑**每级各弹一次三选一**（且每次重抽三张）
  ⇒ 连升 3 级要点 3 次。波末又自动拾取整波 XP，所以「开局」这一段尤其密集。

改动：
  config.gd      —— 新增合并上限与溢出折算常量
  level_up_ui.gd —— `_merged` + open() 算级数 + _choose() 一次生效 ×N + merged_count()
  smoke_test.gd  —— 把「连升第二组重新抽卡」那三条断言换成合并语义的断言
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path   # noqa: E402

CFG = game_path("scripts", "core", "config.gd")
LU = game_path("scripts", "ui", "level_up_ui.gd")
SMOKE = game_path("tests", "smoke_test.gd")

# ---------------------------------------------------------------- config.gd
cfg_edits = [(
    "static func xp_need(level: int) -> int:\n"
    "	return 4 + (level - 1) * 3\n",
    "## ---- 连升合并（第 9 轮 · 用户反馈「开始时选好多次奖励」）----\n"
    "## 成因：`xp_need` 前期太平（1→2 级只要 4 点），而 W1 一只小怪就给 2~3 点 XP\n"
    "##   （见 MOBS 的 xp 字段），一波 10+ 只 ⇒ 一波就能跨 2~3 级；\n"
    "##   而旧逻辑是**每个等级各弹一次三选一**（且每次重新抽三张）⇒ 连升 3 级要点 3 次。\n"
    "##   波末又会自动拾取整波 XP，所以「开局那几波」尤其密集。\n"
    "## 修法：连升 N 级合并成**一次**选择，选中的那张**生效 N 次**（收益不减，点击 N → 1）。\n"
    "## ⚠️ 上限不是随便定的：叠 N 次对 `dmg_mult` 这类**乘法**效果是复利，\n"
    "##    一次升 8 级全塞进一张卡会直接击穿平衡；超出的级数折成材料（见下）。\n"
    "const LEVEL_MERGE_CAP := 3          # 单次选择最多承载几级的收益\n"
    "const LEVEL_MERGE_OVERFLOW_MAT := 12  # 超出上限的每一级折算成多少材料\n"
    "\n"
    "static func xp_need(level: int) -> int:\n"
    "	return 4 + (level - 1) * 3\n",
)]

# ---------------------------------------------------------------- level_up_ui.gd
lu_edits = []

lu_edits.append((
    "var _choices: Array = []   # 当前三张升级卡（Registry.upgrades 元素）\n",
    "var _choices: Array = []   # 当前三张升级卡（Registry.upgrades 元素）\n"
    "var _merged := 1            # 本次选择合并了几级收益（连升合并，见 open/_choose）\n",
))

lu_edits.append((
    "func open() -> void:\n"
    "	GameState.set_phase(GameState.Phase.LEVEL_UP)\n"
    "	_choices = []\n",
    "func open() -> void:\n"
    "	GameState.set_phase(GameState.Phase.LEVEL_UP)\n"
    "	_choices = []\n"
    "	# 连升合并（第 9 轮）：积压的 N 级合并成**一次**选择，选中的那张生效 N 次。\n"
    "	# 上限对齐 Config.LEVEL_MERGE_CAP，超出的级数在 _choose 里折成材料。\n"
    "	# ⚠️ 这里只定「这一次代表几级」，**不动 level_queue** —— 队列一律由 _choose 清零。\n"
    "	_merged = clampi(maxi(GameState.level_queue, 1), 1, Config.LEVEL_MERGE_CAP)\n",
))

lu_edits.append((
    "	_title.text = \"升级！Lv %d\" % GameState.level\n",
    "	_title.text = \"升级！Lv %d\" % GameState.level\n"
    "	if _merged > 1:\n"
    "		# 必须让玩家看见「为什么只选一次」——否则会以为漏了两次升级\n"
    "		_title.text += \"  ·  连升 %d 级（本次选择生效 ×%d）\" % [_merged, _merged]\n",
))

lu_edits.append((
    "func card_count() -> int:\n"
    "	return _choices.size()\n",
    "func card_count() -> int:\n"
    "	return _choices.size()\n"
    "\n"
    "## 本次选择代表几级收益（连升合并后的级数；冒烟与 UI 文案都读它，不各自算一遍）\n"
    "func merged_count() -> int:\n"
    "	return _merged\n",
))

lu_edits.append((
    "	if player and uid != \"\":\n"
    "		player.apply_upgrade(uid)\n"
    "	Haptics.rumble(0.25, 0.0, 0.08)   # 手柄确认轻震\n"
    "	GameState.level_queue = maxi(0, GameState.level_queue - 1)\n"
    "	_choices = []\n"
    "	if GameState.level_queue > 0:\n"
    "		# 连升：为下一次升级重新抽取三张，避免空卡片锁死\n"
    "		open()\n"
    "	else:\n"
    "		visible = false\n"
    "		GameState.set_phase(GameState.Phase.PLAYING)\n",
    "	# 连升合并（第 9 轮）：一次点击兑现 _merged 级的收益。\n"
    "	# ⚠️ 金/红「唯一件」的第二、三次会被 `player.apply_upgrade` 的硬闸门拒绝 ——\n"
    "	#    这是对的（唯一件本就不该叠加），所以这里不做任何补救，收益自然少算。\n"
    "	var times := maxi(1, _merged)\n"
    "	if player and uid != \"\":\n"
    "		for _t in times:\n"
    "			player.apply_upgrade(uid)\n"
    "	# 超出合并上限的级数折成材料 —— 避免「一次升 8 级」被一张卡白白吃掉\n"
    "	var overflow := GameState.level_queue - times\n"
    "	if overflow > 0:\n"
    "		GameState.add_materials(overflow * Config.LEVEL_MERGE_OVERFLOW_MAT)\n"
    "	Haptics.rumble(0.25, 0.0, 0.08)   # 手柄确认轻震\n"
    "	# 队列一次清零：合并后不存在「还剩几级要补弹」，这是玩家少点几次的全部来源\n"
    "	GameState.level_queue = 0\n"
    "	_merged = 1\n"
    "	_choices = []\n"
    "	visible = false\n"
    "	GameState.set_phase(GameState.Phase.PLAYING)\n",
))

# ---------------------------------------------------------------- smoke_test.gd
smoke_edits = [(
    "	# ---- 单次跨两级：第一次选择后必须立即重抽三张，第二次选择后恢复战斗 ----\n"
    "	var need_two := Config.xp_need(GameState.level) + Config.xp_need(GameState.level + 1)\n"
    "	GameState.gain_xp(need_two + 1)\n"
    "	await get_tree().process_frame\n"
    "	if GameState.phase != GameState.Phase.LEVEL_UP or GameState.level_queue != 2 or ui.card_count() != 3:\n"
    "		_fail(\"单次跨两级未生成首组卡（phase=%d queue=%d cards=%d）\" %\n"
    "			[GameState.phase, GameState.level_queue, ui.card_count()])\n"
    "		return\n"
    "	ui._choose(0)\n"
    "	await get_tree().process_frame\n"
    "	if GameState.phase != GameState.Phase.LEVEL_UP or GameState.level_queue != 1 or ui.card_count() != 3:\n"
    "		_fail(\"连升第二组未重新抽卡（phase=%d queue=%d cards=%d）\" %\n"
    "			[GameState.phase, GameState.level_queue, ui.card_count()])\n"
    "		return\n"
    "	var focus2: Control = ui.get_viewport().gui_get_focus_owner()\n"
    "	if focus2 == null or focus2.get_parent() != ui.get_node(\"Center/Box/Cards\"):\n"
    "		_fail(\"连升第二组卡未获得焦点\")\n"
    "		return\n"
    "	ui._choose(0)\n"
    "	if GameState.phase != GameState.Phase.PLAYING or GameState.level_queue != 0:\n"
    "		_fail(\"连升完成后未恢复 PLAYING\")\n"
    "		return\n",
    "	# ---- 单次跨两级：第 9 轮起**合并成一次选择**，收益 ×2 ----\n"
    "	# 旧行为：每个等级各弹一次、每次重抽三张 → 连升 N 级要点 N 次（用户反馈次数太多）。\n"
    "	# 本段钉两件事：① 只弹一次（仍是三选一）  ② 收益真的按级数兑现。\n"
    "	# ⚠️ 第 3 条「第二组卡有焦点」的断言已随本次行为变更删除 —— 不再有第二组卡。\n"
    "	var need_two := Config.xp_need(GameState.level) + Config.xp_need(GameState.level + 1)\n"
    "	GameState.gain_xp(need_two + 1)\n"
    "	await get_tree().process_frame\n"
    "	if GameState.phase != GameState.Phase.LEVEL_UP or GameState.level_queue != 2 or ui.card_count() != 3:\n"
    "		_fail(\"单次跨两级未生成首组卡（phase=%d queue=%d cards=%d）\" %\n"
    "			[GameState.phase, GameState.level_queue, ui.card_count()])\n"
    "		return\n"
    "	if ui.merged_count() != 2:\n"
    "		_fail(\"连升两级未合并成一次选择（merged=%d）\" % ui.merged_count())\n"
    "		return\n"
    "	var pick_rarity := \"common\"\n"
    "	var pick_id := \"\"\n"
    "	if typeof(ui._choices[0]) == TYPE_DICTIONARY:\n"
    "		pick_rarity = String(ui._choices[0].get(\"rarity\", \"common\"))\n"
    "		pick_id = String(ui._choices[0].get(\"id\", \"\"))\n"
    "	# 期望次数从**被测数据**算：金/红唯一件的第二次会被硬闸门拒绝 → 只 +1；\n"
    "	# 其余强化吃满 merged 次。不写死 2，否则一抽到神话卡就假红。\n"
    "	var want_times := 1 if Config.is_unique_rarity(pick_rarity) else 2\n"
    "	var own_before := int(player.upgrades_owned.get(pick_id, 0))\n"
    "	ui._choose(0)\n"
    "	await get_tree().process_frame\n"
    "	if GameState.phase != GameState.Phase.PLAYING or GameState.level_queue != 0:\n"
    "		_fail(\"连升完成后未恢复 PLAYING（phase=%d queue=%d）\" %\n"
    "			[GameState.phase, GameState.level_queue])\n"
    "		return\n"
    "	if pick_id != \"\":\n"
    "		var got := int(player.upgrades_owned.get(pick_id, 0)) - own_before\n"
    "		print(\"SMOKE: merge pick=%s rarity=%s applied=%d want=%d\" %\n"
    "			[pick_id, pick_rarity, got, want_times])\n"
    "		if got != want_times:\n"
    "			_fail(\"连升收益未按级数兑现（%s 期望 +%d，实际 +%d）\" % [pick_id, want_times, got])\n"
    "			return\n",
)]

ok = True
for tag, path, edits in [("config", CFG, cfg_edits), ("level_up", LU, lu_edits), ("smoke", SMOKE, smoke_edits)]:
    if not apply_file(path, edits, tag):
        ok = False
print("DONE" if ok else "FAILED")
sys.exit(0 if ok else 1)
