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
## reaction_id -> 下次可发放「反应同化度」的时间戳（2026-09-19）。
## ⚠️ `EventBus.element_reaction` 是**每只怪各发一次**，AOE/扩散打中 N 只怪就是一帧 N 次；
##    不加这个闸，同化度增益就随「同屏怪数」线性膨胀（实测 W7 五系全灌到 2.0）。
var _assim_cd: Dictionary = {}
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

## 法宝盒子三选一（第 9 轮 · 需求 4）：中间 BOSS 的战利品
var boss_box_ui: Control = null
var _box_choices: Array = []      # 当前盒子的候选法宝 id（测试观测用）

## 场景属性地形区域（第 9 轮引入 · 第 16 轮起**跨区块累积、不销毁**，见 fx/terrain_zone.gd）
var _terrain_zones: Array = []   # 已生成并常驻的各区块地形（顺序 = 生成顺序）
var _terrain_block := 0          # 最近一片地形所属的区块号（0 = 还没有）

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
		# 读档会把 stats 整体覆盖：清掉区域增益槽位（此时场上还没有地形，槽位本应为空，
		# 这行是防"带着上一局的已应用量去做差减"那类静默扣属性，见 player.reset_zone_buffs）
		player.reset_zone_buffs()
	# 局外天赋（MetaProgress）：新局应用；读档局不重复应用（效果已烙进存档 stats）；
	# 每日挑战不吃局外天赋（全服同局，天赋会造成个体差异）
	if restored_wave == 0 and not GameState.daily:
		MetaProgress.apply_on_run_start(player)
		# 自定义开局规则：材料掉落倍率注入 harvesting（加成语义，与天赋/道具叠加）。
		# 难度缩放在 Registry 里由 "custom" 条目承载，这里只补经济维度
		var mat_bonus := RunRules.materials_bonus()
		if mat_bonus != 0.0:
			player.stats.harvesting = float(player.stats.harvesting) + mat_bonus
			player._sanitize_stats()
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
	# 悬浮气泡的宿主：挂 CanvasLayer（`$UI`）才能压在整个界面之上；
	# 挂到 HUD 上会被商店 / 暂停面板盖住（HUD 的 z 比它们低）
	hud.bubble_host = $UI
	# 江湖奇遇事件卡（Phase 4）
	event_card_ui = preload("res://scenes/ui/event_card.tscn").instantiate()
	$UI.add_child(event_card_ui)
	event_card_ui.player = player
	event_card_ui.chosen.connect(_on_event_choice)
	# 武器进化方向选择弹窗（多分支进化时让玩家挑方向）
	evolve_choose_ui = preload("res://scenes/ui/evolve_choose.tscn").instantiate()
	$UI.add_child(evolve_choose_ui)
	evolve_choose_ui.evolved.connect(_on_evolve_choice)
	# 法宝盒子三选一（第 9 轮 · 需求 4）
	boss_box_ui = preload("res://scenes/ui/boss_box.tscn").instantiate()
	$UI.add_child(boss_box_ui)
	boss_box_ui.player = player
	boss_box_ui.picked.connect(_on_boss_box_pick)
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
	# 逐波平衡日志（第 8 轮需求 4）：续档接着写（保住前面几波的历史），新局清空重记。
	# ⚠️ 必须在 `start_wave` 之前 —— `begin_wave` 的快照基线要取「本波尚未开始」时的计数。
	BalanceLog.begin_run(restored_wave > 0)
	if restored_wave > 0:
		# 区域加成护栏（§5.5.3 · S3.5）：读档会重新走 `start_wave(restored_wave)`，
		# 必须让**已经发过**的区块不再发一次，否则反复读同一档就能反复白拿同化度。
		#
		# 为什么一律是 `block_of(restored_wave) - 1`：
		#   本项目的所有存档点（含初始档）都在**被命名的那一波开始之前**写入
		#   （`save(w + 1, ...)` / `shop_ui.save(_wave + 1, ...)` / `start_wave(1)` 之前），
		#   所以 `restored_wave` 这一波的区域加成**一定还没发**，
		#   而它之前的所有区块都已经发过（且已烙进存档 stats）。
		#   → 记为「上一区」，让紧接着的 start_wave 恰好补上本区那一次。
		#   S4.5 起进度档的 checkpoint 是 `shop`（恢复后先开商店再开波），
		#   但「restored_wave 这一波尚未开始」这个前提不变 —— 本行不用改。
		GameState.area_bonus_block = maxi(0, Config.block_of(restored_wave) - 1)
		if SaveRun.restored_checkpoint == SaveRun.CHECKPOINT_WAVE_START:
			wave_manager.start_wave(restored_wave)
		else:
			shop_ui.open(restored_wave - 1)   # 商店档恢复：属性完整，货架重新生成
	else:
		GameState.start_run()
		# 主菜单选定的开局道具（角色属性/初始武器已在 player._ready 应用）。
		# S4.5 起向导不再有道具步 → 正常流程下这里是空串；保留分支是为了兼容旧档字段
		if GameState.loadout_item != "":
			player.apply_item(GameState.loadout_item)
		# ⚠️ 新局初始档**刻意**用 `wave_start`：第 1 波之前没有商店，
		#    写 `shop` 会让恢复时去开一个「第 0 波商店」。进度档（wave >= 2）才用 `shop`。
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
	_build_intro_countdown()
	# 返回键路由：Android 返回键走 NOTIFICATION_WM_GO_BACK_REQUEST（不是 ui_cancel），
	# 之前的版本没有任何地方接这个通知，导致移动端按返回键毫无反应。交给 Nav 统一派发。
	Nav.bind(self, _handle_back)
	queue_redraw()

## 底部操作提示 Label（`main.tscn` 的 `UI/Hint`）。
## ⚠️ 2026-09-17（第 7 轮）用户反馈「最下面 wasd 的文字遮挡了 ui」。两层修法：
##   ① `main.tscn` 里把它从 y∈[H-44, H-12]（正压在 `BottomLeft` 属性面板与武器槽行上）
##      抬到 y∈[H-122, H-96]（HUD 底带上方，介于属性面板顶边与屏幕内容之间）；
##   ② 这里再加一层 —— **只在 INTRO / PLAYING 显示**，商店 / 升级三选一 / 暂停 /
##      结算 / 图鉴时自动隐藏，免得它再压到那些页面的底栏。
## 用「每帧比较」而不是连 `phase_changed` 信号：相位在 main.gd / wave_manager.gd /
## shop_ui.gd 里被改了十几处，信号漏接一处就会残留；每帧一次 bool 比较成本可忽略。
var _hint_label: Label = null

