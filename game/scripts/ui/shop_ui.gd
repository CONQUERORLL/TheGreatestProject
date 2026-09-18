extends Control
## 商店 UI（波末清场后由 main 打开；节点全部代码构建，见 godot-game-ui 技能）
## 功能：6 格商品（武器/道具/升级属性，来自 Registry）+ 锁定 + 刷新 + 回血 + 下一波
##        购买不重掷 —— 已购格留在原位显示「已售出」，只有付刷新费才换新货
## 布局：左侧角色属性面板 ｜ 中间商品 ｜ 右侧已购道具（可按 50% 购入价出售）
## 卡面按稀有度着色：common 白 / rare 蓝 / epic 紫 / mythic 金 / legendary 红
## 输入：鼠标 + 手柄焦点导航（卡片行 ↓ 动作区，动作区 ↑ 第一张可购卡）

var player  # characters/player.gd 引用，由 main 注入
var wave_manager: Node   # systems/wave_manager.gd 引用，由 main 注入
var main: Node           # scripts/main.gd 引用（商店关闭后询问是否先弹江湖奇遇）
var goods: Array = []    # 商品 [{kind, wtype/id, ico, name, desc, rarity, base_price, sold, locked}]
var _affinity_cache: Array = []   # 本次商店的构筑亲和标签（开店时算一次，见 _affinity）
var _dim_cache: Dictionary = {}   # 第 13 轮：各维度已投入条目数（开店时算一次，见 _dim_counts）

var _reroll_cost := 0
var _wave := 0
var _save_dirty := false    # 有未落盘的商店操作
var _save_pending := false  # 合并写定时器已排队
var _assim_pity := 0        # 连续「整店没出同化度」的店数，刷到即归零（第 9 轮保底）
var _forced_assim := false  # 本店是否由同化度保底塞了一格（测试观测，同 forced_synergy）
var _temp_confirm = null     # 退出二次确认对话框（需求 3：临时槽有武器时退出需确认）

var _title: Label
var _mat: Label
var _weapon_bar: HBoxContainer   # 武器栏（HUD 同款聚合槽位，商店也要一眼看到当前武器）
var _goods_box: GridContainer   # 第 9 轮：一排放不下就平均换行（见 _goods_grid），不再是单行 HBox
var _left_box: VBoxContainer
var _items_box: VBoxContainer
var _reroll_btn: Button
var _heal_btn: Button
var _next_btn: Button

func _ready() -> void:
	_build()
	visible = false
	_reroll_btn.pressed.connect(reroll)
	_heal_btn.pressed.connect(heal)
	_next_btn.pressed.connect(_on_next_pressed)

# ---------------- 界面构建（代码节点） ----------------

func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.04, 0.05, 0.07, 0.82)   # 模态遮罩（拦截点击到世界）
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	# 小屏用安全区边距（避开刘海 / 打孔 / 手势条），桌面沿用 12
	var sm := UiMetrics.margin() if UiMetrics.prefers_full_page() else Vector2(12.0, 12.0)
	for m in ["margin_left", "margin_right"]:
		margin.add_theme_constant_override(m, int(maxf(sm.x, 12.0)))
	for m in ["margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, int(maxf(sm.y, 12.0)))
	add_child(margin)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 14)
	margin.add_child(hb)
	# 左侧：角色属性面板。小屏放不下「288 宽属性栏 + 最多 5 张 150 宽商品卡」——
	# 合计超过 1000 单位，而手机横屏只有约 900 宽，商品卡会被顶出屏幕右侧点不到。
	# 小屏隐藏属性栏（暂停页仍能查全部属性），宽度全让给商品区。
	var compact := UiMetrics.prefers_full_page()
	if not compact:
		hb.add_child(_make_side_panel(_make_left_column()))
	# 中间：标题 + 商品 + 动作
	var center := VBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_theme_constant_override("separation", 12)
	hb.add_child(center)
	_title = _mk_label(25, Color("f2e7c7"))
	center.add_child(_title)
	_mat = _mk_label(18, Color("e8b84b"))
	center.add_child(_mat)
	# 武器栏：HUD 同款聚合槽位（永久槽聚合同名 xN + 空槽占位；临时槽标注「临时」）。
	# 旧版只有左栏一行小字「持有：…」，且小屏模式整个左栏隐藏 —— 商店里看不到武器栏。
	_weapon_bar = HBoxContainer.new()
	_weapon_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	_weapon_bar.add_theme_constant_override("separation", 6)
	_weapon_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(_weapon_bar)
	# 商品区容器：GridContainer 而不是 HBoxContainer（第 9 轮）。
	# `columns == 商品数` 时行为与单行 HBox 完全一致；放不下时由 `_goods_grid()`
	# 改小 columns，就变成「平均换行」（6 格 → 3+3，而不是 5+1 留一张孤卡）。
	# 旧版单行 HBox 的问题是硬溢出：桌面 6 × 150 宽 + 左右侧栏本来就超出 1280，
	# 最后一张卡会被顶到屏幕外 —— 看得见、点不到，且不报错。
	_goods_box = GridContainer.new()
	_goods_box.columns = Config.SHOP_SLOTS
	# ⚠️ GridContainer **没有** `alignment`（那是 BoxContainer 的属性）——
	#    写错了不是静默失败而是运行期 `Invalid assignment of property`，
	#    并且会**中断整个 `_build()`**，导致后面所有控件（含 reroll/heal/next 三个按钮）
	#    全是 null，商店直接不可用。居中只能用 size_flags。
	_goods_box.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_goods_box.add_theme_constant_override("h_separation", 8)
	_goods_box.add_theme_constant_override("v_separation", 8)
	_goods_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(_goods_box)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 10)
	actions.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(actions)
	_reroll_btn = _mk_action("刷新", 128.0)
	_heal_btn = _mk_action("回血", 148.0)
	_next_btn = _mk_action("下一波 →", 148.0)
	_next_btn.add_theme_font_size_override("font_size", 17)
	for b: Button in [_reroll_btn, _heal_btn, _next_btn]:
		actions.add_child(b)
	# 右侧：已购道具（可出售）。小屏保留但收窄 —— 卖东西是这一栏唯一的入口，
	# 砍掉会让手机上无法出售道具；宽度从 288 压到约 180，把空间让给商品卡
	hb.add_child(_make_side_panel(_make_right_column(), UiMetrics.dp(180.0) if compact else 288.0))

func _make_side_panel(inner: Control, want_w := 288.0) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(want_w, 0.0)
	panel.add_theme_stylebox_override("panel", _side_style())
	panel.add_child(inner)
	return panel

func _side_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("181c24")
	sb.border_color = Color("2c3340")
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	return sb

## 左侧属性栏 = 「固定视图 + 滚动条」（第 9 轮 · 用户要求）。
## 属性行数会随道具 / 法宝 / 同化度增长，裸 VBox 超出面板高度只会被**裁掉** ——
## 看不到最后几行，且没有任何提示（不是报错，只是「信息悄悄少了」）。
func _make_left_column() -> Control:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_left_box = VBoxContainer.new()
	_left_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_left_box.add_theme_constant_override("separation", 4)
	scroll.add_child(_left_box)
	return scroll

func _make_right_column() -> VBoxContainer:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	var head := _mk_label(15, Color("e8b84b"))
	head.text = "已购道具"
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	vb.add_child(head)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)
	_items_box = VBoxContainer.new()
	_items_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_items_box.add_theme_constant_override("separation", 4)
	scroll.add_child(_items_box)
	return vb

