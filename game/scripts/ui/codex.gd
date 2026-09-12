extends Control
## 图鉴：九类百科 —— 状态 / 五行 / 武器 / 道具 / 法宝 / 升级 / 敌人 / 奇遇 / 成就
## （分类真相以本文件 TABS 常量为准，注释仅作概览；新增分类时务必同步 TABS）
## 数据全部来自 Config + Registry（创意工坊内容自动出现）
## 支持名称搜索 + 全部/已解锁/未解锁筛选；未解锁条目灰态并显示解锁条件
## 打开：open()；Esc / 手柄 B：_close() 并发 closed 信号（由主菜单接回焦点）

signal closed

const TABS := [
	{ "id": "status", "name": "状态", "ico": "🔥" },
	{ "id": "reaction", "name": "五行", "ico": "☯" },
	{ "id": "weapon", "name": "武器", "ico": "🔫" },
	{ "id": "item", "name": "道具", "ico": "🧩" },
	{ "id": "artifact", "name": "法宝", "ico": "🔮" },
	{ "id": "upgrade", "name": "升级", "ico": "✨" },
	{ "id": "enemy", "name": "敌人", "ico": "👾" },
	{ "id": "event", "name": "奇遇", "ico": "🎴" },
	{ "id": "achieve", "name": "成就", "ico": "🏆" },
]

const AI_NAMES := { "chaser": "追击", "runner": "冲刺", "shooter": "远程", "boss": "BOSS 弹幕" }
const SHAPE_NAMES := { "circle": "圆形", "square": "方形", "diamond": "菱形" }
const LOCK_HINTS := {
	"status": "在战斗中触发一次该状态即可解锁",
	"reaction": "让同一敌人同时带上两种相异五行的状态即可解锁",
	"weapon": "获得一次该武器即可解锁（开局武器 / 商店购买 / 进化）",
	"item": "获得一次该道具即可解锁（商店购买 / 开局携带）",
	"artifact": "获得一次该法宝即可解锁（精英击杀 / BOSS 必掉 / 商店）",
	"upgrade": "选择一次该升级即可解锁（升级三选一 / 商店）",
	"enemy": "遭遇一次该敌人即可解锁（任意波次出现）",
	"event": "在商店后偶遇一次该奇遇即可解锁（每局最多 3~5 次，10 张不重复）",
}
const CAT_COLORS := {
	"status": Color("ef8354"), "reaction": Color("6fd6c8"), "weapon": Color("e8b84b"),
	"item": Color("6fbf73"), "upgrade": Color("7aa2f7"), "enemy": Color("d9534f"),
	"artifact": Color("c39bf5"), "event": Color("d8a1e8"),
}

## 法宝触发时机的中文描述（与 Config.ARTIFACT_TRIGGERS 一一对应）
const ARTIFACT_TRIGGER_NAMES := {
	"on_reaction": "五行反应触发时", "on_kill": "击杀敌人时",
	"on_status_apply": "施加状态时", "on_deal_hit": "造成伤害时",
	"on_take_hit": "受到攻击时", "on_wave_end": "每波结束时",
}
const ARTIFACT_PARAM_NAMES := {
	"element": "限定五行", "key": "限定反应", "status": "限定状态",
	"hp_below": "目标生命低于",
}
const ARTIFACT_EFFECT_NAMES := {
	"patch": "改写反应效果", "bonus_dmg_pct": "追加攻击力", "chance": "触发概率",
	"radius": "作用半径", "apply_status": "施加状态", "stacks": "施加层数",
	"duration": "持续时长", "stat": "叠加属性", "per_stack": "每层数值",
	"stack_max": "层数上限", "stack_reset": "层数重置", "dmg_mult": "伤害倍率",
	"heal_pct": "回复最大生命", "high_hp": "高血阈值", "high_hp_armor": "高血护甲",
	"low_hp": "低血阈值", "low_hp_dmg_reduce": "低血减伤", "add_stacks": "追加层数",
	"bonus_materials": "额外材料",
}

var _tab_group := ButtonGroup.new()
var _tab_btns: Array = []
var _list_group := ButtonGroup.new()
var _list_btns: Array = []
var _list_box: VBoxContainer
var _detail: VBoxContainer
var _close_btn: Button
var _tab := "status"
var _selected_id := "burn"
var _search_edit: LineEdit
var _count_label: Label
var _achieve_bar: ProgressBar
var _filter_group := ButtonGroup.new()
var _filter_btns: Array = []
var _filter := "all"     # all / unlocked / locked
var _query := ""
var _page_tween: Tween = null

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	_build()

func open() -> void:
	visible = true
	_rebuild_list()
	_focus_selected()

## 从解锁 toast 直达条目：切到对应分类、清空搜索/筛选并选中目标
func open_entry(cat: String, id: String) -> void:
	var tab := cat
	var known := false
	for spec in TABS:
		if String(spec.id) == tab:
			known = true
			break
	if not known:
		tab = "status"
	_filter = "all"
	_query = ""
	if _search_edit != null:
		_search_edit.text = ""
	for b in _filter_btns:
		b.button_pressed = String(b.get_meta("filter", "")) == "all"
	_selected_id = id
	visible = true
	_select_tab(tab, false)
	_select_entry(_selected_id)
	_focus_selected()
	Haptics.rumble(0.1, 0.0, 0.04)

func _close() -> void:
	Sfx.play("ui_back")
	visible = false
	closed.emit()

func _unhandled_input(event: InputEvent) -> void:
	if not visible or not event.is_action_pressed("ui_cancel"):
		return
	# 搜索框有内容时，第一次 Esc 先清空搜索，再按才关闭
	if _search_edit != null and _search_edit.has_focus() and _search_edit.text != "":
		_search_edit.text = ""
		_on_search_changed("")
	else:
		_close()
	get_viewport().set_input_as_handled()