func _process(delta: float) -> void:
	# 操作提示显隐：随阶段同步（只在真的变了时写，避免每帧触发重绘）
	if _hint_label == null:
		_hint_label = $UI.get_node_or_null("Hint") as Label
	if _hint_label != null:
		var hint_on := GameState.phase == GameState.Phase.PLAYING \
			or GameState.phase == GameState.Phase.INTRO
		if _hint_label.visible != hint_on:
			_hint_label.visible = hint_on
	# 开场倒计时读秒（INTRO 期间玩家被冻结不能移动，没有提示会被当成 bug）
	if _intro_label != null:
		var intro_on := GameState.phase == GameState.Phase.INTRO
		if intro_on:
			_intro_label.text = "准备… %d" % maxi(1,
				int(ceil(maxf(0.0, wave_manager.intro_t))))
		if _intro_label.visible != intro_on:
			_intro_label.visible = intro_on
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
	elif event.is_action_pressed("ui_cancel"):
		# 移动端：返回键由 Nav 统一路由（它同时接管 GO_BACK 通知与 ui_cancel 两条来路，
		# 两条路可能撞车，只能由一方处理）。这里主动让位，否则一次返回会被算成两次。
		if Nav.owns_back():
			return
		# 桌面：Esc 与 pause 同键已在上面的分支消费，能走到这里的只有手柄 B
		# → 战斗中暂停 / 暂停中恢复
		toggle_pause()
	elif event.is_action_pressed("toggle_mute"):
		Settings.toggle_mute()
		EventBus.banner_requested.emit("声音", "已静音" if Settings.master_vol <= 0.0001 else "已恢复", 1.0)
	# ---- 结算页 R 重开：按钮文案写「再来一局（R）」，R 必须真的生效 ----
	elif event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_R:
		match GameState.phase:
			GameState.Phase.GAME_OVER:
				get_tree().reload_current_scene()
			GameState.Phase.VICTORY:
				_finish_victory_run()
				get_tree().reload_current_scene()
		get_viewport().set_input_as_handled()
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
				# Ctrl+1~5 = 五把五行武器，与开局池一一对应（每把恰好一个元素）。
				# 刻意按 Config.LOADOUT_WEAPONS 顺序排：调试时顺手能轮一遍五个元素。
				KEY_1: _debug_set_weapon("knife")        # 金
				KEY_2: _debug_set_weapon("blight_bow")   # 木
				KEY_3: _debug_set_weapon("frost_staff")  # 水
				KEY_4: _debug_set_weapon("flamethrower") # 火
				KEY_5: _debug_set_weapon("thunder_gong") # 土
				KEY_6: wave_manager.spawn("shooter")
				KEY_7: wave_manager.spawn("boss")
		# 按 R 重开已移除（结算面板用「再来一局」主动重开）

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
	# §7.4 五行反应：给参与的两个元素（`from` / `to`）各加一点同化度。
	# ⚠️ **必须放在下面「特效节流」的 early return 之前** —— 那段节流管的是打击感
	#    （震屏 / 顿帧 / 中央提示），同化度是**玩法数值**，不该被视觉节流吃掉。
	# ⚠️ 若 reaction 缺 `from`/`to`，这里会**静默什么都不加** —— 由冒烟断言兜底。
	#
	# ⚠️⚠️ 按 reaction_id 冷却发放（2026-09-19）：本信号是**每只怪各发一次**，
	#    AOE / 中毒扩散一次打中 N 只怪就是一帧 N 次 → 增益本会随同屏怪数线性膨胀
	#    （实测 W7 就把五系全灌到上限 2.0）。加闸后增益只由**时间**决定，
	#    与怪数解耦；反应本身的伤害 / 特效 / 图鉴完全不受影响。
	var assim_now := Time.get_ticks_msec()
	if assim_now >= int(_assim_cd.get(reaction_id, 0)):
		_assim_cd[reaction_id] = assim_now + Config.REACTION_ASSIM_COOLDOWN_MS
		for r_el in [String(reaction.get("from", "")), String(reaction.get("to", ""))]:
			if r_el == "":
				continue
			# ⚠️ 必须显式标 String：`r_el` 取自 Array 是 Variant，`"assim_" + r_el` 推不出类型
			var r_key: String = "assim_" + r_el
			player.stats[r_key] = float(player.stats.get(r_key, 0.0)) + Config.REACTION_ASSIM_GAIN
		player._sanitize_stats()
	# 2026-09-19 卡顿修复：反应特效（粒子 + 震屏 + 顿帧 + 中央提示）整体并入节流。
	# 之前 Burst.spawn 在节流**之外**，连杆局面每秒几十~上百次反应各 spawn 一次粒子，
	# 实测与场上积压掉落物叠加把 144fps 打到 10fps。同化度（上面的数值）不受节流影响。
	var now := Time.get_ticks_msec()
	if now < _reaction_juice_cd:
		return
	_reaction_juice_cd = now + REACTION_JUICE_CD_MS
	_reaction_count += 1
	# 相克爆发更猛（复用 Burst，无额外场景开销）
	Burst.spawn(self, pos, accent, 22 if overcome else 12, 300.0 if overcome else 190.0)
	var fallback_shake := 4.0 if overcome else 1.8
	_on_screen_shake(float(reaction.get("shake", fallback_shake)))
	_trigger_hit_stop(REACTION_HIT_STOP_MS, HIT_STOP_SCALE)
	_show_reaction_popup(reaction, accent, overcome, now)

## 测试钩子：清空「反应同化度」的冷却表。
## 冒烟直接 emit `element_reaction` 来断言增益，若被前序用例留下的冷却挡掉会假失败。
func reset_reaction_assim_for_tests() -> void:
	_assim_cd.clear()

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

## 暂停页的「图鉴」按钮（第 8 轮）。
## ⚠️ 相位已经是 PAUSED了，**不要再压一层相位栈** ——
##    直接把图鉴叠在暂停遮罩之上，关闭后自然回到暂停页。
##    那么为什么 `_codex_phase_before = -1`？因为 -1 的语义就是「关闭时不还原相位」；
##    若照拄 `_open_toast_target` 记成 PAUSED，关闭时会反复写同一个值（无害但误导）。
func _open_codex_from_pause() -> void:
	_ensure_codex()
	if _codex == null:
		return
	_codex_phase_before = -1
	HintBubble.hide_for($UI)
	_codex.open()

## 退出游戏（第 8 轮）：暂停页与结算页共用。
## ⚠️ 不做任何存档动作。`SaveRun` 的存档点是「波末进商店」与「波开始」，
##    战斗中退出用的是上一波快照 —— 与「返回主菜单」完全一致，不会丢整局进度。
func _quit_game() -> void:
	get_tree().quit()

func _on_codex_closed() -> void:
	if _codex_phase_before != -1:
		GameState.set_phase(_codex_phase_before)
		_codex_phase_before = -1
	_next_toast()