func _mk_label(size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _mk_action(text: String, w: float) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(w, 40.0)
	return b

## 侧面板属性行：名称 + 数值（数值金色）
func _stat_row(name_text: String, value_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := Label.new()
	l.text = name_text
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color("9aa3b2"))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 悬浮看该属性的具体含义（第 8 轮）。`attach_hover` 会把这**一个 Label**
	# 置为 STOP，整行仍是 IGNORE —— 所以不会挡住右侧数值或下方按钮。
	HintBubble.attach_hover(l, name_text, EntryText.stat_help(name_text), self)
	row.add_child(l)
	var v := Label.new()
	v.text = value_text
	v.add_theme_font_size_override("font_size", 13)
	v.add_theme_color_override("font_color", Color("f2e7c7"))
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(v)
	return row

## 刷新左侧属性面板（含角色特性）
func _refresh_left() -> void:
	for c in _left_box.get_children():
		_left_box.remove_child(c)
		c.queue_free()
	var ch: Dictionary = Registry.get_character(GameState.character_id)
	var head := HBoxContainer.new()
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var av := CharacterAvatar.new()
	av.setup(GameState.character_id, 44.0)
	head.add_child(av)
	var nm := Label.new()
	nm.text = " %s" % ch.get("name", "?")
	nm.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	nm.add_theme_font_size_override("font_size", 17)
	nm.add_theme_color_override("font_color", Color("e8b84b"))
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(nm)
	_left_box.add_child(head)
	var s: Dictionary = player.stats
	_left_box.add_child(_stat_row("生命", "%d / %d" % [roundi(player.hp), roundi(s.max_hp)]))
	# 武器容量 = 永久槽 + 临时槽（需求 3：商店新增 2 个临时武器槽）
	var _wperm: int = player.weapons.size()
	var _wtemp: int = player.temp_weapons.size()
	_left_box.add_child(_stat_row("武器",
		"%d / %d（临时槽 %d/%d）"
		% [_wperm + _wtemp, MetaProgress.weapon_slots() + Config.TEMP_WEAPON_SLOTS,
		   _wtemp, Config.TEMP_WEAPON_SLOTS]))
	# 武器列表（需求 2：商店也能查看当前武器；临时槽武器标注）
	var _wl := ""
	for _w in player.weapons:
		var _wc: Dictionary = Registry.weapons.get(String(_w.get("type", "")), {})
		_wl += (", " if _wl != "" else "") + String(_wc.get("name", "?"))
	for _t in player.temp_weapons:
		var _tc: Dictionary = Registry.weapons.get(String(_t.get("type", "")), {})
		_wl += (", " if _wl != "" else "") + String(_tc.get("name", "?")) + "（临时）"
	if _wl != "":
		var _wlab := Label.new()
		_wlab.text = "持有：" + _wl
		_wlab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_wlab.add_theme_font_size_override("font_size", 11)
		_wlab.add_theme_color_override("font_color", Color("9aa3b2"))
		_wlab.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_left_box.add_child(_wlab)
	_left_box.add_child(_stat_row("伤害", "x%.2f" % float(s.dmg_mult)))
	_left_box.add_child(_stat_row("攻速", "x%.2f" % float(s.as_mult)))
	_left_box.add_child(_stat_row("移速", "%.0f" % float(s.base_speed * s.speed_mult)))
	_left_box.add_child(_stat_row("暴击率", "%d%%" % roundi(float(s.crit_ch) * 100.0)))
	_left_box.add_child(_stat_row("暴击伤害", "x%.2f" % float(s.crit_mult)))
	_left_box.add_child(_stat_row("护甲", "%d" % int(s.armor)))
	_left_box.add_child(_stat_row("闪避", "%d%%" % roundi(float(s.dodge) * 100.0)))
	_left_box.add_child(_stat_row("拾取范围", "%.0f" % float(s.pickup_range)))
	_left_box.add_child(_stat_row("回复", "%.1f / 秒" % float(s.regen)))
	_left_box.add_child(_stat_row("收获率", "+%d%%" % roundi(float(s.harvesting) * 100.0)))
	_left_box.add_child(_stat_row("吸血", "%.0f / 击杀" % float(s.lifesteal)))
	# ---- 五行同化度（§6.2 / S5）----
	# 与 main.gd `_refresh_pause_content` 里的那一节同源同步：同化度此前**界面完全不显示**
	# （ui/ 下 grep `assim` 零命中，2026-09-17 第 7 轮补）。商店是买「金髓 / 青木汁…」的地方，
	# 更需要当场看见自己现在各系多少 —— 否则买了不知道加了什么。
	# ⚠️ 只列 > 0 的元素，白板角色不开这一节。
	var assim_hdr := false
	for assim_eid in Config.ELEMENTS:
		var assim_key := "assim_" + String(assim_eid)
		var assim_val := float(s.get(assim_key, 0.0))
		if assim_val <= 0.0:
			continue
		if not assim_hdr:
			assim_hdr = true
			_left_box.add_child(_stat_row("五行同化",
				"受到该元素伤害 ↓｜用该元素输出 ↑"))
		_left_box.add_child(_stat_row(
			"　%s同化" % String(Config.ELEMENT_NAME.get(String(assim_eid), String(assim_eid))),
			"+%d%%" % roundi(assim_val * 100.0)))
	var status_hit := 0.0
	for sid in Config.STATUS:
		status_hit += float(s.get("on_hit_" + String(sid), 0.0))
	if float(s.status_dmg_mult) > 0.0 or float(s.status_dur_mult) > 0.0 or status_hit > 0.0:
		_left_box.add_child(_stat_row("异常强化", "伤害 +%d%%｜时长 +%d%%｜命中 +%d%%"
			% [roundi(float(s.status_dmg_mult) * 100.0), roundi(float(s.status_dur_mult) * 100.0),
			roundi(status_hit * 100.0)]))
	# 角色特性
	var sep := ColorRect.new()
	sep.color = Color("2c3340")
	sep.custom_minimum_size = Vector2(0.0, 1.0)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_left_box.add_child(sep)
	var trait_t := Label.new()
	trait_t.text = "角色特性"
	trait_t.add_theme_font_size_override("font_size", 13)
	trait_t.add_theme_color_override("font_color", Color("e8b84b"))
	trait_t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_left_box.add_child(trait_t)
	var trait_l := Label.new()
	trait_l.text = ch.get("desc", "无特性")
	trait_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	trait_l.add_theme_font_size_override("font_size", 12)
	trait_l.add_theme_color_override("font_color", Color("9aa3b2"))
	trait_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_left_box.add_child(trait_l)

## 刷新右侧已购面板（法宝 + 道具，出售按钮 = 50% 购入价）
func _refresh_right() -> void:
	for c in _items_box.get_children():
		_items_box.remove_child(c)
		c.queue_free()
	# 仅在「法宝 + 道具 + 武器 + 临时武器」全空时才显示空面板并返回，
	# 否则下方会按存在与否分别渲染对应分组（需求 2：仅持有武器时也要能查看/卖出）
	if player.artifacts_owned.is_empty() and player.items_owned.is_empty() \
			and player.weapons.is_empty() and player.temp_weapons.is_empty():
		var empty := _mk_label(12, Color("5a6270"))
		empty.text = "暂无道具"
		_items_box.add_child(empty)
		return
	# 法宝列在道具之前：每种限 1 件无数量，是触发式构筑核心，与纯属性道具分开看
	if not player.artifacts_owned.is_empty():
		_items_box.add_child(_group_label("法宝"))
		for aid: String in player.artifacts_owned:
			var a: Dictionary = Registry.get_artifact(aid)
			if a.is_empty():
				continue   # mod 卸载后残留的持有记录
			var arow := HBoxContainer.new()
			arow.add_theme_constant_override("separation", 6)
			var anm := Label.new()
			anm.text = "%s %s" % [a.get("ico", "🔮"), a.get("name", aid)]
			anm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			anm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			anm.add_theme_font_size_override("font_size", 13)
			anm.add_theme_color_override("font_color",
				Config.rarity_color(a.get("rarity", "common")))
			anm.mouse_filter = Control.MOUSE_FILTER_IGNORE
			arow.add_child(anm)
			HintBubble.attach_click(anm, _entry_detail_provider("artifact", aid), self)
			# 叠层法宝（断刃锋/玄武核）显示当前层数，否则这一列空着
			var stacks := int(player.artifact_stacks.get(aid, 0))
			if stacks > 0:
				var ast := Label.new()
				ast.text = "%d 层" % stacks
				ast.add_theme_font_size_override("font_size", 13)
				ast.add_theme_color_override("font_color", Color("f2e7c7"))
				ast.mouse_filter = Control.MOUSE_FILTER_IGNORE
				arow.add_child(ast)
			var asell := Button.new()
			asell.text = "%d◆" % roundi(float(int(a.get("price", 110))) * 0.5)
			asell.custom_minimum_size = _sell_btn_size()
			asell.tooltip_text = "出售（50% 购入价，并清除其叠层加成）"
			asell.pressed.connect(_sell_artifact.bind(aid))
			arow.add_child(asell)
			_items_box.add_child(arow)
	if player.items_owned.is_empty():
		return
	if not player.artifacts_owned.is_empty():
		_items_box.add_child(_group_label("道具"))
	for id: String in player.items_owned:
		var cnt := int(player.items_owned[id])
		var it: Dictionary = Registry.items.get(id, {})
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var nm := Label.new()
		nm.text = "%s %s" % [it.get("ico", "🧩"), it.get("name", id)]
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		nm.add_theme_font_size_override("font_size", 13)
		nm.add_theme_color_override("font_color", Config.rarity_color(it.get("rarity", "common")))
		nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(nm)
		HintBubble.attach_click(nm, _entry_detail_provider("item", id), self)
		var ct := Label.new()
		ct.text = "x%d" % cnt
		ct.add_theme_font_size_override("font_size", 13)
		ct.add_theme_color_override("font_color", Color("f2e7c7"))
		ct.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(ct)
		var sell := Button.new()
		sell.text = "%d◆" % roundi(float(int(it.get("price", 30))) * 0.5)
		sell.custom_minimum_size = _sell_btn_size()
		sell.tooltip_text = "出售 1 个（50% 购入价）"
		sell.pressed.connect(_sell.bind(id))
		row.add_child(sell)
		_items_box.add_child(row)
	# ---- 需求 2：商店也能查看 / 卖出已持有武器（含临时槽）----
	if not player.weapons.is_empty() or not player.temp_weapons.is_empty():
		_items_box.add_child(_group_label("武器"))
		for _w in player.weapons:
			_items_box.add_child(_weapon_sell_row(String(_w.get("type", "")), false))
		for _wt in player.temp_weapons:
			_items_box.add_child(_weapon_sell_row(String(_wt.get("type", "")), true))

## ---- 点击详情（第 8 轮）----
## 把条目 id 解析成 `{title, body}`。实现全在 `EntryText`，这里只做「哪个表去查」。
func _entry_detail_by(kind: String, id: String) -> Dictionary:
	match kind:
		"artifact":
			return EntryText.entry_detail(Registry.get_artifact(id), "法宝")
		"weapon":
			return EntryText.entry_detail(Registry.weapons.get(id, {}), "武器")
		"upgrade":
			return EntryText.entry_detail(Registry.upgrades.get(id, {}), "升级")
		_:
			return EntryText.entry_detail(Registry.items.get(id, {}), "道具")

func _entry_detail_provider(kind: String, id: String) -> Callable:
	return func() -> Dictionary:
		return _entry_detail_by(kind, id)

## 商品卡点击详情：回 Registry 取**原始**条目。
## ⚠️ `goods[i].desc` 会被进化提示改写（「进化 1/3 → 庚金剑域」），
##    直接拿它当描述会让玩家点开看到的是进度条而不是武器说明。
func _good_detail(i: int) -> Dictionary:
	if i < 0 or i >= goods.size():
		return { "title": "", "body": "" }
	var g: Dictionary = goods[i]
	var kind := String(g.get("kind", ""))
	if kind == "weapon":
		return _entry_detail_by("weapon", String(g.get("wtype", "")))
	return _entry_detail_by(kind, String(g.get("id", "")))

func _good_detail_provider(i: int) -> Callable:
	return func() -> Dictionary:
		return _good_detail(i)

## 分组小标题（法宝 / 道具）：仅当两类同时非空时才需要区分，但法宝单列时也加上保持一致
func _group_label(text_str: String) -> Label:
	var l := _mk_label(13, Color("e8b84b"))
	l.text = text_str
	return l

## 出售 1 个道具（返还 50% 并移除效果，购买价按当前波次上浮的差价不计入返还）
func _sell(id: String) -> void:
	var got: int = player.sell_item(id)
	if got > 0:
		GameState.add_materials(got)
		Haptics.rumble(0.2, 0.0, 0.06)
		Sfx.play("ui_select")
		_refresh()
		_save_checkpoint()   # 出售后即时重存

## 出售法宝：sell_artifact 内部已先清零叠层属性（否则暴击率/护甲会残留）
func _sell_artifact(id: String) -> void:
	var got: int = player.sell_artifact(id)
	if got > 0:
		GameState.add_materials(got)
		Haptics.rumble(0.2, 0.0, 0.06)
		Sfx.play("ui_select")
		_refresh()
		_save_checkpoint()

## 武器出售行（需求 2）：名称（临时槽标注）+ 50% 购入价卖出按钮
func _weapon_sell_row(wtype: String, is_temp: bool) -> HBoxContainer:
	var c: Dictionary = Registry.weapons.get(wtype, {})
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var nm := Label.new()
	nm.text = "%s %s%s" % [c.get("ico", "🗡"), c.get("name", wtype),
		"（临时）" if is_temp else ""]
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm.add_theme_font_size_override("font_size", 13)
	nm.add_theme_color_override("font_color", Config.rarity_color(c.get("rarity", "common")))
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(nm)
	HintBubble.attach_click(nm, _entry_detail_provider("weapon", wtype), self)
	var sell := Button.new()
	sell.text = "%d◆" % roundi(float(Registry.weapon_price(wtype)) * 0.5)
	sell.custom_minimum_size = _sell_btn_size()
	sell.tooltip_text = "出售（50% 购入价）"
	sell.pressed.connect(_sell_weapon.bind(wtype))
	row.add_child(sell)
	return row

## 出售一把武器：sell_weapon 内部优先永久槽、否则临时槽，返还 50% 基础价
func _sell_weapon(wtype: String) -> void:
	var got: int = player.sell_weapon(wtype)
	if got > 0:
		GameState.add_materials(got)
		Haptics.rumble(0.2, 0.0, 0.06)
		Sfx.play("ui_select")
		_refresh()
		_save_checkpoint()

# ---------------- 开关与商品 ----------------

## 打开商店（原型 openShop：刷新费 = 8 + wave*3 × 砍价折扣，重掷商品）
func open(shop_wave: int) -> void:
	HintBubble.hide_for(self)   # 重开时收起上一家店残留的详情卡
	_wave = shop_wave
	_reroll_cost = _discounted_reroll(Config.shop_reroll_cost(_wave))
	GameState.set_phase(GameState.Phase.SHOP)
	_roll_goods()
	_title.text = "商店 · 备战第 %d 波" % (_wave + 1)
	visible = true
	_refresh()
	# 轻淡入过渡（0.12s，不阻塞交互）
	modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, 0.12)
	_grab_first_focus()