func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.04, 0.06, 0.82)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(1100.0, 660.0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("181c24")
	sb.border_color = Color("2c3340")
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(12)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	sb.content_margin_top = 14.0
	sb.content_margin_bottom = 14.0
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	panel.add_child(root)
	var title := Label.new()
	title.text = "📖 图 鉴"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color("e8b84b"))
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(title)
	var tip := Label.new()
	tip.text = "状态 / 五行 / 武器 / 道具 / 升级 / 敌人 / 成就 · 搜索 + 解锁筛选 · 未解锁条目灰态 · Esc / 手柄 B 返回"
	tip.add_theme_font_size_override("font_size", 12)
	tip.add_theme_color_override("font_color", Color("9aa3b2"))
	tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(tip)
	# 顶部分类标签
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 8)
	root.add_child(tab_row)
	for spec in TABS:
		var tid := String(spec.id)
		var tb := Button.new()
		tb.toggle_mode = true
		tb.button_group = _tab_group
		tb.text = "%s %s" % [String(spec.ico), String(spec.name)]
		tb.custom_minimum_size = Vector2(150.0, 40.0)
		tb.set_meta("tab", tid)
		tb.add_theme_font_size_override("font_size", 15)
		tb.pressed.connect(func() -> void: _select_tab(tid))
		_wire_hover_sfx(tb)
		tab_row.add_child(tb)
		_tab_btns.append(tb)
	for i in _tab_btns.size():
		var tb2: Button = _tab_btns[i]
		if i > 0:
			tb2.focus_neighbor_left = tb2.get_path_to(_tab_btns[i - 1])
		if i < _tab_btns.size() - 1:
			tb2.focus_neighbor_right = tb2.get_path_to(_tab_btns[i + 1])
	# 左列表（搜索/筛选 + 列表） + 右详情
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 16)
	hb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(hb)
	var left_box := VBoxContainer.new()
	left_box.custom_minimum_size = Vector2(240.0, 0.0)
	left_box.add_theme_constant_override("separation", 6)
	left_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hb.add_child(left_box)
	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "搜索名称…"
	_search_edit.clear_button_enabled = true
	_search_edit.custom_minimum_size = Vector2(0.0, 32.0)
	_search_edit.text_changed.connect(_on_search_changed)
	left_box.add_child(_search_edit)
	var filter_row := HBoxContainer.new()
	filter_row.add_theme_constant_override("separation", 4)
	left_box.add_child(filter_row)
	for spec in [["all", "全部"], ["unlocked", "已解锁"], ["locked", "未解锁"]]:
		var fid := String(spec[0])
		var fb := Button.new()
		fb.toggle_mode = true
		fb.button_group = _filter_group
		fb.text = String(spec[1])
		fb.custom_minimum_size = Vector2(74.0, 30.0)
		fb.add_theme_font_size_override("font_size", 12)
		fb.set_meta("filter", fid)
		fb.button_pressed = fid == _filter
		fb.pressed.connect(func() -> void: _set_filter(fid))
		_wire_hover_sfx(fb)
		filter_row.add_child(fb)
		_filter_btns.append(fb)
	for i in _filter_btns.size():
		var fb2: Button = _filter_btns[i]
		if i > 0:
			fb2.focus_neighbor_left = fb2.get_path_to(_filter_btns[i - 1])
		if i < _filter_btns.size() - 1:
			fb2.focus_neighbor_right = fb2.get_path_to(_filter_btns[i + 1])
	_count_label = Label.new()
	_count_label.add_theme_font_size_override("font_size", 12)
	_count_label.add_theme_color_override("font_color", Color("9aa3b2"))
	_count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left_box.add_child(_count_label)
	_achieve_bar = _bar(0.0, 1.0, Color("e8b84b"), 0.0, 10.0)
	_achieve_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_achieve_bar.visible = false
	left_box.add_child(_achieve_bar)
	var left_scroll := ScrollContainer.new()
	left_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_box.add_child(left_scroll)
	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_theme_constant_override("separation", 6)
	left_scroll.add_child(_list_box)
	var right_scroll := ScrollContainer.new()
	right_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	hb.add_child(right_scroll)
	_detail = VBoxContainer.new()
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.add_theme_constant_override("separation", 6)
	right_scroll.add_child(_detail)
	_close_btn = Button.new()
	_close_btn.text = "返 回（Esc）"
	_close_btn.custom_minimum_size = Vector2(0.0, 44.0)
	_close_btn.pressed.connect(_close)
	_wire_hover_sfx(_close_btn)
	root.add_child(_close_btn)
	_select_tab("status", false)

## 切换分类；focus=true 时把焦点交给该分类首个条目（手柄导航）
func _select_tab(tab_id: String, focus := true) -> void:
	var previous_tab := _tab
	_tab = tab_id
	for tb in _tab_btns:
		if String(tb.get_meta("tab")) == tab_id:
			tb.button_pressed = true
			break
	var entries := _entries_for(tab_id)
	var found := false
	for e in entries:
		if String(e.id) == _selected_id:
			found = true
			break
	if not found and not entries.is_empty():
		_selected_id = String(entries[0].id)
	_rebuild_list()
	if focus:
		Sfx.play("ui_page")
		_animate_page(1.0 if _tab_index(tab_id) >= _tab_index(previous_tab) else -1.0)
	if focus:
		_focus_selected()
	Haptics.rumble(0.1, 0.0, 0.04)

func _select_entry(id: String) -> void:
	_selected_id = id
	for b in _list_btns:
		if String(b.get_meta("id")) == id:
			b.button_pressed = true
			break
	_refresh(id)
	Sfx.play("ui_click")
	_animate_page(1.0)
	Haptics.rumble(0.1, 0.0, 0.04)

func _focus_selected() -> void:
	for b in _list_btns:
		if String(b.get_meta("id")) == _selected_id:
			b.grab_focus()
			return
	if not _list_btns.is_empty():
		_list_btns[0].grab_focus()

## 当前分类的条目清单：{ id, ico, name, accent }
func _entries_for(tab_id: String) -> Array:
	var out: Array = []
	match tab_id:
		"status":
			for sid in Config.STATUS:
				var st: Dictionary = Config.STATUS[sid]
				out.append({ "id": String(sid), "ico": String(st.get("ico", "❓")),
					"name": String(st.get("name", sid)),
					"accent": Color(String(st.get("color", "#e8b84b"))) })
		"reaction":
			for r in Registry.reaction_list():
				var rid := String(r.get("id", ""))
				out.append({ "id": rid, "ico": String(r.get("ico", "☯")),
					"name": String(r.get("name", rid)),
					"accent": Config.rarity_color(String(r.get("rarity", "common"))) })
		"weapon":
			for id in Registry.weapons:
				var w: Dictionary = Registry.weapons[id]
				out.append({ "id": String(id), "ico": String(w.get("ico", "🔧")),
					"name": String(w.get("name", id)),
					"accent": Config.rarity_color(String(w.get("rarity", "common"))) })
		"item":
			for it in Registry.item_list():
				out.append({ "id": String(it.get("id", "")), "ico": String(it.get("ico", "🧩")),
					"name": String(it.get("name", "")),
					"accent": Config.rarity_color(String(it.get("rarity", "common"))) })
		"artifact":
			# 按五行分组排序（Registry.artifact_list() 是字典 values，顺序不保证）
			var arts := Registry.artifact_list()
			arts.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
				var ei := Config.ELEMENTS.find(String(x.get("element", "")))
				var ej := Config.ELEMENTS.find(String(y.get("element", "")))
				if ei != ej:
					return ei < ej
				return Config.RARITIES.find(String(x.get("rarity", "common"))) \
					< Config.RARITIES.find(String(y.get("rarity", "common"))))
			for ar in arts:
				out.append({ "id": String(ar.get("id", "")),
					"ico": String(ar.get("ico", "🔮")),
					"name": String(ar.get("name", "")),
					"accent": Config.rarity_color(String(ar.get("rarity", "common"))) })
		"upgrade":
			for up in Registry.upgrade_list():
				out.append({ "id": String(up.get("id", "")), "ico": String(up.get("ico", "✨")),
					"name": String(up.get("name", "")),
					"accent": Config.rarity_color(String(up.get("rarity", "common"))) })
		"enemy":
			for id in Registry.enemies:
				var e: Dictionary = Registry.enemies[id]
				out.append({ "id": String(id), "ico": "👾",
					"name": String(e.get("name", id)),
					"accent": Color(String(e.get("color", "#d9534f"))) })
		"event":
			for ec in Config.EVENT_CARDS:
				out.append({ "id": String(ec.get("id", "")), "ico": String(ec.get("ico", "🎴")),
					"name": String(ec.get("title", "")),
					"accent": Config.rarity_color(String(ec.get("rarity", "common"))) })
		"achieve":
			out.append({ "id": "_stats", "ico": "📊", "name": "统计总览",
				"accent": Color("e8b84b") })
			for id in CodexData.ACHIEVEMENTS:
				var a: Dictionary = CodexData.ACHIEVEMENTS[id]
				var aid := String(id)
				out.append({ "id": aid, "ico": String(a.get("ico", "🏆")),
					"name": String(a.get("name", aid)),
					"accent": Color("e8b84b") if CodexData.achievement_unlocked(aid)
						else Color("5a6270") })
	return out