## 每波开始：BOSS 波切激烈曲，普通波切战斗曲；并按地图主题切换氛围粒子
func _on_wave_started(w: int) -> void:
	BalanceLog.begin_wave(w)   # 逐波平衡日志（第 8 轮）：从本波起点开始累计增量
	Music.play_track(Music.track_for_wave(w), 0.35)
	_apply_map_theme(GameState.map_theme)
	_grant_area_bonus(w)
	_setup_terrain_zone(w)     # 场景属性地形区域（第 9 轮引入 / 第 16 轮改为常驻增益区）
	if player != null and is_instance_valid(player):
		player.on_wave_start()   # 角色特性：战意按"本波击杀"重新累积

## 区域加成（§5.5.3 · S3.5）：**进入某区块的第一波**给玩家该元素同化度 +`AREA_BONUS`。
##
## 为什么是「进区一次性」而不是「每波都发」：同化度是**养成轴**（§7），
## 每波都发会把它变成纯计时奖励；一次性发放才让它成为「选择在哪个区深耕」的取舍。
##
## ⚠️ 幂等护栏走 `GameState.area_bonus_block`（不落存档，由 _ready 按 restored_wave 反推）：
##    没有它，读档重进同一波就会重复领取（`start_wave` 会被读档路径重新调用）。
## ⚠️ 只在 `block > 已发区块` 时发 —— 用 `>` 而不是 `!=`，这样哪怕玩家因为某种
##    异常路径回到更早的波次，也不会把已经到手的区块重新发一遍。
func _grant_area_bonus(w: int) -> void:
	var block := Config.block_of(w)
	if block <= GameState.area_bonus_block:
		return
	GameState.area_bonus_block = block
	var area := GameState.area_element
	if area == "" or player == null or not is_instance_valid(player):
		return
	var key := "assim_" + area
	player.stats[key] = float(player.stats.get(key, 0.0)) + Config.AREA_BONUS
	player._sanitize_stats()   # 受 §7.2 上限约束
	# 横幅顺带交代**地面新增的那片区域**（第 16 轮 · 需求 6）：区域现在是"双方都能吃的
	# 增益"，不写出来玩家只能靠猜 —— 而它恰恰是"要不要在这一区开战"的决策依据。
	var ztxt := Config.zone_buff_text(area)
	var zdesc := String(Config.zone_buff(area).get("desc", ""))
	EventBus.banner_requested.emit(
		"第 %d 区块 · %s" % [block, Config.map_theme_name(GameState.map_theme)],
		"区域加成：%s同化度 +%d%%%s" % [String(Config.ELEMENT_NAME.get(area, area)),
			int(round(Config.AREA_BONUS * 100.0)),
			("　地上新增 %s（%s，敌我通用）" % [ztxt, zdesc]) if ztxt != "" else ""], 3.0)

## 场景属性地形区域（第 9 轮引入 · 第 16 轮按用户需求 6 重做）：
## 进入**新区块**（每 4 波）时**新增**一片圆形地形；**旧区不销毁** —— 用户原话
## 「场景轮转后，之前的区域不消失」。同一区块内四波复用同一片（圆心/属性都不变）。
##
## ⚠️ 判据用 `blk <= _terrain_block`（而不是 `==`）：读档 / 回退波次回到更早的区块时，
##    那片地本来就还在场上，不该重复生成第二片。
##
## ⚠️ 节点必须插成**第一个子节点**且 `z_index = 0`：它是地面装饰，
##    必须压在敌人 / 掉落物 / 玩家之下（铁律 3：新视觉元素必须显式声明 z_index 与预算组）。
##    它刻意不进 `fx` 组也不吃特效预算 —— 它是常驻地面，不是一次性特效。
func _setup_terrain_zone(w: int) -> void:
	if player == null or not is_instance_valid(player):
		return
	var blk := Config.block_of(w)
	if blk <= _terrain_block:
		return
	var z: Dictionary = Config.terrain_zone_for_wave(String(player.element), w)
	if z.is_empty():
		return
	# 无尽局会无限加片区 → 超出上限先把**最早**那片撤干净再踢掉（见 Config.TERRAIN_ZONE_MAX）
	while _terrain_zones.size() >= Config.TERRAIN_ZONE_MAX:
		var old = _terrain_zones.pop_front()
		if is_instance_valid(old):
			old.clear()
			old.queue_free()
	var zone: Node2D = TerrainZone.new()
	zone.zone_id = "blk%d" % blk
	zone.name = "TerrainZone_%s" % zone.zone_id
	zone.z_index = 0
	zone.player = player
	add_child(zone)
	move_child(zone, 0)
	if not zone.configure(z):
		zone.queue_free()
		return
	_terrain_block = blk
	_terrain_zones.append(zone)

## 撤销**所有**区域当前给玩家/敌人加的临时增益（区域节点本身**不销毁** —— 第 16 轮 ·
## 需求 6：场景轮转后旧区仍在；下一波回到 PLAYING 后各区的 0.35s 扫描会自动重写）。
##
## 消费点必须包含**所有「本波结束 / 即将写档 / 记平衡日志」的路径**
## （main._on_wave_ended / main._on_boss_killed / main._on_player_died）——
## 少一处的后果是站在区里的属性增益被 `SaveRun.save()` 当成**永久属性**写进档，
## **且完全不报错**（与第 9 轮那片临时同化度同源的坑）。
func _suspend_terrain_buffs() -> void:
	for zone in _terrain_zones:
		if is_instance_valid(zone):
			zone.clear()

# ------------------------------------------------------------
# 地图主题化（Phase 5）
# 主题由波次推导（Config.map_theme_for_wave），每波开始时应用到背景与氛围粒子。
# 主题只影响观感（底色 / 网格 / 边框 / 粒子），不影响玩法。
# ------------------------------------------------------------

var _theme_fx: Node2D = null

## §16.4 氛围粒子工厂：从 match 硬分支改为注册表。
## 新增第 4 种粒子只需在此加一行；mod 亦可走同一张表注册。
## 未知键：warn + 回落竹叶（与旧口径一致），不静默失败。
## ⚠️ 必须是 var 而非 const：字典值是对 class_name 的引用，GDScript 不把 class 引用算作
## 「常量表达式」，写成 const 会触发 "Assigned value for constant isn't a constant expression"。
var AMBIENT_FX := {
	"bamboo_leaf": BambooLeaf, "incense": Incense, "ghost_fire": GhostFire,
}

## 应用地图主题：换氛围粒子 → 重绘竞技场。
##
## 障碍物已整体移除（2026-09-14）。移除理由记录在此，避免以后有人不加思索地加回来：
##   · 地形遮挡只对远程弹丸生效 —— 近战斩击、火焰喷射、光环/脉冲特性、主动技能
##     全部不做遮挡查询，等于「玩家能隔墙打怪、怪却打不到玩家」，地形沦为单向掩体
##   · 怪群一多，地形与怪群叠加把走位空间挤死，与「靠走位生存」的核心体验直接冲突
## 场地因此回到纯开阔竞技场，主题只负责底色 / 网格 / 边框 / 氛围粒子。
func _apply_map_theme(theme_id: String) -> void:
	var theme := Config.map_theme(theme_id)
	if theme.is_empty():
		return
	# §16.2：优先用区块专属 ambient，空则回落主题默认 particle
	var pk := String(theme.get("ambient", ""))
	if pk == "":
		pk = String(theme.get("particle", "bamboo_leaf"))
	_rebuild_theme_fx(pk)
	queue_redraw()