func goods_count() -> int:
	return goods.size()

func get_reroll_cost() -> int:
	return _reroll_cost

## 砍价大师天赋：刷新费按等级折扣（最低 60 折）
func _discounted_reroll(base: int) -> int:
	var disc := minf(0.40, MetaProgress.effect_sum("reroll"))
	return maxi(1, roundi(float(base) * (1.0 - disc)))

## 外部/测试接口：锁定指定格（刷新时保留；已售格不可锁）
func set_lock(i: int, on: bool) -> void:
	if i >= 0 and i < goods.size() and not goods[i].sold:
		goods[i].locked = on

## 6 格商品：42% 武器格（满槽则跳过），29% 升级属性，其余道具
## 升级/道具按稀有度加权抽取（品阶越高越稀有，权重随波次小幅提升）
## 格数由 Config.SHOP_SLOTS 决定 —— 别在这里再写一次 6
func _roll_goods() -> void:
	goods = []
	_affinity_cache.clear()   # 开店时重算一次构筑亲和（本店期间武器/法宝不会变）
	_dim_cache.clear()        # 第 13 轮：短板维度统计同样开店重算一次
	var weapon_full: bool = player.weapons.size() >= MetaProgress.weapon_slots()
	for _i in Config.SHOP_SLOTS:
		goods.append(_roll_one(weapon_full))
	_after_roll()

