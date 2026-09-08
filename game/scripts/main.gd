extends Node2D
## 主场景：竞技场绘制 + 相机震动 + 横幅/结算 UI + 波次调度入口

var shake := 0.0
var banner_t := 0.0

@onready var player: CharacterBody2D = $Player
@onready var camera: Camera2D = $Player/Camera
@onready var dead_label: Label = $UI/DeadLabel
@onready var victory_label: Label = $UI/VictoryLabel
var _pause_menu: Control = null
var _phase_before_pause := GameState.Phase.PLAYING
var _dead_menu: Control = null
var _victory_menu: Control = null
@onready var banner_title: Label = $UI/BannerTitle
@onready var banner_sub: Label = $UI/BannerSub
@onready var wave_manager: Node = $WaveManager
@onready var level_up_ui: Control = $UI/LevelUp
@onready var shop_ui: Control = $UI/Shop
@onready var hud: Control = $UI/HUD

func _ready() -> void:
	# 支持 -- --seed=123 复现（与 Web 原型 ?seed=123 等价）
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			GameRng.seed_from(int(arg.trim_prefix("--seed=")) & 0xFFFFFFFF)
	# 主菜单"继续游戏"：消费标志并恢复存档（档无效自动回退正常开局）
	var restored_wave := 0
	if GameState.continue_pending:
		GameState.continue_pending = false
		restored_wave = SaveRun.restore(player)
	EventBus.screen_shake.connect(_on_screen_shake)
	EventBus.player_died.connect(_on_player_died)
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.boss_killed.connect(_on_boss_killed)
	EventBus.banner_requested.connect(_on_banner)
	EventBus.wave_ended.connect(_on_wave_ended)
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	wave_manager.player = player
	level_up_ui.player = player
	shop_ui.player = player
	shop_ui.wave_manager = wave_manager
	hud.player = player
	hud.wave_manager = wave_manager
	# 开发者面板（F1 呼出）
	var dev := preload("res://scenes/ui/dev_panel.tscn").instantiate()
	$UI.add_child(dev)
	dev.player = player
	dev.wave_manager = wave_manager
	# 移动端虚拟摇杆（触屏设备自动显示）
	var touch := preload("res://scripts/ui/touch_controls.gd").new()
	touch.name = "TouchControls"
	$UI.add_child(touch)
	touch.pause_requested.connect(toggle_pause)
	if restored_wave > 0:
		if SaveRun.restored_checkpoint == SaveRun.CHECKPOINT_WAVE_START:
			wave_manager.start_wave(restored_wave)
		else:
			shop_ui.open(restored_wave - 1)   # 商店档恢复：属性完整，货架重新生成
	else:
		GameState.start_run()
		# 主菜单选定的开局道具（角色属性/初始武器已在 player._ready 应用）
		if GameState.loadout_item != "":
			player.apply_item(GameState.loadout_item)
		var initial_save_ok := SaveRun.save(1, player, SaveRun.CHECKPOINT_WAVE_START)
		wave_manager.start_wave(1)
		if not initial_save_ok:
			EventBus.banner_requested.emit("存档失败", "新局尚未写入存档", 2.0)
	_build_pause_menu()
	_build_end_menus()
	queue_redraw()

