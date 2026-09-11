extends Node2D
## 主场景：竞技场绘制 + 相机震动 + 横幅/结算 UI + 波次调度入口
## + 状态触发打击感（顿帧/震屏）+ BGM 阶段切换 + 图鉴武器登记

var shake := 0.0
var banner_t := 0.0

## 状态触发打击感：顿帧（Engine.time_scale）+ 震屏，全局节流防高频状态刷屏
const HIT_STOP_SCALE := 0.18
const HIT_STOP_MS := 45
const STATUS_JUICE_CD_MS := 180
var _hit_stop_until_ms := 0
var _hit_stop_on := false
var _status_juice_cd := 0
var _status_juice_count := 0   # 测试观测：状态打击感触发次数
var _codex_scan_t := 0.0

## 五行反应打击感：粒子 + 震屏 + 顿帧 + 屏幕中央提示（音效由 Sfx 订阅同一信号）
const REACTION_HIT_STOP_MS := 45
const REACTION_JUICE_CD_MS := 90     # 全局节流：连锁反应不叠成卡帧
const REACTION_POPUP_HOLD := 0.64    # 中央提示驻留（含淡入淡出共 1.2s）
const REACTION_POPUP_CD_MS := 400    # 同名反应提示节流
var _reaction_juice_cd := 0
var _reaction_count := 0             # 测试观测：反应打击感触发次数
var _reaction_popup_cd: Dictionary = {}   # reaction_id -> 下次可弹提示时间戳
var _reaction_label: Label = null
var _reaction_tween: Tween = null

## 图鉴/成就解锁 toast：右上角轻量提示，队列化（最多 4 条，1.15s/条）
var _toast_panel: PanelContainer
var _toast_label: Label
var _toast_queue: Array = []
var _toast_t := 0.0
var _toast_count := 0   # 测试观测：toast 累计次数
var _toast_target: Array = []   # 当前 toast 指向的图鉴条目 [category, id]
var _codex: Control = null      # 局内图鉴（点击 toast 时懒加载）
var _codex_phase_before := -1   # 打开图鉴前暂停的阶段（-1 = 未暂停）

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
@onready var artifact_system: Node = $ArtifactSystem
@onready var level_up_ui: Control = $UI/LevelUp
@onready var shop_ui: Control = $UI/Shop
@onready var hud: Control = $UI/HUD

## 江湖奇遇事件卡（Phase 4）：与 dev_panel / touch_controls 同一策略，代码 instantiate
var event_card_ui: Control = null
var _pending_wave_after_event := 0   # 事件选择结束后要启动的波次（0 = 无待处理）
var event_cards_played := 0          # 测试观测：本局实际弹出的奇遇次数

## 武器进化方向选择弹窗（多分支进化时让玩家挑方向）
var evolve_choose_ui: Control = null
var _pending_evolve_choices: Array = []   # 待选择的进化选项队列（逐个弹出）
var _pending_evolve_wave := 0             # 进化流程结束后要写入存档的波次（0 = 无）

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
	# 局外天赋（MetaProgress）：新局应用；读档局不重复应用（效果已烙进存档 stats）；
	# 每日挑战不吃局外天赋（全服同局，天赋会造成个体差异）
	if restored_wave == 0 and not GameState.daily:
		MetaProgress.apply_on_run_start(player)
	EventBus.screen_shake.connect(_on_screen_shake)
	EventBus.player_died.connect(_on_player_died)
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.boss_killed.connect(_on_boss_killed)
	EventBus.banner_requested.connect(_on_banner)
	EventBus.wave_ended.connect(_on_wave_ended)
	EventBus.wave_started.connect(_on_wave_started)
	EventBus.status_applied.connect(_on_status_applied)
	EventBus.element_reaction.connect(_on_element_reaction)
	EventBus.codex_unlocked.connect(_on_codex_unlocked)
	EventBus.artifact_acquired.connect(_on_artifact_acquired)
	EventBus.achievement_unlocked.connect(_on_achievement_unlocked)
	EventBus.unlocks_achieved.connect(_on_unlocks_achieved)
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	wave_manager.player = player
	artifact_system.player = player
	level_up_ui.player = player
	shop_ui.player = player
	shop_ui.wave_manager = wave_manager
	shop_ui.main = self   # 商店关闭后由 main 决定是否先弹奇遇（见 shop_ui.next_wave）
	hud.player = player
	hud.wave_manager = wave_manager
	# 江湖奇遇事件卡（Phase 4）
	event_card_ui = preload("res://scenes/ui/event_card.tscn").instantiate()
	$UI.add_child(event_card_ui)
	event_card_ui.player = player
	event_card_ui.chosen.connect(_on_event_choice)
	# 武器进化方向选择弹窗（多分支进化时让玩家挑方向）
	evolve_choose_ui = preload("res://scenes/ui/evolve_choose.tscn").instantiate()
	$UI.add_child(evolve_choose_ui)
	evolve_choose_ui.evolved.connect(_on_evolve_choice)
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
	# 桌面鼠标点触移动（单击走向点击点 / 长按拖动跟随光标）
	var mouse_move := preload("res://scripts/ui/mouse_move.gd").new()
	mouse_move.name = "MouseMove"
	$UI.add_child(mouse_move)
	mouse_move.player = player
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
	# BGM：战斗按波次切曲，商店/读档回商店档时切舒缓曲（菜单音乐由 main_menu 负责）
	if GameState.phase == GameState.Phase.SHOP:
		Music.play_track("shop", 0.5)
	else:
		Music.play_track(Music.track_for_wave(wave_manager.wave), 0.5)
	_build_pause_menu()
	_build_end_menus()
	_build_toast()
	_build_reaction_popup()
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
	# 顿帧恢复用真实时间判定（Engine.time_scale 不影响）
	if _hit_stop_on and Time.get_ticks_msec() >= _hit_stop_until_ms:
		_end_hit_stop()
	# 图鉴：定期登记玩家当前武器（商店购买/进化/读档/调试等所有来源统一覆盖）
	_codex_scan_t -= delta
	if _codex_scan_t <= 0.0:
		_codex_scan_t = 0.5
		_scan_codex_weapons()
	if _toast_t > 0.0:
		_toast_t -= delta
		if _toast_t <= 0.0:
			_next_toast()

