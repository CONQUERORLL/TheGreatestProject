extends Control
## 游戏 HUD（移植自原型 updateHUD）
## 左上：血条 + 等级/经验条；顶中：波次/计时（BOSS 波显示血量）；
## 右上：材料/击杀；左下：属性行；底中：武器槽（按类型聚合 xN + 空槽补位）；
## 右侧：异常状态图例 + 五行反应折叠页（点标题展开，见 _build_reaction_section）；
## 全屏受击红晕（监听 player_damaged 拉满后淡出）。除折叠页标题外不拦截鼠标。

var player  # characters/player.gd 引用，由 main 注入
var wave_manager: Node   # systems/wave_manager.gd 引用，由 main 注入

var _vignette_a := 0.0
var _weapons_key := ""
var _stats_t := 0.0   # 左下属性行刷新节流（0.2s 一次，属性不逐帧变化）

@onready var _hp_bar: ProgressBar = $TopLeft/Box/HpRow/HpBar
@onready var _hp_text: Label = $TopLeft/Box/HpRow/HpText
@onready var _lv_text: Label = $TopLeft/Box/XpRow/LvText
@onready var _xp_bar: ProgressBar = $TopLeft/Box/XpRow/XpBar
@onready var _wave_text: Label = $Top/WaveText
@onready var _timer_text: Label = $Top/TimerText
@onready var _mat_text: Label = $TopRight/MatText
@onready var _kill_text: Label = $TopRight/KillText
@onready var _top_right: VBoxContainer = $TopRight
@onready var _stats_label: Label = $BottomLeft/StatsText
@onready var _weapons_box: HBoxContainer = $WeaponsBox
@onready var _vignette: ColorRect = $Vignette

var _score_text: Label   # 无尽模式积分（代码追加到右上角）
var _status_panel: PanelContainer   # 右侧异常状态图例（仅显示当前构筑可施加的状态）
var _status_box: VBoxContainer
var _status_key := ""   # 来源签名：武器/道具/加成变化才重建
var _reaction_open := false   # 五行反应表折叠状态（默认收起，点标题展开）
var _bonus_label: Label = null   # 强化加成行（图例末尾又追加了反应节，不再能用“最后一个子节点”定位）

func _ready() -> void:
	_style_bar(_hp_bar, Color("ef6b5e"))
	_style_bar(_xp_bar, Color("7ec850"))
	EventBus.player_damaged.connect(_on_player_damaged)
	_score_text = Label.new()
	_score_text.add_theme_font_size_override("font_size", 14)
	_score_text.add_theme_color_override("font_color", Color("ff9d3b"))
	_score_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_score_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top_right.add_child(_score_text)
	_build_status_legend()

func get_wave_text() -> String:
	return _wave_text.text

func get_hp_text() -> String:
	return _hp_text.text

func get_lv_text() -> String:
	return _lv_text.text

func _on_player_damaged(_amount: float) -> void:
	_vignette_a = 1.0