## 条目是否已达成：成就页用成就状态，其余用图鉴解锁状态；统计总览恒亮
func _entry_unlocked(id: String) -> bool:
	if _tab == "achieve":
		return id == "_stats" or CodexData.achievement_unlocked(id)
	return CodexData.is_unlocked(_tab, id)

func _rebuild_list() -> void:
	for c in _list_box.get_children():
		_list_box.remove_child(c)
		c.queue_free()
	_list_btns.clear()
	var all_entries := _entries_for(_tab)
	if _tab == "achieve":
		_count_label.text = "已达成 %d/%d" % [CodexData.unlocked_achievement_count(),
			CodexData.ACHIEVEMENTS.size()]
		if _achieve_bar != null:
			_achieve_bar.visible = true
			_achieve_bar.max_value = float(maxi(1, CodexData.ACHIEVEMENTS.size()))
			_achieve_bar.value = float(CodexData.unlocked_achievement_count())
	else:
		_count_label.text = "已解锁 %d/%d" % [CodexData.unlocked_count(_tab), all_entries.size()]
		if _achieve_bar != null:
			_achieve_bar.visible = false
	var shown: Array = []
	for e in all_entries:
		var eid := String(e.id)
		var is_unlocked := _entry_unlocked(eid)
		if _filter == "unlocked" and not is_unlocked:
			continue
		if _filter == "locked" and is_unlocked:
			continue
		if not _matches_entry(e, _query):
			continue
		shown.append(e)
	# 选中项被筛掉时，落到首个可见条目
	var keep := false
	for e in shown:
		if String(e.id) == _selected_id:
			keep = true
			break
	if not keep and not shown.is_empty():
		_selected_id = String(shown[0].id)
	for e in shown:
		var eid := String(e.id)
		var locked := not _entry_unlocked(eid)
		var b := Button.new()
		b.toggle_mode = true
		b.button_group = _list_group
		b.custom_minimum_size = Vector2(214.0, 40.0)
		b.text = ("🔒 " if locked else "%s " % String(e.ico)) + String(e.name)
		b.add_theme_font_size_override("font_size", 14)
		var col: Color = Color("5a6270") if locked else e.accent
		b.add_theme_color_override("font_color", col)
		b.add_theme_color_override("font_hover_color", col)
		b.add_theme_color_override("font_pressed_color", col)
		b.add_theme_color_override("font_focus_color", col)
		b.set_meta("id", eid)
		b.pressed.connect(func() -> void: _select_entry(eid))
		_wire_hover_sfx(b)
		if eid == _selected_id:
			b.button_pressed = true
		_list_box.add_child(b)
		_list_btns.append(b)
	if shown.is_empty():
		_list_box.add_child(_empty("没有匹配的条目"))
		_clear_detail("没有匹配的条目")
		return
	for i in _list_btns.size():
		var lb: Button = _list_btns[i]
		if i > 0:
			lb.focus_neighbor_top = lb.get_path_to(_list_btns[i - 1])
		if i < _list_btns.size() - 1:
			lb.focus_neighbor_bottom = lb.get_path_to(_list_btns[i + 1])
	# 手柄焦点链：列表 ↑ → 当前筛选按钮 ↑ → 当前分类标签
	var active_filter: Button = _active_filter_btn()
	var active_tab: Button = null
	for tb in _tab_btns:
		if String(tb.get_meta("tab")) == _tab:
			active_tab = tb
			break
	if active_filter != null:
		if active_tab != null:
			active_filter.focus_neighbor_top = active_filter.get_path_to(active_tab)
			active_tab.focus_neighbor_bottom = active_tab.get_path_to(active_filter)
		if _search_edit != null:
			_search_edit.focus_neighbor_bottom = _search_edit.get_path_to(active_filter)
		if not _list_btns.is_empty():
			var first: Button = _list_btns[0]
			active_filter.focus_neighbor_bottom = active_filter.get_path_to(first)
			first.focus_neighbor_top = first.get_path_to(active_filter)
	if _close_btn != null and not _list_btns.is_empty():
		_close_btn.focus_neighbor_top = _close_btn.get_path_to(_list_btns[_list_btns.size() - 1])
	_refresh(_selected_id)

func _matches_entry(e: Dictionary, q: String) -> bool:
	if q == "":
		return true
	if String(e.name).to_lower().find(q) >= 0:
		return true
	return String(e.id).to_lower().find(q) >= 0

func _clear_detail(text: String) -> void:
	for c in _detail.get_children():
		_detail.remove_child(c)
		c.queue_free()
	_detail.add_child(_empty(text))

func _active_filter_btn() -> Button:
	for b in _filter_btns:
		if String(b.get_meta("filter", "")) == _filter:
			return b
	return _filter_btns[0] if not _filter_btns.is_empty() else null

func _set_filter(fid: String) -> void:
	_filter = fid
	for b in _filter_btns:
		if String(b.get_meta("filter", "")) == fid:
			b.button_pressed = true
			break
	_rebuild_list()
	Sfx.play("ui_click")
	_animate_page(1.0)
	_focus_selected()
	Haptics.rumble(0.1, 0.0, 0.04)

func _on_search_changed(text: String) -> void:
	_query = text.strip_edges().to_lower()
	_rebuild_list()

func _refresh(id: String) -> void:
	for c in _detail.get_children():
		_detail.remove_child(c)
		c.queue_free()
	if _tab == "achieve":
		if id == "_stats":
			_detail_stats()
		else:
			_detail_achievement(id)
		return
	if id == "" or not CodexData.is_unlocked(_tab, id):
		_detail_locked(id)
		return
	match _tab:
		"status": _detail_status(id)
		"reaction": _detail_reaction(id)
		"weapon": _detail_weapon(id)
		"item": _detail_item(id)
		"artifact": _detail_artifact(id)
		"upgrade": _detail_upgrade(id)
		"enemy": _detail_enemy(id)
		"event": _detail_event(id)

# ---------------- 成就 / 统计详情 ----------------

func _detail_achievement(id: String) -> void:
	var a: Dictionary = CodexData.ACHIEVEMENTS.get(id, {})
	if a.is_empty():
		return
	var unlocked := CodexData.achievement_unlocked(id)
	var accent: Color = Color("e8b84b") if unlocked else Color("5a6270")
	_detail.add_child(_header(String(a.get("ico", "🏆")), String(a.get("name", id)), accent,
		String(a.get("desc", ""))))
	_detail.add_child(_section("进度"))
	var cur := CodexData.achievement_progress(id)
	var tgt := CodexData.achievement_target(id)
	_detail.add_child(_bar(float(cur), float(tgt), Color("e8b84b")))
	_detail.add_child(_stat_row(String(CodexData.STAT_NAMES.get(String(a.get("stat", "")), "进度")),
		"%d / %d" % [cur, tgt]))
	_detail.add_child(_stat_row("奖励", "✦ %d 土豆精华%s" % [CodexData.achievement_reward(id),
		"（已发放）" if unlocked else "（达成后发放）"]))
	_detail.add_child(_stat_row("状态", "✅ 已达成" if unlocked else "未达成 · 继续战斗即可推进"))