func _unhandled_input(event: InputEvent) -> void:
	# 主动技能：F 键释放（战斗阶段）
	if event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_F \
			and GameState.phase == GameState.Phase.PLAYING:
		player.cast_skill()
		get_viewport().set_input_as_handled()
		return
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
	# ---- 奇遇事件卡期间：根节点直接处理输入（与升级 UI 同策略） ----
	# 事件卡发生在商店关闭之后、下一波开始之前，此时 phase 仍是 SHOP（安全暂停态）
	elif GameState.phase == GameState.Phase.SHOP and event_card_ui != null and event_card_ui.visible:
		if event.is_action_pressed("ui_accept"):
			var e_focus: Control = get_viewport().gui_get_focus_owner()
			if e_focus is Button and not e_focus.disabled \
					and e_focus.get_parent() == event_card_ui.get_node("Center/Box/Cards"):
				event_card_ui._choose(e_focus.get_index())
			else:
				for i in event_card_ui.choice_count():
					if event_card_ui.is_choice_enabled(i):
						event_card_ui._choose(i)
						break
			get_viewport().set_input_as_handled()
		elif event is InputEventKey and event.pressed and not event.echo:
			match event.physical_keycode:
				KEY_1: event_card_ui._choose(0); get_viewport().set_input_as_handled()
				KEY_2: event_card_ui._choose(1); get_viewport().set_input_as_handled()
				KEY_3: event_card_ui._choose(2); get_viewport().set_input_as_handled()
	# ---- 调试构建专属：Ctrl+1~5 换武器 / Ctrl+6 射手 / Ctrl+7 BOSS ----
	# 必须按住 Ctrl：裸按数字键 1-7 会误触换武器，把 player.weapons 整体替换、武器+强化一次性丢失
	# OS.is_debug_build() 守卫：发布版玩家不该能凭空换武器 / 刷 BOSS / 快速重开
	elif event is InputEventKey and event.pressed and not event.echo and OS.is_debug_build():
		if GameState.phase == GameState.Phase.PLAYING and event.ctrl_pressed:
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
			_finish_victory_run()
			get_tree().reload_current_scene()

func _debug_set_weapon(type: String) -> void:
	if Registry.weapons.has(type):
		player.weapons = [{ "type": type, "cd": 0.1 }]

func _on_screen_shake(amount: float) -> void:
	shake = maxf(shake, amount)
	Haptics.rumble_from_shake(amount)   # 战斗震动随震屏强度联动

## 状态首次触发：震屏 + 顿帧 + 图鉴解锁（180ms 全局节流，火焰喷射器也不会糊屏）
func _on_status_applied(status_id: String, _stacks: int, _pos: Vector2) -> void:
	CodexData.unlock("status", status_id)
	var now := Time.get_ticks_msec()
	if now < _status_juice_cd:
		return
	_status_juice_cd = now + STATUS_JUICE_CD_MS
	_status_juice_count += 1
	_on_screen_shake(2.2)
	_trigger_hit_stop(HIT_STOP_MS, HIT_STOP_SCALE)

## 五行反应特效：粒子常驻播放，震屏/顿帧/中央提示走全局节流
func _on_element_reaction(reaction_id: String, pos: Vector2, _targets: Array) -> void:
	var reaction: Dictionary = Registry.get_reaction(reaction_id)
	var accent := _reaction_color(reaction)
	var overcome := String(reaction.get("type", "")) == "overcome"
	# 相克爆发更猛（复用 Burst，无额外场景开销）
	Burst.spawn(self, pos, accent, 22 if overcome else 12, 300.0 if overcome else 190.0)
	var now := Time.get_ticks_msec()
	if now < _reaction_juice_cd:
		return
	_reaction_juice_cd = now + REACTION_JUICE_CD_MS
	_reaction_count += 1
	var fallback_shake := 4.0 if overcome else 1.8
	_on_screen_shake(float(reaction.get("shake", fallback_shake)))
	_trigger_hit_stop(REACTION_HIT_STOP_MS, HIT_STOP_SCALE)
	_show_reaction_popup(reaction, accent, overcome, now)

## 反应主色：两五行配色混合（key = "elemA+elemB"）；无 key 时退回稀有度色
func _reaction_color(reaction: Dictionary) -> Color:
	var parts := String(reaction.get("key", "")).split("+")
	if parts.size() != 2:
		return Config.rarity_color(String(reaction.get("rarity", "common")))
	var a := Color(String(Config.ELEMENT_COLOR.get(String(parts[0]), "#ffffff")))
	var b := Color(String(Config.ELEMENT_COLOR.get(String(parts[1]), "#ffffff")))
	return a.lerp(b, 0.5)