## 换主题氛围粒子：同屏只留一套，切主题时销毁旧的
## 注意：未知 particle 键不静默失败 —— 与 Registry 对未知武器 fx 的处理口径一致（warn + 回落），
## 否则 Config.MAP_THEMES 里写错粒子名会表现为「该主题毫无氛围且查不到原因」
func _rebuild_theme_fx(particle_kind: String) -> void:
	if _theme_fx != null and is_instance_valid(_theme_fx):
		_theme_fx.queue_free()
	_theme_fx = null
	var world := Vector2(Config.WORLD.w, Config.WORLD.h)
	var factory: GDScript = AMBIENT_FX.get(particle_kind, null)
	if factory == null:
		push_warning("[main] 未知的氛围粒子键 %s，回落到竹叶；请检查 Config.MAP_THEMES 的 particle / ambient 字段"
			% particle_kind)
		factory = BambooLeaf
	_theme_fx = factory.spawn(self, world)

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
	# ⚠️ 金/红「唯一件」已持有的一律不进池 —— 否则「供奉兵器」这类选项会白吞一次奖励
	for it in Registry.item_list():
		if String(it.get("rarity", "common")) == rarity \
				and Config.entry_weapon_relevant(it, player.weapons) \
				and Config.unique_pool_ok(it, player.items_owned):
			pool.append({ "item": it, "w": 1.0 })
	if pool.is_empty():
		for it2 in Registry.item_list():
			if not Config.entry_weapon_relevant(it2, player.weapons) \
					or not Config.unique_pool_ok(it2, player.items_owned):
				continue
			pool.append({ "item": it2,
				"w": Config.rarity_weight(String(it2.get("rarity", "common")), wave_manager.wave) })
	if pool.is_empty():
		return
	var picked: Dictionary = GameRng.weighted_pick(pool)
	var id := String(picked.get("id", ""))
	if id == "":
		return
	if not player.apply_item(id):
		# 池已过滤，正常到不了这里；真撞上（同一件唯一件被别的路径先拿到）也不吞奖励，
		# 转材料补偿（与法宝重复获得的处理同口径）
		GameState.add_materials(Config.ARTIFACT_DUP_MATERIALS)
		return
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
##
## ⚠️ 波末**不再全场回收掉落物**（2026-09-19 用户要求，回到 2026-09-02 定的口径）：
## 经验/材料/红心**留在原地跨波**，由玩家自己走位拾取。
## 旧实现在这里 `for l in loot组: l.settle()`，会把整波掉落一次性结清 →
## 瞬间升好几级 → 连续弹 N 张升级卡（用户报「为什么会出现这么多次选择」）。
func _on_wave_ended(w: int) -> void:
	# 区域增益必须在**任何存档/结算之前**撤掉（第 16 轮；第 9 轮那片临时同化度同理）：
	# 它是临时加成，而本波结束后的 `_finish_evolve_flow` 会把 stats 写进存档 ——
	# 不撤的话站在区里拿到的属性会被**永久烙进存档**，且完全不报错。
	# 注意：撤的是**增益**，不是区域本身 —— 第 16 轮起区域跨波常驻（需求 6）。
	_suspend_terrain_buffs()
	if GameState.endless or GameState.daily:
		GameState.add_score(Config.wave_clear_score(w))
	# 波末结算期压住升级卡：本波掉落不再自动入账，但事件波/奇遇的免费升级
	# 仍可能在此积压；压住可保证「进化选择 / 法宝盒子 / 商店」不与升级卡同屏。
	# 由 level_up_ui 在下一波回到 PLAYING 时补弹；flow 进入商店时它会自行解除压住。
	level_up_ui.set_hold(true)
	# 武器进化：单分支自动合成，多分支弹选择 UI 让玩家挑方向（回收后、进商店前）。
	# 流程收尾（`_finish_evolve_flow` → `_enter_shop`）负责开商店 + 落档（需求 4：先奖励后商店）。
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

## 进化流程收尾：所有进化处理完，决定下一步。
## 法宝盒子（第 9 轮 · 需求 4）必须在**进化结算之后、开商店之前**开完，否则玩家选的
## 那件法宝不会进档（读档后凭空消失，且不报错）。盒子开完（或本就无盒子）才进入商店。
## ⚠️ 需求 4 配套：商店在 `_enter_shop` 里才打开，所以奖励盒子与商店不会同时可见 → 不重叠。
func _finish_evolve_flow() -> void:
	# 这里不自增任何计数器，只是把"开盒"插进流程中间；开完会再次回到本函数。
	if GameState.boss_boxes > 0:
		_open_boss_box()
		return
	_enter_shop(_pending_evolve_wave)

## 进入商店并把存档点钉在「进商店时刻」（第 13+ 轮需求 6）。
## 与进化/盒子流程同构：所有进化结算 + 盒子奖励都处理完，才到这里开商店 + 落档，
## 这样「恢复后重新开这一层商店」的断点稳定，且不会把没选完的奖励/进化丢进存档。
## 需求 4 配套：商店在本函数里才打开，奖励盒子（上一步）与商店不会同时可见 → UI 不重叠。
func _enter_shop(w: int) -> void:
	_pending_evolve_wave = 0
	if w <= 0:
		return
	Music.play_track("shop", 0.4)
	shop_ui.open(w)	# open 内部会 _roll_goods + _refresh
	# 需求 6：存档时机 = 进入商店时（CHECKPOINT_SHOP），下次进来直接回到商店页买道具
	if not SaveRun.save(w + 1, player, SaveRun.CHECKPOINT_SHOP):
		EventBus.banner_requested.emit("存档失败", "本次波次进度尚未写入", 2.0)
	# 逐波平衡日志（第 8 轮需求 4）：与存档**同刻**落盘，所以「日志里的状态 == 读档得到的状态」。
	# 这里也是「本波战斗数据」唯一完整的时刻 —— 掉落已回收（`_on_wave_ended`）、进化已结算。
	# 商店里买的东西不算进本波（它属于下一波的起点），这样逐波曲线才读得干净。
	BalanceLog.commit(w, player, "shop")