func _process(delta: float) -> void:
	# 受击红晕淡出
	_vignette_a = maxf(0.0, _vignette_a - delta * 2.2)
	_vignette.color.a = _vignette_a * 0.55
	if player == null or wave_manager == null:
		return
	# 无尽/每日挑战：右上角显示累计积分（标准模式隐藏）
	_score_text.visible = GameState.endless or GameState.daily
	if _score_text.visible:
		_score_text.text = "%s %d" % ["📅" if GameState.daily else "★", GameState.score]
	# 商店/暂停/升级/结算期间战斗数值冻结，跳过整段刷新
	if GameState.phase != GameState.Phase.PLAYING and GameState.phase != GameState.Phase.INTRO:
		return
	var s: Dictionary = player.stats
	# 血条 / 等级 / 经验条
	_hp_bar.max_value = s.max_hp
	_hp_bar.value = clampf(player.hp, 0.0, s.max_hp)
	_hp_text.text = "%d/%d" % [ceili(maxf(player.hp, 0.0)), roundi(s.max_hp)]
	_lv_text.text = "Lv %d" % GameState.level
	_xp_bar.max_value = Config.xp_need(GameState.level)
	_xp_bar.value = GameState.xp
	# 顶中：波次 / 计时（BOSS 在场时显示血量；无尽模式每 10 波一轮）
	var wm_boss: Node2D = wave_manager.boss
	if wm_boss and is_instance_valid(wm_boss):
		_wave_text.text = "BOSS 战"
		_timer_text.text = "BOSS 血量 %d / %d" % [ceili(maxf(wm_boss.hp, 0.0)), roundi(wm_boss.max_hp)]
	else:
		var ev_label := ""
		match wave_manager.event_kind:
			"treasure": ev_label = " · 🎁宝箱守卫"
			"hunt": ev_label = " · ⚔精英狩猎"
			"meteor": ev_label = " · ☄流星雨"
		_wave_text.text = "第 %d 波%s" % [wave_manager.wave, ev_label]
		_timer_text.text = ("剩余 %d 秒" % ceili(wave_manager.wave_timer)) \
			if wave_manager.wave_timer > 0.0 else "清场中…"
	# 右上：材料 / 击杀
	_mat_text.text = "◆ %d" % GameState.materials
	_kill_text.text = "击杀 %d" % GameState.kills
	# 左下：属性行（0.2s 节流，7 项数值格式化不是每帧必要开销）
	_stats_t -= delta
	if _stats_t <= 0.0:
		_stats_t = 0.2
		_stats_label.text = "伤害 x%.2f ｜ 攻速 x%.2f ｜ 暴击 %d%%\n护甲 %d ｜ 闪避 %d%% ｜ 移速 x%.2f ｜ 回复 %.1f/s%s" % [
			s.dmg_mult, s.as_mult, roundi(s.crit_ch * 100.0), int(s.armor),
			roundi(s.dodge * 100.0), s.speed_mult, s.regen, _trait_line()]
		_refresh_status_legend()
	# 武器槽：分组 key 变化才重建（避免每帧建节点）
	var groups := {}
	for w in player.weapons:
		groups[w.type] = groups.get(w.type, 0) + 1
	var key := str(groups)
	if key != _weapons_key:
		_weapons_key = key
		_rebuild_weapons(groups)

## 武器向加成键 → HUD 简称。只列与武器行为直接相关的，
## 其余（经济 / 回复 / 护甲等）走左下属性行，避免 HUD 单行过长
const TRAIT_WEAPON_KEYS := {
	"bullet_speed_bonus": "弹速", "bullet_range_bonus": "射程",
	"melee_range_bonus": "斩击范围", "aoe_radius_bonus": "爆炸范围",
	"low_hp_dmg_bonus": "残血增伤",
}

## 角色特性行：动态特性显示当前数值，静态特性显示最关键的武器向加成 ——
## 只写特性名玩家仍看不出「它到底加在哪」，写出来才叫「精准」。
## 末尾附加主动技能（F 键）的就绪/冷却状态
func _trait_line() -> String:
	var t: Dictionary = player.char_trait
	var out := ""
	if not t.is_empty():
		var extra := ""
		match String(t.get("kind", "")):
			"momentum":
				extra = "（+%d%%）" % roundi(float(player.stats.momentum_dmg_bonus) * 100.0)
			"aura":
				extra = "（半径 %d）" % roundi(player.aura_radius())
			"stats":
				var eff: Dictionary = t.get("effects", {})
				for k in TRAIT_WEAPON_KEYS:
					if eff.has(k):
						extra = "（%s +%d%%）" % [TRAIT_WEAPON_KEYS[k], roundi(float(eff[k]) * 100.0)]
						break
		out = "\n%s %s%s" % [String(t.get("ico", "⚡")), String(t.get("name", "特性")), extra]
	# 主动技能：就绪 / 冷却状态（0.2s 节流刷新，冷却误差可接受）
	if not player.skill.is_empty():
		var sico := String(player.skill.get("ico", "✨"))
		var sname := String(player.skill.get("name", "技能"))
		if player.skill_cd > 0.0:
			out += "\n%s %s [F] 冷却 %.0fs" % [sico, sname, player.skill_cd]
		else:
			out += "\n%s %s [F] 就绪" % [sico, sname]
	return out

func _rebuild_weapons(groups: Dictionary) -> void:
	for c in _weapons_box.get_children():
		c.queue_free()
	for k in groups:
		_weapons_box.add_child(_make_slot(Registry.weapons[k], int(groups[k])))
	for _i in MetaProgress.weapon_slots() - player.weapons.size():
		_weapons_box.add_child(_make_slot({}, 0))