## 中央反应提示（如“💧🔥 水克火 · 蒸汽爆炸！”）：弹入 → 驻留 → 淡出
func _show_reaction_popup(reaction: Dictionary, accent: Color, overcome: bool,
		now: int) -> void:
	if _reaction_label == null:
		return
	var rid := String(reaction.get("id", ""))
	if now < int(_reaction_popup_cd.get(rid, 0)):
		return
	_reaction_popup_cd[rid] = now + REACTION_POPUP_CD_MS
	_reaction_label.text = "%s %s%s" % [String(reaction.get("ico", "☯")),
		String(reaction.get("name", rid)), "！" if overcome else ""]
	_reaction_label.add_theme_color_override("font_color", accent)
	_reaction_label.visible = true
	_reaction_label.modulate.a = 0.0
	_reaction_label.scale = Vector2(0.88, 0.88)
	if _reaction_tween != null and _reaction_tween.is_valid():
		_reaction_tween.kill()
	_reaction_tween = create_tween()
	_reaction_tween.set_parallel(true)
	_reaction_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_reaction_tween.tween_property(_reaction_label, "modulate:a", 1.0, 0.12)
	_reaction_tween.tween_property(_reaction_label, "scale", Vector2.ONE, 0.16)
	_reaction_tween.chain().tween_interval(REACTION_POPUP_HOLD)
	_reaction_tween.chain().tween_property(_reaction_label, "modulate:a", 0.0, 0.4)
	_reaction_tween.chain().tween_callback(func() -> void:
		_reaction_label.visible = false)

## 中央提示标签：屏幕正中，不与顶部横幅（48~118px）重叠
func _build_reaction_popup() -> void:
	_reaction_label = Label.new()
	_reaction_label.set_anchors_preset(Control.PRESET_CENTER)
	_reaction_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_reaction_label.grow_vertical = Control.GROW_DIRECTION_BOTH
	_reaction_label.offset_left = -340.0
	_reaction_label.offset_right = 340.0
	_reaction_label.offset_top = -28.0
	_reaction_label.offset_bottom = 28.0
	_reaction_label.pivot_offset = Vector2(340.0, 28.0)
	_reaction_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_reaction_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_reaction_label.add_theme_font_size_override("font_size", 30)
	_reaction_label.add_theme_color_override("font_outline_color", Color(0.02, 0.03, 0.05, 0.92))
	_reaction_label.add_theme_constant_override("outline_size", 9)
	_reaction_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reaction_label.visible = false
	$UI.add_child(_reaction_label)

func _trigger_hit_stop(duration_ms: int, scale: float) -> void:
	if duration_ms <= 0:
		return
	_hit_stop_until_ms = maxi(_hit_stop_until_ms, Time.get_ticks_msec() + duration_ms)
	if not _hit_stop_on:
		_hit_stop_on = true
		Engine.time_scale = clampf(scale, 0.05, 1.0)

func _end_hit_stop() -> void:
	if not _hit_stop_on:
		return
	_hit_stop_on = false
	Engine.time_scale = 1.0

func _scan_codex_weapons() -> void:
	for w in player.weapons:
		CodexData.unlock("weapon", String(w.type))

func _on_codex_unlocked(cat: String, id: String) -> void:
	_enqueue_toast("📖 图鉴解锁", "%s %s · ✦%d" % [CodexData.display_icon(cat, id),
		CodexData.display_name(cat, id), CodexData.unlock_reward(cat)], cat, id)

## 获得法宝：精英掉落 / BOSS 必掉 / 商店购买 三条渠道的统一出口
## 刻意走队列化 toast 而非 banner：BOSS 掉落时本函数会紧接着发「BOSS 击破！」横幅，
## banner 是单例式后发覆盖先发，两边会互相吃掉；toast 队列（上限 4 条）则依次展示
func _on_artifact_acquired(id: String) -> void:
	var a := Registry.get_artifact(id)
	if a.is_empty():
		return
	_enqueue_toast("🔮 法宝入手", "%s %s · %s" % [String(a.get("ico", "")),
		String(a.get("name", id)), String(a.get("desc", ""))], "artifact", id)

func _on_achievement_unlocked(id: String) -> void:
	_enqueue_toast("🏆 成就达成", "%s %s · ✦%d 精华" % [CodexData.display_icon("achieve", id),
		CodexData.display_name("achieve", id), CodexData.achievement_reward(id)], "achieve", id)

## 解锁系统：结算时一次性广播本轮新解锁的内容（角色/武器）
func _on_unlocks_achieved(entries: Array) -> void:
	if entries.is_empty():
		return
	var names: Array = []
	for e in entries:
		var kind := String(e.get("kind", ""))
		var id := String(e.get("id", ""))
		if kind == "character":
			var ch: Dictionary = Registry.get_character(id)
			if not ch.is_empty():
				names.append("%s %s" % [String(ch.get("ico", "🧑")), String(ch.get("name", id))])
		else:
			var w: Dictionary = Registry.weapons.get(id, {})
			names.append("%s %s" % [String(w.get("ico", "🔧")), String(w.get("name", id))])
	if names.is_empty():
		return
	_enqueue_toast("🔓 解锁新内容", " · ".join(names))

func _enqueue_toast(title: String, body: String, cat := "", id := "") -> void:
	_toast_count += 1
	if _toast_panel == null or _toast_queue.size() >= 4:
		return
	_toast_queue.append({ "title": title, "body": body, "cat": cat, "id": id })
	if not _toast_panel.visible:
		_next_toast()

func _next_toast() -> void:
	if _toast_panel == null:
		return
	if _toast_queue.is_empty():
		_toast_panel.visible = false
		return
	var item: Dictionary = _toast_queue.pop_front()
	_toast_target = [String(item.get("cat", "")), String(item.get("id", ""))]
	var hint := "  ›" if String(item.get("cat", "")) != "" else ""
	_toast_label.text = "%s%s\n%s" % [String(item.get("title", "")), hint,
		String(item.get("body", ""))]
	_toast_panel.visible = true
	_toast_t = 1.15
	_toast_panel.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_toast_panel, "modulate:a", 1.0, 0.12)