## 开一个法宝盒子（第 9 轮 · 需求 4）：3 件**未持有**法宝三选一。
## 与武器进化流程同构（`_show_next_evolve_choice` → 玩家选择 → 回到收尾），
## 所以两者可以叠加：先进化、再开盒、最后统一存档。
##
## 池空（15 件全持有）时**不弹空盒子**，直接折材料 —— 与 BOSS 直掉法宝的兜底同口径。
func _open_boss_box() -> void:
	if GameState.boss_boxes <= 0 or boss_box_ui == null:
		GameState.boss_boxes = 0
		_finish_evolve_flow()
		return
	var ids: Array = artifact_system.pick_artifact_choices(Config.BOSS_BOX_CHOICES)
	if ids.is_empty():
		var boxes: int = GameState.boss_boxes
		GameState.boss_boxes = 0
		var mat: int = Config.ARTIFACT_DUP_MATERIALS * Config.BOSS_BOX_CHOICES * boxes
		GameState.add_materials(mat)
		EventBus.banner_requested.emit("法宝已集齐",
			"%d 个盒子折算为 %d ◆" % [boxes, mat], 2.6)
		shop_ui._refresh()
		_finish_evolve_flow()
		return
	_box_choices = ids
	boss_box_ui.open(ids)

## 玩家选定盒子里的一件法宝。`id == ""` = 放弃（当前 UI 不提供该入口，留作安全网）。
func _on_boss_box_pick(id: String) -> void:
	GameState.boss_boxes = maxi(0, GameState.boss_boxes - 1)
	if id != "" and player != null and is_instance_valid(player):
		player.apply_artifact(id)
		Sfx.play("level_up")
		shop_ui._refresh()
	_open_boss_box()   # 还有盒子就接着开；开完自动回到 _finish_evolve_flow → 存档

func _on_player_died() -> void:
	_suspend_terrain_buffs()   # 同上：别把区域临时增益镀进逐波平衡日志
	Music.play_track("defeat", 0.6)
	CodexData.set_stat_max("best_score", GameState.score)
	if SaveRun.current_run_owns_slot:
		SaveRun.clear()   # 仅清除已由本局成功写入/恢复的槽
	# 逐波平衡日志（第 8 轮）：阵亡也记一笔 —— 「死在第 N 波、什么构筑、最低血量多少」
	# 正是平衡分析最想看的一组数。⚠️ 放在 `SaveRun.clear()` 之后：
	# 存档该清就清，日志刻意留着（它是分析产物，不是进度）。
	BalanceLog.commit(wave_manager.wave, player, "death")
	GameState.set_phase(GameState.Phase.GAME_OVER)
	EventBus.run_ended.emit(false)
	# 局外成长：结算土豆精华（跨局永久；每日挑战不计精华——榜单才是它的奖励）
	var earned := 0
	if not GameState.daily:
		earned = MetaProgress.grant_run_essence(GameState.score,
			wave_manager.wave, GameState.endless)
	# 自定义规则局不参与排行榜（is_competitive：参数可任意调低，上榜等于刷榜）。
	# 精华照给 —— 自定义规则是正当玩法，只是不计名次
	var ranked := RunRules.is_competitive()
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
	elif GameState.endless and ranked:
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
	elif GameState.endless:
		# 自定义规则的无尽局：照常给精华，只标注不入榜
		dead_label.text = "你倒下了 · 积分 %d · 获得 ✦%d 精华" % [GameState.score, earned]
		EventBus.banner_requested.emit("自定义规则局",
			"积分 %d · 不入排行榜 · ✦%d 精华" % [GameState.score, earned], 3.0)
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
	# 区域增益是**临时**加成，BOSS 一死本波就可能立刻结算/存档 → 先撤（第 16 轮；区域本身常驻）
	_suspend_terrain_buffs()
	if GameState.endless:
		# 无尽：积分与波次收尾由 wave_manager 处理（wave_ended → 商店 → 下一波）
		EventBus.banner_requested.emit("BOSS 击破！",
			"积分 +%d · 炼狱继续深入" % Config.boss_kill_score(wave_manager.wave), 2.2)
		return
	# 中间 BOSS（W4/8/12/16）：不通关，也不在这里发奖励。
	# ⚠️ 这个 `return` 是阻止"第 4 波 BOSS 一死就通关"的唯一闸门 —— 少了它，
	#    标准局会在 W4 直接进 VICTORY。
	# ⚠️ 盒子的发放**不在这里**：本函数在 `boss_killed` 的监听顺序里晚于 wave_manager，
	#    而后者已 emit 过 wave_ended（波末流程含存档）→ 在这里发会晚一整波。
	#    真正的发放点是 `wave_manager._on_boss_killed`，见那里的注释。
	if Config.is_mid_boss_wave(wave_manager.wave):
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
	# 通关记录（§9.4）：写 `clear_<角色 id>` = max(旧值, 本局难度档位) → 解锁该角色的下一档难度。
	# ⚠️ 只在**标准局通关**写这一处：每日挑战（上方分支）与自定义规则局都不写。
	#    自定义局的 difficulty_id 是 "custom" → `difficulty_index` 返回 0，
	#    而 set_stat_max 只增不减 → 天然是 no-op，不必再单独判一次 RunRules.
	CodexData.set_stat_max("clear_" + GameState.character_id,
		RunRules.difficulty_index(GameState.difficulty_id))
	BalanceLog.commit(wave_manager.wave, player, "victory")   # 逐波平衡日志：通关也记一笔
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

## 通关后继续：保留通关波的构筑与难度，从下一波进入无尽炼狱
## （自定义规则局的"通关波"不一定是第 20 波，所以用 BOSS 波号 +1，而不是写死 21）
func _continue_endless() -> void:
	if GameState.phase != GameState.Phase.VICTORY:
		return
	GameState.endless = true
	GameState.score = 0
	victory_label.visible = false
	_victory_menu.visible = false
	Haptics.rumble(0.3, 0.0, 0.1)
	var next_wave := maxi(2, wave_manager.wave + 1)
	if not SaveRun.save(next_wave, player, SaveRun.CHECKPOINT_WAVE_START):
		EventBus.banner_requested.emit("存档失败", "无尽进度未写入，仍可继续游玩", 2.0)
	EventBus.banner_requested.emit("无尽炼狱开启", "从第 %d 波继续，挑战没有尽头" % next_wave, 2.6)
	wave_manager.start_wave(next_wave)

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

## 开场倒计时（2026-09-19 用户要求）：INTRO 阶段给一个醒目读秒。
## 动机：INTRO 期间玩家**被冻结不能移动**（波次准备期），没有提示会被当成 bug
## （用户原话「不然还以为刚开始不能移动是 bug」）。
## 用独立 Label 而不是复用横幅 —— 横幅还要播报换区 / BOSS / 奇遇，语义会打架。
var _intro_label: Label = null

func _build_intro_countdown() -> void:
	_intro_label = Label.new()
	_intro_label.set_anchors_preset(Control.PRESET_CENTER)
	_intro_label.offset_left = -200.0
	_intro_label.offset_top = 96.0
	_intro_label.offset_right = 200.0
	_intro_label.offset_bottom = 172.0
	_intro_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_intro_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_intro_label.add_theme_font_size_override("font_size", 48)
	_intro_label.add_theme_color_override("font_color", Color("e8b84b"))
	_intro_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_intro_label.visible = false
	$UI.add_child(_intro_label)

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