func _detail_stats() -> void:
	_detail.add_child(_header("📊", "统计总览", Color("e8b84b"),
		"跨局累计数据 · 随存档持久化（user://codex.json）"))
	_detail.add_child(_section("完成度"))
	_detail.add_child(_progress_row("成就",
		float(CodexData.unlocked_achievement_count()), float(CodexData.ACHIEVEMENTS.size()),
		Color("e8b84b")))
	for cat in CodexData.CATEGORIES:
		var cat_col: Color = CAT_COLORS.get(cat, Color("9aa3b2"))
		_detail.add_child(_progress_row(String(CodexData.CAT_NAMES.get(cat, cat)),
			float(CodexData.unlocked_count(String(cat))),
			float(CodexData.total_entries(String(cat))), cat_col))
	_detail.add_child(_section("战斗"))
	for key in ["kills", "boss_kills", "waves", "best_wave", "status_triggers", "reactions"]:
		_detail.add_child(_stat_row(String(CodexData.STAT_NAMES.get(key, key)),
			str(CodexData.stat(key))))
	_detail.add_child(_section("成长与收集"))
	for key in ["runs", "victories", "evolutions", "purchases", "best_score"]:
		_detail.add_child(_stat_row(String(CodexData.STAT_NAMES.get(key, key)),
			str(CodexData.stat(key))))
	_detail.add_child(_section("图鉴解锁"))
	for cat in CodexData.CATEGORIES:
		_detail.add_child(_stat_row(String(CodexData.CAT_NAMES.get(cat, cat)),
			"%d / %d" % [CodexData.unlocked_count(String(cat)),
				CodexData.total_entries(String(cat))]))
	_detail.add_child(_stat_row("图鉴奖励", "✦ %d 精华" % CodexData.unlock_essence_total()))
	_detail.add_child(_section("成就"))
	_detail.add_child(_stat_row("已达成", "%d / %d" % [CodexData.unlocked_achievement_count(),
		CodexData.ACHIEVEMENTS.size()]))
	_detail.add_child(_stat_row("成就奖励", "✦ %d 精华" % CodexData.achievement_essence_total()))
	_detail.add_child(_section("下一目标"))
	var next_id := _next_achievement_id()
	if next_id == "":
		_detail.add_child(_empty("全部成就已达成 🎉"))
	else:
		var na: Dictionary = CodexData.ACHIEVEMENTS[next_id]
		var np := CodexData.achievement_progress(next_id)
		var nt := CodexData.achievement_target(next_id)
		_detail.add_child(_stat_row("%s %s" % [String(na.get("ico", "🏆")),
			String(na.get("name", next_id))], "还差 %d" % maxi(0, nt - np)))
		_detail.add_child(_bar(float(np), float(nt), Color("e8b84b"), 560.0, 14.0))

## 最接近达成的未完成成就（用于"下一目标"图表）
func _next_achievement_id() -> String:
	var best := ""
	var best_ratio := -1.0
	for id in CodexData.ACHIEVEMENTS:
		var aid := String(id)
		if CodexData.achievement_unlocked(aid):
			continue
		var tgt := CodexData.achievement_target(aid)
		var ratio := float(CodexData.achievement_progress(aid)) / float(maxi(1, tgt))
		if ratio > best_ratio:
			best_ratio = ratio
			best = aid
	return best

## 未解锁条目：灰态占位 + 解锁条件提示（避免直接剧透数值）
func _detail_locked(id: String) -> void:
	var entry: Dictionary = {}
	for e in _entries_for(_tab):
		if String(e.id) == id:
			entry = e
			break
	var name_s := String(entry.get("name", id))
	_detail.add_child(_header("🔒", name_s, Color("5a6270"), "尚未解锁 · 图鉴条目"))
	_detail.add_child(_section("解锁条件"))
	var hint: Label = _empty(String(LOCK_HINTS.get(_tab, "在游戏中首次接触即可解锁")))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(560.0, 0.0)
	_detail.add_child(hint)
	if CodexData.unlock_reward(_tab) > 0:
		_detail.add_child(_stat_row("解锁奖励",
			"✦ %d 土豆精华" % CodexData.unlock_reward(_tab)))

# ---------------- 状态详情 ----------------

func _detail_status(sid: String) -> void:
	var st: Dictionary = Config.STATUS.get(sid, {})
	if st.is_empty():
		return
	var col := Color(String(st.get("color", "#e8b84b")))
	_detail.add_child(_header(String(st.get("ico", "❓")), String(st.get("name", sid)), col,
		String(st.get("desc", ""))))
	_detail.add_child(_section("状态数值"))
	_detail.add_child(_stat_row("持续时长", "%.1f 秒" % float(st.get("duration", 0.0))))
	var tick := float(st.get("tick", 0.0))
	_detail.add_child(_stat_row("跳伤间隔", ("每 %.1f 秒" % tick) if tick > 0.0 else "无持续伤害"))
	var pct := float(st.get("dot_max_hp_pct", 0.0))
	var scale := float(st.get("dot_scale", 0.0))
	var tick_desc := "无"
	if pct > 0.0:
		tick_desc = "最大生命 %.1f%% × 层数" % (pct * 100.0)
	elif scale > 0.0:
		tick_desc = "施加伤害 × %.2f × 层数" % scale
	_detail.add_child(_stat_row("每跳伤害", tick_desc))
	_detail.add_child(_stat_row("层数上限", "×%d" % int(st.get("stack_max", 1))))
	var fx: Array = []
	var spd := float(st.get("speed_mult", 1.0))
	if spd <= 0.001:
		fx.append("定身")
	elif spd < 1.0:
		fx.append("移速 x%.2f" % spd)
	var dt := float(st.get("dmg_taken_mult", 1.0))
	if dt > 1.0:
		fx.append("受到伤害 +%d%%" % roundi((dt - 1.0) * 100.0))
	_detail.add_child(_stat_row("附加效果", " · ".join(fx) if not fx.is_empty() else "无"))
	var src: Dictionary = Registry.status_sources(sid)
	var wlist: Array = src.get("weapons", [])
	var ilist: Array = src.get("items", [])
	var blist: Array = src.get("boosts", [])
	_detail.add_child(_section("施加来源 · 武器（%d）" % wlist.size()))
	if wlist.is_empty():
		_detail.add_child(_empty("暂无武器可施加该状态"))
	for w in wlist:
		var right := "命中 %d%%" % roundi(float(w.get("chance", 1.0)) * 100.0)
		if int(w.get("stacks", 1)) > 1:
			right += " · %d 层" % int(w.get("stacks", 1))
		_detail.add_child(_row(String(w.get("ico", "🔧")), String(w.get("name", w.get("id", ""))),
			Config.rarity_color(String(w.get("rarity", "common"))), String(w.get("desc", "")), right))
	_detail.add_child(_section("施加来源 · 道具（%d）" % ilist.size()))
	if ilist.is_empty():
		_detail.add_child(_empty("暂无道具可施加该状态"))
	for it in ilist:
		_detail.add_child(_row(String(it.get("ico", "🧩")), String(it.get("name", it.get("id", ""))),
			Config.rarity_color(String(it.get("rarity", "common"))), String(it.get("desc", "")),
			"命中 %d%%" % roundi(float(it.get("chance", 0.0)) * 100.0)))
	_detail.add_child(_section("强化来源 · 道具/升级（%d）" % blist.size()))
	if blist.is_empty():
		_detail.add_child(_empty("暂无强化来源"))
	for b in blist:
		var eff: Dictionary = b.get("effects", {})
		var parts: Array = []
		if eff.has("status_chance"):
			parts.append("命中 +%d%%" % roundi(float(eff["status_chance"]) * 100.0))
		if eff.has("status_dmg_mult"):
			parts.append("伤害 +%d%%" % roundi(float(eff["status_dmg_mult"]) * 100.0))
		if eff.has("status_dur_mult"):
			parts.append("时长 +%d%%" % roundi(float(eff["status_dur_mult"]) * 100.0))
		if eff.has("status_spread"):
			parts.append("中毒传染")
		_detail.add_child(_row(String(b.get("ico", "✨")),
			"[%s] %s" % [String(b.get("kind", "强化")), String(b.get("name", b.get("id", "")))],
			Config.rarity_color(String(b.get("rarity", "common"))), String(b.get("desc", "")),
			" · ".join(parts)))