func _build_toast() -> void:
	_toast_panel = PanelContainer.new()
	_toast_panel.anchor_left = 1.0
	_toast_panel.anchor_right = 1.0
	_toast_panel.offset_left = -340.0
	_toast_panel.offset_right = -16.0
	_toast_panel.offset_top = 76.0
	_toast_panel.offset_bottom = 134.0
	_toast_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_toast_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_toast_panel.gui_input.connect(_on_toast_gui_input)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.11, 0.15, 0.92)
	sb.border_color = Color("e8b84b")
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	_toast_panel.add_theme_stylebox_override("panel", sb)
	_toast_label = Label.new()
	_toast_label.add_theme_font_size_override("font_size", 13)
	_toast_label.add_theme_color_override("font_color", Color("f2e7c7"))
	_toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_panel.add_child(_toast_label)
	_toast_panel.visible = false
	$UI.add_child(_toast_panel)

## 点击 toast → 直达图鉴对应条目（鼠标 / 触屏）
func _on_toast_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_open_toast_target()
	elif event is InputEventScreenTouch and event.pressed:
		_open_toast_target()

## 局内打开图鉴：暂停战斗，关闭后恢复原阶段
func _open_toast_target() -> void:
	if _toast_target.size() < 2 or String(_toast_target[0]) == "":
		return
	var cat := String(_toast_target[0])
	var id := String(_toast_target[1])
	_toast_target = []
	if _toast_panel != null:
		_toast_panel.visible = false
	_toast_t = 0.0
	_ensure_codex()
	if _codex == null:
		return
	_codex_phase_before = -1
	if GameState.phase == GameState.Phase.PLAYING or GameState.phase == GameState.Phase.INTRO:
		_codex_phase_before = GameState.phase
		GameState.set_phase(GameState.Phase.PAUSED)
	_codex.open_entry(cat, id)

func _ensure_codex() -> void:
	if _codex != null:
		return
	_codex = preload("res://scenes/ui/codex.tscn").instantiate()
	$UI.add_child(_codex)
	_codex.closed.connect(_on_codex_closed)

func _on_codex_closed() -> void:
	if _codex_phase_before != -1:
		GameState.set_phase(_codex_phase_before)
		_codex_phase_before = -1
	_next_toast()

## 每波开始：BOSS 波切激烈曲，普通波切战斗曲；并按地图主题重建障碍物与氛围粒子
func _on_wave_started(w: int) -> void:
	Music.play_track(Music.track_for_wave(w), 0.35)
	_apply_map_theme(GameState.map_theme)
	if player != null and is_instance_valid(player):
		player.on_wave_start()   # 角色特性：战意按"本波击杀"重新累积

# ------------------------------------------------------------
# 地图主题化（Phase 5）
# 主题由波次推导（Config.map_theme_for_wave），每波开始时应用到背景/障碍物/粒子。
# 障碍物是「纯数据 + 手写判定」（见 systems/obstacles.gd），不是物理体
# ------------------------------------------------------------

var _theme_fx: Node2D = null
var obstacles_spawned := 0   # 测试观测：本波实际生成的障碍物数量

## 应用地图主题：重建障碍物 → 换氛围粒子 → 重绘竞技场
func _apply_map_theme(theme_id: String) -> void:
	var theme := Config.map_theme(theme_id)
	if theme.is_empty():
		return
	var target := GameRng.range_i(Config.OBSTACLE_MIN, Config.OBSTACLE_MAX)
	# BOSS 波压缩障碍物：既给 BOSS 弹幕留出走位空间，也避免地形把 BOSS 卡在角落
	if Config.is_boss_wave(wave_manager.wave):
		target = mini(target, Config.OBSTACLE_BOSS_MAX)
	obstacles_spawned = spawn_obstacles(theme_id, target)
	_rebuild_theme_fx(String(theme.get("particle", "bamboo_leaf")))
	queue_redraw()

## 生成本波障碍物并重建索引，返回实际数量。
## 拒绝采样：避开玩家出生点（世界中心）安全半径与四周边界，且块与块之间留出通道。
## 单点 12 次尝试失败就放弃该点，不做「强行塞到边上」的兜底——
## 否则会在出生点或角落堆出无法通行的死角
func spawn_obstacles(theme_id: String, count: int) -> int:
	var theme := Config.map_theme(theme_id)
	var kind := String(theme.get("obstacle", "bamboo"))
	var r := Obstacle.radius(kind)
	var wr := float(Config.WORLD.w)
	var hr := float(Config.WORLD.h)
	var origin := Vector2(wr, hr) * 0.5
	var margin := r + 48.0
	var min_gap := r * 2.0 + 56.0   # 块间最小间距：保证任何方向都走得过去
	var entries: Array = []
	for _i in count:
		for _try in 12:
			var p := Vector2(GameRng.range_f(margin, wr - margin),
				GameRng.range_f(margin, hr - margin))
			if p.distance_to(origin) < Config.OBSTACLE_SAFE_RADIUS + r:
				continue
			var blocked := false
			for e in entries:
				var ep: Vector2 = e.pos
				if p.distance_to(ep) < min_gap:
					blocked = true
					break
			if blocked:
				continue
			entries.append({ "pos": p, "kind": kind, "r": r })
			break
	Obstacles.rebuild(entries)
	return Obstacles.count()

## 换主题氛围粒子：同屏只留一套，切主题时销毁旧的
func _rebuild_theme_fx(particle_kind: String) -> void:
	if _theme_fx != null and is_instance_valid(_theme_fx):
		_theme_fx.queue_free()
	_theme_fx = null
	var world := Vector2(Config.WORLD.w, Config.WORLD.h)
	match particle_kind:
		"bamboo_leaf":
			_theme_fx = BambooLeaf.spawn(self, world)
		"incense":
			_theme_fx = Incense.spawn(self, world)
		"ghost_fire":
			_theme_fx = GhostFire.spawn(self, world)

# ------------------------------------------------------------
# 江湖奇遇事件卡（Phase 4）
# 流程：商店关闭 → try_trigger_event_card()（30% / 每局 3~5 次上限）
#       → 命中则弹卡（phase 保持 SHOP = 安全暂停态）
#       → 玩家三选一 → _execute_event_effect() → 启动被推迟的下一波
# 不新增 GameState.Phase：事件本就属于「商店后的间歇」，复用 SHOP 可避免
# 动到存档/暂停/商店三处的阶段判断，风险最低
# ------------------------------------------------------------