func _make_slot(c: Dictionary, count: int) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(48.0, 48.0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	if not c.is_empty():
		var ico := Label.new()
		ico.text = c.ico
		ico.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ico.add_theme_font_size_override("font_size", 18)
		ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(ico)
		var nm := Label.new()
		# 聚合同类武器：名字右侧带 xN（原型 wslot 右上角 wcnt）
		nm.text = c.name + (" x%d" % count if count > 1 else "")
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nm.add_theme_font_size_override("font_size", 11)
		nm.add_theme_color_override("font_color", Color("9aa3b2"))
		nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(nm)
	else:
		panel.modulate.a = 0.3   # 空槽
	return panel

func _style_bar(bar: ProgressBar, fill_color: Color) -> void:
	bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color("14171c")
	bg.border_color = Color(0.0, 0.0, 0.0, 0.33)
	bg.set_border_width_all(1)
	bg.set_corner_radius_all(7)
	var fill := StyleBoxFlat.new()
	fill.bg_color = fill_color
	fill.set_corner_radius_all(7)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fill)

## 右侧异常状态图例：标题 + 每种可施加状态（图标/名称/命中率/层数上限）+ 强化加成
func _build_status_legend() -> void:
	_status_panel = PanelContainer.new()
	_status_panel.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	_status_panel.offset_left = -190.0
	_status_panel.offset_right = -14.0
	_status_panel.offset_top = 0.0
	_status_panel.offset_bottom = 0.0
	_status_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_status_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_status_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_panel.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.094, 0.106, 0.129, 0.72)
	style.border_color = Color("3a4150")
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	_status_panel.add_theme_stylebox_override("panel", style)
	add_child(_status_panel)
	_status_box = VBoxContainer.new()
	_status_box.add_theme_constant_override("separation", 2)
	_status_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_panel.add_child(_status_box)

func _refresh_status_legend() -> void:
	if player == null or not is_instance_valid(player):
		return
	var sources: Dictionary = player.status_sources()
	var dmg_mult := float(player.stats.status_dmg_mult)
	var dur_mult := float(player.stats.status_dur_mult)
	var spread := float(player.stats.status_spread)
	var key := ""
	for sid in sources:
		key += "%s:%.2f:%d|" % [sid, float(sources[sid].chance), int(sources[sid].count)]
	# 折叠状态并入签名：点击标题后签名变化，走同一条重建路径
	key += "d%.2f:t%.2f:s%.2f:r%d" % [dmg_mult, dur_mult, spread, 1 if _reaction_open else 0]
	if key == _status_key:
		return
	_status_key = key
	_rebuild_status_legend(sources, dmg_mult, dur_mult, spread)

## 图例主体重建：异常状态列表 + 五行反应折叠页
## 仅在来源签名变化或折叠状态切换时调用，不逐帧建节点
func _rebuild_status_legend(sources: Dictionary, dmg_mult: float, dur_mult: float,
		spread: float) -> void:
	for c in _status_box.get_children():
		_status_box.remove_child(c)
		c.queue_free()
	_bonus_label = null
	if sources.is_empty() and dmg_mult <= 0.0 and dur_mult <= 0.0:
		_status_panel.visible = false
		return
	_status_panel.visible = true
	var head := Label.new()
	head.text = "异常状态"
	head.add_theme_font_size_override("font_size", 12)
	head.add_theme_color_override("font_color", Color("e8b84b"))
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_box.add_child(head)
	for sid in Config.STATUS:
		var key_sid := String(sid)
		if not sources.has(key_sid):
			continue
		var st_cfg: Dictionary = Config.STATUS[sid]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var ico := Label.new()
		ico.text = String(st_cfg.get("ico", "❓"))
		ico.add_theme_font_size_override("font_size", 13)
		ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(ico)
		var nm := Label.new()
		nm.text = String(st_cfg.get("name", key_sid))
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nm.add_theme_font_size_override("font_size", 12)
		nm.add_theme_color_override("font_color", Color(String(st_cfg.get("color", "#9aa3b2"))))
		nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(nm)
		var val := Label.new()
		var chance := roundi(float(sources[key_sid].chance) * 100.0)
		var stack_max := int(st_cfg.get("stack_max", 1))
		val.text = ("%d%% ×%d" % [chance, stack_max]) if stack_max > 1 else ("%d%%" % chance)
		val.add_theme_font_size_override("font_size", 12)
		val.add_theme_color_override("font_color", Color("f2e7c7"))
		val.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(val)
		_status_box.add_child(row)
	if dmg_mult > 0.0 or dur_mult > 0.0 or (sources.has("poison") and spread >= 1.0):
		var parts: Array = []
		if dmg_mult > 0.0:
			parts.append("伤害 +%d%%" % roundi(dmg_mult * 100.0))
		if dur_mult > 0.0:
			parts.append("时长 +%d%%" % roundi(dur_mult * 100.0))
		if sources.has("poison") and spread >= 1.0:
			parts.append("中毒传染")
		var bonus := Label.new()
		bonus.text = " · ".join(parts)
		bonus.add_theme_font_size_override("font_size", 11)
		bonus.add_theme_color_override("font_color", Color("9aa3b2"))
		bonus.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_status_box.add_child(bonus)
		_bonus_label = bonus
	_build_reaction_section(sources)