## 一轮抽取后的收尾（第 9 轮）。两个保底都只抢「最后一格」，所以必须互斥 ——
## 后跑的那个会把前一个刚塞进去的换掉，表现为「保底明明该触发却没生效」。
## 顺序：同化度保底优先（它带连续落空计数，是更强的承诺），未触发才轮到亲和保底。
func _after_roll() -> void:
	_forced_assim = false
	var has_assim := false
	for g in goods:
		if _is_assim_good(g):
			has_assim = true
			break
	if has_assim:
		_assim_pity = 0
	else:
		_assim_pity += 1
		if Config.SHOP_ASSIM_FORCE_AT > 0 and _assim_pity >= Config.SHOP_ASSIM_FORCE_AT:
			_forced_assim = _force_assim_slot()
	if not _forced_assim:
		_ensure_affinity_goods()

## 同化度倾向倍率：连续落空越多越容易出（刷到一次即归零）
func _assim_weight_mult() -> float:
	return 1.0 + Config.SHOP_ASSIM_PITY_STEP * float(mini(_assim_pity, Config.SHOP_ASSIM_PITY_MAX))

## 货架项是不是「同化度」类。武器与法宝天然不是（它们没有 effects）。
func _is_assim_good(g: Dictionary) -> bool:
	return Config.is_assim_entry(_good_entry(g))

## 从货架项反查注册表条目（武器走 wtype，升级/道具走 id，法宝走 artifacts）
func _good_entry(g: Dictionary) -> Dictionary:
	match String(g.get("kind", "")):
		"weapon":
			return Registry.weapons.get(String(g.get("wtype", "")), {})
		"upgrade":
			return Registry.upgrades.get(String(g.get("id", "")), {})
		"item":
			return Registry.items.get(String(g.get("id", "")), {})
	return {}

## 同化度保底：连续 N 店没出同化度时，把最后一个未锁定格换成同化度条目。
## 池子取「升级 + 道具」两条（同化度两套 id 分别落在两边，见 Config.is_assim_entry）；
## 金/红唯一件与对当前武器无用的条目照旧被闸门挡掉。返回 true = 本店已塞入。
func _force_assim_slot() -> bool:
	if goods.is_empty():
		return false
	var idx := goods.size() - 1
	if bool(goods[idx].get("locked", false)) or bool(goods[idx].get("sold", false)):
		return false
	var taken := {}
	for g in goods:
		taken[String(g.get("id", ""))] = true
	var pool: Array = []
	for u in Registry.upgrade_list():
		if taken.has(String(u.get("id", ""))):
			continue
		if not Config.is_assim_entry(u):
			continue
		if not Config.unique_pool_ok(u, player.upgrades_owned):
			continue
		pool.append({ "item": u,
			"w": Config.rarity_weight(String(u.get("rarity", "common")), _wave) })
	for it in Registry.item_list():
		if taken.has(String(it.get("id", ""))):
			continue
		if not Config.is_assim_entry(it):
			continue
		if not Config.unique_pool_ok(it, player.items_owned):
			continue
		pool.append({ "item": it, "w": Config.rarity_weight(String(it.get("rarity", "common")), _wave) })
	if pool.is_empty():
		return false
	# 同 _ensure_affinity_goods：weighted_pick 返回的是 entry.item（条目本身），
	# 所以 kind 只能靠条目归属反查，别指望从池里带出来
	var e: Dictionary = GameRng.weighted_pick(pool)
	if e.is_empty():
		return false
	var kind := "upgrade" if Registry.upgrades.has(String(e.get("id", ""))) else "item"
	goods[idx] = {
		"kind": kind, "id": e.id, "ico": e.ico, "name": e.name,
		"desc": e.desc, "rarity": e.get("rarity", "common"),
		"base_price": int(e.get("price", 22)),
		"synergy": _synergy(e), "sold": false, "locked": false,
		"forced_assim": true,   # 测试观测：这一格是同化度保底塞进来的
	}
	return true

## 武器出现概率的折扣系数（1.0 = 原样）。满槽 → 买不了（`buy()` 会拦）= 死格，
## 武器侧饱和（满槽 + 全是进化体）另给一档，便于以后只放开其中一个。
## ⚠️ 刻意不在这两个分支之间留「部分降权」：满槽时无论是哪种，格子里放武器都是浪费。
func _weapon_chance_ratio(weapon_full: bool) -> float:
	if not weapon_full:
		return 1.0
	if player != null and is_instance_valid(player) and player.weapon_side_saturated():
		return Config.WEAPON_CHANCE_SATURATED
	return Config.WEAPON_CHANCE_SLOTS_FULL

## 商店武器池：与 Registry.shop_weapon_pool() 同一口径，额外给**已持有的同名武器**加权。
## 只在商店侧加权，不改注册表 —— Registry.shop_weapon_pool 还有别的调用方（main 的发武器），
## 在那里改语义会连带影响「事件卡送武器」这类路径。
## ⚠️ 不能顺手把进化体 weight 改掉：`shop_weight == 0` 是「不进商店池」的既有契约，
##    冒烟专门钉过这一条。
func _shop_weapon_pool() -> Array:
	var pool: Array = Registry.shop_weapon_pool()
	var owned := {}
	for w in player.weapons:
		owned[String(w.type)] = true
	if owned.is_empty():
		return pool
	for e in pool:
		if owned.has(String(e.get("item", ""))):
			e["w"] = float(e.get("w", 1.0)) * Config.SHOP_OWNED_WEAPON_MULT
	return pool

## 亲和保底：整店都没契合商品时，把最后一格换成契合项（已锁定的格不动）。
## 与升级三选一同一个意图 —— 让「这家店与我的构筑有关」成为承诺，而不是运气。
## 只在升级 / 道具里找：二者不受武器槽限制，池子更稳；法宝走独立掷点，不占这一格名额
func _ensure_affinity_goods() -> void:
	if goods.is_empty() or _affinity().is_empty():
		return
	for g in goods:
		if int(g.get("synergy", 0)) > 0:
			return   # 已有契合商品，不干预
	var idx := goods.size() - 1
	if bool(goods[idx].get("locked", false)):
		return
	var taken := {}
	for g2 in goods:
		taken[String(g2.get("id", ""))] = true
	var pool: Array = []
	for u in Registry.upgrade_list():
		if taken.has(String(u.get("id", ""))):
			continue
		if not Config.unique_pool_ok(u, player.upgrades_owned):
			continue   # 金/红唯一件已持有 → 不再出现
		if not Config.entry_weapon_relevant(u, player.weapons):
			continue
		var m := Config.affinity_mult(Config.entry_tags(u), _affinity())
		if m > 1.0:
			var uw := Config.rarity_weight(String(u.get("rarity", "common")), _wave) * m
			# ⚠️ 只收**正权重**：`rarity_weight` 会把高品阶按波次压到 0（epic <W3 / mythic <W6）。
			#    0 权重条目留在池里，`GameRng.weighted_pick` 会 push_error 并返回 null ——
			#    池子看着「非空」，实际一条都挑不出来。
			if uw > 0.0:
				pool.append({ "item": u, "w": uw })
	for it in Registry.item_list():
		if taken.has(String(it.get("id", ""))):
			continue
		if not Config.unique_pool_ok(it, player.items_owned):
			continue   # 金/红唯一件已持有 → 不再出现
		if not Config.entry_weapon_relevant(it, player.weapons):
			continue
		var m2 := Config.affinity_mult(Config.entry_tags(it), _affinity())
		if m2 > 1.0:
			var iw := Config.rarity_weight(String(it.get("rarity", "common")), _wave) * m2
			if iw > 0.0:   # 同上：0 权重不入池
				pool.append({ "item": it, "w": iw })
	if pool.is_empty():
		return
	# 注意 GameRng.weighted_pick 返回的是 entry.item（条目本身），不是整条包装 ——
	# 所以 kind 只能靠条目归属反查，别指望从池里带出来
	# ⚠️ 必须用 `Variant` 接：池子万一一条正权重都没有，`weighted_pick` 返回 null，
	#    直接赋给 `Dictionary` 是**运行期 SCRIPT ERROR**（第 11 轮实测踩到），
	#    而不是「保底放弃」——保底失败本该是静默的。
	var picked: Variant = GameRng.weighted_pick(pool)
	if typeof(picked) != TYPE_DICTIONARY:
		return
	var e: Dictionary = picked
	if e.is_empty():
		return
	var kind := "upgrade" if Registry.upgrades.has(String(e.get("id", ""))) else "item"
	goods[idx] = {
		"kind": kind, "id": e.id, "ico": e.ico, "name": e.name,
		"desc": e.desc, "rarity": e.get("rarity", "common"),
		"base_price": int(e.get("price", 22)),
		"synergy": _synergy(e), "sold": false, "locked": false,
		"forced_synergy": true,   # 测试观测：这一格是保底塞进来的
	}