func _process(delta: float) -> void:
	# 相机震动（对应原型 cam.shake，衰减 22/s）
	shake = maxf(0.0, shake - delta * 22.0)
	camera.offset = Vector2.ZERO if shake <= 0.0 \
		else Vector2(GameRng.range_f(-shake, shake), GameRng.range_f(-shake, shake))
	# 横幅倒计时
	if banner_t > 0.0:
		banner_t -= delta
		if banner_t <= 0.0:
			_hide_banner()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		toggle_pause()
	elif event.is_action_pressed("toggle_mute"):
		Settings.toggle_mute()
		EventBus.banner_requested.emit("声音", "已静音" if Settings.master_vol <= 0.0001 else "已恢复", 1.0)
	# ---- 升级 UI 期间：根节点直接处理输入（最可靠，不依赖子节点 _unhandled_input 触发） ----
	elif GameState.phase == GameState.Phase.LEVEL_UP and level_up_ui.visible:
		if event.is_action_pressed("ui_accept"):
			var focus: Control = get_viewport().gui_get_focus_owner()
			if focus and focus.get_parent() == level_up_ui.get_node("Center/Box/Cards"):
				level_up_ui._choose(focus.get_index())
			elif level_up_ui.card_count() > 0:
				level_up_ui._choose(0)
			get_viewport().set_input_as_handled()
		elif event is InputEventKey and event.pressed and not event.echo:
			match event.physical_keycode:
				KEY_1: level_up_ui._choose(0); get_viewport().set_input_as_handled()
				KEY_2: level_up_ui._choose(1); get_viewport().set_input_as_handled()
				KEY_3: level_up_ui._choose(2); get_viewport().set_input_as_handled()
	# ---- 临时调试：1-5 换武器 / 6 射手 / 7 BOSS（限定 PLAYING，避免与升级卡 1-3 冲突） ----
	elif event is InputEventKey and event.pressed and not event.echo:
		if GameState.phase == GameState.Phase.PLAYING:
			match event.physical_keycode:
				KEY_1: _debug_set_weapon("pistol")
				KEY_2: _debug_set_weapon("smg")
				KEY_3: _debug_set_weapon("shotgun")
				KEY_4: _debug_set_weapon("knife")
				KEY_5: _debug_set_weapon("rocket")
				KEY_6: wave_manager.spawn("shooter")
				KEY_7: wave_manager.spawn("boss")
		elif event.physical_keycode == KEY_R \
				and (GameState.phase == GameState.Phase.GAME_OVER \
					or GameState.phase == GameState.Phase.VICTORY):
			get_tree().reload_current_scene()

func _debug_set_weapon(type: String) -> void:
	if Registry.weapons.has(type):
		player.weapons = [{ "type": type, "cd": 0.1 }]

func _on_screen_shake(amount: float) -> void:
	shake = maxf(shake, amount)
	Haptics.rumble_from_shake(amount)   # 战斗震动随震屏强度联动

func _on_enemy_killed(type: String) -> void:
	GameState.kills += 1
	if GameState.endless:
		GameState.add_score(Config.kill_score(Registry.enemies.get(type, {})))
	Haptics.rumble(0.12, 0.0, 0.06)   # 击杀微震（Haptics 内部节流防叠满）

## 普通波清场后进入商店（BOSS 波击杀直接结算，不走这里）
## 波末自动回收场上全部掉落：经验/材料/红心直接结算，
## 升级选择若在此触发会积压 level_queue，下一波开始时补弹
func _on_wave_ended(w: int) -> void:
	if GameState.endless:
		GameState.add_score(Config.wave_clear_score(w))
	shop_ui.open(w)
	for l in get_tree().get_nodes_in_group("loot"):
		l.settle()
	shop_ui._refresh()   # 回收后刷新材料显示
	if not SaveRun.save(w + 1, player, SaveRun.CHECKPOINT_WAVE_START):
		EventBus.banner_requested.emit("存档失败", "本次波次进度尚未写入", 2.0)

func _on_player_died() -> void:
	if SaveRun.current_run_owns_slot:
		SaveRun.clear()   # 仅清除已由本局成功写入/恢复的槽
	GameState.set_phase(GameState.Phase.GAME_OVER)
	EventBus.run_ended.emit(false)
	if GameState.endless:
		# 无尽：成绩写入排行榜并展示名次
		var ch: Dictionary = Registry.get_character(GameState.character_id)
		var rank := Leaderboard.record(GameState.score, wave_manager.wave,
			String(ch.get("name", "?")), GameState.kills, GameState.run_time)
		dead_label.text = "你倒下了 · 积分 %d" % GameState.score
		if rank == 1:
			EventBus.banner_requested.emit("新纪录！",
				"积分 %d 登顶排行榜" % GameState.score, 3.0)
		elif rank > 1:
			EventBus.banner_requested.emit("挑战结束",
				"积分 %d · 排行榜第 %d 名" % [GameState.score, rank], 3.0)
	else:
		dead_label.text = "你倒下了"
	dead_label.visible = true
	_dead_menu.visible = true
	_dead_menu.get_child(0).grab_focus()   # 再来一局
	Haptics.rumble(0.5, 1.0, 0.5)

## 手柄插拔提示（原型无此反馈，移动端/桌面手柄体验优化）
func _on_joy_connection_changed(device: int, connected: bool) -> void:
	EventBus.banner_requested.emit("手柄",
		"手柄 P%d 已%s" % [device + 1, "连接" if connected else "断开"], 1.5)