# ------------------------------------------------------------
# 五行反应折叠页：状态图例底部的一节，标题常驻、列表按需展开
# ------------------------------------------------------------

## 当前构筑可触发的反应：可施加状态需覆盖反应 key 两端的五行
func _available_reactions(sources: Dictionary) -> Array:
	var elements := {}
	for sid in sources:
		var el := Config.get_element(String(sid))
		if el != "":
			elements[el] = true
	var out: Array = []
	for r in Registry.reaction_list():
		var parts := String(r.get("key", "")).split("+")
		if parts.size() == 2 and elements.has(String(parts[0])) \
				and elements.has(String(parts[1])):
			out.append(r)
	return out

## 标题行常驻（0/10 也显示，让玩家早知道有这套机制），展开后列可触发反应
func _build_reaction_section(sources: Dictionary) -> void:
	var total := Registry.reactions.size()
	if total <= 0:
		return
	var available := _available_reactions(sources)
	_status_box.add_child(_make_reaction_head(available.size(), total))
	if not _reaction_open:
		return
	for r in available:
		_status_box.add_child(_make_reaction_row(r))
	var tip := Label.new()
	tip.text = "同一敌人身上凑齐两种相异五行的状态即可触发" if available.is_empty() \
		else "详细效果见图鉴「五行」页"
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.custom_minimum_size = Vector2(150.0, 0.0)
	tip.add_theme_font_size_override("font_size", 10)
	tip.add_theme_color_override("font_color", Color("7a8291"))
	tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_box.add_child(tip)

## 折叠标题：整行可点（鼠标 / 触屏），与 main.gd 的 toast 点击同一套事件处理
## 只有这一行吃鼠标，避免影响点触移动
func _make_reaction_head(have: int, total: int) -> Control:
	var head := Label.new()
	head.text = "☯ 五行反应 %d/%d  %s" % [have, total, "▾" if _reaction_open else "▸"]
	head.add_theme_font_size_override("font_size", 12)
	head.add_theme_color_override("font_color",
		Color("6fd6c8") if have > 0 else Color("9aa3b2"))
	head.mouse_filter = Control.MOUSE_FILTER_STOP
	head.gui_input.connect(_on_reaction_head_input)
	return head

func _on_reaction_head_input(event: InputEvent) -> void:
	# 写成 if/elif 而不是合并成一个布尔表达式：“is” 的类型收窄只在条件里生效，
	# 赋给变量时 event.button_index 会退化成 Variant 导致 := 推不出类型
	var tapped := false
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		tapped = true
	elif event is InputEventScreenTouch and event.pressed:
		tapped = true
	if not tapped:
		return
	_reaction_open = not _reaction_open
	_refresh_status_legend()

## 反应行：图标 + 名称（稀有度配色）+ 相生/相克标记
func _make_reaction_row(r: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ico := Label.new()
	ico.text = String(r.get("ico", "☯"))
	ico.add_theme_font_size_override("font_size", 13)
	ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(ico)
	var nm := Label.new()
	nm.text = String(r.get("name", ""))
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.add_theme_font_size_override("font_size", 11)
	nm.add_theme_color_override("font_color",
		Config.rarity_color(String(r.get("rarity", "common"))))
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(nm)
	var overcome := String(r.get("type", "")) == "overcome"
	var kind := Label.new()
	kind.text = "相克" if overcome else "相生"
	kind.add_theme_font_size_override("font_size", 11)
	kind.add_theme_color_override("font_color",
		Color("ff9d7a") if overcome else Color("9ad48a"))
	kind.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(kind)
	return row