## 返回键语义（Android 返回 / Windows 鼠标侧键 / 移动端的 ui_cancel 都汇到这里）。
## 与 _unhandled_input 的 ui_cancel 分支共用同一套相位判断，避免写两遍走偏。
## 返回 true = 已消费（Nav 不再往上找）。
func _handle_back() -> bool:
	# 强制选择态：升级 / 进化 / 奇遇卡都必须选完才能继续。
	# 允许返回会留下「没选强化就进了下一波」的中间态，宁可让返回键短暂失效。
	if GameState.phase == GameState.Phase.LEVEL_UP:
		return true
	if evolve_choose_ui != null and evolve_choose_ui.visible:
		return true
	if event_card_ui != null and event_card_ui.visible:
		return true
	# 战斗中 / 开场 / 已暂停：一律映射成暂停开关（与 Esc、摇杆暂停按钮同语义）
	if GameState.phase == GameState.Phase.PLAYING \
			or GameState.phase == GameState.Phase.INTRO \
			or GameState.phase == GameState.Phase.PAUSED:
		toggle_pause()
		return true
	# 商店：安全暂停态，返回 = 跳过商店进入下一波（与「下一波」按钮同语义）
	if GameState.phase == GameState.Phase.SHOP:
		shop_ui.next_wave()
		return true
	# 结算界面：与「返回主菜单」按钮完全同路径 ——
	# 通关必须先 _finish_victory_run() 清档，否则会留下一个「已通关但还能继续读」的档
	if GameState.phase == GameState.Phase.VICTORY:
		_finish_victory_run()
		_goto_main_menu()
		return true
	if GameState.phase == GameState.Phase.GAME_OVER:
		_goto_main_menu()
		return true
	return false

func toggle_pause() -> void:
	# 进化/法宝盒子选择卡都发生在 phase 仍是 PLAYING 的波末流程里 —— 此时按暂停会把
	# 暂停页叠在选择卡上（多层 UI 叠加反馈）。选择类界面打开期间暂停一律让位。
	if evolve_choose_ui != null and evolve_choose_ui.visible:
		return
	if boss_box_ui != null and boss_box_ui.visible:
		return
	if GameState.phase == GameState.Phase.PLAYING or GameState.phase == GameState.Phase.INTRO:
		_phase_before_pause = GameState.phase
		GameState.set_phase(GameState.Phase.PAUSED)
		_refresh_pause_content()
		_pause_overlay.visible = true
		_pause_resume.grab_focus()   # 继续游戏（手柄直达）
	elif GameState.phase == GameState.Phase.PAUSED:
		GameState.set_phase(_phase_before_pause)
		_pause_overlay.visible = false
		HintBubble.hide_for($UI)   # 关暂停页时收起悬浮说明

func _draw() -> void:
	var theme := Config.map_theme(GameState.map_theme)
	var g := 64.0
	var w := Config.WORLD.w
	var h := Config.WORLD.h
	# ---- ① bg_base：主题纯色底色（+ 可选元素染色 bg_tint）----
	draw_rect(Rect2(0.0, 0.0, w, h), Color(String(theme.get("bg", "#101218"))), true)
	var tint := String(theme.get("bg_tint", ""))
	if tint != "":
		var tc := Color(tint)
		tc.a = 0.18
		draw_rect(Rect2(0.0, 0.0, w, h), tc, true)
	# ---- ② bg_decor：预留装饰层（§16.2）：默认空实现，未来美术在此叠加竹林剪影/残垣/鬼火地纹/视差 ----
	_draw_bg_decor(theme)
	# ---- ③ grid：64px 网格（可被主题关掉，见 grid 字段）----
	var grid_color := Color(String(theme.get("grid", "#222730")))
	var x := 0.0
	while x <= w:
		draw_line(Vector2(x, 0.0), Vector2(x, h), grid_color, 1.0)
		x += g
	var y := 0.0
	while y <= h:
		draw_line(Vector2(0.0, y), Vector2(w, y), grid_color, 1.0)
		y += g
	# ---- ④ border：本区区域元素色强调边框（只读 Config，零判定，§5.5.3 · S3.5）----
	# 为什么要叠这一层：换区横幅只闪 2.2s，而「这一区是什么属性」是**要玩家记住的
	# 战术信息**（它决定本区主元素怪更多、更硬，也决定 BOSS 的属性）。
	# 边框是唯一全程在线的载体，所以由它承担；内描边再加一圈纯元素色，
	# 让玩家在弹幕里也能用余光认出属性。
	# ⚠️ 铁律 2：这里只读 Config 的颜色表，零判定 —— 边框不参与碰撞、遮挡、索敌。
	var accent := Color(String(theme.get("accent", "#4a5262")))
	var area := GameState.area_element
	if area != "":
		var ecol := Color(String(Config.ELEMENT_COLOR.get(area, "#ffffff")))
		draw_rect(Rect2(0.0, 0.0, w, h), accent.lerp(ecol, 0.55), false, 4.0)
		var inner := ecol
		inner.a = 0.35
		draw_rect(Rect2(6.0, 6.0, w - 12.0, h - 12.0), inner, false, 2.0)
	else:
		draw_rect(Rect2(0.0, 0.0, w, h), accent, false, 4.0)