# ---------------- 五行反应详情 ----------------

func _detail_reaction(id: String) -> void:
	var r: Dictionary = Registry.reactions.get(id, {})
	if r.is_empty():
		return
	var accent := Config.rarity_color(String(r.get("rarity", "common")))
	var overcome := String(r.get("type", "")) == "overcome"
	_detail.add_child(_header(String(r.get("ico", "☯")), String(r.get("name", id)), accent,
		String(r.get("desc", ""))))
	_detail.add_child(_section("基础信息"))
	_detail.add_child(_stat_row("类型", "相克（爆发）" if overcome else "相生（增强）"))
	_detail.add_child(_stat_row("稀有度", Config.rarity_name(String(r.get("rarity", "common")))))
	_detail.add_child(_stat_row("层数消耗", "消耗参与状态层数" if overcome else "不消耗"))
	_detail.add_child(_stat_row("震屏强度", "%.1f" % float(r.get("shake", 0.0))))
	_detail.add_child(_section("五行组合"))
	var elems := _reaction_elements(r)
	if elems.size() != 2:
		_detail.add_child(_empty("该反应未声明五行组合"))
	for e in elems:
		_detail.add_child(_stat_row(String(e),
			String(Config.ELEMENT_NAME.get(String(e), String(e)))))
	_detail.add_child(_section("触发状态"))
	var sids := _reaction_statuses(elems)
	if sids.is_empty():
		_detail.add_child(_empty("无对应状态"))
	for sid in sids:
		var st: Dictionary = Config.STATUS.get(String(sid), {})
		_detail.add_child(_row(String(st.get("ico", "❓")),
			"%s · %s系" % [String(st.get("name", sid)),
				String(Config.ELEMENT_NAME.get(Config.get_element(String(sid)), "?"))],
			Color(String(st.get("color", "#e8b84b"))), String(st.get("desc", "")), ""))
	_detail.add_child(_section("效果明细"))
	var lines := _reaction_effect_lines(r.get("effect", {}))
	if lines.is_empty():
		_detail.add_child(_empty("无效果"))
	for ln in lines:
		var l := Label.new()
		l.text = "· " + String(ln)
		l.add_theme_font_size_override("font_size", 13)
		l.add_theme_color_override("font_color", Color("d8dde6"))
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_detail.add_child(l)
	var related := _reaction_related(r, elems)
	if not related.is_empty():
		_detail.add_child(_section("共用五行的其他反应（%d）" % related.size()))
		for o in related:
			_detail.add_child(_row(String(o.get("ico", "☯")), String(o.get("name", "")),
				Config.rarity_color(String(o.get("rarity", "common"))),
				String(o.get("desc", "")),
				"相克" if String(o.get("type", "")) == "overcome" else "相生"))

## 反应涉及的两个五行（从 key "elemA+elemB" 解析）
func _reaction_elements(r: Dictionary) -> Array:
	var key := String(r.get("key", ""))
	return [] if key == "" else key.split("+")

## 归属指定五行的全部状态 id（freeze / slow 同属水，两个都会列出）
func _reaction_statuses(elems: Array) -> Array:
	var out: Array = []
	for sid in Config.STATUS_ELEMENT:
		if elems.has(String(Config.STATUS_ELEMENT[sid])):
			out.append(String(sid))
	return out

## 与当前反应共用任一五行的其他反应
func _reaction_related(r: Dictionary, elems: Array) -> Array:
	var out: Array = []
	var self_id := String(r.get("id", ""))
	for other in Registry.reaction_list():
		var oid := String(other.get("id", ""))
		if oid == "" or oid == self_id:
			continue
		for e in String(other.get("key", "")).split("+"):
			if elems.has(String(e)):
				out.append(other)
				break
	return out

## effect 字典 → 中文效果行
func _reaction_effect_lines(eff: Variant) -> Array:
	var out: Array = []
	if typeof(eff) != TYPE_DICTIONARY:
		return out
	var e: Dictionary = eff
	for k in e:
		var key := String(k)
		var v: Variant = e[k]
		match key:
			"add_stacks": out.append("叠加层数：%s" % _status_amount_list(v))
			"duration_add": out.append("延长时长（秒）：%s" % _status_amount_list(v))
			"duration_mult": out.append("时长倍率：%s" % _status_amount_list(v))
			"dmg_mult": out.append("伤害倍率：%s" % _status_amount_list(v))
			"crit_guarantee": out.append("必定暴击：%s" % _status_name_list(v))
			"spread": out.append("扩散半径：%s" % _status_amount_list(v))
			"consume": out.append("消耗层数：%s" % _status_amount_list(v))
			"convert_dmg":
				if typeof(v) == TYPE_DICTIONARY:
					for sid in v:
						out.append("%s 伤害转为 %s"
							% [_status_name(sid), _status_name(v[sid])])
			"aoe_dmg_scale": out.append("范围伤害 = 状态强度合计 x%.1f" % float(v))
			"aoe_radius": out.append("范围半径 %.0f" % float(v))
			"execute_threshold": out.append("目标生命低于 %d%% 时直接碎裂"
				% roundi(float(v) * 100.0))
			"armor_break": out.append("目标受到伤害 +%d%%" % roundi(float(v) * 100.0))
			"armor_break_duration": out.append("上述易伤持续 %.1f 秒" % float(v))
			"dot_mult": out.append("持续伤害 x%.1f" % float(v))
			"dot_duration": out.append("持续伤害强化 %.1f 秒" % float(v))
			_: out.append("%s: %s" % [key, str(v)])
	return out

## 状态显示名（图标 + 中文名）
func _status_name(sid: Variant) -> String:
	var st: Dictionary = Config.STATUS.get(String(sid), {})
	return "%s%s" % [String(st.get("ico", "")), String(st.get("name", sid))]

## {状态: 数值} → “🔥燃烧 ×2、💫眩晕 ×1”
func _status_amount_list(v: Variant) -> String:
	if typeof(v) != TYPE_DICTIONARY:
		return str(v)
	var parts: Array = []
	for sid in v:
		parts.append("%s ×%s" % [_status_name(sid), _num_text(v[sid])])
	return "、".join(parts)

## {状态: 任意} → 只列状态名
func _status_name_list(v: Variant) -> String:
	if typeof(v) != TYPE_DICTIONARY:
		return str(v)
	var parts: Array = []
	for sid in v:
		parts.append(_status_name(sid))
	return "、".join(parts)

func _num_text(v: Variant) -> String:
	var f := float(v)
	return str(int(f)) if is_equal_approx(f, float(int(f))) else "%.1f" % f

# ---------------- 武器详情 ----------------