## 商店关闭后调用（由 shop_ui.next_wave 触发）。
## 返回 true = 已弹出事件卡，调用方不要再启动下一波（选择结束后由 main 启动）
func try_trigger_event_card(next_wave: int) -> bool:
	if event_card_ui == null:
		return false
	if GameState.event_card_count >= GameState.event_card_cap:
		return false
	if not GameRng.chance(Config.EVENT_CARD_CHANCE):
		return false
	var pool: Array = Config.event_card_pool(GameState.events_seen, wave_manager.wave)
	if pool.is_empty():
		return false
	var card: Dictionary = GameRng.weighted_pick(pool)
	if card.is_empty():
		return false
	_pending_wave_after_event = next_wave
	GameState.event_card_count += 1
	GameState.events_seen.append(String(card.get("id", "")))
	event_cards_played += 1
	event_card_ui.open(card)
	Sfx.play("ui_select")
	return true

## 玩家做出选择：执行效果 → 图鉴/统计/信号 → 横幅 → 启动下一波
func _on_event_choice(card_id: String, choice_index: int) -> void:
	var card: Dictionary = Config.event_card(card_id)
	var choices: Array = card.get("choices", [])
	if choice_index < 0 or choice_index >= choices.size():
		_finish_event_flow()
		return
	var ch: Dictionary = choices[choice_index]
	_execute_event_effect(ch.get("effect", {}))
	CodexData.add_stat("events")
	CodexData.unlock("event", card_id)
	EventBus.event_card_triggered.emit(card_id, "%s:%d" % [card_id, choice_index])
	EventBus.banner_requested.emit("奇遇 · %s" % String(card.get("title", "")),
		"%s · %s" % [String(ch.get("text", "")), String(ch.get("hint", ""))], 2.6)
	_finish_event_flow()

## 事件流程收尾：启动被推迟的那一波
func _finish_event_flow() -> void:
	var w := _pending_wave_after_event
	_pending_wave_after_event = 0
	if w > 0:
		wave_manager.start_wave(w)

## 执行事件选项效果。载荷键定义见 Config.EVENT_CARDS 头部注释；
## 未知键一律忽略（mod 内容前向兼容：新键在旧版本上不会炸）
func _execute_event_effect(effect: Dictionary) -> void:
	# ---- 前置消耗（UI 已置灰付不起的选项，这里只做二次保险）----
	var cost := int(effect.get("cost_materials", 0))
	if cost > 0:
		GameState.add_materials(-mini(cost, GameState.materials))
	var hp_pct := float(effect.get("hp_pct_cost", 0.0))
	if hp_pct > 0.0:
		# 至少保留 1 点生命：代价型选项不该变成自杀键
		var pay: float = minf(maxf(0.0, player.hp - 1.0), float(player.stats.max_hp) * hp_pct)
		if pay > 0.0:
			player.hp -= pay
			FloatingText.spawn(self, player.global_position + Vector2(0.0, -26.0),
				"-%d" % roundi(pay), Color("ff8a80"))
	# ---- 属性增益（与升级共用同一套 数据驱动 effects）----
	if effect.has("effects"):
		player.apply_effects(effect.get("effects", {}))
	# ---- 资源 ----
	var mats := int(effect.get("grant_materials", 0))
	if mats > 0:
		GameState.add_materials(mats)
	# ---- 随机道具（按品阶）----
	var ir := String(effect.get("grant_item_rarity", ""))
	if ir != "":
		_grant_random_item(ir)
	# ---- 随机武器 ----
	if bool(effect.get("grant_weapon", false)):
		_grant_random_weapon()
	# ---- 随机法宝 ----
	if bool(effect.get("grant_relic", false)):
		_grant_random_relic()
	# ---- 免费升级（下波开场补弹升级三选一）----
	var free_up := int(effect.get("free_upgrade", 0))
	if free_up > 0:
		GameState.level_queue += free_up
	# ---- 下波额外精英（风险代价）----
	var elites := int(effect.get("next_wave_elite", 0))
	if elites > 0:
		GameState.next_wave_elite += elites

## 按品阶随机获得一件道具；该品阶无内容时退回全量加权池（mod 内容变动时不吞奖励）
func _grant_random_item(rarity: String) -> void:
	var pool: Array = []
	for it in Registry.item_list():
		if String(it.get("rarity", "common")) == rarity \
				and Config.entry_weapon_relevant(it, player.weapons):
			pool.append({ "item": it, "w": 1.0 })
	if pool.is_empty():
		for it2 in Registry.item_list():
			if not Config.entry_weapon_relevant(it2, player.weapons):
				continue
			pool.append({ "item": it2,
				"w": Config.rarity_weight(String(it2.get("rarity", "common")), wave_manager.wave) })
	if pool.is_empty():
		return
	var picked: Dictionary = GameRng.weighted_pick(pool)
	var id := String(picked.get("id", ""))
	if id == "":
		return
	player.apply_item(id)
	FloatingText.spawn(self, player.global_position + Vector2(0.0, -48.0),
		"获得 %s %s" % [String(picked.get("ico", "")), String(picked.get("name", id))],
		Color("ffd24a"))