func _roll_one(weapon_full: bool) -> Dictionary:
	# 法宝先掷：独立于下面武器/升级/道具的 42/29/29 分配，不改动原有比例
	# artifact_pool 已排除持有中的（每种限 1 件），池空时自然落到常规商品，不浪费这一格
	if GameRng.chance(Config.ARTIFACT_SHOP_CHANCE):
		var apool := Registry.artifact_pool(player.artifacts_owned, _wave, false, _affinity())
		if not apool.is_empty():
			var aid := String(GameRng.weighted_pick(apool))
			var a: Dictionary = Registry.get_artifact(aid)
			return { "kind": "artifact", "id": aid, "ico": a.get("ico", "🔮"),
				"name": a.get("name", aid), "desc": a.get("desc", ""),
				"rarity": a.get("rarity", "common"),
				"base_price": int(a.get("price", 110)),
				"synergy": _synergy(a), "sold": false, "locked": false }
	var r := GameRng.range_f(0.0, 1.0)
	# 武器概率与「让出的份额去哪」在这里一次算清（第 9 轮）：
	# 满槽 / 武器侧饱和时武器概率降为 0，**腾出的比例全部并进升级池**（wch + uch 恒等于
	# 原来的 0.42 + 0.29），而不是流向普通道具 —— 这才是「道具挤占核心构筑件」的根治点。
	var wch := Config.WEAPON_SHOP_CHANCE * _weapon_chance_ratio(weapon_full)
	var uch := Config.SHOP_UPGRADE_CHANCE + (Config.WEAPON_SHOP_CHANCE - wch)
	if r < wch:
		var wt: String = GameRng.weighted_pick(_shop_weapon_pool())
		var c: Dictionary = Registry.weapons[wt]
		return { "kind": "weapon", "wtype": wt, "ico": c.ico, "name": c.name,
			"desc": c.desc, "rarity": c.rarity,
			"base_price": Registry.weapon_price(wt), "synergy": 0,
			"sold": false, "locked": false }
	if r < wch + uch:
		var u: Dictionary = GameRng.weighted_pick(
			_rarity_pool(Registry.upgrade_list(), player.upgrades_owned))
		return { "kind": "upgrade", "id": u.id, "ico": u.ico, "name": u.name,
			"desc": u.desc, "rarity": u.get("rarity", "common"),
			"base_price": int(u.get("price", 22)), "synergy": _synergy(u),
			"dim": Config.diminish_mult(u, player.stats, _wave),   # 第 13 轮：观测用
			"dim_keys": Config.dim_suppressed_keys(u, player.stats, _wave),
			"sold": false, "locked": false }
	var it: Dictionary = GameRng.weighted_pick(
		_rarity_pool(Registry.item_list(), player.items_owned))
	return { "kind": "item", "id": it.id, "ico": it.ico, "name": it.name,
		"desc": it.desc, "rarity": it.rarity,
		"base_price": int(it.price), "synergy": _synergy(it),
		"dim": Config.diminish_mult(it, player.stats, _wave),   # 第 13 轮：观测用
		"dim_keys": Config.dim_suppressed_keys(it, player.stats, _wave),
		"sold": false, "locked": false }

## 稀有度加权池：[{ item: 条目, w: rarity_weight(稀有度, 当前波次) × 亲和倍率 }]
## 亲和倍率让与当前角色 / 武器相关的条目更容易出现（见 Config.affinity_tags）；
## 同时过滤掉「对当前武器无用」的武器专属强化（纯枪构筑不出近战范围加成）
## `owned` 传该池对应的「当前持有表」（升级 → upgrades_owned，道具 → items_owned），
## 用于剔除金/红「唯一件」（Config.unique_pool_ok）—— 取表见 _owned_for。
func _rarity_pool(entries: Array, owned: Dictionary) -> Array:
	var aff := _affinity()
	var pool: Array = []
	for e in entries:
		if not Config.entry_weapon_relevant(e, player.weapons):
			continue
		if not Config.unique_pool_ok(e, owned):
			continue   # 金/红唯一件已持有 → 不再出现
		var w: float = Config.rarity_weight(String(e.get("rarity", "common")), _wave) \
			* Config.affinity_mult(Config.entry_tags(e), aff)
		# 第 13 轮两层倾向：
		#   ① 边际递减 —— 该族已经投入越多，越难再刷到（范围类是面积收益，边际递增）
		#   ② 补短板   —— 当前投入最少的维度提权，形成「别再堆了，去补另一维」的引导
		# 两者互斥不了也不该互斥：一是「别过火」，一是「补空白」，叠乘才是完整意图。
		w *= Config.diminish_mult(e, player.stats, _wave)
		w *= Config.shortfall_mult(e, _dim_counts())
		if Config.is_assim_entry(e):
			w *= _assim_weight_mult()   # 连续没刷到 → 越刷越容易出（第 9 轮）
		pool.append({ "item": e, "w": w })
	return pool

## 第 13 轮：统计玩家已在各「短板维度」投入了多少件（升级 + 道具，按持有份数累加）。
## 用**件数**而不是 stats 数值做基准 —— 不同维度的属性量纲不同（max_hp 是百级、
## crit_ch 是零点零几），直接比数值没有可比性，件数是天然的公共尺子。
func _dim_counts() -> Dictionary:
	if not _dim_cache.is_empty():
		return _dim_cache
	# ⚠️ 四个维度**恒先置 0**：空字典会让 _dim_cache.is_empty() 永远为真（反复重算），
	#    也会让 Config.shortfall_mult 走「刚开局不引导」分支，补短板永远不生效。
	var counts := { "offense": 0, "area": 0, "tank": 0, "utility": 0 }
	for uid in player.upgrades_owned:
		_bump_dim(counts, Registry.upgrades.get(String(uid), {}),
			int(player.upgrades_owned[uid]))
	for iid in player.items_owned:
		_bump_dim(counts, Registry.items.get(String(iid), {}), int(player.items_owned[iid]))
	_dim_cache = counts
	return _dim_cache

static func _bump_dim(counts: Dictionary, e: Dictionary, n: int) -> void:
	var d := Config.entry_dim(e)
	if d == "":
		return
	counts[d] = int(counts.get(d, 0)) + n

## 唯一件闸门要用的「当前持有表」：升级看 upgrades_owned，道具看 items_owned。
## 法宝不在此列 —— 它一直走 Registry.artifact_pool(artifacts_owned, …) 的独立通道。
func _owned_for(kind: String) -> Dictionary:
	return player.upgrades_owned if kind == "upgrade" else player.items_owned

## 当前构筑的亲和标签（开店时算一次并缓存）
func _affinity() -> Array:
	if _affinity_cache.is_empty():
		_affinity_cache = Config.affinity_tags(GameState.character_id,
			player.weapons, player.artifacts_owned)
	return _affinity_cache

## 条目与当前构筑的契合度（命中的亲和标签数量，0 = 无关）。
## 抽取已经按它加权（见 _rarity_pool），货架上也标出来 ——
## 光让好东西更容易出现还不够，玩家得**看见**它为什么好
func _synergy(e: Dictionary) -> int:
	var aff := _affinity()
	if aff.is_empty():
		return 0
	var hit := 0
	for t in Config.entry_tags(e):
		if t in aff:
			hit += 1
	return hit

