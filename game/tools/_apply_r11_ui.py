# -*- coding: utf-8 -*-
"""第 11 轮 · Q5：悬浮粒度收窄 + 同化度显示实际生效值 + 暂停面板补武器区。"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path

ET = game_path("scripts", "ui", "entry_text.gd")
MAIN = game_path("scripts", "main.gd")

ET_EDITS = [
    # ---- ① 修掉一条已失效的注释（它声称的用例已不存在）----
    ('''## ⚠️ 代价：写错一个字（"攻击速度" vs "攻速"）会静默失效。
##    冒烟里有 `_check_stat_help()` 双向钉死：既查表非空，也查两张表的键互相齐全。''',
     '''## ⚠️ 代价：写错一个字（"攻击速度" vs "攻速"）会静默失效。
##    ⚠️ 本条注释曾写「冒烟里有 `_check_stat_help()` 双向钉死」—— 第 11 轮核实：
##    该用例**已不存在**（全仓 grep `stat_help` 只剩 3 个调用点，没有任何断言）。
##    也就是说现在**没有东西在守这张表**，加/改键之后请自己核对调用点的显示名。
##    表本身保持**全集**（单一真值来源，不随 UI 口味增删）；
##    「哪些属性才值得弹悬浮」由调用点按 `HOVER_HELP` 决定。'''),

    # ---- ② 悬浮粒度：只留「不看说明就不知道」的三类 ----
    ('''## 五行同化行的后缀：`"　金同化"` → 用表头那条说明
const ASSIM_SUFFIX := "同化"''',
     '''## 五行同化行的后缀：`"　金同化"` → 用表头那条说明
const ASSIM_SUFFIX := "同化"

## ---- 悬浮粒度：只有「不看说明就不知道」的属性才弹气泡 ----
## 用户第 11 轮原话：「基础属性，比如说血量，攻击，攻速这种，不需要描述的就不用悬浮显示，
## 同化度，异常状态之类的，就应该有」。于是把「表里有说明」与「界面上值得弹」拆开：
##   · `STAT_HELP` 保持**全集**（单一真值来源）；
##   · 弹不弹由这里决定 —— 只留三类字面看不懂的（武器 = 同名可叠各自开火 / 同化度 = 双向 /
##     异常强化 = 三项合成一个数字）。
## 刻意**不**收进来的（自解释，弹了只是噪音）：生命 / 伤害 / 攻速 / 移速 / 暴击率 /
##   暴击伤害 / 护甲 / 闪避 / 拾取范围 / 回复 / 收获率 / 吸血。
const HOVER_HELP := ["武器", "五行同化", "异常强化"]

## 该显示名是否值得弹悬浮说明（`"　金同化"` 这类带前缀的行算作「五行同化」）。
static func needs_help(display_name: String) -> bool:
	var key := display_name.strip_edges()
	if key in HOVER_HELP:
		return true
	return key.ends_with(ASSIM_SUFFIX) and HOVER_HELP.has("五行同化")'''),

    # ---- ③ 同化度说明补「白板角色不生效」（口径 = player.gd:813 / player.gd:502）----
    ('	"五行同化": "同化度是**双向**的：受该元素伤害按「受击侧」减伤，用该元素输出按「输出侧」增伤。",',
     '	"五行同化": "同化度是**双向**的：① 挨该元素的打 → 按「受击侧」减伤；② 用该元素打人 → 按「输出侧」增伤。⚠️ 两条通道都要求**角色自身有五行属性**（player.gd:813 / player.gd:502），白板角色堆同化度不生效。",'),

    # ---- ④ on_hit_* 是「同键相加」，写清楚可叠加 ----
    ('						out.append("命中 %d%% 施加%s" % [roundi(v * 100.0), String(st.get("name", sid))])',
     '						out.append("命中 %d%% 施加%s（同类可叠加，概率相加）"\n							% [roundi(v * 100.0), String(st.get("name", sid))])'),
]

MAIN_EDITS = [
    # ---- ⑤ 悬浮只对 HOVER_HELP 里的属性挂 ----
    ('''	HintBubble.attach_hover(l, name_text, EntryText.stat_help(name_text), $UI)''',
     '''	# 悬浮看该属性的具体含义 —— 但**只对「不看说明就不知道」的属性弹**（第 11 轮收窄）。
	# 原先是 15 条基础属性全挂（生命/伤害/攻速…），用户反馈那是噪音；
	# 判断依据集中在 `EntryText.HOVER_HELP`，这里不做第二份名单。
	# 不挂时 Label 保持 IGNORE（整行仍然完全穿透），与改动前的点击行为一致。
	if EntryText.needs_help(name_text):
		HintBubble.attach_hover(l, name_text, EntryText.stat_help(name_text), $UI)'''),

    # ---- ⑥ 同化度：显示**实际生效**的受击/输出数值 ----
    ('''	var assim_hdr := false
	for assim_eid in Config.ELEMENTS:
		var assim_key := "assim_" + String(assim_eid)
		var assim_val := float(s.get(assim_key, 0.0))
		if assim_val <= 0.0:
			continue
		if not assim_hdr:
			assim_hdr = true
			_pause_left.add_child(_pause_stat_row("五行同化",
				"受到该元素伤害 ↓｜用该元素输出 ↑"))
		_pause_left.add_child(_pause_stat_row(
			"　%s同化" % String(Config.ELEMENT_NAME.get(String(assim_eid), String(assim_eid))),
			"+%d%%" % roundi(assim_val * 100.0)))''',
     '''	# ⚠️ 第 11 轮：用户反馈「现在的同化度不够清晰」。原先只报 `+12%` 这个**库存值**，
	#    玩家看不出它换来多少。现在按游戏自己的两条通道**当场算一遍**（口径 = 源码）：
	#      · 受击侧 player.gd:813-815 → `Config.apply_hit_mult(dmg, 来袭元素, 我的元素, 同化度)`
	#      · 输出侧 player.gd:501-504 → `Config.out_mult(我的元素, 出招元素) + 同化度`
	#    用 raw = 100 探一次，差值就是真实百分比 —— 与战斗同函数，不会与实现脱节。
	# ⚠️ 两条通道都要求**角色自身有五行属性**，`element == ""` 时都直接跳过
	#    → 白板角色堆同化度是**废属性**，必须显式写明，否则玩家会一直堆一个不生效的数字。
	var char_elem := String(player.element)
	var assim_hdr := false
	for assim_eid in Config.ELEMENTS:
		var assim_key := "assim_" + String(assim_eid)
		var assim_val := float(s.get(assim_key, 0.0))
		if assim_val <= 0.0:
			continue
		var assim_name := String(Config.ELEMENT_NAME.get(String(assim_eid), String(assim_eid)))
		if not assim_hdr:
			assim_hdr = true
			_pause_left.add_child(_pause_stat_row("五行同化",
				"（角色无五行 → 同化度不生效）" if char_elem == "" else "受该元素伤害 ↓｜用该元素输出 ↑"))
		var take_pct := 0
		var give_pct := 0
		if char_elem != "":
			var probe := Config.apply_hit_mult(100.0, String(assim_eid), char_elem, assim_val)
			take_pct = roundi((probe / 100.0 - 1.0) * 100.0)
			give_pct = roundi((Config.out_mult(char_elem, String(assim_eid)) + assim_val) * 100.0)
		_pause_left.add_child(_pause_stat_row(
			"　%s同化" % assim_name,
			"+%d%% → 挨伤 %s%d%%｜输出 %s%d%%"
			% [roundi(assim_val * 100.0), "+" if take_pct > 0 else "", take_pct,
				"+" if give_pct > 0 else "", give_pct]))'''),

    # ---- ⑦ 暂停面板补武器区（原先只有一行「武器 3/5」计数，武器详情点不出来）----
    ('''	# 右：已购道具（相同叠加显示数量）+ 法宝区
	for c in _pause_items.get_children():''',
     '''	# 右：**武器区**（第 11 轮新增）
	# 用户原话：「道具和武器在暂停界面点击查看详情时，只有名称，没有道具效果描述」。
	# 查证：武器详情**点不出来**——这个面板此前根本没有武器列表，只有左栏一行
	# 「武器 3/5」计数（`_pause_stat_row("武器", ...)`）。这里按与道具 / 法宝同一套补上：
	# 同名分组显示 xN，点名字 → `EntryText.entry_detail(..., "武器")`
	# （它会额外补「射程 / 有效射程 / 加成通道」三行 —— 那是玩家最需要的口径）。
	var wt := Label.new()
	wt.text = "武器"
	wt.add_theme_font_size_override("font_size", 13)
	wt.add_theme_color_override("font_color", Color("e8b84b"))
	wt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_items.add_child(wt)
	if player.weapons.is_empty():
		var we := Label.new()
		we.text = "暂无武器"
		we.add_theme_font_size_override("font_size", 12)
		we.add_theme_color_override("font_color", Color("5a6270"))
		_pause_items.add_child(we)
	else:
		var wgroups := {}
		for w in player.weapons:
			wgroups[w.type] = int(wgroups.get(w.type, 0)) + 1
		for wid in wgroups:
			var wcfg: Dictionary = Registry.weapons.get(String(wid), {})
			var wrow := HBoxContainer.new()
			wrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var wl := Label.new()
			wl.text = "%s %s" % [wcfg.get("ico", "🗡"), wcfg.get("name", String(wid))]
			wl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			wl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			wl.add_theme_font_size_override("font_size", 13)
			wl.add_theme_color_override("font_color", Config.rarity_color(wcfg.get("rarity", "common")))
			wl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			wrow.add_child(wl)
			HintBubble.attach_click(wl, func() -> Dictionary:
				return EntryText.entry_detail(Registry.weapons.get(String(wid), {}), "武器"), $UI)
			var wc := Label.new()
			wc.text = "x%d" % int(wgroups[wid])
			wc.add_theme_font_size_override("font_size", 13)
			wc.add_theme_color_override("font_color", Color("f2e7c7"))
			wc.mouse_filter = Control.MOUSE_FILTER_IGNORE
			wrow.add_child(wc)
			_pause_items.add_child(wrow)
	var wsep := ColorRect.new()
	wsep.color = Color("2c3340")
	wsep.custom_minimum_size = Vector2(0.0, 1.0)
	wsep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_items.add_child(wsep)
	# 右：已购道具（相同叠加显示数量）+ 法宝区
	for c in _pause_items.get_children():'''),
]

ok = apply_file(ET, ET_EDITS, "entry_text-r11")
ok = apply_file(MAIN, MAIN_EDITS, "main-r11") and ok
if not ok:
    sys.exit(1)