## 随机获得一把武器；武器槽已满时转材料补偿（别让奖励凭空消失）
func _grant_random_weapon() -> void:
	if player.weapons.size() >= MetaProgress.weapon_slots():
		var comp := 90
		GameState.add_materials(comp)
		FloatingText.spawn(self, player.global_position + Vector2(0.0, -48.0),
			"武器槽已满 · +%d ◆" % comp, Color("ffd24a"))
		return
	var wid := String(GameRng.weighted_pick(Registry.shop_weapon_pool()))
	if wid == "":
		return
	player.weapons.append({ "type": wid, "cd": 0.1 })
	player.refresh_family_synergy()
	var cfg: Dictionary = Registry.weapons.get(wid, {})
	FloatingText.spawn(self, player.global_position + Vector2(0.0, -48.0),
		"获得 %s %s" % [String(cfg.get("ico", "")), String(cfg.get("name", wid))], Color("ffd24a"))

## 随机获得一件未持有法宝；集齐后转等比材料补偿
func _grant_random_relic() -> void:
	var aff := Config.affinity_tags(GameState.character_id,
		player.weapons, player.artifacts_owned)
	var pool := Registry.artifact_pool(player.artifacts_owned, wave_manager.wave, false, aff)
	if pool.is_empty():
		GameState.add_materials(Config.ARTIFACT_DUP_MATERIALS)
		return
	var aid := String(GameRng.weighted_pick(pool))
	if aid == "":
		return
	player.apply_artifact(aid)   # 内部发 artifact_acquired → 队列化 toast 展示详情

func _exit_tree() -> void:
	Engine.time_scale = 1.0   # 双保险：切场景/测试结束不残留慢动作

func _on_enemy_killed(type: String) -> void:
	GameState.kills += 1
	if GameState.endless or GameState.daily:
		GameState.add_score(Config.kill_score(Registry.enemies.get(type, {})))
	Haptics.rumble(0.12, 0.0, 0.06)   # 击杀微震（Haptics 内部节流防叠满）

## 普通波清场后进入商店（BOSS 波击杀直接结算，不走这里）
## 波末自动回收场上全部掉落：经验/材料/红心直接结算，
## 升级选择若在此触发会积压 level_queue，下一波开始时补弹
func _on_wave_ended(w: int) -> void:
	if GameState.endless or GameState.daily:
		GameState.add_score(Config.wave_clear_score(w))
	shop_ui.open(w)
	Music.play_track("shop", 0.4)
	for l in get_tree().get_nodes_in_group("loot"):
		l.settle()
	shop_ui._refresh()   # 回收后刷新材料显示
	# 武器进化：单分支自动合成，多分支弹选择 UI 让玩家挑方向（回收后、存档前）
	_start_evolve_flow(w)

## 波末武器进化流程：先自动进化「单分支」武器，再逐个弹出「多分支」选择；
## 全部处理完后统一存档（进度包含所有进化结果）
func _start_evolve_flow(w: int) -> void:
	var evolved: Array = player.evolve_weapons()
	if not evolved.is_empty():
		Haptics.rumble(0.5, 0.2, 0.3)
		Sfx.play("victory")
		EventBus.banner_requested.emit("⚔ 武器进化！", " · ".join(evolved), 3.0)
		CodexData.add_stat("evolutions", evolved.size())
		shop_ui._refresh()   # 武器栏已变化
	_pending_evolve_choices = player.pending_evolve_choices()
	_pending_evolve_wave = w
	if _pending_evolve_choices.is_empty():
		_finish_evolve_flow()
	else:
		_show_next_evolve_choice()

## 弹出下一个待选择的进化方向
func _show_next_evolve_choice() -> void:
	if _pending_evolve_choices.is_empty():
		_finish_evolve_flow()
		return
	var choice: Dictionary = _pending_evolve_choices.pop_front()
	evolve_choose_ui.setup(choice)

## 玩家选定进化方向：执行指定进化 → 继续下一个待选
func _on_evolve_choice(weapon: String, target: String) -> void:
	var txt: String = player.evolve_weapon_to(weapon, target)
	if txt != "":
		Haptics.rumble(0.5, 0.2, 0.3)
		Sfx.play("victory")
		EventBus.banner_requested.emit("⚔ 武器进化！", txt, 3.0)
		CodexData.add_stat("evolutions", 1)
		shop_ui._refresh()
	_show_next_evolve_choice()

## 进化流程收尾：所有进化处理完，写入存档
func _finish_evolve_flow() -> void:
	var w := _pending_evolve_wave
	_pending_evolve_wave = 0
	if w > 0 and not SaveRun.save(w + 1, player, SaveRun.CHECKPOINT_WAVE_START):
		EventBus.banner_requested.emit("存档失败", "本次波次进度尚未写入", 2.0)

