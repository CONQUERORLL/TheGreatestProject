extends Control
## 商店 UI（波末清场后由 main 打开；节点全部代码构建，见 godot-game-ui 技能）
## 功能：4 格商品（武器/道具/升级属性，来自 Registry）+ 锁定 + 刷新 + 回血 + 下一波
## 布局：左侧角色属性面板 ｜ 中间商品 ｜ 右侧已购道具（可按 50% 购入价出售）
## 卡面按稀有度着色：common 白 / rare 蓝 / epic 紫 / mythic 金 / legendary 红
## 输入：鼠标 + 手柄焦点导航（卡片行 ↓ 动作区，动作区 ↑ 第一张可购卡）

var player  # characters/player.gd 引用，由 main 注入
var wave_manager: Node   # systems/wave_manager.gd 引用，由 main 注入
var main: Node           # scripts/main.gd 引用（商店关闭后询问是否先弹江湖奇遇）
var goods: Array = []    # 商品 [{kind, wtype/id, ico, name, desc, rarity, base_price, sold, locked}]
var _affinity_cache: Array = []   # 本次商店的构筑亲和标签（开店时算一次，见 _affinity）

var _reroll_cost := 0
var _wave := 0
var _save_dirty := false    # 有未落盘的商店操作
var _save_pending := false  # 合并写定时器已排队

var _title: Label
var _mat: Label
var _goods_box: HBoxContainer
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
	_next_btn.pressed.connect(next_wave)

# ---------------- 界面构建（代码节点） ----------------

func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.04, 0.05, 0.07, 0.82)   # 模态遮罩（拦截点击到世界）
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, 12)
	add_child(margin)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 14)
	margin.add_child(hb)
	# 左侧：角色属性面板
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
	_goods_box = HBoxContainer.new()
	_goods_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_goods_box.add_theme_constant_override("separation", 8)
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
	# 右侧：已购道具（可出售）
	hb.add_child(_make_side_panel(_make_right_column()))

func _make_side_panel(inner: Control) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(288.0, 0.0)
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

func _make_left_column() -> VBoxContainer:
	_left_box = VBoxContainer.new()
	_left_box.add_theme_constant_override("separation", 4)
	return _left_box

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
	_left_box.add_child(_stat_row("武器", "%d / %d" % [player.weapons.size(), MetaProgress.weapon_slots()]))
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
	if player.artifacts_owned.is_empty() and player.items_owned.is_empty():
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
			asell.custom_minimum_size = Vector2(56.0, 24.0)
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
		var ct := Label.new()
		ct.text = "x%d" % cnt
		ct.add_theme_font_size_override("font_size", 13)
		ct.add_theme_color_override("font_color", Color("f2e7c7"))
		ct.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(ct)
		var sell := Button.new()
		sell.text = "%d◆" % roundi(float(int(it.get("price", 30))) * 0.5)
		sell.custom_minimum_size = Vector2(56.0, 24.0)
		sell.tooltip_text = "出售 1 个（50% 购入价）"
		sell.pressed.connect(_sell.bind(id))
		row.add_child(sell)
		_items_box.add_child(row)

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

# ---------------- 开关与商品 ----------------

## 打开商店（原型 openShop：刷新费 = 8 + wave*3 × 砍价折扣，重掷商品）
func open(shop_wave: int) -> void:
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

## 4 格商品：42% 武器格（满槽则跳过），29% 升级属性，其余道具
## 升级/道具按稀有度加权抽取（品阶越高越稀有，权重随波次小幅提升）
func _roll_goods() -> void:
	goods = []
	_affinity_cache.clear()   # 开店时重算一次构筑亲和（本店期间武器/法宝不会变）
	var weapon_full: bool = player.weapons.size() >= MetaProgress.weapon_slots()
	for _i in 4:
		goods.append(_roll_one(weapon_full))

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
	if not weapon_full and r < Config.WEAPON_SHOP_CHANCE:
		var wt: String = GameRng.weighted_pick(Registry.shop_weapon_pool())
		var c: Dictionary = Registry.weapons[wt]
		return { "kind": "weapon", "wtype": wt, "ico": c.ico, "name": c.name,
			"desc": c.desc, "rarity": c.rarity,
			"base_price": Registry.weapon_price(wt), "synergy": 0,
			"sold": false, "locked": false }
	if r < Config.WEAPON_SHOP_CHANCE + Config.SHOP_UPGRADE_CHANCE:
		var u: Dictionary = GameRng.weighted_pick(_rarity_pool(Registry.upgrade_list()))
		return { "kind": "upgrade", "id": u.id, "ico": u.ico, "name": u.name,
			"desc": u.desc, "rarity": u.get("rarity", "common"),
			"base_price": int(u.get("price", 22)), "synergy": _synergy(u),
			"sold": false, "locked": false }
	var it: Dictionary = GameRng.weighted_pick(_rarity_pool(Registry.item_list()))
	return { "kind": "item", "id": it.id, "ico": it.ico, "name": it.name,
		"desc": it.desc, "rarity": it.rarity,
		"base_price": int(it.price), "synergy": _synergy(it),
		"sold": false, "locked": false }