func _on_boss_killed() -> void:
	if GameState.endless:
		# 无尽：积分与波次收尾由 wave_manager 处理（wave_ended → 商店 → 下一波）
		EventBus.banner_requested.emit("BOSS 击破！",
			"积分 +%d · 炼狱继续深入" % Config.boss_kill_score(wave_manager.wave), 2.2)
		return
	if SaveRun.current_run_owns_slot:
		SaveRun.clear()   # 仅清除已由本局成功写入/恢复的槽
	GameState.set_phase(GameState.Phase.VICTORY)
	EventBus.run_ended.emit(true)
	victory_label.visible = true
	Sfx.play("victory")
	_victory_menu.visible = true
	_victory_menu.get_child(0).grab_focus()   # 再来一局

var _banner_tween: Tween = null

func _on_banner(title: String, subtitle: String, duration: float) -> void:
	banner_title.text = title
	banner_sub.text = subtitle
	banner_title.visible = true
	banner_sub.visible = true
	banner_t = duration
	if _banner_tween:
		_banner_tween.kill()
	_banner_tween = create_tween()
	_banner_tween.set_parallel(true)
	_banner_tween.tween_property(banner_title, "modulate:a", 1.0, 0.15).from(0.0)
	_banner_tween.tween_property(banner_sub, "modulate:a", 1.0, 0.15).from(0.0)

func _hide_banner() -> void:
	if _banner_tween:
		_banner_tween.kill()
	_banner_tween = create_tween()
	_banner_tween.set_parallel(true)
	_banner_tween.tween_property(banner_title, "modulate:a", 0.0, 0.18)
	_banner_tween.tween_property(banner_sub, "modulate:a", 0.0, 0.18)
	_banner_tween.chain().tween_callback(func() -> void:
		banner_title.visible = false
		banner_sub.visible = false)

func toggle_pause() -> void:
	if GameState.phase == GameState.Phase.PLAYING or GameState.phase == GameState.Phase.INTRO:
		_phase_before_pause = GameState.phase
		GameState.set_phase(GameState.Phase.PAUSED)
		_refresh_pause_content()
		_pause_overlay.visible = true
		_pause_resume.grab_focus()   # 继续游戏（手柄直达）
	elif GameState.phase == GameState.Phase.PAUSED:
		GameState.set_phase(_phase_before_pause)
		_pause_overlay.visible = false

func _draw() -> void:
	var g := 64.0
	var w := Config.WORLD.w
	var h := Config.WORLD.h
	var grid_color := Color("222730")
	var x := 0.0
	while x <= w:
		draw_line(Vector2(x, 0.0), Vector2(x, h), grid_color, 1.0)
		x += g
	var y := 0.0
	while y <= h:
		draw_line(Vector2(0.0, y), Vector2(w, y), grid_color, 1.0)
		y += g
	draw_rect(Rect2(0.0, 0.0, w, h), Color("4a5262"), false, 4.0)

# ---- 暂停 / 死亡 / 胜利 按钮菜单（代码构建，手柄可导航） ----

var _pause_overlay: Control = null
var _pause_resume: Button = null
var _pause_left: VBoxContainer = null
var _pause_items: VBoxContainer = null