## §16.2 预留的装饰层：当前不绘制任何内容（保持空实现，避免影响战斗可读性）。
## 未来接视差背景 / 竹林剪影 / 残垣 / 鬼火地纹时，只需在此按 theme 的装饰字段绘制，
## 不动 bg_base / grid / border 任一层。视觉层零判定（见 §16.5）。
func _draw_bg_decor(theme: Dictionary) -> void:
	pass

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
	# 小屏用安全区边距（避开刘海 / 打孔 / 手势条），桌面沿用 20
	var pm := UiMetrics.margin() if UiMetrics.prefers_full_page() else Vector2(20.0, 20.0)
	for m in ["margin_left", "margin_right"]:
		margin.add_theme_constant_override(m, int(pm.x))
	for m in ["margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(m, int(pm.y))
	_pause_overlay.add_child(margin)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 14)
	margin.add_child(hb)
	# 三栏宽度：小屏收窄（288/300 → 约 190/170），把中间按钮区让出来。
	# 旧版固定 288 + 300，在手机横屏（约 900 单位宽）会把中间挤到只剩 250，
	# 「继续游戏 / 返回主菜单」两个按钮几乎贴在一起
	var compact_pause := UiMetrics.prefers_full_page()
	var side_l := UiMetrics.dp(190.0) if compact_pause else 288.0
	var side_r := UiMetrics.dp(170.0) if compact_pause else 300.0
	var act_w := UiMetrics.dp(180.0) if compact_pause else 220.0
	var act_h := UiMetrics.touch_at_least(UiMetrics.dp(38.0)) if compact_pause else 44.0
	# 左：角色属性面板 —— 「固定视图 + 滚动条」（第 9 轮 · 用户要求）。
	# 属性行数随道具 / 法宝 / 同化度增长，裸 VBox 超出面板高度只会被裁掉，
	# 而且裁掉的部分**没有任何提示**（暂停页又正是玩家想核对属性的地方）。
	_pause_left = VBoxContainer.new()
	_pause_left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pause_left.add_theme_constant_override("separation", 4)
	var pl_scroll := ScrollContainer.new()
	pl_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pl_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pl_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	pl_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	pl_scroll.add_child(_pause_left)
	hb.add_child(_mk_side_panel(side_l, pl_scroll))
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
	# 移动端没有 Esc：提示改成返回键（Android 返回键现在由 Nav 路由到 pause 开关）
	tip.text = "返回键 / Start 继续" if compact_pause else "Esc / Start 继续"
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip.add_theme_font_size_override("font_size", 13)
	tip.add_theme_color_override("font_color", Color("9aa3b2"))
	center.add_child(tip)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center.add_child(spacer)
	_pause_resume = Button.new()
	_pause_resume.text = "继续游戏"
	_pause_resume.custom_minimum_size = Vector2(act_w, act_h)
	_pause_resume.pressed.connect(toggle_pause)
	center.add_child(_pause_resume)
	var menu_btn := Button.new()
	menu_btn.text = "返回主菜单"
	menu_btn.custom_minimum_size = Vector2(act_w, act_h)
	menu_btn.pressed.connect(_goto_main_menu)
	center.add_child(menu_btn)
	# ---- 第 8 轮：暂停页补「图鉴」与「退出游戏」----
	# 用户反馈「游戏中暂停看不到退出」。查证：这一页原本**只有**
	# 「继续游戏 / 返回主菜单」—— 根本没有退出入口（不是被挡住）。
	# 而回主菜单后，首页的「退出」在 16:9 全屏又会被切掉
	# （见 `main_menu._build_home`）—— 两个 bug 叠起来就是「退不出去」。
	# 图鉴按钮同样是用户要求：「需要暂停时可以看图鉴」。
	var codex_btn := Button.new()
	codex_btn.text = "图鉴"
	codex_btn.custom_minimum_size = Vector2(act_w, act_h)
	codex_btn.tooltip_text = "查看五行 / 武器 / 道具 / 法宝 / 敌人 / 奇遇 / 成就"
	codex_btn.pressed.connect(_open_codex_from_pause)
	center.add_child(codex_btn)
	var quit_btn := Button.new()
	quit_btn.text = "退出游戏"
	quit_btn.custom_minimum_size = Vector2(act_w, act_h)
	quit_btn.tooltip_text = "直接退出到桌面（本波进度 = 上一波进商店时的快照）"
	quit_btn.pressed.connect(_quit_game)
	center.add_child(quit_btn)
	# 右：已购道具（只展示，不出售）
	var rbox := VBoxContainer.new()
	rbox.add_theme_constant_override("separation", 6)
	var side := _mk_side_panel(side_r, rbox)
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
	# 悬浮看该属性的具体含义（第 8 轮）。只把**这一个 Label** 置为 STOP，
	# 整行仍是 IGNORE —— 不会挡住右侧数值。宿主用 `$UI`（气泡是 Control，
	# 挂 CanvasLayer 下才能在整个酸盘层之上自由定位；挂 Node2D 上会跟着相机跑）。
	# 悬浮看该属性的具体含义 —— 但**只对「不看说明就不知道」的属性弹**（第 11 轮收窄）。
	# 原先是 15 条基础属性全挂（生命/伤害/攻速…），用户反馈那是噪音；
	# 判断依据集中在 `EntryText.HOVER_HELP`，这里不做第二份名单。
	# 不挂时 Label 保持 IGNORE（整行仍然完全穿透），与改动前的点击行为一致。
	if EntryText.needs_help(name_text):
		HintBubble.attach_hover(l, name_text, EntryText.stat_help(name_text), $UI)
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
	HintBubble.hide_for($UI)   # 重建面板前先收起气泡，否则会留一张上次的旧卡
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
	# 武器容量 = 永久槽 + 临时槽（需求 3）；暂停界面也能查看当前武器（需求 2）
	var _pperm: int = player.weapons.size()
	var _ptemp: int = player.temp_weapons.size()
	_pause_left.add_child(_pause_stat_row("武器",
		"%d / %d（临时槽 %d/%d）"
		% [_pperm + _ptemp, MetaProgress.weapon_slots() + Config.TEMP_WEAPON_SLOTS,
		   _ptemp, Config.TEMP_WEAPON_SLOTS]))
	var _pwl := ""
	for _pw in player.weapons:
		var _pwc: Dictionary = Registry.weapons.get(String(_pw.get("type", "")), {})
		_pwl += (", " if _pwl != "" else "") + String(_pwc.get("name", "?"))
	for _pt in player.temp_weapons:
		var _ptc: Dictionary = Registry.weapons.get(String(_pt.get("type", "")), {})
		_pwl += (", " if _pwl != "" else "") + String(_ptc.get("name", "?")) + "（临时）"
	if _pwl != "":
		var _pwlab := Label.new()
		_pwlab.text = "持有：" + _pwl
		_pwlab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_pwlab.add_theme_font_size_override("font_size", 11)
		_pwlab.add_theme_color_override("font_color", Color("9aa3b2"))
		_pwlab.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_pause_left.add_child(_pwlab)
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
	# ---- 五行同化度（§6.2 / S5）----
	# ⚠️ 2026-09-17（第 7 轮）用户问「角色同化度属性为什么没有显示在角色面板上」。
	#    查证结论：在 game/scripts/ui/** 里 grep `assim` **零命中** —— 同化度此前只在
	#    战斗计算（Config.hit_mult / out_mult）与存档里被读写，**界面层从不展示**。
	#    这是「真缺失」而不是「显示错了」。
	# 语义：assim_<元素> 是同一个数字的两个方向 —— 受击侧按 `hit_mult` 减伤（你就是
	#    这种元素，挨打更不痛），输出侧按 `out_mult` 加伤（就是上面那「异常强化」一行
	#    的位置，同化度走独立通道，不在那三个百分比里）。所以这里直接把双向含义写在表头。
	# ⚠️ 只列 > 0 的元素：白板角色（potato）与未堆同化的局不开这一节，
	#    免得 5 行 0% 白占版面；元素顺序走 Config.ELEMENTS（字母序，与图鉴一致）。
	# ⚠️ 第 11 轮：用户反馈「现在的同化度不够清晰」。原先只报 `+12%` 这个**库存值**，
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
				"+" if give_pct > 0 else "", give_pct]))
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
	# 右栏重建起点 —— ⚠️ 本句必须在**任何** `_pause_items.add_child()` 之前。
	# 第 11 轮踩到过：武器区第一版写在这句上面，加完就被它清掉 ——
	# 面板上一行武器都没有，而且**不报任何错**（「分区标题存在」类断言也照样判绿，
	# 因为标题一起被删了）。修法是把清空提前，并补一条断言**具体条目**的冒烟用例。
	for c in _pause_items.get_children():
		_pause_items.remove_child(c)
		c.queue_free()
	# 右：**临时增益区**（第 11 轮新增 · 用户需求 6）
	# 用户原话：「技能/地图区域 buff 应在武器上方显示、暂停可点看、局内可悬浮看」。
	# 这里只列**当前真的生效**的（数据源与 HUD 增益条同为 `player.active_buffs()`），
	# 点名字出详情 —— 两个入口同源，所以永远不会互相说不一致的话。
	var bft := Label.new()
	bft.text = "临时增益"
	bft.add_theme_font_size_override("font_size", 13)
	bft.add_theme_color_override("font_color", Color("e8b84b"))
	bft.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_items.add_child(bft)
	var buffs_now: Array = player.active_buffs()
	if buffs_now.is_empty():
		var bfe := Label.new()
		bfe.text = "暂无（技能 / 地脉区域 / 战意生效时自动出现）"
		bfe.add_theme_font_size_override("font_size", 12)
		bfe.add_theme_color_override("font_color", Color("5a6270"))
		bfe.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_pause_items.add_child(bfe)
	else:
		for b in buffs_now:
			var bd: Dictionary = b
			var brow := HBoxContainer.new()
			brow.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var bl := Label.new()
			bl.text = "%s %s" % [String(bd.get("ico", "✨")), String(bd.get("name", "增益"))]
			bl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			bl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			bl.add_theme_font_size_override("font_size", 13)
			bl.add_theme_color_override("font_color", Color(bd.get("color", Color("7ee0c0"))))
			bl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			brow.add_child(bl)
			HintBubble.attach_click(bl, func() -> Dictionary:
				return EntryText.buff_detail(bd), $UI)
			var bv := Label.new()
			var b_remain := float(bd.get("remain", -1.0))
			bv.text = ("%.1fs" % b_remain) if b_remain >= 0.0 else "持续"
			bv.add_theme_font_size_override("font_size", 13)
			bv.add_theme_color_override("font_color", Color("f2e7c7"))
			bv.mouse_filter = Control.MOUSE_FILTER_IGNORE
			brow.add_child(bv)
			_pause_items.add_child(brow)
	var bfsep := ColorRect.new()
	bfsep.color = Color("2c3340")
	bfsep.custom_minimum_size = Vector2(0.0, 1.0)
	bfsep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_items.add_child(bfsep)
	# 右：**武器区**（第 11 轮新增）
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
	# ⚠️ 清空**不能**再在这里做一次：它已经提到本栏开头（见那里的注释）。
	#    放在这里会把上面刚建好的临时增益区 + 武器区一起删掉。
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
			# 点击道具名 → 加成 + 描述（第 8 轮）
			HintBubble.attach_click(l2, func() -> Dictionary:
				return EntryText.entry_detail(Registry.items.get(id, {}), "道具"), $UI)
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
		HintBubble.attach_click(nm, func() -> Dictionary:
			return EntryText.entry_detail(Registry.get_artifact(aid), "法宝"), $UI)
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
	# 结算页按钮高度（移动端适配补齐）：38 单元 ≈ 38dp，够不着 Material 的 48dp 最小可点尺寸，
	# 手机上「再来一局 / 返回主菜单 / 退出游戏」会点空。触摸设备按触控下限抬到 48dp。
	# ⚠️ 必须 gate 在 `prefers_full_page()` 上：桌面 units_per_inch≈96，`dp(38)` 只有 22.8，
	#    直接套 dp 会让桌面按钮**变矮**（与 `_build_pause_panel` 同样的写法与理由）。
	var full := UiMetrics.prefers_full_page()
	var h_btn := UiMetrics.touch_at_least(UiMetrics.dp(38.0)) if full else 38.0
	var h_btn_big := UiMetrics.touch_at_least(UiMetrics.dp(46.0)) if full else 46.0
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
	retry_btn.custom_minimum_size = Vector2(200.0, h_btn)
	retry_btn.pressed.connect(func() -> void: get_tree().reload_current_scene())
	dead_vbox.add_child(retry_btn)
	var back_btn := Button.new()
	back_btn.text = "返回主菜单"
	back_btn.custom_minimum_size = Vector2(200.0, h_btn)
	back_btn.pressed.connect(_goto_main_menu)
	dead_vbox.add_child(back_btn)
	# 第 8 轮：结算页也得能退 —— 否则只能先回主菜单再找那个被切掉的「退出」
	var dead_quit := Button.new()
	dead_quit.text = "退出游戏"
	dead_quit.custom_minimum_size = Vector2(200.0, h_btn)
	dead_quit.pressed.connect(_quit_game)
	dead_vbox.add_child(dead_quit)
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
	_victory_continue.custom_minimum_size = Vector2(270.0, h_btn_big)
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
	vic_retry.custom_minimum_size = Vector2(270.0, h_btn)
	vic_retry.pressed.connect(func() -> void:
		_finish_victory_run()
		get_tree().reload_current_scene())
	vic_vbox.add_child(vic_retry)
	var vic_back := Button.new()
	vic_back.text = "返回主菜单"
	vic_back.custom_minimum_size = Vector2(270.0, h_btn)
	vic_back.pressed.connect(func() -> void:
		_finish_victory_run()
		_goto_main_menu())
	vic_vbox.add_child(vic_back)
	var vic_quit := Button.new()
	vic_quit.text = "退出游戏"
	vic_quit.custom_minimum_size = Vector2(270.0, h_btn)
	vic_quit.pressed.connect(_quit_game)
	vic_vbox.add_child(vic_quit)
	_victory_menu = vic_vbox

func _goto_main_menu() -> void:
	BalanceLog.close_run()   # 逐波平衡日志（第 8 轮）：回主菜单即停止累计（盘上日志保留）
	Haptics.rumble(0.3, 0.0, 0.1)
	# 商店是安全点：离开前落盘，口径与其它存档点一致（S4.5 = 通过波次进商店，checkpoint `shop`）。
	# 战斗/升级中不落盘 —— 保留上一波进商店时的快照，避免「退出重进刷本波收益」。
	if GameState.phase == GameState.Phase.SHOP:
		if not SaveRun.save(wave_manager.wave + 1, player, SaveRun.CHECKPOINT_SHOP):
			EventBus.banner_requested.emit("存档失败", "无法返回主菜单，请检查磁盘空间", 2.0)
			return
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