func _detail_weapon(id: String) -> void:
	if not Registry.weapons.has(id):
		return
	var w: Dictionary = Registry.weapons[id]
	var accent := Config.rarity_color(String(w.get("rarity", "common")))
	_detail.add_child(_header(String(w.get("ico", "🔧")), String(w.get("name", id)), accent,
		String(w.get("desc", ""))))
	_detail.add_child(_section("基础属性"))
	_detail.add_child(_stat_row("稀有度", Config.rarity_name(String(w.get("rarity", "common")))))
	var melee := String(w.get("attack_type", "projectile")) == "melee"
	_detail.add_child(_stat_row("攻击类型", "近战" if melee else "远程"))
	_detail.add_child(_stat_row("基础伤害", "%.1f" % float(w.get("dmg", 0.0))))
	_detail.add_child(_stat_row("冷却", "%.2f 秒" % float(w.get("cd", 0.0))))
	if melee:
		_detail.add_child(_stat_row("范围 / 扇角", "%.0f / %.2f 弧度"
			% [float(w.get("range", 0.0)), float(w.get("swing_arc", 0.0))]))
	else:
		_detail.add_child(_stat_row("弹速 / 弹丸", "%.0f / %d"
			% [float(w.get("bspeed", 0.0)), int(w.get("pellets", 1))]))
		if float(w.get("splash", 0.0)) > 0.0:
			_detail.add_child(_stat_row("爆炸半径", "%.0f" % float(w.get("splash", 0.0))))
	_detail.add_child(_stat_row("商店价格", "%d ◆" % int(w.get("price", 30))))
	var sid := String(w.get("status", ""))
	if sid != "" and Config.STATUS.has(sid):
		var st: Dictionary = Config.STATUS[sid]
		_detail.add_child(_section("施加状态"))
		_detail.add_child(_row(String(st.get("ico", "❓")), String(st.get("name", sid)),
			Color(String(st.get("color", "#e8b84b"))), String(st.get("desc", "")),
			"命中 %d%% · %d 层" % [roundi(float(w.get("status_chance", 1.0)) * 100.0),
				int(w.get("status_stacks", 1))]))
	var need := int(w.get("evolve_need", 0))
	var branches: Array = w.get("evolve_branches", [])
	if branches.is_empty() and Registry.weapons.has(String(w.get("evolve_to", ""))):
		branches = [String(w.get("evolve_to", ""))]
	if need > 0 and not branches.is_empty():
		_detail.add_child(_section("进化"))
		for b in branches:
			if not Registry.weapons.has(String(b)):
				continue
			var evo: Dictionary = Registry.weapons[String(b)]
			_detail.add_child(_row(String(evo.get("ico", "🔧")), String(evo.get("name", "")),
				Config.rarity_color(String(evo.get("rarity", "common"))), String(evo.get("desc", "")),
				"持有 %d 把进化分支" % need))

# ---------------- 道具 / 升级详情 ----------------

func _detail_item(id: String) -> void:
	if not Registry.items.has(id):
		return
	_detail_effects_entry(Registry.items[id], "道具")

func _detail_upgrade(id: String) -> void:
	if not Registry.upgrades.has(id):
		return
	_detail_effects_entry(Registry.upgrades[id], "升级")

## 法宝详情：与道具/升级不同，法宝没有 effects 属性表，而是「触发条件 + 效果载荷」，
## 所以不能走 _detail_effects_entry，逐段展开 trigger / params / effect
func _detail_artifact(id: String) -> void:
	var a := Registry.get_artifact(id)
	if a.is_empty():
		return
	var accent := Config.rarity_color(String(a.get("rarity", "common")))
	_detail.add_child(_header(String(a.get("ico", "🔮")), String(a.get("name", id)), accent,
		String(a.get("desc", ""))))
	_detail.add_child(_section("基础信息"))
	_detail.add_child(_stat_row("类别", "法宝"))
	_detail.add_child(_stat_row("五行", String(Config.ELEMENT_NAME.get(
		String(a.get("element", "")), "-"))))
	_detail.add_child(_stat_row("稀有度",
		Config.rarity_name(String(a.get("rarity", "common")))))
	_detail.add_child(_stat_row("价格", "%d ◆" % int(a.get("price", 110))))
	_detail.add_child(_stat_row("触发时机", String(ARTIFACT_TRIGGER_NAMES.get(
		String(a.get("trigger", "")), String(a.get("trigger", "-"))))))
	# 触发过滤条件：params 为空 = 不限（如潮汐珠任意受击、建木枝每波）
	var params: Dictionary = a.get("params", {})
	_detail.add_child(_section("触发条件"))
	if params.is_empty():
		_detail.add_child(_empty("无额外限制（该时机任意触发）"))
	for k in params:
		_detail.add_child(_stat_row(String(ARTIFACT_PARAM_NAMES.get(String(k), String(k))),
			_artifact_value(String(k), params[k])))
	_detail.add_child(_section("效果"))
	var effect: Dictionary = a.get("effect", {})
	if effect.is_empty():
		_detail.add_child(_empty("无效果"))
	for k in effect:
		_detail.add_child(_stat_row(String(ARTIFACT_EFFECT_NAMES.get(String(k), String(k))),
			_artifact_value(String(k), effect[k])))
	_detail.add_child(_section("获取渠道"))
	_detail.add_child(_stat_row("精英击杀", "%d%% 掉落" % roundi(
		Config.ARTIFACT_ELITE_DROP_CHANCE * 100.0)))
	_detail.add_child(_stat_row("BOSS", "必掉（传说权重 ×%s）"
		% str(Config.ARTIFACT_BOSS_LEGENDARY_MULT)))
	_detail.add_child(_stat_row("商店", "%d%% 概率占一格" % roundi(
		Config.ARTIFACT_SHOP_CHANCE * 100.0)))
	_detail.add_child(_stat_row("重复获得", "+%d ◆ 材料补偿" % Config.ARTIFACT_DUP_MATERIALS))

## 法宝 params/effect 的值转人话：百分比/倍率/秒数按语义格式化，
## 状态与反应 id 转中文名，patch 这类嵌套字典展开为逐行子条目
func _artifact_value(k: String, v: Variant) -> String:
	# 注意：GDScript 的 match 多值模式不能跨行续行（会报
	# "Expected expression for match pattern"），所以百分比类键拆成两组单行
	match k:
		"chance", "bonus_dmg_pct", "heal_pct", "hp_below":
			return "%d%%" % roundi(float(v) * 100.0)
		"low_hp_dmg_reduce", "high_hp", "low_hp":
			return "%d%%" % roundi(float(v) * 100.0)
		"dmg_mult":
			return "×%.2f" % float(v)
		"duration":
			return "%.1f 秒" % float(v)
		"radius":
			return "%.0f 像素" % float(v)
		"apply_status", "status":
			return String(Config.STATUS.get(String(v), {}).get("name", v))
		"element":
			return String(Config.ELEMENT_NAME.get(String(v), v))
		"key":
			return _reaction_name_by_key(String(v))
		"stat":
			return _artifact_stat_label(String(v))
		"stack_reset":
			return "每波开始" if String(v) == "wave" else "仅局终"
		"patch":
			return _patch_summary(v)
	return str(v)

## 叠层属性中文名：目前只有断刃锋（暴击率）与玄武核（护甲）两件，
## 未知键回退英文（mod 可注册其他属性，不强行穷举）
func _artifact_stat_label(s: String) -> String:
	match s:
		"crit_ch": return "暴击率"
		"armor": return "护甲"
		"max_hp": return "生命上限"
		"dmg_mult": return "伤害倍率"
	return s