## 暂停页：全屏遮罩 + 左角色属性 / 中按钮 / 右已购道具
func _build_pause_menu() -> void:
	_pause_overlay = Control.new()
	_pause_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause_overlay.visible = false
	$UI.add_child(_pause_overlay)
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.04, 0.06, 0.82)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause_overlay.add_child(dim)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, 20)
	_pause_overlay.add_child(margin)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 14)
	margin.add_child(hb)
	# 左：角色属性面板
	_pause_left = VBoxContainer.new()
	_pause_left.add_theme_constant_override("separation", 4)
	hb.add_child(_mk_side_panel(288.0, _pause_left))
	# 中：标题 + 按钮
	var center := VBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_theme_constant_override("separation", 10)
	hb.add_child(center)
	var title := Label.new()
	title.text = "已暂停"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color("f2e7c7"))
	center.add_child(title)
	var tip := Label.new()
	tip.text = "Esc / Start 继续"
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip.add_theme_font_size_override("font_size", 13)
	tip.add_theme_color_override("font_color", Color("9aa3b2"))
	center.add_child(tip)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center.add_child(spacer)
	_pause_resume = Button.new()
	_pause_resume.text = "继续游戏"
	_pause_resume.custom_minimum_size = Vector2(220.0, 44.0)
	_pause_resume.pressed.connect(toggle_pause)
	center.add_child(_pause_resume)
	var menu_btn := Button.new()
	menu_btn.text = "返回主菜单"
	menu_btn.custom_minimum_size = Vector2(220.0, 44.0)
	menu_btn.pressed.connect(_goto_main_menu)
	center.add_child(menu_btn)
	# 右：已购道具（只展示，不出售）
	var rbox := VBoxContainer.new()
	rbox.add_theme_constant_override("separation", 6)
	var side := _mk_side_panel(300.0, rbox)
	hb.add_child(side)
	var head := Label.new()
	head.text = "已购道具"
	head.add_theme_font_size_override("font_size", 15)
	head.add_theme_color_override("font_color", Color("e8b84b"))
	rbox.add_child(head)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	rbox.add_child(scroll)
	_pause_items = VBoxContainer.new()
	_pause_items.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pause_items.add_theme_constant_override("separation", 4)
	scroll.add_child(_pause_items)