func _price_of(g: Dictionary) -> int:
	return int(round(float(Config.shop_price(g.base_price, _wave)) * RunRules.shop_price_mult()))

func _refresh() -> void:
	# 记录当前焦点所在卡片，重建后优先原位恢复（避免焦点跳回第一张）
	var focus_idx := _focused_card_index()
	_mat.text = "◆ %d" % GameState.materials
	_refresh_weapon_bar()
	_refresh_left()
	_refresh_right()
	# 自定义规则：禁用刷新 / 禁用回血（按钮保留但灰掉，让玩家看得见"这是规则限制"）
	if RunRules.reroll_disabled():
		_reroll_btn.text = "刷新（规则禁用）"
		_reroll_btn.disabled = true
	else:
		_reroll_btn.text = "刷新 (%d ◆)" % _reroll_cost
		_reroll_btn.disabled = GameState.materials < _reroll_cost
	if RunRules.heal_disabled():
		_heal_btn.text = "回血（规则禁用）"
		_heal_btn.disabled = true
	else:
		_heal_btn.text = "回血 50%% (%d ◆)" % Config.SHOP_HEAL_PRICE
		_heal_btn.disabled = GameState.materials < Config.SHOP_HEAL_PRICE \
			or player.hp >= player.stats.max_hp
	_build_goods()
	# 卡片重建会销毁旧焦点节点，重新抓焦保证手柄不断导航
	if visible:
		_grab_focus_near(focus_idx)

## 重建武器栏（需求：商店页要能一眼看到当前武器栏）。
## 与 HUD `_rebuild_weapons` 同口径：永久槽按同名聚合 xN + 空槽占位，临时槽武器附后并标注。
## 临时槽**不**显示空占位 —— 空临时槽是「没有溢出」，不是「少了武器」。
func _refresh_weapon_bar() -> void:
	for c in _weapon_bar.get_children():
		_weapon_bar.remove_child(c)
		c.queue_free()
	var groups := {}   # 永久槽：type -> 持有数
	for w in player.weapons:
		var wt := String(w.get("type", ""))
		groups[wt] = int(groups.get(wt, 0)) + 1
	for k in groups:
		_weapon_bar.add_child(_make_weapon_slot(String(k), int(groups[k]), false))
	for _i in MetaProgress.weapon_slots() - player.weapons.size():
		_weapon_bar.add_child(_make_weapon_slot("", 0, false))
	var tgroups := {}   # 临时槽
	for t in player.temp_weapons:
		var tt := String(t.get("type", ""))
		tgroups[tt] = int(tgroups.get(tt, 0)) + 1
	for k in tgroups:
		_weapon_bar.add_child(_make_weapon_slot(String(k), int(tgroups[k]), true))

## 单个武器槽：HUD `_make_slot` 同款 48×48 面板；空槽半透明占位；悬浮查武器详情
func _make_weapon_slot(wtype: String, count: int, is_temp: bool) -> Control:
	var c: Dictionary = Registry.weapons.get(wtype, {})
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(48.0, 48.0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.094, 0.106, 0.129, 0.78)
	style.border_color = Color("3a4150")
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	panel.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(box)
	if c.is_empty():
		panel.modulate.a = 0.3   # 空槽
		return panel
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var ico := Label.new()
	ico.text = String(c.get("ico", "🗡"))
	ico.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ico.add_theme_font_size_override("font_size", 18)
	ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(ico)
	var nm := Label.new()
	# 聚合同类武器：名字右侧带 xN；临时槽再带「临时」角标
	nm.text = String(c.get("name", wtype)) + (" x%d" % count if count > 1 else "") \
		+ ("（临时）" if is_temp else "")
	nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nm.add_theme_font_size_override("font_size", 11)
	nm.add_theme_color_override("font_color", Color("9aa3b2"))
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(nm)
	# 悬浮查详情：与右栏出售行同一 detail provider（面板本身 STOP，整槽可点看说明）
	HintBubble.attach_hover(panel, String(c.get("name", wtype)) + ("（临时）" if is_temp else ""),
		EntryText.entry_detail(c, "武器").get("body", ""), self)
	return panel

## 当前焦点位于哪张商品卡（buy/lock 钮均可），无焦点返回 -1
func _focused_card_index() -> int:
	var focus := get_viewport().gui_get_focus_owner()
	if focus == null:
		return -1
	for i in _goods_box.get_child_count():
		var card: Control = _goods_box.get_child(i)
		if focus == card.get_meta("buy_btn") or focus == card.get_meta("lock_btn"):
			return i
	return -1

## 恢复焦点：优先原位（未禁用），否则第一张可购卡/任意卡
func _grab_focus_near(prefer: int) -> void:
	if prefer >= 0 and prefer < _goods_box.get_child_count():
		var btn: Button = _goods_box.get_child(prefer).get_meta("buy_btn")
		if btn != null and not btn.disabled:
			btn.grab_focus()
			return
	_grab_first_focus()

func _build_goods() -> void:
	# 每次重建都重算列数：货架格数 / 屏宽 / 左右栏都可能与上次不同
	_goods_box.columns = _goods_grid().x
	for c in _goods_box.get_children():
		_goods_box.remove_child(c)
		c.queue_free()
	for i in goods.size():
		_goods_box.add_child(_make_good_card(i))
	_wire_focus()

## 跨行焦点接线：购买钮 ↓ → 刷新；锁定钮 ↓ → 回血；动作区 ↑ → 第一张可购卡
func _wire_focus() -> void:
	var first := _first_card_button()
	for card in _goods_box.get_children():
		var buy: Button = card.get_meta("buy_btn")
		var lock: Button = card.get_meta("lock_btn")
		buy.focus_neighbor_bottom = buy.get_path_to(_reroll_btn)
		lock.focus_neighbor_bottom = lock.get_path_to(_heal_btn)
	if first:
		for b: Button in [_reroll_btn, _heal_btn, _next_btn]:
			b.focus_neighbor_top = _reroll_btn.get_path_to(first)

func _first_card_button() -> Button:
	var fallback: Button = null
	for card in _goods_box.get_children():
		var buy: Button = card.get_meta("buy_btn")
		if not buy.disabled:
			return buy
		if fallback == null:
			fallback = buy
	return fallback

## 稀有度卡面样式：色底 + 稀有度描边（common 白 / rare 蓝 / epic 紫 / legendary 红）
func _rarity_style(r: String) -> StyleBoxFlat:
	var col: Color = Config.rarity_color(r)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(col.r, col.g, col.b, 0.10)
	sb.border_color = col
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	return sb

## 商品区可用尺寸（第 9 轮）：扣掉左右侧栏与外边距后，留给商品阵列的那一块。
## ⚠️ 这里是**估算**而不是实测容器尺寸：`_build_goods()` 跑在容器 settle 之前，
##    拿不到真实 rect。宁可估保守一点（算窄），也不要让卡片溢出屏幕外点不到。
func _goods_avail() -> Vector2:
	var avail := UiMetrics.available()
	if UiMetrics.prefers_full_page():
		# 小屏：无左属性栏；扣右侧出售栏（dp(180)）+ 栏间距 + 外边距 + 标题/材料/武器栏/动作区高度
		avail.x -= UiMetrics.dp(180.0) + 14.0 + UiMetrics.dp(24.0)
		avail.y -= UiMetrics.dp(190.0)
	else:
		# 桌面：左属性栏 288 + 右出售栏 288 + 两个 14 栏间距 + 24 外边距
		avail.x -= 288.0 * 2.0 + 14.0 * 2.0 + 24.0
		avail.y -= 210.0
	return Vector2(maxf(avail.x, 200.0), maxf(avail.y, 200.0))

func _goods_min_w() -> float:
	return UiMetrics.dp(110.0) if UiMetrics.prefers_full_page() else 150.0

func _goods_min_h() -> float:
	return UiMetrics.dp(120.0) if UiMetrics.prefers_full_page() else 150.0

func _goods_max_h() -> float:
	return UiMetrics.dp(238.0)