## 反应 key（如 "fire+metal"）→ 反应名；mod 覆盖同 key 反应时取注册表里的当前值
func _reaction_name_by_key(rkey: String) -> String:
	for rid in Registry.reactions:
		var r: Dictionary = Registry.reactions[rid]
		if String(r.get("key", "")) == rkey:
			return "%s（%s）" % [String(r.get("name", rid)), rkey]
	return rkey

## patch 类法宝（熔金炉/孢心/落魂钟/蛟皇目）的改写内容展开为可读行
func _patch_summary(v: Variant) -> String:
	if typeof(v) != TYPE_DICTIONARY:
		return str(v)
	var parts: Array = []
	for op in v:
		if typeof(v[op]) != TYPE_DICTIONARY:
			continue
		var verb := "设为" if String(op) == "set" else "增加"
		for key in v[op]:
			var raw: Variant = v[op][key]
			if typeof(raw) == TYPE_DICTIONARY:
				for sub in raw:
					parts.append("%s %s·%s = %s" % [verb, String(key), String(sub),
						_artifact_value(String(sub), raw[sub])])
			else:
				parts.append("%s %s = %s" % [verb, String(key),
					_artifact_value(String(key), raw)])
	return "；".join(parts) if not parts.is_empty() else str(v)

func _detail_effects_entry(data: Dictionary, kind: String) -> void:
	var accent := Config.rarity_color(String(data.get("rarity", "common")))
	_detail.add_child(_header(String(data.get("ico", "🧩")), String(data.get("name", "")), accent,
		String(data.get("desc", ""))))
	_detail.add_child(_section("基础信息"))
	_detail.add_child(_stat_row("类别", kind))
	_detail.add_child(_stat_row("稀有度", Config.rarity_name(String(data.get("rarity", "common")))))
	_detail.add_child(_stat_row("价格", "%d ◆" % int(data.get("price", 30))))
	_detail.add_child(_section("效果"))
	var lines := _effect_lines(data.get("effects", {}))
	if lines.is_empty():
		_detail.add_child(_empty("无属性效果"))
	for ln in lines:
		var l := Label.new()
		l.text = "· " + String(ln)
		l.add_theme_font_size_override("font_size", 13)
		l.add_theme_color_override("font_color", Color("d8dde6"))
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_detail.add_child(l)
	var eff: Dictionary = data.get("effects", {})
	var related: Array = []
	for sid in Config.STATUS:
		if float(eff.get("on_hit_" + String(sid), 0.0)) > 0.0:
			related.append(String(sid))
	if not related.is_empty():
		_detail.add_child(_section("关联状态"))
		for sid2 in related:
			var st: Dictionary = Config.STATUS[sid2]
			_detail.add_child(_row(String(st.get("ico", "❓")), String(st.get("name", sid2)),
				Color(String(st.get("color", "#e8b84b"))), String(st.get("desc", "")),
				"命中 %d%%" % roundi(float(eff["on_hit_" + sid2]) * 100.0)))

## effects 字典 → 中文效果行（图鉴/升级/道具共用）
func _effect_lines(effects: Dictionary) -> Array:
	var out: Array = []
	for k in effects:
		var key := String(k)
		var v := float(effects[k])
		match key:
			"max_hp": out.append("最大生命 +%.0f" % v)
			"regen": out.append("生命回复 +%.1f / 秒" % v)
			"armor": out.append("护甲 +%.0f" % v)
			"dodge": out.append("闪避 +%d%%" % roundi(v * 100.0))
			"dmg_mult": out.append("伤害 +%d%%" % roundi(v * 100.0))
			"as_mult": out.append("攻速 +%d%%" % roundi(v * 100.0))
			"crit_ch": out.append("暴击率 +%d%%" % roundi(v * 100.0))
			"crit_mult": out.append("暴击伤害 +%d%%" % roundi(v * 100.0))
			"speed_mult": out.append("移速 +%d%%" % roundi(v * 100.0))
			"base_speed": out.append("基础移速 +%.0f" % v)
			"pickup_range": out.append("拾取范围 +%.0f" % v)
			"harvesting": out.append("收获率 +%d%%" % roundi(v * 100.0))
			"lifesteal": out.append("击杀回复 +%.0f" % v)
			"heal_flat": out.append("最大生命 +%.0f（并立即回复）" % v)
			"heal_pct": out.append("立即回复最大生命 %d%%" % roundi(v * 100.0))
			"status_chance": out.append("异常命中率 +%d%%" % roundi(v * 100.0))
			"status_dmg_mult": out.append("状态伤害 +%d%%" % roundi(v * 100.0))
			"status_dur_mult": out.append("异常时长 +%d%%" % roundi(v * 100.0))
			"status_spread": out.append("中毒目标死亡时传染")
			_:
				if key.begins_with("on_hit_"):
					var sid3 := key.trim_prefix("on_hit_")
					var st2: Dictionary = Config.status_cfg(sid3)
					if not st2.is_empty():
						out.append("命中 %d%% 施加%s" % [roundi(v * 100.0), String(st2.get("name", sid3))])
					else:
						out.append("%s +%d%%" % [key, roundi(v * 100.0)])
				else:
					out.append("%s +%.2f" % [key, v])
	return out

# ---------------- 敌人详情 ----------------

func _detail_enemy(id: String) -> void:
	if not Registry.enemies.has(id):
		return
	var e: Dictionary = Registry.enemies[id]
	var accent := Color(String(e.get("color", "#d9534f")))
	var boss := _enemy_is_boss(e)
	_detail.add_child(_header("👾", String(e.get("name", id)), accent, "BOSS" if boss else "普通敌人"))
	_detail.add_child(_section("基础属性"))
	_detail.add_child(_stat_row("生命", "%.0f" % float(e.get("hp", 0.0))))
	_detail.add_child(_stat_row("移速", "%.0f" % float(e.get("speed", 0.0))))
	_detail.add_child(_stat_row("接触伤害", "%.0f" % float(e.get("dmg", 0.0))))
	var shape := String(e.get("shape", "circle"))
	_detail.add_child(_stat_row("半径 / 形状", "%.0f / %s"
		% [float(e.get("r", 0.0)), String(SHAPE_NAMES.get(shape, shape))]))
	var ai := String(e.get("ai", "chaser"))
	_detail.add_child(_stat_row("AI 行为", String(AI_NAMES.get(ai, ai))))
	_detail.add_child(_stat_row("经验 / 材料", "%d / %d" % [int(e.get("xp", 0)), int(e.get("mat", 0))]))
	_detail.add_child(_stat_row("红心掉率", "%d%%" % roundi(float(e.get("heart_chance", 0.0)) * 100.0)))
	_detail.add_child(_stat_row("状态抗性", "%d%%" % roundi(float(e.get("status_resist", 0.0)) * 100.0)))
	_detail.add_child(_section("出现波次"))
	_detail.add_child(_stat_row("常规", _enemy_waves(id)))
	if boss:
		var btitle := String(Config.BOSS_TITLES.get(id, ""))
		if btitle != "":
			_detail.add_child(_stat_row("BOSS 称号", btitle))

func _enemy_is_boss(e: Dictionary) -> bool:
	return bool(e.get("is_boss", false)) or String(e.get("ai", "")) == "boss"