func _on_player_died() -> void:
	Music.play_track("defeat", 0.6)
	CodexData.set_stat_max("best_score", GameState.score)
	if SaveRun.current_run_owns_slot:
		SaveRun.clear()   # 仅清除已由本局成功写入/恢复的槽
	GameState.set_phase(GameState.Phase.GAME_OVER)
	EventBus.run_ended.emit(false)
	# 局外成长：结算土豆精华（跨局永久；每日挑战不计精华——榜单才是它的奖励）
	var earned := 0
	if not GameState.daily:
		earned = MetaProgress.grant_run_essence(GameState.score,
			wave_manager.wave, GameState.endless)
	# 每日挑战：死亡积分入今日榜（通关在 boss_killed 结算）
	if GameState.daily:
		var ch_d: Dictionary = Registry.get_character(GameState.character_id)
		var rank_d := Leaderboard.record(GameState.score, wave_manager.wave,
			String(ch_d.get("name", "?")), GameState.kills, GameState.run_time,
			"daily:" + GameState.daily_date)
		dead_label.text = "你倒下了 · 今日挑战积分 %d" % GameState.score
		if rank_d > 0:
			EventBus.banner_requested.emit("今日榜更新",
				"积分 %d · 今日第 %d 名" % [GameState.score, rank_d], 3.0)
	elif GameState.endless:
		# 无尽：成绩写入排行榜并展示名次
		var ch: Dictionary = Registry.get_character(GameState.character_id)
		var rank := Leaderboard.record(GameState.score, wave_manager.wave,
			String(ch.get("name", "?")), GameState.kills, GameState.run_time)
		dead_label.text = "你倒下了 · 积分 %d · 获得 ✦%d 精华" % [GameState.score, earned]
		if rank == 1:
			EventBus.banner_requested.emit("新纪录！",
				"积分 %d 登顶排行榜 · 获得 ✦%d 精华" % [GameState.score, earned], 3.0)
		elif rank > 1:
			EventBus.banner_requested.emit("挑战结束",
				"积分 %d · 排行榜第 %d 名 · ✦%d 精华" % [GameState.score, rank, earned], 3.0)
	else:
		dead_label.text = "你倒下了 · 获得 ✦%d 精华" % earned
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
	if GameState.daily:
		# 每日挑战：通关结算入今日榜（BOSS 击破加分 ×2）
		GameState.add_score(Config.boss_kill_score(wave_manager.wave) * 2)
		CodexData.set_stat_max("best_score", GameState.score)
		GameState.set_phase(GameState.Phase.VICTORY)
		EventBus.run_ended.emit(true)
		var ch_v: Dictionary = Registry.get_character(GameState.character_id)
		var rank_v := Leaderboard.record(GameState.score, wave_manager.wave,
			String(ch_v.get("name", "?")), GameState.kills, GameState.run_time,
			"daily:" + GameState.daily_date)
		victory_label.text = "今日挑战完成！· 积分 %d%s" % [GameState.score,
			" · 今日第 %d 名" % rank_v if rank_v > 0 else ""]
		victory_label.visible = true
		Music.play_track("victory", 0.6)
		Sfx.play("victory")
		_victory_menu.visible = true
		_victory_continue.visible = false   # 每日挑战无"继续无尽"
		for btn in _victory_menu.get_children():
			if btn is Button and btn.visible:
				btn.grab_focus()
				break
		return
	# 标准模式通关：存档保留到玩家作出选择（继续无尽会改写为无尽档）
	CodexData.set_stat_max("best_score", GameState.score)
	GameState.set_phase(GameState.Phase.VICTORY)
	EventBus.run_ended.emit(true)
	# 局外成长：通关结算土豆精华（按波次折算）
	var earned_v := MetaProgress.grant_run_essence(0, wave_manager.wave, false)
	victory_label.text = "通关！· 获得 ✦%d 精华" % earned_v
	victory_label.visible = true
	Music.play_track("victory", 0.6)
	Sfx.play("victory")
	_victory_menu.visible = true
	_victory_continue.grab_focus()   # 继续无尽（默认焦点）

## 通关后继续：保留第 10 波构筑与难度，从第 11 波进入无尽炼狱
func _continue_endless() -> void:
	if GameState.phase != GameState.Phase.VICTORY:
		return
	GameState.endless = true
	GameState.score = 0
	victory_label.visible = false
	_victory_menu.visible = false
	Haptics.rumble(0.3, 0.0, 0.1)
	if not SaveRun.save(11, player, SaveRun.CHECKPOINT_WAVE_START):
		EventBus.banner_requested.emit("存档失败", "无尽进度未写入，仍可继续游玩", 2.0)
	EventBus.banner_requested.emit("无尽炼狱开启", "从第 11 波继续，挑战没有尽头", 2.6)
	wave_manager.start_wave(11)

## 通关结算后结束本局（重开/回主菜单前清理存档；继续无尽则保留）
func _finish_victory_run() -> void:
	if GameState.phase == GameState.Phase.VICTORY and SaveRun.current_run_owns_slot:
		SaveRun.clear()

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
	var theme := Config.map_theme(GameState.map_theme)
	var g := 64.0
	var w := Config.WORLD.w
	var h := Config.WORLD.h
	# 主题底色（Phase 5）：氛围主要交给背景色，网格与边框取同系色保证可读性
	draw_rect(Rect2(0.0, 0.0, w, h), Color(String(theme.get("bg", "#101218"))), true)
	var grid_color := Color(String(theme.get("grid", "#222730")))
	var x := 0.0
	while x <= w:
		draw_line(Vector2(x, 0.0), Vector2(x, h), grid_color, 1.0)
		x += g
	var y := 0.0
	while y <= h:
		draw_line(Vector2(0.0, y), Vector2(w, y), grid_color, 1.0)
		y += g
	draw_rect(Rect2(0.0, 0.0, w, h), Color(String(theme.get("accent", "#4a5262"))), false, 4.0)
	# 障碍物：与背景同一遍绘制（静态内容，由 CanvasItem 缓存，不产生逐帧开销）
	Obstacles.draw_all(self)

# ---- 暂停 / 死亡 / 胜利 按钮菜单（代码构建，手柄可导航） ----