## 出售按钮尺寸（移动端适配补齐）。桌面 56×24 —— 右侧栏是纯列表，24 够用。
## 但手机上左侧属性栏已按 compact 隐藏，右侧栏成了**唯一**的出售入口
## （第 9 轮特意保留它就是为了「手机上也能卖东西」），24 单元 ≈ 24dp、
## 只有 Material 最小触控目标（48dp）的一半，手指根本按不准 —— 那这一栏就白保留了。
func _sell_btn_size() -> Vector2:
	if not UiMetrics.prefers_full_page():
		return Vector2(56.0, 24.0)
	return Vector2(UiMetrics.dp(56.0), UiMetrics.touch_at_least(UiMetrics.dp(24.0)))

## 商品阵列的行列（第 9 轮）。思路与菜单首页一致：**先把最大列数按宽度算出来，
## 再用 ceil 反推行数，最后用 ceil(n/rows) 平均分列** —— 这样 6 格在「最多 4 列」
## 的宽度下得到 3+3，而不是 4+2（后者最后一行只有两张，视觉上不平衡，
## 也会让该行的卡比上一行宽，玩家点起来手感不一致）。
func _goods_grid() -> Vector2i:
	var n := maxi(1, goods.size())
	var gap := 8.0
	var avail := _goods_avail()
	var max_cols := int(floor((avail.x + gap) / (_goods_min_w() + gap)))
	max_cols = clampi(max_cols, 1, n)
	var rows := int(ceil(float(n) / float(max_cols)))
	var cols := int(ceil(float(n) / float(rows)))
	return Vector2i(cols, rows)

## 商品卡尺寸：由 `_goods_grid()` 的行列与可用区域反推，宽度/高度各自 clamp 到
## 「最小可读」与「最大舒适」之间。桌面不再固定 150×238 —— 那是旧版溢出的根源。
func _good_card_size() -> Vector2:
	var g := _goods_grid()
	var avail := _goods_avail()
	var gap := 8.0
	var w := (avail.x - gap * float(g.x - 1)) / float(g.x)
	var h := (avail.y - gap * float(g.y - 1)) / float(g.y)
	return Vector2(maxf(w, _goods_min_w()), clampf(h, _goods_min_h(), _goods_max_h()))

func _make_good_card(i: int) -> Control:
	var g: Dictionary = goods[i]
	var price := _price_of(g)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = _good_card_size()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _rarity_style(g.rarity))
	if g.sold:
		panel.modulate = Color(1.0, 1.0, 1.0, 0.45)
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(box)
	var ico := Label.new()
	ico.text = g.ico
	ico.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ico.add_theme_font_size_override("font_size", 30)
	ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(ico)
	var name_l := Label.new()
	name_l.text = String(g.name) + (" ✦" if int(g.get("synergy", 0)) > 0 else "")
	name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_l.add_theme_font_size_override("font_size", 14)
	name_l.add_theme_color_override("font_color", Config.rarity_color(g.rarity))
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(name_l)
	# 点击物品名 → 弹出「加成 + 描述」详情（第 8 轮）。
	# provider 在**点击那一刻**才求值，所以拿到的一定是当场数据（不是挂载时的旧值）。
	HintBubble.attach_click(name_l, _good_detail_provider(i), self)
	# 武器显示已拥有数量（同名武器聚合提示）+ 进化进度（如 3/4）
	if g.kind == "weapon":
		# 持有数含临时槽（需求 3：临时槽也是同名武器的持有来源）
		var owned: int = player.weapon_count(String(g.wtype))
		if owned > 0:
			name_l.text = "%s  x%d" % [g.name, owned]
		# 进化提示：拥有同名武器时显示进度/预告（多分支时显示下一个未持有的进化方向）
		var wcfg: Dictionary = Registry.weapons.get(g.wtype, {})
		var need := int(wcfg.get("evolve_need", 0))
		if need > 0 and owned > 0:
			var ex_name: String = player.next_evolve_name(String(g.wtype))
			if ex_name != "":
				if owned >= need:
					g.desc = "★ 波末自动进化 → %s" % ex_name
				else:
					g.desc = "进化 %d/%d → %s（再买 %d 把）" % [owned, need, ex_name, need - owned]
	var desc := Label.new()
	# 第 13 轮补充：边际递减压制角标 —— 让玩家看见「这件为什么老不出 / 出现概率被压」。
	# 只压到一定程度才亮标（dim < 0.999 即已被压），并显示具体是哪个属性超额。
	var dim: float = float(g.get("dim", 1.0))
	if dim < 0.999:
		var badge := Label.new()
		var btxt := "↓ 边际递减 ×%.2f" % dim
		var keys: PackedStringArray = PackedStringArray(g.get("dim_keys", []))
		if keys.size() > 0:
			var parts: PackedStringArray = []
			for kk in keys:
				parts.append(Config.dim_key_label(String(kk)))
			btxt += " · " + "、".join(parts)
		badge.text = btxt
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		badge.add_theme_font_size_override("font_size", 10)
		badge.add_theme_color_override("font_color", Color("e8a13a"))
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(badge)
	# 契合标记：让「这件东西跟你的角色 / 武器是一路的」一眼可见
	if int(g.get("synergy", 0)) > 0:
		desc.text = "✦ 契合当前构筑\n" + String(g.desc)
	else:
		desc.text = String(g.desc)
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# 描述列宽跟随卡片宽度（旧版写死 132 = 150 卡宽 − 内边距；
	# 小屏卡片变窄后 132 的硬下限会把卡重新撑宽，自适应白做）
	desc.custom_minimum_size = Vector2(maxf(60.0, _good_card_size().x - 18.0), 0.0)
	desc.add_theme_font_size_override("font_size", 11)
	desc.add_theme_color_override("font_color", Color("9aa3b2"))
	desc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(desc)
	# 操作行：锁定钮 + 购买钮
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(row)
	var lock_btn := Button.new()
	lock_btn.custom_minimum_size = Vector2(34.0, 30.0)
	lock_btn.text = "🔒" if g.locked else "🔓"
	lock_btn.toggle_mode = true
	lock_btn.button_pressed = g.locked
	lock_btn.visible = not g.sold
	lock_btn.tooltip_text = "锁定：刷新时保留此商品"
	lock_btn.pressed.connect(_toggle_lock.bind(i))
	row.add_child(lock_btn)
	var btn := Button.new()
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if g.sold:
		btn.text = "已售出"
		btn.disabled = true
	else:
		btn.text = "%d ◆" % price
		# 满槽武器拦截在扣钱前（修正原型 buyGood 先扣钱后检查的坑）
		btn.disabled = GameState.materials < price \
			or (g.kind == "weapon" and player.weapon_capacity_full())
		btn.pressed.connect(buy.bind(i))
	row.add_child(btn)
	panel.set_meta("buy_btn", btn)
	panel.set_meta("lock_btn", lock_btn)
	return panel

## 切换锁定（只更新该格按钮，不重建面板，避免焦点跳动）
func _toggle_lock(i: int) -> void:
	if i < 0 or i >= goods.size() or goods[i].sold:
		return
	goods[i].locked = not goods[i].locked
	Haptics.rumble(0.15, 0.0, 0.05)
	Sfx.play("ui_select")
	var card: Control = _goods_box.get_child(i)
	var lock_btn: Button = card.get_meta("lock_btn")
	lock_btn.text = "🔒" if goods[i].locked else "🔓"
	lock_btn.button_pressed = goods[i].locked

