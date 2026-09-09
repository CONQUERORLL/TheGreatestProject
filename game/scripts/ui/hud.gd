extends Control
## 游戏 HUD（移植自原型 updateHUD）
## 左上：血条 + 等级/经验条；顶中：波次/计时（BOSS 波显示血量）；
## 右上：材料/击杀；左下：属性行；底中：武器槽（按类型聚合 xN + 空槽补位）；
## 全屏受击红晕（监听 player_damaged 拉满后淡出）。全部节点不拦截鼠标。

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
		_stats_label.text = "伤害 x%.2f ｜ 攻速 x%.2f ｜ 暴击 %d%%\n护甲 %d ｜ 闪避 %d%% ｜ 移速 x%.2f ｜ 回复 %.1f/s" % [
			s.dmg_mult, s.as_mult, roundi(s.crit_ch * 100.0), int(s.armor),
			roundi(s.dodge * 100.0), s.speed_mult, s.regen]
		_refresh_status_legend()
	# 武器槽：分组 key 变化才重建（避免每帧建节点）
	var groups := {}
	for w in player.weapons:
		groups[w.type] = groups.get(w.type, 0) + 1
	var key := str(groups)
	if key != _weapons_key:
		_weapons_key = key
		_rebuild_weapons(groups)

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
	key += "d%.2f:t%.2f:s%.2f" % [dmg_mult, dur_mult, spread]
	if key == _status_key:
		return
	_status_key = key
	for c in _status_box.get_children():
		_status_box.remove_child(c)
		c.queue_free()
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