var _pause_overlay: Control = null
var _pause_resume: Button = null
var _pause_left: VBoxContainer = null
var _pause_items: VBoxContainer = null
var _victory_continue: Button = null

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
	_pause_left.add_child(head)
	var s: Dictionary = player.stats
	_pause_left.add_child(_pause_stat_row("生命", "%d / %d" % [roundi(player.hp), roundi(s.max_hp)]))
	_pause_left.add_child(_pause_stat_row("武器", "%d / %d" % [player.weapons.size(), MetaProgress.weapon_slots()]))
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
	var status_hit := 0.0
	for sid in Config.STATUS:
		status_hit += float(s.get("on_hit_" + String(sid), 0.0))
	if float(s.status_dmg_mult) > 0.0 or float(s.status_dur_mult) > 0.0 or status_hit > 0.0:
		_pause_left.add_child(_pause_stat_row("异常强化", "伤害 +%d%%｜时长 +%d%%｜命中 +%d%%"
			% [roundi(float(s.status_dmg_mult) * 100.0), roundi(float(s.status_dur_mult) * 100.0),
			roundi(status_hit * 100.0)]))
	# 状态图例：6 种异常说明 + 当前构筑已激活的高亮
	var legend_t := Label.new()
	legend_t.text = "状态图例"
	legend_t.add_theme_font_size_override("font_size", 13)
	legend_t.add_theme_color_override("font_color", Color("e8b84b"))
	legend_t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_left.add_child(legend_t)
	var sources: Dictionary = player.status_sources()
	for sid in Config.STATUS:
		var st_cfg: Dictionary = Config.STATUS[sid]
		var active := sources.has(String(sid))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var ico := Label.new()
		ico.text = String(st_cfg.get("ico", "❓"))
		ico.add_theme_font_size_override("font_size", 13)
		ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(ico)
		var st_name := Label.new()
		st_name.text = ("● " if active else "○ ") + String(st_cfg.get("name", sid))
		st_name.custom_minimum_size = Vector2(64.0, 0.0)
		st_name.add_theme_font_size_override("font_size", 12)
		st_name.add_theme_color_override("font_color",
			Color(String(st_cfg.get("color", "#9aa3b2"))) if active else Color("5a6270"))
		st_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(st_name)
		var desc := Label.new()
		desc.text = String(st_cfg.get("desc", ""))
		desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.add_theme_font_size_override("font_size", 11)
		desc.add_theme_color_override("font_color", Color("9aa3b2") if active else Color("4a5260"))
		desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(desc)
		_pause_left.add_child(row)
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
	# 右：已购道具（相同叠加显示数量）+ 法宝区
	for c in _pause_items.get_children():
		_pause_items.remove_child(c)
		c.queue_free()
	if player.items_owned.is_empty():
		var empty := Label.new()
		empty.text = "暂无道具"
		empty.add_theme_font_size_override("font_size", 12)
		empty.add_theme_color_override("font_color", Color("5a6270"))
		_pause_items.add_child(empty)
	else:
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
	_pause_artifact_rows()

## 暂停面板法宝区：法宝不占常驻 HUD（spec 第五章），这里是局内查看持有与叠层的入口。
## 叠层必须显示：断刃锋/玄武核的属性随层数涨，看不到层数就无法判断构筑强度。
func _pause_artifact_rows() -> void:
	var sep := ColorRect.new()
	sep.color = Color("2c3340")
	sep.custom_minimum_size = Vector2(0.0, 1.0)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_items.add_child(sep)
	var t := Label.new()
	t.text = "法宝"
	t.add_theme_font_size_override("font_size", 13)
	t.add_theme_color_override("font_color", Color("e8b84b"))
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_items.add_child(t)
	if player.artifacts_owned.is_empty():
		var empty := Label.new()
		empty.text = "暂无法宝（精英击杀 / BOSS / 商店可得）"
		empty.add_theme_font_size_override("font_size", 12)
		empty.add_theme_color_override("font_color", Color("5a6270"))
		_pause_items.add_child(empty)
		return
	for aid: String in player.artifacts_owned:
		var a: Dictionary = Registry.get_artifact(aid)
		if a.is_empty():
			continue   # mod 卸载后的残留持有，不画空行
		var row := HBoxContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var nm := Label.new()
		nm.text = "%s %s" % [a.get("ico", "🔮"), a.get("name", aid)]
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		nm.add_theme_font_size_override("font_size", 13)
		nm.add_theme_color_override("font_color", Config.rarity_color(a.get("rarity", "common")))
		nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(nm)
		var bits: Array[String] = []
		var elem := String(a.get("element", ""))
		if elem != "" and Config.ELEMENT_NAME.has(elem):
			bits.append(String(Config.ELEMENT_NAME[elem]))
		var stacks := int(player.artifact_stacks.get(aid, 0))
		if stacks > 0:
			bits.append("x%d 层" % stacks)
		var st := Label.new()
		st.text = " ".join(bits)
		st.add_theme_font_size_override("font_size", 13)
		st.add_theme_color_override("font_color", Color("f2e7c7"))
		st.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(st)
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
	# 胜利界面按钮：继续无尽 / 再来一局 / 返回主菜单
	victory_label.text = "通关！"
	var vic_vbox := VBoxContainer.new()
	vic_vbox.set_anchors_preset(Control.PRESET_CENTER)
	vic_vbox.offset_left = -140.0
	vic_vbox.offset_top = -52.0
	vic_vbox.offset_right = 140.0
	vic_vbox.offset_bottom = 148.0
	vic_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vic_vbox.add_theme_constant_override("separation", 8.0)
	vic_vbox.visible = false
	$UI.add_child(vic_vbox)
	_victory_continue = Button.new()
	_victory_continue.text = "🔥 继续挑战 · 无尽炼狱"
	_victory_continue.custom_minimum_size = Vector2(270.0, 46.0)
	_victory_continue.add_theme_font_size_override("font_size", 17)
	_victory_continue.pressed.connect(_continue_endless)
	vic_vbox.add_child(_victory_continue)
	var vic_tip := Label.new()
	vic_tip.text = "保留当前构筑，从第 11 波继续"
	vic_tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vic_tip.add_theme_font_size_override("font_size", 12)
	vic_tip.add_theme_color_override("font_color", Color("9aa3b2"))
	vic_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vic_vbox.add_child(vic_tip)
	var vic_retry := Button.new()
	vic_retry.text = "再来一局（R）"
	vic_retry.custom_minimum_size = Vector2(270.0, 38.0)
	vic_retry.pressed.connect(func() -> void:
		_finish_victory_run()
		get_tree().reload_current_scene())
	vic_vbox.add_child(vic_retry)
	var vic_back := Button.new()
	vic_back.text = "返回主菜单"
	vic_back.custom_minimum_size = Vector2(270.0, 38.0)
	vic_back.pressed.connect(func() -> void:
		_finish_victory_run()
		_goto_main_menu())
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