## 购买（sold/材料不足/满槽武器拦截，扣钱 → 生效 → 重渲染）
func buy(i: int) -> void:
	if i < 0 or i >= goods.size():
		return
	var g: Dictionary = goods[i]
	var price := _price_of(g)
	if g.sold or GameState.materials < price:
		return
	# 武器满槽（永久 + 临时都满）才拦截；否则买武器由下面的路由送进对应槽
	if g.kind == "weapon" and player.weapon_capacity_full():
		return
	# 商店开着期间已通过掉落/事件拿到同一件法宝：直接标售罄且不扣钱。
	# 否则玩家会为一件已拥有的法宝付 110~300 只换回 60 材料补偿（apply_artifact 的重复分支）
	if g.kind == "artifact" and player.artifacts_owned.has(String(g.id)):
		g.sold = true
		_refresh()
		return
	# 同理：金/红「唯一件」在商店开着期间已从掉落 / 事件拿到 → 同样标售罄且不扣钱，
	# 否则玩家会为一件已持有的金/红件付全价，只换回 apply_item 的拒绝
	if g.kind in ["upgrade", "item"] and not Config.unique_pool_ok(g, _owned_for(String(g.kind))):
		g.sold = true
		_refresh()
		return
	GameState.add_materials(-price)
	g.sold = true
	Haptics.rumble(0.25, 0.0, 0.08)   # 手柄确认轻震
	Sfx.play("buy")
	if g.kind == "weapon":
		var _wt: String = String(g.wtype)
		var _cfg: Dictionary = Registry.weapons.get(_wt, {})
		var _need := int(_cfg.get("evolve_need", 0))
		# 路由：永久槽未满先进永久槽；永久满则进临时槽（需求 3：临时槽是永久槽满后的溢出位）
		if player.weapons.size() < MetaProgress.weapon_slots():
			player.weapons.append({ "type": _wt, "cd": 0.1 })
		elif player.temp_weapons.size() < Config.TEMP_WEAPON_SLOTS:
			player.temp_weapons.append({ "type": _wt, "cd": 0.1 })
		else:
			# 双槽皆满的安全兜底（按钮本应已禁用），退款不买
			GameState.add_materials(price)
			g.sold = false
			_refresh()
			return
		player.refresh_family_synergy()
		# 需求 3：买够 need 把立刻进化（单分支自动合成；当前 5 把基础武器全是单分支）
		if _need > 0 and player.weapon_count(_wt) >= _need:
			var _txt: String = player.instant_evolve(_wt)
			if _txt != "":
				Haptics.rumble(0.5, 0.2, 0.3)
				Sfx.play("victory")
				EventBus.banner_requested.emit("⚔ 武器进化！", _txt, 3.0)
	elif g.kind == "upgrade":
		player.apply_upgrade(g.id)
	elif g.kind == "artifact":
		player.apply_artifact(g.id)
	else:
		player.apply_item(g.id)
	var purchased_id := String(g.wtype) if g.kind == "weapon" else String(g.id)
	EventBus.item_purchased.emit(purchased_id)
	_refresh()
	_save_checkpoint()   # 商店内即时重存，退出不丢购物

## 刷新：费用 ×1.4 递增（吃砍价折扣）；已售格与锁定格原位保留，其余重 roll
## 注意：**购买本身不触发重掷** —— 买掉的格子只标「已售出」留在原位（见 buy()），
## 货架内容只在玩家主动付刷新费时变动，这样「买哪一格」才是真决策。
func reroll() -> void:
	if RunRules.reroll_disabled():
		EventBus.banner_requested.emit("规则禁用", "本局已禁用商店刷新", 1.6)
		return
	if GameState.materials < _reroll_cost:
		return
	GameState.add_materials(-_reroll_cost)
	_reroll_cost = _discounted_reroll(roundi(_reroll_cost * 1.4))
	Haptics.rumble(0.25, 0.0, 0.08)
	Sfx.play("reroll")
	var old := goods.duplicate(true)
	var weapon_full: bool = player.weapons.size() >= MetaProgress.weapon_slots()
	goods = []
	for i in Config.SHOP_SLOTS:
		if i < old.size() and (old[i].sold or old[i].locked):
			goods.append(old[i])   # 原位保留
		else:
			goods.append(_roll_one(weapon_full))
	_after_roll()
	_refresh()
	_save_checkpoint()   # 刷新扣费后即时重存

## 回血：15 ◆ 回复 50% 最大生命（原型 btnHeal）
func heal() -> void:
	if RunRules.heal_disabled():
		EventBus.banner_requested.emit("规则禁用", "本局已禁用商店回血", 1.6)
		return
	if GameState.materials < Config.SHOP_HEAL_PRICE:
		return
	GameState.add_materials(-Config.SHOP_HEAL_PRICE)
	player.hp = minf(player.stats.max_hp, player.hp + player.stats.max_hp * 0.5)
	Haptics.rumble(0.25, 0.0, 0.08)
	Sfx.play("heal")
	_refresh()
	_save_checkpoint()   # 回血扣费后即时重存

## 存档合并写：商店内连续购买/刷新/回血只落一次盘（0.4s 内合并），
## 下一波/返回主菜单前强制落盘，最多丢 0.4s 内的最后一步操作
func _save_checkpoint() -> bool:
	_save_dirty = true
	if not _save_pending:
		_save_pending = true
		get_tree().create_timer(0.4).timeout.connect(_flush_save)
	return true

func _flush_save() -> void:
	_save_pending = false
	if not _save_dirty:
		return
	_save_dirty = false
	# S4.5：本函数就是「进商店时存档」的正主，checkpoint 用 `shop` ——
	# 恢复后重新打开这一层商店（`shop_ui.open(_wave)`），而不是把 `_wave + 1` 波重打一遍。
	if not SaveRun.save(_wave + 1, player, SaveRun.CHECKPOINT_SHOP):
		EventBus.banner_requested.emit("存档失败", "进度未写入，请检查磁盘空间", 2.0)

## 下一波：强制落盘后关闭商店并进入 intro。
## 江湖奇遇（Phase 4）：30% 概率先弹事件卡；命中时由 main 在三选一结束后
## 再启动这一波（本函数直接 return，不重复推进）
func next_wave() -> void:
	_flush_save()
	visible = false
	goods = []
	var target := _wave + 1
	if main != null and main.try_trigger_event_card(target):
		return
	wave_manager.start_wave(target)

## 下一波按钮入口（需求 3）：临时武器槽有武器时，退出商店会半价卖出，先二次确认。
## 确认 → 半价返还材料 + 进入下一波；取消 → 留在商店继续操作。
func _on_next_pressed() -> void:
	if player != null and is_instance_valid(player) and player.temp_weapons.size() > 0:
		_ask_exit_with_temp()
	else:
		next_wave()

func _ask_exit_with_temp() -> void:
	if _temp_confirm != null and is_instance_valid(_temp_confirm):
		return
	var d := ConfirmationDialog.new()
	d.title = "退出商店确认"
	d.dialog_text = "临时武器槽中还有 %d 把武器，退出商店将按半价自动卖出。确定离开？" \
		% player.temp_weapons.size()
	add_child(d)
	# 宽一点避免文字被截断
	d.min_size = Vector2(360.0, 0.0)
	d.confirmed.connect(_on_temp_confirmed)
	d.canceled.connect(_on_temp_canceled.bind(d))
	d.popup_centered()
	_temp_confirm = d

func _on_temp_confirmed() -> void:
	var got := 0
	if player != null and is_instance_valid(player):
		got = player.sell_temp_weapons()
	if got > 0:
		GameState.add_materials(got)
		Haptics.rumble(0.2, 0.0, 0.06)
		Sfx.play("ui_select")
	_clear_temp_confirm()
	next_wave()

func _on_temp_canceled(d: ConfirmationDialog) -> void:
	_clear_temp_confirm()

func _clear_temp_confirm() -> void:
	if _temp_confirm != null and is_instance_valid(_temp_confirm):
		_temp_confirm.queue_free()
	_temp_confirm = null

func _grab_first_focus() -> void:
	# 默认焦点给第一张可购买的卡片按钮，供手柄直接操作
	var first := _first_card_button()
	if first:
		first.grab_focus()
	else:
		_next_btn.grab_focus()

## 手柄 A / Enter 回退：焦点在哪个按钮就触发哪个操作
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_accept"):
		var focus := get_viewport().gui_get_focus_owner()
		# 仅当焦点落在商店自身子树内才转发（临时槽退出确认的 ConfirmDialog
		# 是独立窗口，其按钮焦点不在本树内，交给对话框自身处理，避免重复触发）
		if focus is Button and not focus.disabled and is_ancestor_of(focus):
			focus.pressed.emit()
			get_viewport().set_input_as_handled()
