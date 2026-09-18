# -*- coding: utf-8 -*-
"""第 11 轮 · 用户需求 6：buff 显示层。

用户原话：
  「技能/地图区域 buff 应该在武器上方显示、暂停可点看、局内可悬浮看」

三处一起做，且**共用同一个数据源** `player.active_buffs()`（另记一份「显示用状态」
迟早与 stats 的实值分叉，就是第 8 轮那个「看到的 ≠ 打到的」同款问题）：
  ① HUD：武器槽正上方一条临时增益条，芯片可悬浮看详情
  ② 暂停面板：右栏新增「临时增益」区，点名出详情（与 HUD 同源）
  ③ 文案：`EntryText.buff_detail()` 单一格式化入口，两处共用

顺带**修掉上一批引入的真 bug**：暂停面板「武器区」当初插在了 `_pause_items` 的
清空循环**之前** —— 加完立刻被同函数下面几行删掉，面板上一行武器都没有。
「分区标题存在」类断言抓不到它（标题也被删了，但当时根本没有这条断言）。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path

P1 = game_path("scripts", "characters", "player.gd")
TXT = game_path("scripts", "ui", "entry_text.gd")
HUD = game_path("scripts", "ui", "hud.gd")
MAIN = game_path("scripts", "main.gd")
SMK = game_path("tests", "smoke_test.gd")

# ============================================================
# player.gd —— 数据源
# ============================================================
P1_EDITS = [
    ('''\t\tout[String(sid2)] = e2
\treturn out

## 应用升级效果（数据驱动：effects 键 = stats 键，创意工坊自定义升级直接生效）''',
     '''\t\tout[String(sid2)] = e2
\treturn out

## 当前生效的**临时增益**（第 11 轮 · 用户需求 6）。
## 用户原话：「技能/地图区域 buff 应在武器上方显示、暂停可点看、局内可悬浮看」。
##
## 返回 `[{ "ico", "name", "effects", "note", "remain", "color" }]`：
##   effects —— 直接取自**真正写进 stats 的那份增量**（不是另记一份显示状态）
##   remain  —— 剩余秒数；`< 0` = 无倒计时（站进区域 / 按波累积类）
##
## ⚠️ 数据源必须是运行时真值字段。另记一份「展示用状态」迟早与 stats 的实值分叉 ——
##    那就是第 8 轮「看到的 ≠ 打到的」同款问题。本函数**仅供展示，不参与任何结算**。
func active_buffs() -> Array:
\tvar out: Array = []
\t# ① 主动技能临时增益：`_skill_buff()` 把 effects 写进 stats，`_skill_buff_t` 是剩余秒
\tif _skill_buff_t > 0.0 and not _skill_buff_effects.is_empty():
\t\tout.append({
\t\t\t"ico": String(skill.get("ico", "✨")),
\t\t\t"name": String(skill.get("name", "技能增益")),
\t\t\t"effects": _skill_buff_effects.duplicate(),
\t\t\t"note": "主动技能持续期间生效，结束即撤销",
\t\t\t"remain": _skill_buff_t,
\t\t\t"color": Color("7ee0c0"),
\t\t})
\t# ② 地形属性区域（第 9 轮）：站进区块才有，**离区即撤**（所以没有倒计时）
\tif _zone_assim_element != "" and not is_zero_approx(_zone_assim_applied):
\t\tvar en := String(Config.ELEMENT_NAME.get(_zone_assim_element, _zone_assim_element))
\t\tout.append({
\t\t\t"ico": "🗺",
\t\t\t"name": "%s地脉" % en,
\t\t\t"effects": { "assim_" + _zone_assim_element: _zone_assim_applied },
\t\t\t"note": "站在%s区块内才有，离开区块立即失效" % en,
\t\t\t"remain": -1.0,
\t\t\t"color": Color(String(Config.ELEMENT_COLOR.get(_zone_assim_element, "#9aa3b2"))),
\t\t})
\t# ③ 战意（momentum 特性）：按本波击杀累积、**波末清零** → 同样无倒计时
\tif float(stats.get("momentum_dmg_bonus", 0.0)) > 0.0:
\t\tout.append({
\t\t\t"ico": String(char_trait.get("ico", "⚔")),
\t\t\t"name": String(char_trait.get("name", "战意")),
\t\t\t"effects": { "dmg_mult": float(stats.get("momentum_dmg_bonus", 0.0)) },
\t\t\t"note": "按本波击杀累积，每波结束清零",
\t\t\t"remain": -1.0,
\t\t\t"color": Color("ff9d3b"),
\t\t})
\treturn out

## 应用升级效果（数据驱动：effects 键 = stats 键，创意工坊自定义升级直接生效）'''),
]

# ============================================================
# entry_text.gd —— 单一文案入口（HUD 悬浮 / 暂停点击共用）
# ============================================================
TXT_EDITS = [
    ('''## 效果行拼成一行（商店卡 / 悬浮气泡用；图鉴用 `effect_lines` 逐行显示）''',
     '''## 临时增益（技能 / 地脉区域 / 战意）→ 详情卡。
## HUD 的悬浮与暂停页的点击**共用这一个格式化**，两处文案不可能说不一致的话。
## ⚠️ 正文**必须非空**：`HintBubble.attach_hover()` 对空 body 是**静默不挂**的
##    （那是它的既定语义），正文写漏了不会报错，只是悬浮没反应 —— 冒烟钉死了这一点。
static func buff_detail(b: Dictionary) -> Dictionary:
	var lines: Array = []
	var remain := float(b.get("remain", -1.0))
	if remain >= 0.0:
		lines.append("剩余 %.1f 秒" % remain)
	else:
		lines.append("持续时间：无倒计时（条件成立期间常驻）")
	var note := String(b.get("note", ""))
	if note != "":
		lines.append(note)
	var eff: Dictionary = b.get("effects", {})
	var es := effect_summary(eff)
	lines.append("当前加成：" + es if es != "" else "当前加成：无额外属性（见上方说明）")
	return { "title": String(b.get("name", "临时增益")), "body": "\\n".join(lines) }


## 效果行拼成一行（商店卡 / 悬浮气泡用；图鉴用 `effect_lines` 逐行显示）'''),
]

# ============================================================
# hud.gd —— 武器槽正上方的临时增益条
# ============================================================
HUD_VARS_OLD = '''var _bonus_label: Label = null   # 强化加成行（图例末尾又追加了反应节，不再能用“最后一个子节点”定位）'''
HUD_VARS_NEW = '''var _bonus_label: Label = null   # 强化加成行（图例末尾又追加了反应节，不再能用“最后一个子节点”定位）
# ---- 临时增益条（第 11 轮 · 用户需求 6）----
# 用户原话：「技能/地图区域 buff 应该在武器上方显示、暂停可点看、局内可悬浮看」。
var bubble_host: Node = null     # 由 main 注入 `$UI`；气泡挂 CanvasLayer 才能压在整个 UI 之上
var _buff_row: HBoxContainer = null
var _buffs_key := ""             # 内容签名：不变则不动节点（避免每帧建控件）'''

HUD_READY_OLD = '''\t_top_right.add_child(_score_text)
\t_build_status_legend()'''
HUD_READY_NEW = '''\t_top_right.add_child(_score_text)
\t# 临时增益条：**武器槽正上方**。位置与尺寸在 `_layout_buff_row()` 里显式给 ——
\t# 它不是任何 Container 的子节点，光靠锚点不会自己量出「刚好包住芯片」的宽高。
\t_buff_row = HBoxContainer.new()
\t_buff_row.add_theme_constant_override("separation", 6)
\t_buff_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
\t_buff_row.visible = false
\tadd_child(_buff_row)
\t_build_status_legend()'''

HUD_PROC_OLD = '''\t# 商店/暂停/升级/结算期间战斗数值冻结，跳过整段刷新
\tif GameState.phase != GameState.Phase.PLAYING and GameState.phase != GameState.Phase.INTRO:
\t\treturn'''
HUD_PROC_NEW = '''\t# 商店/暂停/升级/结算期间战斗数值冻结，跳过整段刷新
\tif GameState.phase != GameState.Phase.PLAYING and GameState.phase != GameState.Phase.INTRO:
\t\t# 临时增益条也要收起来：它描述的是**本场战斗**的实时状态，
\t\t# 停在商店里还挂着「剩余 3.2s」是错的（暂停页有独立的增益区可看）
\t\tif _buff_row != null:
\t\t\t_buff_row.visible = false
\t\treturn'''

HUD_PROC_TAIL_OLD = '''\tvar key := str(groups)
\tif key != _weapons_key:
\t\t_weapons_key = key
\t\t_rebuild_weapons(groups)'''
HUD_PROC_TAIL_NEW = '''\tvar key := str(groups)
\tif key != _weapons_key:
\t\t_weapons_key = key
\t\t_rebuild_weapons(groups)
\t_refresh_buff_row()

# ------------------------------------------------------------
# 临时增益条（第 11 轮 · 用户需求 6）
# ------------------------------------------------------------

## 每帧按 `player.active_buffs()` 的签名决定重不重建；重建后重排一次位置。
func _refresh_buff_row() -> void:
\tif _buff_row == null:
\t\treturn
\tvar buffs: Array = player.active_buffs()
\tvar key := ""
\tfor b in buffs:
\t\tkey += "%s|%.1f|" % [String((b as Dictionary).get("name", "")),
\t\t\tfloat((b as Dictionary).get("remain", -1.0))]
\tif key != _buffs_key:
\t\t_buffs_key = key
\t\tfor c in _buff_row.get_children():
\t\t\t_buff_row.remove_child(c)
\t\t\tc.queue_free()
\t\tfor b in buffs:
\t\t\t_buff_row.add_child(_make_buff_chip(b))
\t_buff_row.visible = not buffs.is_empty()
\tif _buff_row.visible:
\t\t_layout_buff_row()

## 尺寸与位置都**显式**算：`_buff_row` 的直接父节点是 HUD 根 Control（不是一个 Container），
## 所以没人替它 `size = get_combined_minimum_size()`（HUD 根是 Control，不是 Container）。
## 不显式设的话 rect 恒为 0，芯片画不出来且**不报任何错**。
func _layout_buff_row() -> void:
\t_buff_row.size = _buff_row.get_combined_minimum_size()
\t_buff_row.position = Vector2(
\t\t_weapons_box.position.x + (_weapons_box.size.x - _buff_row.size.x) * 0.5,
\t\t_weapons_box.position.y - _buff_row.size.y - 4.0)

## 单个增益芯片：`[图标 名称] [剩余秒]`。
## 悬浮出详情 —— 与暂停页点出来的是同一份 `EntryText.buff_detail()`。
func _make_buff_chip(b: Dictionary) -> Control:
\tvar accent := Color(b.get("color", Color("7ee0c0")))
\tvar panel := PanelContainer.new()
\tvar style := StyleBoxFlat.new()
\tstyle.bg_color = Color(0.094, 0.106, 0.129, 0.85)
\tstyle.border_color = accent
\tstyle.set_border_width_all(1)
\tstyle.set_corner_radius_all(7)
\tstyle.content_margin_left = 7.0
\tstyle.content_margin_right = 7.0
\tstyle.content_margin_top = 2.0
\tstyle.content_margin_bottom = 2.0
\tpanel.add_theme_stylebox_override("panel", style)
\tpanel.mouse_filter = Control.MOUSE_FILTER_IGNORE
\tvar box := HBoxContainer.new()
\tbox.add_theme_constant_override("separation", 4)
\tbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
\tpanel.add_child(box)
\tvar lbl := Label.new()
\tlbl.text = "%s %s" % [String(b.get("ico", "✨")), String(b.get("name", "增益"))]
\tlbl.add_theme_font_size_override("font_size", 11)
\tlbl.add_theme_color_override("font_color", accent)
\tlbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
\tbox.add_child(lbl)
\tvar remain := float(b.get("remain", -1.0))
\tif remain >= 0.0:
\t\tvar t := Label.new()
\t\tt.text = "%.1fs" % remain
\t\tt.add_theme_font_size_override("font_size", 11)
\t\tt.add_theme_color_override("font_color", Color("f2e7c7"))
\t\tt.mouse_filter = Control.MOUSE_FILTER_IGNORE
\t\tbox.add_child(t)
\t# 悬浮详情（`attach_hover` 会把 panel 置为 MOUSE_FILTER_STOP 才收得到 hover）
\tif bubble_host != null:
\t\tHintBubble.attach_hover(panel, String(b.get("name", "增益")),
\t\t\tString(EntryText.buff_detail(b).get("body", "")), bubble_host)
\treturn panel'''

HUD_EDITS = [
    (HUD_VARS_OLD, HUD_VARS_NEW),
    (HUD_READY_OLD, HUD_READY_NEW),
    (HUD_PROC_OLD, HUD_PROC_NEW),
    (HUD_PROC_TAIL_OLD, HUD_PROC_TAIL_NEW),
]

# ============================================================
# main.gd —— 注入 bubble_host + 修武器区位置 + 新增临时增益区
# ============================================================
MAIN_EDITS = [
    ('''\thud.player = player
\thud.wave_manager = wave_manager''',
     '''\thud.player = player
\thud.wave_manager = wave_manager
\t# 悬浮气泡的宿主：挂 CanvasLayer（`$UI`）才能压在整个界面之上；
\t# 挂到 HUD 上会被商店 / 暂停面板盖住（HUD 的 z 比它们低）
\thud.bubble_host = $UI'''),
    # ---- ① 把清空循环提到右栏最前面 ----
    ('''\t_pause_left.add_child(trait_l)
\t# 右：**武器区**（第 11 轮新增）''',
     '''\t_pause_left.add_child(trait_l)
\t# 右栏重建起点 —— ⚠️ 本句必须在**任何** `_pause_items.add_child()` 之前。
\t# 第 11 轮踩到过：武器区第一版写在这句上面，加完就被它清掉 ——
\t# 面板上一行武器都没有，而且**不报任何错**（「分区标题存在」类断言也照样判绿，
\t# 因为标题一起被删了）。修法是把清空提前，并补一条断言**具体条目**的冒烟用例。
\tfor c in _pause_items.get_children():
\t\t_pause_items.remove_child(c)
\t\tc.queue_free()
\t# 右：**临时增益区**（第 11 轮新增 · 用户需求 6）
\t# 用户原话：「技能/地图区域 buff 应在武器上方显示、暂停可点看、局内可悬浮看」。
\t# 这里只列**当前真的生效**的（数据源与 HUD 增益条同为 `player.active_buffs()`），
\t# 点名字出详情 —— 两个入口同源，所以永远不会互相说不一致的话。
\tvar bft := Label.new()
\tbft.text = "临时增益"
\tbft.add_theme_font_size_override("font_size", 13)
\tbft.add_theme_color_override("font_color", Color("e8b84b"))
\tbft.mouse_filter = Control.MOUSE_FILTER_IGNORE
\t_pause_items.add_child(bft)
\tvar buffs_now: Array = player.active_buffs()
\tif buffs_now.is_empty():
\t\tvar bfe := Label.new()
\t\tbfe.text = "暂无（技能 / 地脉区域 / 战意生效时自动出现）"
\t\tbfe.add_theme_font_size_override("font_size", 12)
\t\tbfe.add_theme_color_override("font_color", Color("5a6270"))
\t\tbfe.mouse_filter = Control.MOUSE_FILTER_IGNORE
\t\t_pause_items.add_child(bfe)
\telse:
\t\tfor b in buffs_now:
\t\t\tvar bd: Dictionary = b
\t\t\tvar brow := HBoxContainer.new()
\t\t\tbrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
\t\t\tvar bl := Label.new()
\t\t\tbl.text = "%s %s" % [String(bd.get("ico", "✨")), String(bd.get("name", "增益"))]
\t\t\tbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
\t\t\tbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
\t\t\tbl.add_theme_font_size_override("font_size", 13)
\t\t\tbl.add_theme_color_override("font_color", Color(bd.get("color", Color("7ee0c0"))))
\t\t\tbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
\t\t\tbrow.add_child(bl)
\t\t\tHintBubble.attach_click(bl, func() -> Dictionary:
\t\t\t\treturn EntryText.buff_detail(bd), $UI)
\t\t\tvar bv := Label.new()
\t\t\tvar b_remain := float(bd.get("remain", -1.0))
\t\t\tbv.text = ("%.1fs" % b_remain) if b_remain >= 0.0 else "持续"
\t\t\tbv.add_theme_font_size_override("font_size", 13)
\t\t\tbv.add_theme_color_override("font_color", Color("f2e7c7"))
\t\t\tbv.mouse_filter = Control.MOUSE_FILTER_IGNORE
\t\t\tbrow.add_child(bv)
\t\t\t_pause_items.add_child(brow)
\tvar bfsep := ColorRect.new()
\tbfsep.color = Color("2c3340")
\tbfsep.custom_minimum_size = Vector2(0.0, 1.0)
\tbfsep.mouse_filter = Control.MOUSE_FILTER_IGNORE
\t_pause_items.add_child(bfsep)
\t# 右：**武器区**（第 11 轮新增）'''),
    # ---- ② 删掉原来那句（已提前） ----
    ('''\t_pause_items.add_child(wsep)
\t# 右：已购道具（相同叠加显示数量）+ 法宝区
\tfor c in _pause_items.get_children():
\t\t_pause_items.remove_child(c)
\t\tc.queue_free()
\tif player.items_owned.is_empty():''',
     '''\t_pause_items.add_child(wsep)
\t# 右：已购道具（相同叠加显示数量）+ 法宝区
\t# ⚠️ 清空**不能**再在这里做一次：它已经提到本栏开头（见那里的注释）。
\t#    放在这里会把上面刚建好的临时增益区 + 武器区一起删掉。
\tif player.items_owned.is_empty():'''),
]

# ============================================================
# smoke_test.gd —— 断言「真的显示了具体条目」，而不只是「分区存在」
# ============================================================
SMK_EDITS = [
    # ① 暂停面板：武器区 + 临时增益区必须**真的有内容**
    ('''\tif art_name == "" or art_stack == "":
\t\t_fail("暂停面板法宝区未显示持有法宝与叠层（name='%s' stack='%s'）"
\t\t\t% [art_name, art_stack])
\t\treturn
\t_main.toggle_pause()''',
     '''\tif art_name == "" or art_stack == "":
\t\t_fail("暂停面板法宝区未显示持有法宝与叠层（name='%s' stack='%s'）"
\t\t\t% [art_name, art_stack])
\t\treturn
\t# ---- 武器区 / 临时增益区（第 11 轮新增 · 用户需求 5/6）----
\t# ⚠️ 必须断言**具体条目**而不能只断言「分区标题在」：武器区第一版插在了
\t#    `_pause_items` 的清空循环之前 —— 加完立刻被同函数下面几行删掉，
\t#    面板上一行武器都没有；而「标题存在」类断言会跟着标题一起被判绿（都没有）。
\t#    用户的诉求本来就是「点武器/道具能看到东西」，所以这里直接找**武器名**。
\tif _find_label_text(pi, "临时增益") == "":
\t\t_fail("暂停面板缺少临时增益分区")
\t\treturn
\tif _find_label_text(pi, "武器") == "":
\t\t_fail("暂停面板缺少武器分区")
\t\treturn
\tif p2.weapons.is_empty():
\t\t_fail("暂停面板武器区用例前置不成立：玩家此刻一件武器都没有")
\t\treturn
\tvar first_wid := String(p2.weapons[0].type)
\tvar first_wcfg: Dictionary = Registry.weapons.get(first_wid, {})
\tif first_wcfg.is_empty():
\t\t_fail("暂停面板武器区用例前置不成立：Registry 缺武器 %s" % first_wid)
\t\treturn
\tif _find_label_text(pi, String(first_wcfg.get("name", first_wid))) == "":
\t\t_fail("暂停面板武器区没列出实际持有的武器（%s）—— 多半是被同函数的清空循环删掉了"
\t\t\t% first_wid)
\t\treturn
\t_main.toggle_pause()'''),
    # ② 临时增益：数据源 + HUD 条 + 文案，三处一起断言
    ('''\t_check_reach_safety()
\t_check_spread_channel()
\t_check_balance_log()''',
     '''\t_check_reach_safety()
\t_check_spread_channel()
\t_check_buff_display()
\t_check_balance_log()'''),
    ('''## 单把武器在「白板 + 单体 + 非暴击」下的**稳态 DoT DPS**。''',
     '''## 第 11 轮 · 用户需求 6：临时增益显示层。
## 断言「数据源 → HUD 增益条 → 详情文案」三段都真的接上：
##   ① `player.active_buffs()` 在技能增益生效时给出条目（其余情形归零 → 反面对照）
##   ② HUD 的增益条子节点数 = 条目数（挂上了才叫「在武器上方显示」）
##   ③ `EntryText.buff_detail()` 正文非空 —— 空正文会让 `attach_hover` **静默不挂**，
##      悬浮没反应却不报错，正是最难发现的那一类
func _check_buff_display() -> void:
\tvar p: Node2D = _main.get_node("Player")
\tvar h: Control = _main.get_node("UI/HUD")
\t# 反面对照：先把技能增益清空，`active_buffs()` 里不许再出现「剩余秒」那一条
\tvar keep_t := float(p._skill_buff_t)
\tvar keep_eff: Dictionary = p._skill_buff_effects.duplicate()
\tp._skill_buff_t = 0.0
\tp._skill_buff_effects = {}
\tfor b in p.active_buffs():
\t\tif float((b as Dictionary).get("remain", -1.0)) >= 0.0:
\t\t\tp._skill_buff_t = keep_t
\t\t\tp._skill_buff_effects = keep_eff
\t\t\t_fail("第11轮：技能增益已清空，active_buffs 仍报出带倒计时的条目")
\t\t\treturn
\t# 正向：注入一条技能增益（直接写字段，不走 use_skill —— 那会真的进冷却）
\tp._skill_buff_effects = { "dmg_mult": 0.25 }
\tp._skill_buff_t = 4.0
\tvar buffs: Array = p.active_buffs()
\tif buffs.is_empty():
\t\tp._skill_buff_t = keep_t
\t\tp._skill_buff_effects = keep_eff
\t\t_fail("第11轮：技能增益生效时 active_buffs 为空")
\t\treturn
\tvar timed: Dictionary = {}
\tfor b in buffs:
\t\tif float((b as Dictionary).get("remain", -1.0)) >= 0.0:
\t\t\ttimed = b
\t\t\tbreak
\tif timed.is_empty() or not is_equal_approx(float(timed.get("remain", 0.0)), 4.0):
\t\tp._skill_buff_t = keep_t
\t\tp._skill_buff_effects = keep_eff
\t\t_fail("第11轮：技能增益没带出剩余秒（期望 4.0，得到 %s）" % str(timed))
\t\treturn
\t# ② HUD 增益条：显式刷一次（`_process` 在非 PLAYING 阶段会跳过整段刷新）
\th._refresh_buff_row()
\tif int(h._buff_row.get_child_count()) != buffs.size():
\t\tp._skill_buff_t = keep_t
\t\tp._skill_buff_effects = keep_eff
\t\t_fail("第11轮：HUD 增益条芯片数 %d ≠ active_buffs 条目数 %d"
\t\t\t% [int(h._buff_row.get_child_count()), buffs.size()])
\t\treturn
\tif not h._buff_row.visible:
\t\tp._skill_buff_t = keep_t
\t\tp._skill_buff_effects = keep_eff
\t\t_fail("第11轮：有增益时 HUD 增益条仍不可见")
\t\treturn
\t# 芯片尺寸必须真的量出来 —— `_buff_row` 的父节点是 Control 不是 Container，
\t# 没人替它设 size；不显式设的话宽高恒 0，芯片画不出来且不报错。
\tif h._buff_row.size.x <= 0.0 or h._buff_row.size.y <= 0.0:
\t\tp._skill_buff_t = keep_t
\t\tp._skill_buff_effects = keep_eff
\t\t_fail("第11轮：HUD 增益条尺寸为零（芯片画不出来）")
\t\treturn
\t# ③ 详情文案：正文必须非空且说明实际加成（空正文 = 悬浮静默不挂）
\tvar det := EntryText.buff_detail(timed)
\tvar body := String(det.get("body", ""))
\tif body.strip_edges() == "":
\t\tp._skill_buff_t = keep_t
\t\tp._skill_buff_effects = keep_eff
\t\t_fail("第11轮：buff_detail 正文为空 → 悬浮会静默不挂")
\t\treturn
\tif not body.contains("剩余") or not body.contains("25%"):
\t\tp._skill_buff_t = keep_t
\t\tp._skill_buff_effects = keep_eff
\t\t_fail("第11轮：buff_detail 正文没写清剩余时间与实际加成：%s" % body.replace("\\n", " / "))
\t\treturn
\t# 收尾：原样还回去
\tp._skill_buff_t = keep_t
\tp._skill_buff_effects = keep_eff
\tprint("SMOKE: 第11轮 临时增益显示（技能/地脉/战意数据源 · HUD 武器上方增益条 · 详情文案）OK")


## 单把武器在「白板 + 单体 + 非暴击」下的**稳态 DoT DPS**。'''),
]

ok = apply_file(P1, P1_EDITS, "player-r11-buff")
ok = apply_file(TXT, TXT_EDITS, "entrytext-r11-buff") and ok
ok = apply_file(HUD, HUD_EDITS, "hud-r11-buff") and ok
ok = apply_file(MAIN, MAIN_EDITS, "main-r11-buff") and ok
ok = apply_file(SMK, SMK_EDITS, "smoke-r11-buff") and ok
if not ok:
    sys.exit(1)