func _mk_side_panel(w: float, inner: Control) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(w, 0.0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("181c24")
	sb.border_color = Color("2c3340")
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	panel.add_theme_stylebox_override("panel", sb)
	panel.add_child(inner)
	return panel

func _pause_stat_row(name_text: String, value_text: String) -> HBoxContainer:
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

## 打开暂停页时重建左右面板内容（数值/道具实时变化）
func _refresh_pause_content() -> void:
	# 左：角色 + 全数值 + 特性
	for c in _pause_left.get_children():
		_pause_left.remove_child(c)
		c.queue_free()
	var ch: Dictionary = Registry.get_character(GameState.character_id)
	var head := HBoxContainer.new()
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ico := Label.new()
	ico.text = ch.get("ico", "🧑")
	ico.add_theme_font_size_override("font_size", 22)
	ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(ico)
	var nm := Label.new()
	nm.text = " %s" % ch.get("name", "?")
	nm.add_theme_font_size_override("font_size", 17)
	nm.add_theme_color_override("font_color", Color("e8b84b"))
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(nm)
	_pause_left.add_child(head)
	var s: Dictionary = player.stats
	_pause_left.add_child(_pause_stat_row("生命", "%d / %d" % [roundi(player.hp), roundi(s.max_hp)]))
	_pause_left.add_child(_pause_stat_row("武器", "%d / %d" % [player.weapons.size(), Config.WEAPON_SLOTS]))
	_pause_left.add_child(_pause_stat_row("伤害", "x%.2f" % float(s.dmg_mult)))
	_pause_left.add_child(_pause_stat_row("攻速", "x%.2f" % float(s.as_mult)))
	_pause_left.add_child(_pause_stat_row("移速", "%.0f" % float(s.base_speed * s.speed_mult)))
	_pause_left.add_child(_pause_stat_row("暴击率", "%d%%" % roundi(float(s.crit_ch) * 100.0)))
	_pause_left.add_child(_pause_stat_row("暴击伤害", "x%.2f" % float(s.crit_mult)))
	_pause_left.add_child(_pause_stat_row("护甲", "%d" % int(s.armor)))
	_pause_left.add_child(_pause_stat_row("闪避", "%d%%" % roundi(float(s.dodge) * 100.0)))
	_pause_left.add_child(_pause_stat_row("拾取范围", "%.0f" % float(s.pickup_range)))
	_pause_left.add_child(_pause_stat_row("回复", "%.1f / 秒" % float(s.regen)))
	_pause_left.add_child(_pause_stat_row("收获率", "+%d%%" % roundi(float(s.harvesting) * 100.0)))
	_pause_left.add_child(_pause_stat_row("吸血", "%.0f / 击杀" % float(s.lifesteal)))
	var sep := ColorRect.new()
	sep.color = Color("2c3340")
	sep.custom_minimum_size = Vector2(0.0, 1.0)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_left.add_child(sep)
	var trait_t := Label.new()
	trait_t.text = "角色特性"
	trait_t.add_theme_font_size_override("font_size", 13)
	trait_t.add_theme_color_override("font_color", Color("e8b84b"))
	trait_t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_left.add_child(trait_t)
	var trait_l := Label.new()
	trait_l.text = ch.get("desc", "无特性")
	trait_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	trait_l.add_theme_font_size_override("font_size", 12)
	trait_l.add_theme_color_override("font_color", Color("9aa3b2"))
	trait_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_left.add_child(trait_l)
	# 右：已购道具（相同叠加显示数量）
	for c in _pause_items.get_children():
		_pause_items.remove_child(c)
		c.queue_free()
	if player.items_owned.is_empty():
		var empty := Label.new()
		empty.text = "暂无道具"
		empty.add_theme_font_size_override("font_size", 12)
		empty.add_theme_color_override("font_color", Color("5a6270"))
		_pause_items.add_child(empty)
		return
	for id: String in player.items_owned:
		var it: Dictionary = Registry.items.get(id, {})
		var row := HBoxContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var l2 := Label.new()
		l2.text = "%s %s" % [it.get("ico", "🧩"), it.get("name", id)]
		l2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l2.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l2.add_theme_font_size_override("font_size", 13)
		l2.add_theme_color_override("font_color", Config.rarity_color(it.get("rarity", "common")))
		l2.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(l2)
		var ct := Label.new()
		ct.text = "x%d" % int(player.items_owned[id])
		ct.add_theme_font_size_override("font_size", 13)
		ct.add_theme_color_override("font_color", Color("f2e7c7"))
		ct.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(ct)
		_pause_items.add_child(row)

func _build_end_menus() -> void:
	# 死亡界面按钮
	dead_label.text = "你倒下了"
	var dead_vbox := VBoxContainer.new()
	dead_vbox.set_anchors_preset(Control.PRESET_CENTER)
	dead_vbox.offset_left = -120.0
	dead_vbox.offset_top = 8.0
	dead_vbox.offset_right = 120.0
	dead_vbox.offset_bottom = 90.0
	dead_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	dead_vbox.add_theme_constant_override("separation", 8.0)
	dead_vbox.visible = false
	$UI.add_child(dead_vbox)
	var retry_btn := Button.new()
	retry_btn.text = "再来一局（R）"
	retry_btn.custom_minimum_size = Vector2(200.0, 38.0)
	retry_btn.pressed.connect(func() -> void: get_tree().reload_current_scene())
	dead_vbox.add_child(retry_btn)
	var back_btn := Button.new()
	back_btn.text = "返回主菜单"
	back_btn.custom_minimum_size = Vector2(200.0, 38.0)
	back_btn.pressed.connect(_goto_main_menu)
	dead_vbox.add_child(back_btn)
	_dead_menu = dead_vbox
	# 胜利界面按钮
	victory_label.text = "通关！"
	var vic_vbox := VBoxContainer.new()
	vic_vbox.set_anchors_preset(Control.PRESET_CENTER)
	vic_vbox.offset_left = -120.0
	vic_vbox.offset_top = 8.0
	vic_vbox.offset_right = 120.0
	vic_vbox.offset_bottom = 90.0
	vic_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vic_vbox.add_theme_constant_override("separation", 8.0)
	vic_vbox.visible = false
	$UI.add_child(vic_vbox)
	var vic_retry := Button.new()
	vic_retry.text = "再来一局（R）"
	vic_retry.custom_minimum_size = Vector2(200.0, 38.0)
	vic_retry.pressed.connect(func() -> void: get_tree().reload_current_scene())
	vic_vbox.add_child(vic_retry)
	var vic_back := Button.new()
	vic_back.text = "返回主菜单"
	vic_back.custom_minimum_size = Vector2(200.0, 38.0)
	vic_back.pressed.connect(_goto_main_menu)
	vic_vbox.add_child(vic_back)
	_victory_menu = vic_vbox

func _goto_main_menu() -> void:
	Haptics.rumble(0.3, 0.0, 0.1)
	# 商店是安全点，离开前保存；战斗/升级中保留波次开始快照，避免重复刷收益。
	if GameState.phase == GameState.Phase.SHOP:
		if not SaveRun.save(wave_manager.wave + 1, player, SaveRun.CHECKPOINT_WAVE_START):
			EventBus.banner_requested.emit("存档失败", "无法返回主菜单，请检查磁盘空间", 2.0)
			return
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