## 稀有度加权池：[{ item: 条目, w: rarity_weight(稀有度, 当前波次) × 亲和倍率 }]
## 亲和倍率让与当前角色 / 武器相关的条目更容易出现（见 Config.affinity_tags）
func _rarity_pool(entries: Array) -> Array:
	var aff := _affinity()
	var pool: Array = []
	for e in entries:
		var w: float = Config.rarity_weight(String(e.get("rarity", "common")), _wave) \
			* Config.affinity_mult(Config.entry_tags(e), aff)
		pool.append({ "item": e, "w": w })
	return pool

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
	return Config.shop_price(g.base_price, _wave)

func _refresh() -> void:
	# 记录当前焦点所在卡片，重建后优先原位恢复（避免焦点跳回第一张）
	var focus_idx := _focused_card_index()
	_mat.text = "◆ %d" % GameState.materials
	_refresh_left()
	_refresh_right()
	_reroll_btn.text = "刷新 (%d ◆)" % _reroll_cost
	_reroll_btn.disabled = GameState.materials < _reroll_cost
	_heal_btn.text = "回血 50%% (%d ◆)" % Config.SHOP_HEAL_PRICE
	_heal_btn.disabled = GameState.materials < Config.SHOP_HEAL_PRICE \
		or player.hp >= player.stats.max_hp
	_build_goods()
	# 卡片重建会销毁旧焦点节点，重新抓焦保证手柄不断导航
	if visible:
		_grab_focus_near(focus_idx)

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

func _make_good_card(i: int) -> Control:
	var g: Dictionary = goods[i]
	var price := _price_of(g)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(150.0, 238.0)
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
	# 武器显示已拥有数量（同名武器聚合提示）+ 进化进度（如 3/4）
	if g.kind == "weapon":
		var owned := 0
		for w in player.weapons:
			if w.type == g.wtype:
				owned += 1
		if owned > 0:
			name_l.text = "%s  x%d" % [g.name, owned]
		# 进化提示：拥有同名武器时显示进度/预告
		var wcfg: Dictionary = Registry.weapons.get(g.wtype, {})
		var need := int(wcfg.get("evolve_need", 0))
		if need > 0 and owned > 0:
			var ex_name: String = Registry.weapons[wcfg.evolve_to].name
			if owned >= need:
				g.desc = "★ 波末自动进化 → %s" % ex_name
			else:
				g.desc = "进化 %d/%d → %s（再买 %d 把）" % [owned, need, ex_name, need - owned]
	var desc := Label.new()
	# 契合标记：让「这件东西跟你的角色 / 武器是一路的」一眼可见
	if int(g.get("synergy", 0)) > 0:
		desc.text = "✦ 契合当前构筑\n" + String(g.desc)
	else:
		desc.text = String(g.desc)
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(132.0, 0.0)
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
			or (g.kind == "weapon" and player.weapons.size() >= MetaProgress.weapon_slots())
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
	if g.kind == "weapon" and player.weapons.size() >= MetaProgress.weapon_slots():
		return
	# 商店开着期间已通过掉落/事件拿到同一件法宝：直接标售罄且不扣钱。
	# 否则玩家会为一件已拥有的法宝付 110~300 只换回 60 材料补偿（apply_artifact 的重复分支）
	if g.kind == "artifact" and player.artifacts_owned.has(String(g.id)):
		g.sold = true
		_refresh()
		return
	GameState.add_materials(-price)
	g.sold = true
	Haptics.rumble(0.25, 0.0, 0.08)   # 手柄确认轻震
	Sfx.play("buy")
	if g.kind == "weapon":
		player.weapons.append({ "type": g.wtype, "cd": 0.1 })
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
func reroll() -> void:
	if GameState.materials < _reroll_cost:
		return
	GameState.add_materials(-_reroll_cost)
	_reroll_cost = _discounted_reroll(roundi(_reroll_cost * 1.4))
	Haptics.rumble(0.25, 0.0, 0.08)
	Sfx.play("reroll")
	var old := goods.duplicate(true)
	var weapon_full: bool = player.weapons.size() >= MetaProgress.weapon_slots()
	goods = []
	for i in 4:
		if old[i].sold or old[i].locked:
			goods.append(old[i])   # 原位保留
		else:
			goods.append(_roll_one(weapon_full))
	_refresh()
	_save_checkpoint()   # 刷新扣费后即时重存

## 回血：15 ◆ 回复 50% 最大生命（原型 btnHeal）
func heal() -> void:
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
	if not SaveRun.save(_wave + 1, player, SaveRun.CHECKPOINT_WAVE_START):
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
		if focus is Button and not focus.disabled:
			focus.pressed.emit()
			get_viewport().set_input_as_handled()