## 敌人出现波次：内置刷怪表 1~10 波 + 事件/BOSS/精英池兜底说明
func _enemy_waves(id: String) -> String:
	var waves: Array = []
	for w in range(1, Config.WAVES_TOTAL + 1):
		for entry in Registry.wave_composition(w):
			if typeof(entry) == TYPE_DICTIONARY and String(entry.get("item", "")) == id:
				waves.append(str(w))
				break
	if not waves.is_empty():
		return "第 %s 波" % ", ".join(waves)
	if id == "chest_guard":
		return "宝箱守卫事件波"
	for entry2 in Config.ELITE_POOL:
		if typeof(entry2) == TYPE_DICTIONARY and String(entry2.get("item", "")) == id:
			return "精英替换池（第 4 波起）"
	if Config.BOSS_POOL.has(id):
		return "BOSS 轮换池（第 10 波 / 无尽每 10 波）"
	if Registry.enemies.has(id) and _enemy_is_boss(Registry.enemies[id]):
		return "BOSS（创意工坊 / 特殊事件）"
	return "特殊事件 / 创意工坊"

## 奇遇详情（Phase 4）：地域 / 品阶 / 触发规则 / 三种抉择
func _detail_event(id: String) -> void:
	var ec := Config.event_card(id)
	if ec.is_empty():
		return
	var accent: Color = Config.rarity_color(String(ec.get("rarity", "common")))
	var theme_id := String(ec.get("theme", ""))
	_detail.add_child(_header(String(ec.get("ico", "🎴")), String(ec.get("title", id)),
		accent, Config.map_theme_name(theme_id)))
	_detail.add_child(_section("触景"))
	var d := Label.new()
	d.text = String(ec.get("desc", ""))
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	d.add_theme_font_size_override("font_size", 13)
	d.add_theme_color_override("font_color", Color("9aa3b2"))
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail.add_child(d)
	_detail.add_child(_section("奇遇信息"))
	_detail.add_child(_stat_row("地域", Config.map_theme_name(theme_id)))
	_detail.add_child(_stat_row("品阶", Config.rarity_name(String(ec.get("rarity", "common")))))
	_detail.add_child(_stat_row("触发", "商店关闭后 %d%% · 每局 %d~%d 次"
		% [roundi(Config.EVENT_CARD_CHANCE * 100.0),
		Config.EVENT_CARD_MIN, Config.EVENT_CARD_MAX]))
	_detail.add_child(_section("三种抉择"))
	var choices: Array = ec.get("choices", [])
	for i in choices.size():
		var ch: Dictionary = choices[i]
		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 2)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var t := Label.new()
		t.text = "%d. %s" % [i + 1, String(ch.get("text", ""))]
		t.add_theme_font_size_override("font_size", 14)
		t.add_theme_color_override("font_color", accent.lightened(0.15))
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(t)
		var h := Label.new()
		h.text = "    " + String(ch.get("hint", ""))
		h.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		h.add_theme_font_size_override("font_size", 12)
		h.add_theme_color_override("font_color", Color("9aa3b2"))
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(h)
		_detail.add_child(row)

# ---------------- 通用小部件 ----------------

func _header(ico: String, name: String, accent: Color, subtitle: String) -> HBoxContainer:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ico_l := Label.new()
	ico_l.text = ico
	ico_l.add_theme_font_size_override("font_size", 28)
	ico_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(ico_l)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 1)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var nm := Label.new()
	nm.text = name
	nm.add_theme_font_size_override("font_size", 21)
	nm.add_theme_color_override("font_color", accent)
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(nm)
	if subtitle != "":
		var sub := Label.new()
		sub.text = subtitle
		sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sub.custom_minimum_size = Vector2(560.0, 0.0)
		sub.add_theme_font_size_override("font_size", 12)
		sub.add_theme_color_override("font_color", Color("9aa3b2"))
		sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(sub)
	head.add_child(box)
	return head

func _section(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", Color("e8b84b"))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _stat_row(name: String, value: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var n := Label.new()
	n.text = name
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	n.add_theme_font_size_override("font_size", 13)
	n.add_theme_color_override("font_color", Color("9aa3b2"))
	n.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(n)
	var v := Label.new()
	v.text = value
	v.add_theme_font_size_override("font_size", 13)
	v.add_theme_color_override("font_color", Color("f2e7c7"))
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(v)
	return row

func _bar(cur: float, maxv: float, color: Color, width := 560.0, height := 18.0) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.max_value = float(maxi(1, roundi(maxv)))
	bar.value = clampf(cur, 0.0, bar.max_value)
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(width, height)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	fill.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("fill", fill)
	var track := StyleBoxFlat.new()
	track.bg_color = Color("2c3340")
	track.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("background", track)
	return bar

## 图表行：名称 + 进度条 + 数值（完成度 / 下一目标）
func _progress_row(name_text: String, cur: float, maxv: float, color: Color) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := Label.new()
	l.text = name_text
	l.custom_minimum_size = Vector2(104.0, 0.0)
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color("9aa3b2"))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(l)
	var bar := _bar(cur, maxv, color, 0.0, 14.0)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(bar)
	var v := Label.new()
	v.text = "%d/%d" % [int(cur), int(maxv)]
	v.custom_minimum_size = Vector2(64.0, 0.0)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_theme_font_size_override("font_size", 13)
	v.add_theme_color_override("font_color", Color("f2e7c7"))
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(v)
	return row

func _row(ico: String, title: String, title_color: Color, desc: String, right: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ico_l := Label.new()
	ico_l.text = ico
	ico_l.custom_minimum_size = Vector2(28.0, 0.0)
	ico_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ico_l.add_theme_font_size_override("font_size", 16)
	ico_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(ico_l)
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 1)
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_l := Label.new()
	name_l.text = title
	name_l.add_theme_font_size_override("font_size", 14)
	name_l.add_theme_color_override("font_color", title_color)
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid.add_child(name_l)
	if desc != "":
		var desc_l := Label.new()
		desc_l.text = desc
		desc_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_l.custom_minimum_size = Vector2(430.0, 0.0)
		desc_l.add_theme_font_size_override("font_size", 11)
		desc_l.add_theme_color_override("font_color", Color("9aa3b2"))
		desc_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mid.add_child(desc_l)
	row.add_child(mid)
	if right != "":
		var right_l := Label.new()
		right_l.text = right
		right_l.add_theme_font_size_override("font_size", 13)
		right_l.add_theme_color_override("font_color", Color("f2e7c7"))
		right_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		right_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(right_l)
	return row

func _empty(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color("5a6270"))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _wire_hover_sfx(control: Control) -> void:
	control.mouse_entered.connect(func() -> void: Sfx.play("ui_hover"))

func _tab_index(tab_id: String) -> int:
	for i in TABS.size():
		if String(TABS[i].id) == tab_id:
			return i
	return 0

func _animate_page(direction: float) -> void:
	if _detail == null:
		return
	if _page_tween != null and _page_tween.is_valid():
		_page_tween.kill()
	_detail.modulate.a = 0.0
	_detail.scale = Vector2(0.985, 0.985)
	_detail.pivot_offset = _detail.size * 0.5
	_detail.rotation = 0.008 * direction
	_page_tween = create_tween()
	_page_tween.set_parallel(true)
	_page_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_page_tween.tween_property(_detail, "modulate:a", 1.0, 0.16)
	_page_tween.tween_property(_detail, "scale", Vector2.ONE, 0.16)
	_page_tween.tween_property(_detail, "rotation", 0.0, 0.16)
