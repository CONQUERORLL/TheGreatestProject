extends Node
## 冒烟测试：武器闭环 + 掉落拾取 + 波次推进（波末掉落自动回收）+ 商店 + BOSS 弹幕
##   + 升级三选一（含波末积压升级补弹）+ HUD + 手柄焦点 + Registry/mod 加载 + 数值断言
##   + 粒子/飘字/爆炸特效（fx 组）+ 稀有度加权/新品阶/新角色/新怪物回归
##   + 无尽炼狱（BOSS 波衔接/积分/存档/排行榜）+ 240 敌群性能压测
## 运行：godot --headless --path . res://tests/smoke_test.tscn（退出码 0=通过）

class SegmentEnemy:
	extends Node2D
	var flee := 0.0
	var radius := 1.0

var _main: Node
var _last_ended := 0
var _mats_at_end := -1      # 第 1 波收波结算后的材料数（含自动回收）
var _xp_at_end := -1        # 第 1 波收波结算后的经验/等级收益
## 波末「不自动回收」哨兵（2026-09-19）：收波前往场上放一个掉落物，收波后它必须
## 仍在原处 —— 旧实现在 `main._on_wave_ended` 里对 loot 组逐个 `settle()`，会把它吃掉。
var _loot_sentinel = null
var _loot_sentinel_pos := Vector2.ZERO
var _failed := false        # 失败标记：await 协程内 _fail 后外层不再继续输出 PASS
var _event_suppress_count := 0   # 奇遇抑制：原 event_card_count
var _event_suppress_cap := 0     # 奇遇抑制：原 event_card_cap

const TEST_SAVE_ROOT := "user://tests/smoke_run"
const TEST_CODEX_PATH := "user://tests/codex_data.json"
const TEST_META_PATH := "user://tests/meta_progress.json"
const TEST_STEAM_PATH := "user://tests/steam_pending.json"
const TEST_UNLOCKS_PATH := "user://tests/unlocks.json"

func _ready() -> void:
	SaveRun.set_storage_root_for_tests(TEST_SAVE_ROOT)
	# 逐波平衡日志（第 8 轮）同款隔离：用例会真的写 user:// 日志，绝不能落到正式档上
	BalanceLog.set_storage_root_for_tests(TEST_SAVE_ROOT)
	# 第 13 轮：整局轨迹日志同款隔离（它每 1s 落一次盘，不隔离会写进正式 run_trace/）
	RunTrace.set_dir_for_tests(TEST_SAVE_ROOT + "/run_trace/")
	_cleanup_test_storage(false)
	# 隔离本机天赋档（必须在清理之后：清理会还原存储路径）
	MetaProgress.set_storage_path_for_tests(TEST_META_PATH)
	MetaProgress.reset_for_tests()   # 开局加成会污染数值断言
	CodexData.set_storage_path_for_tests(TEST_CODEX_PATH)
	CodexData.reset_for_tests()
	PlatformAchievements.set_storage_path_for_tests(TEST_STEAM_PATH)
	PlatformAchievements.reset_for_tests()
	Unlocks.set_storage_path_for_tests(TEST_UNLOCKS_PATH)
	Unlocks.reset_for_tests()
	_main = preload("res://scenes/main.tscn").instantiate()
	add_child(_main)
	# 音频：SFX / Music 独立总线 + 主场景自动切战斗 BGM + 独立音量生效
	if AudioServer.get_bus_index(Settings.BUS_SFX) == -1 \
			or AudioServer.get_bus_index(Settings.BUS_MUSIC) == -1:
		_fail("SFX / Music 音频总线未创建")
		return
	# 平台成就桥：未接入 Steam 时静默降级为待上报队列（游戏内成就/奖励不受影响）
	if PlatformAchievements == null or PlatformAchievements.is_available():
		_fail("PlatformAchievements 未注册或 headless 误检测到 Steam 后端")
		return
	# 成就数量不写死数字：真实判据是 PlatformAchievements._load_steam_config 的
	# `defs == STEAM_IDS == ACHIEVEMENTS` 三方对齐（steam_config_valid）。
	# 这里另守一个**下限**，防止「三处一起删掉一条」把配置整体缩水还判绿。
	const ACH_FLOOR := 13
	if not PlatformAchievements.steam_config_valid() \
			or PlatformAchievements.steam_definitions().size() \
				!= CodexData.ACHIEVEMENTS.size() \
			or PlatformAchievements.steam_definitions().size() < ACH_FLOOR:
		_fail("Steamworks 成就配置未完整对齐（defs=%d / codex=%d / 下限 %d）"
			% [PlatformAchievements.steam_definitions().size(),
				CodexData.ACHIEVEMENTS.size(), ACH_FLOOR])
		return
	var steam_defs: Dictionary = PlatformAchievements.steam_definitions()
	for achievement_id in CodexData.ACHIEVEMENTS:
		var aid := String(achievement_id)
		if not steam_defs.has(aid) \
				or String(steam_defs[aid].get("api_name", "")) \
					!= String(PlatformAchievements.STEAM_IDS.get(aid, "")):
			_fail("Steamworks API Name 映射错误（%s）" % aid)
			return
	for category in CodexData.UNLOCK_REWARDS:
		var unlock_reward := CodexData.unlock_reward(String(category))
		if unlock_reward < 4 or unlock_reward > 7:
			_fail("图鉴奖励超出平衡范围（%s=%d）" % [String(category), unlock_reward])
			return
	for achievement_id in CodexData.ACHIEVEMENTS:
		if CodexData.achievement_reward(String(achievement_id)) <= 0:
			_fail("成就奖励必须为正数（%s）" % String(achievement_id))
			return
	if not CodexData.achievement_reward("first_blood") \
			< CodexData.achievement_reward("slayer_100") \
			or not CodexData.achievement_reward("slayer_100") \
				< CodexData.achievement_reward("slayer_1000") \
			or not CodexData.achievement_reward("survivor_5") \
				< CodexData.achievement_reward("clear_10") \
			or not CodexData.achievement_reward("clear_10") \
				< CodexData.achievement_reward("clear_20") \
			or not CodexData.achievement_reward("clear_20") \
				< CodexData.achievement_reward("endless_20") \
			or not CodexData.achievement_reward("boss_hunter") \
				< CodexData.achievement_reward("boss_10"):
		_fail("成就奖励未保持阶梯递进")
		return
	# 通关成就（clear_20）与无尽成就（endless_20）**必须不同源**：
	# 标准局 best_wave 最高只到 19 —— 第 9 轮改版后中间 BOSS（W4/8/12/16）会正常派发
	# wave_ended，但**最终 BOSS（W20）不派发**（它直接走通关分支），
	# 所以 best_wave 永远够不到 20，endless_20 只在无尽成立。
	# 若后人图省事把 clear_20 改成 best_wave 20，两条成就会永远同时解锁 —— 这条守住它。
	var c20: Dictionary = CodexData.ACHIEVEMENTS.get("clear_20", {})
	var e20: Dictionary = CodexData.ACHIEVEMENTS.get("endless_20", {})
	if c20.is_empty() or String(c20.get("stat", "")) != "victories" \
			or int(c20.get("target", 0)) != 1:
		_fail("clear_20 必须以 victories>=1 判定（当前 %s）" % str(c20))
		return
	if not e20.is_empty() and String(e20.get("stat", "")) == String(c20.get("stat", "")):
		_fail("clear_20 与 endless_20 同源（stat=%s），两条成就会同时解锁"
			% String(c20.get("stat", "")))
		return
	var forwarded_before: int = PlatformAchievements.forwarded_count()
	EventBus.achievement_unlocked.emit("first_blood")
	if PlatformAchievements.forwarded_count() <= forwarded_before \
			or PlatformAchievements.pending_count() <= 0:
		_fail("平台成就桥未接收/排队成就")
		return
	# 离线队列落盘：未接入平台时成就 id 写入隔离的 user:// 队列文件
	if not FileAccess.file_exists(TEST_STEAM_PATH):
		_fail("平台成就离线队列未落盘")
		return
	# 模拟 SDK 就绪（重启恢复队列 → 自动补发到 Steamworks 后台）
	PlatformAchievements.reset_for_tests()
	PlatformAchievements._load_pending()
	if PlatformAchievements.pending_count() <= 0:
		_fail("平台成就离线队列未从磁盘恢复")
		return
	PlatformAchievements.set_backend_for_tests("steam")
	if not PlatformAchievements.steam_stats_ready():
		_fail("注入 Steam 后端未进入统计就绪态")
		return
	PlatformAchievements._flush_pending()
	if PlatformAchievements.pending_count() != 0 \
			or not _forwarded_call(PlatformAchievements.test_calls(), "ACH_FIRST_BLOOD") \
			or not _store_stats_call(PlatformAchievements.test_calls()):
		_fail("平台成就未在后端可用时补发（calls=%s）" % str(PlatformAchievements.test_calls()))
		return
	PlatformAchievements.set_backend_for_tests("")   # 还原真实检测（headless 无 SDK）
	# 胜利统计：事件累加后写盘，再从磁盘恢复；旧格式缺少 victories 时默认为 0
	var victories_before: int = CodexData.stat("victories")
	EventBus.run_ended.emit(true)
	EventBus.run_ended.emit(false)
	if CodexData.stat("victories") != victories_before + 1:
		_fail("胜利统计累加错误（%d -> %d）"
			% [victories_before, CodexData.stat("victories")])
		return
	CodexData._save_now()
	CodexData.reset_for_tests()
	CodexData._load()
	if CodexData.stat("victories") != victories_before + 1:
		_fail("胜利统计保存/加载失败（%d）" % CodexData.stat("victories"))
		return
	if Music.current_track() != "battle":
		_fail("战斗 BGM 未随主场景启动（%s）" % Music.current_track())
		return
	# 外部 BGM 素材：存在则必须优先走文件加载（缺失时回退程序生成，仍可运行）
	if FileAccess.file_exists("res://assets/audio/bgm/battle.wav") \
			and Music.current_source() != "file":
		_fail("外部 BGM 未优先加载（source=%s）" % Music.current_source())
		return
	# BGM 分波次：按**区块**升级（区块 1 battle / 区块 2 battle_mid / 区块 3+ battle_late）。
	# 断言覆盖每个区块的首尾两波 —— 只测区块中段会漏掉 `block_of` 的边界写错。
	# ⚠️ 这张表里**只能放非 BOSS 波**：第 9 轮起区块末波（W4/8/12/16）也是 BOSS 波，
	#    它们的曲子交给下面的循环统一校验；写进这张表会立刻以"BGM 映射错了"报红。
	var bgm_expect := { 1: "battle", 3: "battle", 5: "battle_mid", 7: "battle_mid",
		9: "battle_late", 19: "battle_late" }
	for bw in bgm_expect:
		if Music.track_for_wave(int(bw)) != String(bgm_expect[bw]):
			_fail("BGM 分波次映射错误（W%d → %s，期望 %s）"
				% [int(bw), Music.track_for_wave(int(bw)), String(bgm_expect[bw])])
			return
	# BOSS 波（含第 9 轮新增的中间 BOSS）必须一律切 BOSS 曲。
	# ⚠️ 期望集**从被测数据算**（`Config.is_boss_wave`），不写死 4/8/12/16 ——
	#    否则以后调整 BOSS 节奏（每 4 波 → 每 5 波）时会以"BGM 坏了"的面目报红。
	for bw2 in range(1, Config.WAVES_TOTAL + 1):
		if not Config.is_boss_wave(bw2):
			continue
		if Music.track_for_wave(bw2) != "boss":
			_fail("BOSS 波未切 BOSS 曲（W%d → %s）" % [bw2, Music.track_for_wave(bw2)])
			return
	Music.play_track("battle_mid")
	if Music.current_track() != "battle_mid":
		_fail("中盘 BGM 未生成/切换失败")
		return
	if FileAccess.file_exists("res://assets/audio/bgm/battle_mid.wav") \
			and Music.current_source() != "file":
		_fail("中盘外部 BGM 未优先加载（source=%s）" % Music.current_source())
		return
	# 8 首外部素材全部可解析：文件存在时必须走 file，不得静默回退程序生成
	for track_name in ["menu", "shop", "battle", "battle_mid", "battle_late", "boss",
			"victory", "defeat"]:
		if FileAccess.file_exists(String(Music.TRACK_FILES[track_name])):
			Music.play_track(String(track_name))
			if Music.current_source() != "file":
				_fail("外部 BGM 素材解析失败：%s" % track_name)
				return
	Music.play_track("battle")
	# BGM 淡入淡出：播放中切曲先淡出旧曲再淡入新曲，结束后音量回到基准
	var fade_path: bool = Music._player != null and Music._player.playing
	Music.play_track("battle_mid", 0.2)
	if fade_path and Music.current_track() != "battle":
		_fail("播放中切曲未走淡出路径（%s）" % Music.current_track())
		return
	await get_tree().create_timer(0.5).timeout
	if Music.current_track() != "battle_mid" \
			or absf(Music.volume_db() - float(Music.BASE_DB)) > 0.5:
		_fail("BGM 淡变未落到目标曲目/基准音量（%s %.1f dB）"
			% [Music.current_track(), Music.volume_db()])
		return
	Music.play_track("battle", 0.2)
	await get_tree().create_timer(0.5).timeout
	if Music.current_track() != "battle":
		_fail("BGM 淡变回战斗曲失败（%s）" % Music.current_track())
		return
	var music_bak := Settings.music_vol
	var sfx_bak := Settings.sfx_vol
	Settings.set_music(0.5)
	Settings.set_sfx(0.25)
	if absf(Settings.music_vol - 0.5) > 0.001 or absf(Settings.sfx_vol - 0.25) > 0.001:
		_fail("音效/音乐独立音量设置失败")
		return
	Settings.set_music(music_bak)
	Settings.set_sfx(sfx_bak)
	# toast 点击 → 局内图鉴直达条目（战斗中暂停，关闭后恢复原阶段）
	if _main._toast_panel.mouse_filter != Control.MOUSE_FILTER_STOP:
		_fail("toast 未开启点击响应")
		return
	_main._toast_target = ["achieve", "first_blood"]
	var phase_before_click: int = GameState.phase
	_main._open_toast_target()
	if _main._codex == null or not _main._codex.visible:
		_fail("点击 toast 未打开局内图鉴")
		return
	if _main._codex._tab != "achieve" or String(_main._codex._selected_id) != "first_blood":
		_fail("toast 未跳转到对应图鉴条目（%s/%s）" % [_main._codex._tab, _main._codex._selected_id])
		return
	if GameState.phase != GameState.Phase.PAUSED:
		_fail("局内图鉴未暂停战斗")
		return
	_main._codex._close()
	if GameState.phase != phase_before_click:
		_fail("关闭局内图鉴后未恢复战斗阶段（%d -> %d）" % [phase_before_click, GameState.phase])
		return
	EventBus.wave_ended.connect(_on_wave_ended)
	# 首杀窗口。
	#
	# ⚠️ S2 从 8.0 放宽到 16.0：开局武器默认值从 `pistol`（远程 540 弹速）变成了
	#    `knife`（近战 **射程 95px**）—— 实测首杀落在 **t≈11.6s**（探针 25s 窗口实测，
	#    见 S2 施工记录），8s 必然误红。这不是武器"没开火"（`try_fire` 自动索敌，
	#    近战走 `_melee_slash`，探针里 kills 会持续增长），而是**近战需要等敌人走进
	#    95px 才够得着**，属于设计使然。
	#    16.0 给了约 1.4 倍余量，同时仍能守住"武器真的在造成伤害"这条语义。
	get_tree().create_timer(16.0).timeout.connect(_check_weapons)

func _on_wave_ended(w: int) -> void:
	_last_ended = w
	if w == 1:
		_mats_at_end = GameState.materials
		_xp_at_end = GameState.xp + (GameState.level - 1) * 4   # 粗略合并等级收益

func _check_weapons() -> void:
	var wm: Node = _main.get_node("WaveManager")
	var loot_field := get_tree().get_nodes_in_group("loot").size()
	print("SMOKE: kills=%d wave=%d loot_field=%d mats=%d xp=%d lv=%d" %
		[GameState.kills, wm.wave, loot_field, GameState.materials, GameState.xp, GameState.level])
	if GameState.kills <= 0:
		_fail("武器未产生击杀")
		return
	if loot_field <= 0 and GameState.materials <= 0 and GameState.xp <= 0:
		_fail("击杀未产生掉落/拾取")
		return
	# 掉落不再波末回收，验证玩家磁吸拾取：传送到首个掉落物旁等磁吸结算
	var loots := get_tree().get_nodes_in_group("loot")
	if loots.size() > 0:
		var player: Node2D = _main.get_node("Player")
		player.global_position = loots[0].global_position + Vector2(30.0, 0.0)
		await get_tree().create_timer(0.8).timeout
		print("SMOKE: pickup mats=%d xp=%d" % [GameState.materials, GameState.xp])
	# 清除场上所有掉落（防止倒计时期间再拾取升级导致 wave_timer 停转）
	for loot in get_tree().get_nodes_in_group("loot"):
		loot.queue_free()
	await get_tree().process_frame
	# 如果拾取 XP 触发了升级，先选卡关闭升级 UI
	var ui: Control = _main.get_node("UI/LevelUp")
	while ui.visible:
		ui._choose(0)
		await get_tree().process_frame
	# 波末「不自动回收」哨兵：放在场角，且**不给 player 引用**
	# （loot 的 `_physics_process` 在 player 为空时直接 return → 既不会被磁吸、
	#  也不会接触结算，只有「波末全场 settle()」这条旧路径能动它 → 判据确定性）
	_loot_sentinel = preload("res://scenes/loot/loot.tscn").instantiate()
	_main.add_child(_loot_sentinel)
	_loot_sentinel.setup("mat", 7, Vector2(120.0, 120.0), Vector2.ZERO)
	await get_tree().process_frame
	_loot_sentinel_pos = _loot_sentinel.global_position
	# 压缩第 1 波剩余时间，验证 收波清场（掉落保留）→ 商店 → 下一波 流程
	var wm2: Node = _main.get_node("WaveManager")
	wm2.wave_timer = 0.5
	# 等待期间若击杀拾取经验触发升级，弹窗会把阶段切到 LEVEL_UP 并暂停波次计时；
	# 轮询自动选卡（仅在升级阶段，避免误触商店），保证计时持续推进
	_wait_wave_end()

func _wait_wave_end() -> void:
	var ui: Control = _main.get_node("UI/LevelUp")
	var waited := 0.0
	while _last_ended < 1 and waited < 10.0:
		if ui.visible and GameState.phase == GameState.Phase.LEVEL_UP:
			ui._choose(0)
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	_check_wave()

func _check_wave() -> void:
	var wm: Node = _main.get_node("WaveManager")
	var shop: Control = _main.get_node("UI/Shop")
	print("SMOKE: wave=%d last_ended=%d mats_at_end=%d xp_at_end=%d lv=%d xp=%d" %
		[wm.wave, _last_ended, _mats_at_end, _xp_at_end, GameState.level, GameState.xp])
	if _last_ended < 1:
		_fail("波次未推进（last_ended=%d）" % _last_ended)
		return
	if _mats_at_end <= 0 and _xp_at_end <= 0:
		_fail("击杀既未拾取也无自动回收收益")
		return
	if GameState.level <= 1 and GameState.xp <= 0:
		_fail("经验未入账")
		return
	# 波末**不再**自动回收掉落（2026-09-19 用户要求：留在原地、自己走位拾取）。
	# 哨兵必须仍在场上且留在原位 —— 旧实现在这里逐个 settle()，哨兵会被结算掉。
	if _loot_sentinel == null or not is_instance_valid(_loot_sentinel) \
			or _loot_sentinel.is_queued_for_deletion():
		_fail("波末把掉落物自动回收了（哨兵已消失）—— 应保留原位由玩家走位拾取")
		return
	if _loot_sentinel.global_position.distance_to(_loot_sentinel_pos) > 1.0:
		_fail("波末掉落物位置被改动（%.0f,%.0f → %.0f,%.0f，应原位保留）"
			% [_loot_sentinel_pos.x, _loot_sentinel_pos.y,
				_loot_sentinel.global_position.x, _loot_sentinel.global_position.y])
		return
	print("SMOKE: 波末掉落保留原位（哨兵存活 · 场上 %d 件）"
		% get_tree().get_nodes_in_group("loot").size())
	if GameState.phase != GameState.Phase.SHOP:
		_fail("波末未进入商店（phase=%d）" % GameState.phase)
		return
	if not get_tree().get_nodes_in_group("player_bullets").is_empty() \
			or not get_tree().get_nodes_in_group("enemy_bullets").is_empty():
		_fail("波末未清理双方弹丸")
		return
	_suppress_event_cards()
	shop.next_wave()
	_restore_event_cards()
	if wm.wave != 2 or GameState.phase != GameState.Phase.INTRO:
		_fail("商店下一波未生效（wave=%d phase=%d）" % [wm.wave, GameState.phase])
		return
	var intro_pos: Vector2 = _main.get_node("Player").global_position
	GameState.touch_move = Vector2.RIGHT
	await get_tree().physics_frame
	GameState.touch_move = Vector2.ZERO
	if _main.get_node("Player").global_position != intro_pos:
		_fail("INTRO 阶段玩家仍在移动")
		return
	# 事件波 / 奇遇的免费升级可能在此积压：直接进入 PLAYING 触发补弹并清空（模拟玩家选卡），
	# 避免 INTRO 自然结束后升级 UI 弹出冻结 BOSS 测试窗口
	GameState.set_phase(GameState.Phase.PLAYING)
	var lu_drain: Control = _main.get_node("UI/LevelUp")
	while lu_drain.visible or GameState.level_queue > 0:
		if lu_drain.visible:
			lu_drain._choose(0)
		else:
			GameState.level_queue = 0
		await get_tree().process_frame
	# 掉落物**保留**（2026-09-19 起波末不再自动回收）—— 这里只观测，不断言清零
	print("SMOKE: loot_left=%d (波末不再自动回收，保留原地)"
		% get_tree().get_nodes_in_group("loot").size())
	# 数值调整断言：波时 30+3w（§8 二十波制）、初始移速 742（495+50%）
	# ⚠️ 旧值是 45/50（`45 + 5(w-1)`）—— 20 波制下那条曲线末波要 140s，已废弃。
	#    这里同时钉住首末两端，只改一端（例如漏改 +3w 的系数）会立刻报红。
	if Config.wave_duration(1) != 33.0 or Config.wave_duration(20) != 90.0 \
			or not is_equal_approx(Config.PLAYER.base_speed, 742.0):
		_fail("数值调整未生效（波时/移速）")
		return
	# Registry 注册表 + 示例 mod 加载断言
	#
	# ⭐ 五行体系 S2：内置武器收缩到 5 把五行武器，其余 24 把移入官方工坊包
	#    （`game/mods/brotato_lite_core/manifest.json`）→ 内置 5 + mod `laser` 1 = **6**。
	#    阈值从 8 改 5：「五行武器齐全」是新语义（旧语义「内置武器够多」已不适用）。
	#
	# ⚠️ `has("laser")` **必须保留** —— 它才是这条断言真正的价值：
	#    验证**创意工坊加载链路是通的**（`_load_mod_dir` → `_apply_manifest` → `register_weapon`）。
	#    只删不改这里的 size() 会把这个覆盖一起丢掉。
	if Registry.weapons.size() < 6 or not Registry.weapons.has("laser"):
		_fail("Registry 未加载示例 mod 武器 laser（内置 %d 把）" % Registry.weapons.size())
		return
	# 内置五行武器必须齐全且各自带 element（防「元素武器漏配 element → 默默退化成白板」）
	for wid in Config.LOADOUT_WEAPONS:
		if not Registry.weapons.has(String(wid)):
			_fail("开局池武器缺失：%s" % String(wid))
			return
		var we: String = String(Registry.weapons[String(wid)].get("element", ""))
		if not Config.ELEMENTS.has(we):
			_fail("开局池武器 %s 的 element 非法/缺失：'%s'" % [String(wid), we])
			return
	# 五行武器恰好覆盖 5 个元素、不重不漏（这是「五把 = 五行」这句话的机器可验版本）
	var elem_seen: Array = []
	for wid2 in Config.LOADOUT_WEAPONS:
		var e2: String = String(Registry.weapons[String(wid2)].get("element", ""))
		if e2 in elem_seen:
			_fail("开局池元素重复：%s（%s 与 %s）" % [e2, String(wid2), e2])
			return
		elem_seen.append(e2)
	if elem_seen.size() != Config.ELEMENTS.size():
		_fail("开局池元素覆盖不全：%s" % str(elem_seen))
		return
	# ⭐ 五行体系 S2：内置角色收缩到 6 个（potato 白板 + 5 元素修士）
	#    阈值 7 → 6。
	if Registry.items.size() < 19 or Registry.difficulties.size() < 3 \
			or Registry.characters.size() < 6:
		_fail("Registry 内置内容缺失（items=%d difficulties=%d characters=%d）"
			% [Registry.items.size(), Registry.difficulties.size(), Registry.characters.size()])
		return
	# 6 角色 = 恰好 1 个白板 + 5 个元素，且 5 元素不重不漏（§13 断言 8）
	#
	# ⚠️ S2：必须只遍历**内置 6 角色**。原先遍历 `Registry.characters` 全量是"当时恰好等于内置"
	#    的巧合 —— 一旦工坊包加载进来（11 个角色），`vampire` 之类的旧角色会被同一条推导链
	#    推出元素（实测 vampire → metal），与 `metal_adept` 撞车 → 误报「角色元素重复」。
	#    "内置 5 元素齐备"这个验收目标本来就只约束内置内容，故显式列清单。
	var builtin_char_ids := ["potato", "metal_adept", "wood_adept", "water_adept",
		"fire_adept", "earth_adept"]
	var blanks := 0
	var char_elems: Array = []
	for cid in builtin_char_ids:
		if not Registry.characters.has(String(cid)):
			_fail("内置角色缺失：%s" % String(cid))
			return
		var ce: String = Config.element_for_character(String(cid))
		if ce == "":
			blanks += 1
		else:
			if ce in char_elems:
				_fail("角色元素重复：%s（%s）" % [ce, String(cid)])
				return
			char_elems.append(ce)
	if blanks != 1 or char_elems.size() != Config.ELEMENTS.size():
		_fail("内置 6 角色应为 1 白板 + 5 元素，实为 白板 %d / 元素 %d（%s）"
			% [blanks, char_elems.size(), str(char_elems)])
		return
	# 新品阶/新内容回归：金色+红色道具与升级、新武器、新角色、新怪物、难度精英
	if not Config.RARITIES.has("mythic") or not Config.RARITIES.has("legendary"):
		_fail("稀有度枚举缺少 mythic/legendary")
		return
	if Config.rarity_weight("legendary", 1) != 0.0 \
			or Config.rarity_weight("legendary", 9) <= 0.0:
		_fail("稀有度权重曲线错误（legendary 应 LV1=0、LV9 起解锁）")
		return
	if not Registry.items.has("i-crown") or not Registry.upgrades.has("berserk"):
		_fail("高品阶道具/升级未注册")
		return
	# ⚠️ 五行体系 S2 的连带改动：`sniper` / `blade` / 6 个旧角色（berserker/ranger/farmer/
	#    vampire/guardian/gunner）**已移入官方工坊包**，不再进内置 Registry。
	#    这条断言原意是「Phase 1/2 的内容没丢」，故改为断言**新内置集**齐全 ——
	#    同时它顺带成了 S2 的验收锚：内置武器恰好 5 把五行 + 1 把 mod laser。
	#    （被冻结的内容由工坊包提供，`laser` 那条断言已覆盖工坊链路是否通。）
	for wid in Config.LOADOUT_WEAPONS:
		if not Registry.weapons.has(String(wid)):
			_fail("内置五行武器缺失：%s" % String(wid))
			return
	# （内置角色存在性已在上面「1 白板 + 5 元素」处逐个验过，不再重复）
	for eid in ["swarm", "bomber", "wizard", "shadow", "guard"]:
		if not Registry.enemies.has(eid):
			_fail("新怪物缺失：%s" % eid)
			return
	if not is_equal_approx(float(Registry.difficulties.nightmare.elite_chance), 0.2):
		_fail("噩梦难度精英概率未生效")
		return
	# Phase 3 内容填充验收（放在此处：玩家 stats 还没被任何道具/升级改动过，
	# 下面的「效果键必须被 player.stats 接住」才是一份干净的基准）
	_check_phase3_content()
	if _failed:
		return
	# BOSS 弹幕验证（前面已显式进入 PLAYING，生成后 0.2s 即发射供测试观察）
	var boss: Node2D = preload("res://scenes/enemies/enemy.tscn").instantiate()
	boss.setup("boss", 10)
	boss.ring_cd = 0.2   # 尽快发射
	if not boss.is_boss():
		_fail("BOSS 判定失败（is_boss）")
		return
	var player: Node2D = _main.get_node("Player")
	boss.position = player.global_position + Vector2(300, 0)
	add_child(boss)
	boss.player = player
	player.hp = 100.0   # 保证测试期间玩家存活
	player.iframes = 1.0e9   # BOSS 弹幕强化后密集致死，测试窗口期免伤
	get_tree().create_timer(3.0).timeout.connect(_check_boss)

func _check_boss() -> void:
	var bullets := get_tree().get_nodes_in_group("enemy_bullets").size()
	print("SMOKE: boss_bullets=%d" % bullets)
	if bullets <= 0:
		_fail("BOSS 未发射弹幕")
		return
	# ---- 特效断言：命中粒子+飘字、玩家受击、爆炸光环+橙色粒子 ----
	var player: Node2D = _main.get_node("Player")
	var boss: Node2D = null
	for e in get_tree().get_nodes_in_group("enemies"):
		if e.is_boss():
			boss = e
			break
	if boss == null:
		_fail("BOSS 未在场，特效断言无法执行")
		return
	var fx0 := get_tree().get_nodes_in_group("fx").size()
	boss.take_damage(2.0, false)           # 命中：伤害飘字 + 3 粒命中粒子
	var fx1 := get_tree().get_nodes_in_group("fx").size()
	player.iframes = 0.0
	player.take_damage(10.0)               # 玩家受击：-N 飘字 + 6 粒红粒子（或闪避飘字）
	player.iframes = 1.0e9                 # 受击断言后恢复免伤（BOSS 仍在场持续弹幕）
	var fx2 := get_tree().get_nodes_in_group("fx").size()
	print("SMOKE: fx hit %d->%d->%d" % [fx0, fx1, fx2])
	if fx1 <= fx0 or fx2 <= fx1:
		_fail("受击未生成粒子/飘字特效（fx %d->%d->%d）" % [fx0, fx1, fx2])
		return
	Explosion.spawn(_main, boss.global_position, 60.0, 0.0, false)
	await get_tree().process_frame
	# 直接找刚生成的 Explosion 实例，而不是比对 fx 组总数：组计数跨越了一个帧边界，
	# 会被「同一帧里自然到期的旧特效」抵消（Burst 存活 0.2~0.5s，随时可能整批回收），
	# 属于测试自身的竞态——增加场上特效数量后已能稳定复现假失败
	var ex_node: Node2D = null
	for n in get_tree().get_nodes_in_group("fx"):
		if n is Explosion:
			ex_node = n
			break
	print("SMOKE: fx explosion ->%s" % ("有" if ex_node != null else "无"))
	if ex_node == null:
		_fail("爆炸未生成光环特效（fx 组内找不到 Explosion 节点）")
		return
	# ---- 升级三选一流程验证：排空积压 → 恰好升 1 级 → 弹卡 → 选择 ----
	var ui: Control = _main.get_node("UI/LevelUp")
	while GameState.phase == GameState.Phase.LEVEL_UP and ui.card_count() > 0:
		ui._choose(0)   # 排空 BOSS 测试窗口内意外积压的连升
	GameState.xp = 0
	GameState.level_queue = 0
	player.hp = 60.0   # 非满血，保证 heal 升级也可被检测
	GameState.gain_xp(Config.xp_need(GameState.level) + 1)   # 恰好升 1 级 → 弹卡
	get_tree().create_timer(0.5).timeout.connect(_check_levelup)

func _check_levelup() -> void:
	var ui: Control = _main.get_node("UI/LevelUp")
	var player: Node2D = _main.get_node("Player")
	print("SMOKE: phase=%d queue=%d cards=%d" %
		[GameState.phase, GameState.level_queue, ui.card_count()])
	if GameState.phase != GameState.Phase.LEVEL_UP or ui.card_count() != 3:
		_fail("升级 UI 未打开或卡牌数不对（phase=%d cards=%d）"
			% [GameState.phase, ui.card_count()])
		return
	# 手柄焦点断言：默认焦点应在第一张卡
	var focus: Control = ui.get_viewport().gui_get_focus_owner()
	if focus == null or focus.get_parent() != ui.get_node("Center/Box/Cards"):
		_fail("升级卡未获得手柄焦点")
		return
	var stats_before: Dictionary = player.stats.duplicate()
	var hp_before: float = player.hp
	ui._choose(0)   # 模拟选第一张
	print("SMOKE: after_choose phase=%d queue=%d" % [GameState.phase, GameState.level_queue])
	if GameState.phase != GameState.Phase.PLAYING or GameState.level_queue != 0:
		_fail("选择后未恢复正常游戏")
		return
	if player.stats == stats_before and is_equal_approx(player.hp, hp_before):
		_fail("升级未产生任何属性变化")
		return
	# ---- 单次跨两级：第 12 轮起**改回「一级选一次」**（撤回第 9 轮的连升合并）----
	# 第 9 轮：N 级合并成一次选择、收益 ×N，只弹一次（玩家看不出自己升了几级）。
	# 第 12 轮：每级各弹一次三选一、每次重抽三张，`level_queue` 每次只 -1。
	# 判据用**弹卡次数**：合并版跨两级只弹 1 次，逐级版必须弹 2 次。
	# （不比较 upgrades_owned 增量：金/红唯一件会被硬闸门拦下，增量本就不确定。）
	var need_two := Config.xp_need(GameState.level) + Config.xp_need(GameState.level + 1)
	GameState.gain_xp(need_two + 1)
	await get_tree().process_frame
	if GameState.phase != GameState.Phase.LEVEL_UP or GameState.level_queue != 2 or ui.card_count() != 3:
		_fail("单次跨两级未生成首组卡（phase=%d queue=%d cards=%d）" %
			[GameState.phase, GameState.level_queue, ui.card_count()])
		return
	# 逐次排空：每级弹一次、队列每次 -1（与波末排空同款写法，不另造时序）
	# ⚠️ 第 13 轮：刻意走**真实 Button.pressed 发射**，不再直接调 ui._choose(0)。
	#   直接调用绕开了 Button 的发射栈，会让「信号发射途中销毁发射者」这类缺陷
	#   对冒烟完全隐形 —— 线上那次卡死的 22 条 object.cpp:2324 就是这么漏掉的：
	#   全项目冒烟里没有一处是经由真实点击驱动选卡的。
	var pops := 0
	while GameState.level_queue > 0 or ui.visible:
		if ui.visible:
			var cards_node: Node = ui.get_node("Center/Box/Cards")
			var btn := cards_node.get_child(0) as Button
			if btn == null:
				_fail("升级卡按钮缺失（Cards 子节点数=%d）" % cards_node.get_child_count())
				return
			btn.pressed.emit()
			# 回归闸一：queue_free 是帧末销毁，发射返回时按钮必须仍然有效。
			if not is_instance_valid(btn):
				_fail("选卡后发射者按钮被同步销毁（信号发射途中销毁了发射者）")
				return
			# 回归闸二：重建卡阵后旧按钮必须处于「已排队删除」状态，
			# 不能是「已脱离场景树但没人管」的孤儿节点。
			# 若哪天改回 free()：Godot 的 lock 会拦下销毁 → 既脱树又未排队 → 这里必须红。
			if btn.get_parent() == null and not btn.is_queued_for_deletion():
				_fail("重建卡阵后按钮成了孤儿节点（已脱离场景树但未排队删除）")
				return
			pops += 1
		else:
			_fail("一级选一次：还有 %d 级没弹卡就关窗了" % GameState.level_queue)
			return
		await get_tree().process_frame
	# 反向对照：合并版这里只会是 1
	if pops < 2:
		_fail("一级选一次：跨两级只弹了 %d 次（应 ≥2）" % pops)
		return
	if GameState.phase != GameState.Phase.PLAYING or GameState.level_queue != 0:
		_fail("两级选完后未恢复 PLAYING（phase=%d queue=%d）" %
			[GameState.phase, GameState.level_queue])
		return
	print("SMOKE: per-level level-up OK（跨两级弹了 %d 次）" % pops)
	# ---- 空白卡回归：品阶门槛把亲和保底池清零时（契合升级全是 epic 且 Lv<3），
	# weighted_pick 曾返回 null → 第三张卡只剩 [3] 的空白卡。复现路径：
	# 火焰喷射器开局 → 亲和标签 {burn} → 契合升级只有 epic 的 burningheart（Lv 1 权重 0）----
	var lvl_bak: int = GameState.level
	var wps_bak: Array = player.weapons
	GameState.level = 1
	player.weapons = [{ "type": "flamethrower", "cd": 0.0 }]
	var blank_runs := 0
	for _r in 6:   # 多次开框：保底只在「前三张都不契合」时触发，多跑几轮覆盖
		ui.open()
		await get_tree().process_frame
		if ui.card_count() != 3:
			_fail("升级卡不足三张（%d）" % ui.card_count())
			GameState.level = lvl_bak
			player.weapons = wps_bak
			return
		for ci in 3:
			var cid := ""
			if typeof(ui._choices[ci]) == TYPE_DICTIONARY:
				cid = String(ui._choices[ci].get("id", ""))
			if cid == "":
				blank_runs += 1
		ui._choose(0)   # 关掉当前框（queue 为 0 → 回 PLAYING）
		await get_tree().process_frame
	GameState.level = lvl_bak
	player.weapons = wps_bak
	if blank_runs > 0:
		_fail("品阶门槛期出现 %d 张空白升级卡（亲和保底池全零未兜底）" % blank_runs)
		return
	print("SMOKE: level-up blank card regression OK")
	# ---- 商店流程验证：压缩第 2 波 → 清场 → 自动进商店 → 购买/刷新/回血/下一波 ----
	var wm: Node = _main.get_node("WaveManager")
	wm.wave_timer = 0.5
	get_tree().create_timer(3.0).timeout.connect(_check_shop)

func _check_shop() -> void:
	var shop: Control = _main.get_node("UI/Shop")
	var player: Node2D = _main.get_node("Player")
	print("SMOKE: shop phase=%d goods=%d mats=%d" %
		[GameState.phase, shop.goods_count(), GameState.materials])
	if GameState.phase != GameState.Phase.SHOP or shop.goods_count() != Config.SHOP_SLOTS:
		_fail("商店未打开或商品数不对（phase=%d goods=%d）"
			% [GameState.phase, shop.goods_count()])
		return
	if shop.get_viewport().gui_get_focus_owner() == null:
		_fail("商店焦点丢失（手柄导航不可用）")
		return
	# 商店武器栏（UI 排序/可见性需求）：永久槽聚合 + 空槽占位 + 临时槽，槽位数与持有数一致
	var wbar: HBoxContainer = shop._weapon_bar
	if wbar == null:
		_fail("商店未构建武器栏")
		return
	var _wperm_n: int = player.weapons.size()
	var _wdistinct := {}
	for _wp in player.weapons:
		_wdistinct[String(_wp.get("type", ""))] = true
	var _wtemp_d := {}
	for _wtp in player.temp_weapons:
		_wtemp_d[String(_wtp.get("type", ""))] = true
	var _wexpect: int = _wdistinct.size() + maxi(0, MetaProgress.weapon_slots() - _wperm_n) \
		+ _wtemp_d.size()
	if wbar.get_child_count() != _wexpect:
		_fail("商店武器栏槽数不对（%d != %d，武器 %d/临时 %d）"
			% [wbar.get_child_count(), _wexpect, _wperm_n, player.temp_weapons.size()])
		return
	# #7 同店去重：货架上不得出现两件相同的唯一件（金/红道具升级、或同一法宝）
	var seen_uniq := {}
	for g_u in shop.goods:
		var gid_u := String(g_u.get("id", ""))
		if gid_u == "":
			continue
		var is_uniq: bool = String(g_u.get("kind", "")) == "artifact" \
			or Config.is_unique_rarity(String(g_u.get("rarity", "common")))
		if not is_uniq:
			continue
		if seen_uniq.has(gid_u):
			_fail("#7 商店出现两件相同的唯一件（%s）" % gid_u)
			return
		seen_uniq[gid_u] = true
	# #7 确定性验证过滤本身：把某件唯一件标为「本店已摆出」后必须从池中消失
	var uniq_probe: Dictionary = {}
	for cand_u in Registry.item_list():
		if not Config.is_unique_rarity(String(cand_u.get("rarity", "common"))):
			continue
		if not Config.unique_pool_ok(cand_u, player.items_owned):
			continue
		if not Config.entry_weapon_relevant(cand_u, player.weapons):
			continue
		uniq_probe = cand_u
		break
	if uniq_probe.is_empty():
		_fail("找不到可用作 #7 验证的金/红道具")
		return
	var puid := String(uniq_probe.get("id", ""))
	if shop._rarity_pool([uniq_probe], player.items_owned, { puid: true }).size() != 0:
		_fail("#7 同店去重失效：已摆出的唯一件仍进池（%s）" % puid)
		return
	if shop._rarity_pool([uniq_probe], player.items_owned, {}).size() != 1:
		_fail("#7 反向对照失败：未被占用时该唯一件应可进池（%s）" % puid)
		return
	# #4a 饱和闸：用人造条目验证判据本身（不依赖具体内容数据）
	var sat_entry: Dictionary = { "id": "probe_sat", "effects": { "status_chance": 0.10 } }
	var st_probe: Dictionary = { "status_chance": 0.5 }
	if Config.is_saturated_entry(sat_entry, st_probe):
		_fail("#4a 未顶格却判为饱和（status_chance=0.5）")
		return
	st_probe["status_chance"] = 1.0
	if not Config.is_saturated_entry(sat_entry, st_probe):
		_fail("#4a 已顶格却未判为饱和（status_chance=1.0）")
		return
	# 反向：条目还有别的未顶格键时不算饱和（不能因为一个键满了就整件判死）
	var mix_entry: Dictionary = { "id": "probe_mix",
		"effects": { "status_chance": 0.10, "dmg_mult": 0.2 } }
	if Config.is_saturated_entry(mix_entry, st_probe):
		_fail("#4a 多键条目应只在**全部**可饱和键顶格时才判饱和")
		return
	# 不可饱和键（heal_flat 不在 STAT_LIMITS 内）不计入判定 → 永不被判饱和
	var heal_entry: Dictionary = { "id": "probe_heal", "effects": { "heal_flat": 20.0 } }
	if Config.is_saturated_entry(heal_entry, {}):
		_fail("#4a 不可饱和键（heal_flat）不应被判饱和")
		return
	# #2 经济：物价指数必须加速增长（线性 + 二次项），刷新费 / 回血费同步吃指数
	var m1 := Config.shop_price_mult(1)
	var m10 := Config.shop_price_mult(10)
	var m20 := Config.shop_price_mult(20)
	if not is_equal_approx(m1, 1.0) or m10 <= 2.0 * m1 or m20 <= 2.0 * m10:
		_fail("#2 物价指数未按加速曲线增长（W1=%.2f W10=%.2f W20=%.2f）" % [m1, m10, m20])
		return
	if Config.heal_price(20) <= Config.heal_price(1):
		_fail("#2 回血费未随波次上浮（W1=%d W20=%d）"
			% [Config.heal_price(1), Config.heal_price(20)])
		return
	if Config.shop_reroll_cost(20) <= Config.shop_reroll_cost(1) * 3:
		_fail("#2 刷新费未随物价指数上浮（W1=%d W20=%d）"
			% [Config.shop_reroll_cost(1), Config.shop_reroll_cost(20)])
		return
	# 购买
	GameState.materials += 999
	var mats0: int = GameState.materials
	shop.buy(0)
	print("SMOKE: buy mats %d -> %d sold=%s" % [mats0, GameState.materials, shop.goods[0].sold])
	if GameState.materials >= mats0 or not shop.goods[0].sold:
		_fail("购买未生效")
		return
	# 刷新（费用 ×1.4 递增，只重掷未售格）
	var cost0: int = shop.get_reroll_cost()
	GameState.materials += 999
	shop.reroll()
	print("SMOKE: reroll cost %d -> %d goods=%d" %
		[cost0, shop.get_reroll_cost(), shop.goods_count()])
	if shop.get_reroll_cost() <= cost0 or shop.goods_count() != Config.SHOP_SLOTS:
		_fail("刷新未生效")
		return
	# 回血
	player.hp = 40.0
	GameState.materials += 999
	var hp0: float = player.hp
	shop.heal()
	print("SMOKE: heal hp %.0f -> %.0f" % [hp0, player.hp])
	if player.hp <= hp0:
		_fail("商店回血未生效")
		return
	# 锁定：找首个未售格锁定，刷新后该格同位同内容且保持锁定
	var li := -1
	for i in shop.goods.size():
		if not shop.goods[i].sold:
			li = i
			break
	if li < 0:
		_fail("无未售格可测锁定")
		return
	var locked_id: String = shop.goods[li].get("wtype", shop.goods[li].get("id", ""))
	GameState.materials += 999
	shop.set_lock(li, true)
	var cost0b: int = shop.get_reroll_cost()
	shop.reroll()
	var lg: Dictionary = shop.goods[li]
	var locked_id2: String = lg.get("wtype", lg.get("id", ""))
	print("SMOKE: lock slot=%d id=%s->%s locked=%s cost=%d->%d" %
		[li, locked_id, locked_id2, lg.locked, cost0b, shop.get_reroll_cost()])
	if locked_id2 != locked_id or not lg.locked:
		_fail("锁定商品未在刷新后原位保留")
		return
	if shop.get_viewport().gui_get_focus_owner() == null:
		_fail("刷新后商店焦点丢失（手柄断导航）")
		return
	# 波末升级压住（UI 排序需求）：hold 期间升级只积压 level_queue、不弹卡，
	# 解除后回到 PLAYING 才补弹 —— 保证进化/盒子/商店不与升级卡叠屏
	var lu: Control = _main.get_node("UI/LevelUp")
	var _q0: int = GameState.level_queue
	GameState.set_phase(GameState.Phase.PLAYING)   # 模拟波末结算瞬间仍是 PLAYING（真实 bug 路径）
	lu.set_hold(true)
	GameState.gain_xp(Config.xp_need(GameState.level))
	if GameState.level_queue != _q0 + 1 or lu.visible:
		_fail("hold 期间升级卡不应弹出（queue=%d visible=%s）"
			% [GameState.level_queue, lu.visible])
		return
	GameState.set_phase(GameState.Phase.SHOP)      # 结算流程收尾进商店 → 自动解除压住
	lu.set_hold(false)
	GameState.set_phase(GameState.Phase.PLAYING)   # 模拟下一波开场 → 补弹积压升级
	if not lu.visible or GameState.level_queue != _q0 + 1:
		_fail("回到 PLAYING 未补弹升级卡（queue=%d visible=%s）"
			% [GameState.level_queue, lu.visible])
		return
	# 恢复现场（不真选卡：升级内容是随机的，随机不进断言，也不污染后续数值断言）
	GameState.set_phase(GameState.Phase.SHOP)
	lu.visible = false
	GameState.level_queue = _q0
	_check_shop_rules()
	_check_shop_evolve()
	# 下一波
	_suppress_event_cards()
	shop.next_wave()
	_restore_event_cards()
	var wm: Node = _main.get_node("WaveManager")
	print("SMOKE: next wave=%d phase=%d" % [wm.wave, GameState.phase])
	if wm.wave != 3 or GameState.phase != GameState.Phase.INTRO:
		_fail("商店下一波未生效")
		return
	# ---- HUD 验证 ----
	get_tree().create_timer(0.5).timeout.connect(_check_hud)

## 商店规则验证：① 货架格数 = Config.SHOP_SLOTS；② 购买后**不自动重掷**
## （已售格原位保留、其余格内容 id 不变）；③ 售价随波次上浮。
func _check_shop_rules() -> void:
	var shop: Control = _main.get_node("UI/Shop")
	# ① 格数
	if shop.goods_count() != Config.SHOP_SLOTS:
		_fail("货架格数不是 %d（实际 %d）" % [Config.SHOP_SLOTS, shop.goods_count()])
		return
	# ② 购买不重掷：先记录全店 id，买第一个未售格，再比对每个格子的 id
	var ids_before: Array = []
	for i in shop.goods.size():
		ids_before.append(_good_key(shop.goods[i]))
	var bi := -1
	for i in shop.goods.size():
		if not shop.goods[i].sold and not shop.goods[i].locked:
			bi = i
			break
	if bi < 0:
		_fail("无未售格可测「购买不重掷」")
		return
	GameState.materials += 999
	shop.buy(bi)
	if not shop.goods[bi].sold:
		_fail("购买未生效（购买不重掷用例前置失败）")
		return
	for i in shop.goods.size():
		var now_key := _good_key(shop.goods[i])
		if i == bi:
			# 被买走的那格：内容 id 不变，只是 sold 置位
			if now_key != ids_before[i]:
				_fail("购买后已售格内容被改写（%s -> %s）" % [ids_before[i], now_key])
				return
		elif now_key != ids_before[i]:
			_fail("购买后第 %d 格被自动重掷了（%s -> %s）" % [i, ids_before[i], now_key])
			return
	print("SMOKE: shop buy-no-reroll OK slots=%d bought=%d" % [shop.goods_count(), bi])
	# ③ 售价随波次上浮：同一 base_price 在 wave 1 / wave 10 的报价必须严格更大
	var p1 := Config.shop_price(100, 1)
	var p10 := Config.shop_price(100, 10)
	print("SMOKE: shop price w1=%d w10=%d" % [p1, p10])
	if p1 != 100 or p10 <= p1:
		_fail("商店售价未随波次上浮（w1=%d w10=%d）" % [p1, p10])
		return
	# ④ 暴击率硬上限：把 crit_ch 灌到 5.0 后跑 sanitize，必须被夹到 Config.CRIT_CHANCE_CAP
	var pl: Node2D = _main.get_node("Player")
	var saved_crit := float(pl.stats.crit_ch)
	pl.stats.crit_ch = 5.0
	pl._sanitize_stats()
	var capped := float(pl.stats.crit_ch)
	print("SMOKE: crit cap %.2f -> %.2f (cap=%.2f)" % [5.0, capped, Config.CRIT_CHANCE_CAP])
	if not is_equal_approx(capped, Config.CRIT_CHANCE_CAP):
		_fail("暴击率未被夹到上限 %.2f（实际 %.3f）" % [Config.CRIT_CHANCE_CAP, capped])
		pl.stats.crit_ch = saved_crit
		return
	if float(Registry.STAT_LIMITS["crit_ch"].y) > Config.CRIT_CHANCE_CAP \
			or float(Registry.EFFECT_LIMITS["crit_ch"]) > Config.CRIT_CHANCE_CAP:
		_fail("Registry limits 未同步收紧到 %.2f" % Config.CRIT_CHANCE_CAP)
		pl.stats.crit_ch = saved_crit
		return
	pl.stats.crit_ch = saved_crit
	# ⑤ 怪物掉落材料 -10%：系数必须是 Config.MATERIAL_DROP_MULT，且敌表 mat 均为正
	print("SMOKE: material drop mult=%.2f" % Config.MATERIAL_DROP_MULT)
	if not is_equal_approx(Config.MATERIAL_DROP_MULT, 0.9):
		_fail("怪物掉落材料系数不是 0.9（%.3f）" % Config.MATERIAL_DROP_MULT)
		return
	for eid in Registry.enemies:
		var m := float(Registry.enemies[eid].get("mat", 0))
		if m <= 0.0:
			_fail("敌人 %s 的 mat 非正（%.2f）—— 掉落系数乘后会归零" % [eid, m])
			return

## 商品身份键：武器用 wtype（无 id），其余用 id —— 比对用，别用于展示
func _good_key(g: Dictionary) -> String:
	if g.has("wtype"):
		return "w:" + String(g.wtype)
	return "%s:%s" % [String(g.get("kind", "")), String(g.get("id", ""))]

## 出怪池里「远程怪」权重占比（需求 1 断言用）：远程怪名单见 Config.BAND_RANGED_MOB_IDS。
## 取模块级函数（GDScript 不允许在其它函数体内嵌套定义 func）。
func _ranged_share_of(c: Array) -> float:
	var _tot := 0.0
	var _r := 0.0
	for _e in c:
		var _w := float(_e.get("w", 0.0))
		_tot += _w
		if Config.BAND_RANGED_MOB_IDS.has(String(_e.get("item", ""))):
			_r += _w
	return _r / _tot if _tot > 0.0 else 0.0

## 商店·需求 3 集成验证：① 永久槽满时买武器进临时槽且买够 need 把即时进化；
## ② 永久+临时都满时武器购买按钮禁用；③ 临时槽有武器时「下一波」先弹二次确认框、
## 不立即进波，取消后临时槽保留。全程快照/还原实况 Player，避免污染后续 HUD/进波流程。
func _check_shop_evolve() -> void:
	var shop: Control = _main.get_node("UI/Shop")
	var pl: Node2D = _main.get_node("Player")
	var w_bak: Array = pl.weapons.duplicate(true)
	var t_bak: Array = pl.temp_weapons.duplicate(true)
	var m_bak: int = GameState.materials
	# ① 路由 + 即时进化：永久槽满（2 金剑 + 3 水枪）时买金剑 → 进临时槽 → 凑 3 把即时进化
	pl.weapons = []
	pl.temp_weapons = []
	for _i in 2:
		pl.weapons.append({ "type": "knife", "cd": 0.1 })
	for _i in 3:
		pl.weapons.append({ "type": "frost_staff", "cd": 0.1 })
	shop.goods[0] = { "kind": "weapon", "wtype": "knife", "ico": "🗡",
		"name": "金剑", "desc": "", "rarity": "common", "base_price": 28,
		"sold": false, "locked": false }
	GameState.materials += 999
	shop.buy(0)
	if pl.weapon_count("knife") != 0 or pl.weapon_count("knife_ex") != 1 or pl.temp_weapons.size() != 0:
		_fail("永久槽满买金剑应进临时槽并即时进化（knife=%d knife_ex=%d temp=%d）"
			% [pl.weapon_count("knife"), pl.weapon_count("knife_ex"), pl.temp_weapons.size()])
		pl.weapons = w_bak; pl.temp_weapons = t_bak; GameState.materials = m_bak
		shop._refresh()
		return
	# ② 满槽门禁：永久5 + 临时2 → 武器购买按钮禁用
	pl.weapons = []
	pl.temp_weapons = []
	for _i in 5:
		pl.weapons.append({ "type": "frost_staff", "cd": 0.1 })
	for _i in 2:
		pl.temp_weapons.append({ "type": "knife", "cd": 0.1 })
	shop.goods[0] = { "kind": "weapon", "wtype": "knife", "ico": "🗡",
		"name": "金剑", "desc": "", "rarity": "common", "base_price": 28,
		"sold": false, "locked": false }
	GameState.materials += 999
	shop._refresh()
	var card0: Control = shop._goods_box.get_child(0)
	var btn0: Button = card0.get_meta("buy_btn")
	if btn0 == null or not btn0.disabled:
		_fail("永久+临时槽全满时武器购买按钮应禁用")
		pl.weapons = w_bak; pl.temp_weapons = t_bak; GameState.materials = m_bak
		shop._refresh()
		return
	# ③ 临时槽有武器时「下一波」先弹二次确认框且不立即进波
	pl.temp_weapons = [{ "type": "knife", "cd": 0.1 }]
	shop._on_next_pressed()
	if shop._temp_confirm == null or not is_instance_valid(shop._temp_confirm):
		_fail("临时槽有武器时退出应先弹二次确认框")
		pl.weapons = w_bak; pl.temp_weapons = t_bak; GameState.materials = m_bak
		shop._refresh()
		return
	if GameState.phase != GameState.Phase.SHOP:
		_fail("退出确认框出现前不应直接进波（phase=%d）" % GameState.phase)
		shop._clear_temp_confirm()
		pl.weapons = w_bak; pl.temp_weapons = t_bak; GameState.materials = m_bak
		shop._refresh()
		return
	# 模拟取消：临时槽应保留
	shop._on_temp_canceled(shop._temp_confirm)
	if pl.temp_weapons.is_empty():
		_fail("取消退出后临时槽应仍保留")
	pl.weapons = w_bak; pl.temp_weapons = t_bak; GameState.materials = m_bak
	shop._refresh()
	print("SMOKE: shop temp-slot + instant evolve + capacity gate + exit confirm OK")

func _check_hud() -> void:
	var hud: Control = _main.get_node("UI/HUD")
	var wt: String = hud.get_wave_text()
	var ht: String = hud.get_hp_text()
	var focus: Control = hud.get_viewport().gui_get_focus_owner()
	print("SMOKE: hud wave_text=%s hp=%s lv=%s focus=%s" %
		[wt, ht, hud.get_lv_text(), "有" if focus else "无"])
	if wt.find("3") < 0:
		_fail("HUD 波次文本未更新")
		return
	if ht.find("/") < 0:
		_fail("HUD 血条文本未更新")
		return
	if hud.get_lv_text() == "Lv 1" and GameState.level > 1:
		_fail("HUD 等级文本未更新")
		return
	if focus != null:
		# 商店已关闭（next_wave 后 visible=false），不应残留焦点
		_fail("商店关闭后焦点未释放")
		return
	_check_items()

## 道具追踪/出售（50% 返还 + 效果移除）+ 升级池稀有度 + 暂停面板构建
func _check_items() -> void:
	var p2: Node2D = _main.get_node("Player")
	# 升级池带稀有度（商店可刷出升级属性的前提）
	if Registry.upgrade_list().is_empty() \
			or str(Registry.upgrade_list()[0].get("rarity", "")) == "":
		_fail("升级池缺 rarity 字段（商店升级属性无法着色）")
		return
	# 追踪：apply_item 计数（商店随机购买可能已持有 i-hp，用基线差值断言）
	var hp_base: int = int(p2.items_owned.get("i-hp", 0))
	p2.apply_item("i-hp")
	if int(p2.items_owned.get("i-hp", 0)) != hp_base + 1:
		_fail("apply_item 未计入 items_owned")
		return
	p2.apply_item("i-hp")
	if int(p2.items_owned.get("i-hp", 0)) != hp_base + 2:
		_fail("道具未叠加计数")
		return
	# 出售：返还 50%（30 → 15）+ 数量递减 + 效果移除
	var max2: float = p2.stats.max_hp   # 两次购买后的基线
	GameState.materials = 100
	var got: int = p2.sell_item("i-hp")
	print("SMOKE: sell got=%d mats=%d cnt=%d max_hp %.0f->%.0f" %
		[got, GameState.materials, int(p2.items_owned.get("i-hp", 0)), max2, p2.stats.max_hp])
	if got != 15:
		_fail("出售返还金额不对（应 50%% 购入价 15）")
		return
	GameState.materials += got   # 商店 _sell 负责加钱
	if GameState.materials != 115:
		_fail("出售入账失败")
	if int(p2.items_owned.get("i-hp", 0)) != hp_base + 1 or p2.stats.max_hp >= max2:
		_fail("出售未扣数量或未移除效果")
		return
	p2.sell_item("i-hp")
	if int(p2.items_owned.get("i-hp", 0)) != hp_base:
		_fail("连续出售后数量未回到基线")
		return
	if hp_base == 0 and p2.items_owned.has("i-hp"):
		_fail("售空后道具未移除")
		return
	# ---- 状态效果系统：燃烧 DoT / 冰冻定身+易伤 / 中毒百分比 / 到期清除 / 抗性 ----
	if Config.status_ids().size() < 6 or not Config.STATUS.has("burn"):
		_fail("状态定义缺失（Config.STATUS）")
		return
	var e_stat: Node2D = preload("res://scenes/enemies/enemy.tscn").instantiate()
	e_stat.setup("grunt", 1)
	e_stat.hp = 10000.0
	e_stat.max_hp = 10000.0
	e_stat.position = p2.global_position + Vector2(900.0, 0.0)
	_main.add_child(e_stat)
	e_stat.player = p2
	# 燃烧：按施加时伤害 × dot_scale × 层数跳伤
	var hp_before: float = e_stat.hp
	e_stat.apply_status("burn", 2, 0.0, 50.0, 1.0)
	if not e_stat.has_status("burn") or int(e_stat.statuses.burn.stacks) != 2:
		_fail("燃烧未正确施加/叠层")
		return
	e_stat._tick_statuses(0.5)
	var burn_expected: float = 50.0 * 0.18 * 2.0
	if not is_equal_approx(hp_before - e_stat.hp, burn_expected):
		_fail("燃烧跳伤数值错误（%.2f，期望 %.2f）" % [hp_before - e_stat.hp, burn_expected])
		return
	# 到期清除：一次推进 4 秒（> 燃烧 3s）后燃烧应消失
	e_stat._tick_statuses(4.0)
	if e_stat.has_status("burn"):
		_fail("燃烧到期未清除")
		return
	# 冰冻：移速归零 + 受到伤害 +25%
	# 单状态验证：燃烧+冰冻会触发相克「水克火」把双方一起消耗（见 _check_reactions）
	e_stat.apply_status("freeze", 1, 0.0, 0.0, 1.0)
	if e_stat._status_speed_mult() > 0.001:
		_fail("冰冻未定身（speed_mult=%.2f）" % e_stat._status_speed_mult())
		return
	if not is_equal_approx(e_stat._damage_taken_mult(), 1.25):
		_fail("冰冻易伤倍率错误（%.2f）" % e_stat._damage_taken_mult())
		return
	# 冰冻 + 减速同属水，不触发五行反应，应共存并同时到期
	e_stat.apply_status("slow", 1, 0.0, 0.0, 1.0)
	if not e_stat.has_status("freeze") or not e_stat.has_status("slow"):
		_fail("同五行状态应共存（freeze=%s slow=%s）"
			% [str(e_stat.has_status("freeze")), str(e_stat.has_status("slow"))])
		return
	e_stat._tick_statuses(4.0)
	if e_stat.has_status("freeze") or e_stat.has_status("slow"):
		_fail("状态到期未清除（freeze=%s slow=%s）"
			% [str(e_stat.has_status("freeze")), str(e_stat.has_status("slow"))])
		return
	if not is_equal_approx(e_stat._status_speed_mult(), 1.0):
		_fail("状态清除后移速未恢复")
		return
	# 中毒：按最大生命百分比跳伤（不吃攻击力加成）
	var hp_poison: float = e_stat.hp
	e_stat.apply_status("poison", 3, 0.0, 0.0, 1.0)
	e_stat._tick_statuses(0.8)
	var poison_expected: float = 10000.0 * 0.008 * 3.0
	if not is_equal_approx(hp_poison - e_stat.hp, poison_expected):
		_fail("中毒百分比跳伤错误（%.2f，期望 %.2f）" % [hp_poison - e_stat.hp, poison_expected])
		return
	# 命中载荷：武器状态必定触发（chance=1）+ 状态抗性减半时长
	var status_roll := { "dmg": 10.0, "crit": false, "status": "burn", "status_chance": 1.0,
		"status_stacks": 1, "status_dur": 0.0, "status_power": 10.0, "dur_mult": 1.0, "on_hit": {} }
	e_stat.statuses.clear()
	e_stat.apply_hit_roll(status_roll)
	if not e_stat.has_status("burn"):
		_fail("apply_hit_roll 未施加武器状态")
		return
	e_stat.status_resist = 0.5
	e_stat.statuses.clear()   # 清燃烧：否则会先触发水克火把两者一起消耗
	e_stat.apply_status("freeze", 1, 4.0, 0.0, 1.0)
	if float(e_stat.statuses.freeze.remaining) > 2.05:
		_fail("status_resist 未减免状态时长（%.2f）" % float(e_stat.statuses.freeze.remaining))
		return
	# 玩家侧载荷：武器 status 打包进 roll，经 apply_hit_roll 落到敌人
	#
	# ⚠️ S2：原断言把门槛硬编码成 `status_chance >= 0.85`，那是按旧武器数值写的。
	#    内置武器换成 flamethrower（status_chance = 0.80）后必然失败 ——
	#    但失败原因不是"载荷没打包"，而是"门槛写死了一个过期的数字"。
	#    → 改为**按武器配置推导期望值**：这样换任何武器都不会误报，
	#      而"载荷字段丢失/取错源"仍会被抓到（那才是本断言要看的）。
	var wcfg: Dictionary = Registry.weapons["flamethrower"]
	var w_roll: Dictionary = p2._roll_damage(10.0, wcfg)
	var expect_ch := clampf(float(wcfg.get("status_chance", 1.0)) + float(p2.stats.status_chance), 0.0, 1.0)
	if String(w_roll.status) != "burn" or not is_equal_approx(float(w_roll.status_chance), expect_ch):
		_fail("武器状态载荷未打包（status=%s chance=%.2f，期望 %.2f）"
			% [String(w_roll.status), float(w_roll.status_chance), expect_ch])
		return
	if float(w_roll.status_chance) <= 0.0:
		_fail("武器状态载荷命中率为 0（status=%s）" % String(w_roll.status))
		return
	e_stat.status_resist = 0.0
	e_stat.statuses.clear()
	w_roll.status_chance = 1.0   # 消除随机性，验证链路本身
	e_stat.apply_hit_roll(w_roll)
	if not e_stat.has_status("burn"):
		_fail("武器 roll 经 apply_hit_roll 未施加燃烧")
		return
	# 状态触发反馈：首次施加生成粒子+飘字+彩色环，并发 status_applied 信号（叠层不重复）
	if not Sfx._streams.has("status_burn") or not Sfx._streams.has("status_stun") \
			or not Sfx._streams.has("ui_click") or not Sfx._streams.has("ui_hover") \
			or not Sfx._streams.has("ui_page") or not Sfx._streams.has("ui_back"):
		_fail("状态触发音效未注册")
		return
	e_stat.statuses.clear()
	e_stat._status_flash_t = 0.0
	var sig_hits: Array = []
	var status_cb := func(sid: String, stacks2: int, _pos: Vector2) -> void:
		sig_hits.append([sid, stacks2])
	EventBus.status_applied.connect(status_cb)
	var fx_before := get_tree().get_nodes_in_group("fx").size()
	e_stat.apply_status("burn", 2, 0.0, 40.0, 1.0)
	var fx_after := get_tree().get_nodes_in_group("fx").size()
	if fx_after < fx_before + 2:
		_fail("状态触发未生成粒子/飘字（%d→%d）" % [fx_before, fx_after])
		return
	if e_stat._status_flash_t <= 0.0:
		_fail("状态触发彩色扩散环未激活")
		return
	if sig_hits.size() != 1 or String(sig_hits[0][0]) != "burn" or int(sig_hits[0][1]) != 2:
		_fail("status_applied 信号载荷不对（%s）" % str(sig_hits))
		return
	e_stat.apply_status("burn", 1, 0.0, 40.0, 1.0)   # 叠层刷新不应重复触发
	if sig_hits.size() != 1:
		_fail("状态叠层不应重复触发反馈")
		return
	EventBus.status_applied.disconnect(status_cb)
	# 音效节流：同状态 200ms 内只播一次
	Sfx._status_cd.clear()
	EventBus.status_applied.emit("freeze", 1, Vector2.ZERO)
	var cd0 := int(Sfx._status_cd.get("freeze", 0))
	EventBus.status_applied.emit("freeze", 1, Vector2.ZERO)
	if cd0 <= 0 or int(Sfx._status_cd.get("freeze", 0)) != cd0:
		_fail("状态音效节流失效")
		return
	print("SMOKE: status trigger fx/sfx OK")
	# 状态打击感：震屏/顿帧触发计数 + 顿帧自动恢复（45ms 真实时间）
	if _main._status_juice_count <= 0:
		_fail("状态触发未产生震屏/顿帧打击感")
		return
	var juice_frames := 0
	while Engine.time_scale < 1.0 and juice_frames < 600:
		await get_tree().process_frame
		juice_frames += 1
	if Engine.time_scale < 1.0:
		_fail("状态顿帧未恢复（time_scale=%.2f）" % Engine.time_scale)
		return
	e_stat.queue_free()
	await get_tree().process_frame
	# 状态道具走数据驱动 effects：on_hit_burn 可叠加/可出售移除，并进入 roll.on_hit
	# 商店随机购买可能已持有 i-ember / 咒术等 status_chance 升级，用基线差值断言
	var burn_base: float = float(p2.stats.get("on_hit_burn", 0.0))
	p2.apply_item("i-ember")
	if not is_equal_approx(float(p2.stats.on_hit_burn), burn_base + 0.20):
		_fail("状态道具 on_hit_burn 未生效（%.2f）" % float(p2.stats.on_hit_burn))
		return
	var item_roll: Dictionary = p2._roll_damage(10.0, {})
	var on_hit_map: Dictionary = item_roll.get("on_hit", {})
	var expect_hit: float = clampf(burn_base + 0.20 + float(p2.stats.status_chance), 0.0, 1.0)
	if not is_equal_approx(float(on_hit_map.get("burn", 0.0)), expect_hit):
		_fail("道具 on_hit_burn 未进入 roll.on_hit（%.2f ≠ %.2f）"
			% [float(on_hit_map.get("burn", 0.0)), expect_hit])
		return
	# Registry 拒绝非法状态 id、接受合法状态武器
	var bad_weapon := { "id": "smoke_bad_status", "name": "坏状态武器", "cd": 0.5, "dmg": 5.0, "status": "nope" }
	if Registry.register_weapon(bad_weapon):
		_fail("Registry 接受了未注册的状态 id")
		return
	var ok_weapon := { "id": "smoke_status_weapon", "name": "测试状态武器", "cd": 0.5, "dmg": 5.0,
		"status": "burn", "status_chance": 0.5, "shop_weight": 0.0 }
	if not Registry.register_weapon(ok_weapon):
		_fail("Registry 拒绝了合法状态武器")
		return
	Registry.weapons.erase("smoke_status_weapon")
	_check_status_legend()
	_check_reactions()
	_check_phase2_content()
	_check_phase3_artifacts()
	_check_event_cards()
	_check_map_themes()
	await _check_character_traits()
	await _check_weapon_fx()
	await _check_ballistic_lead()
	_check_affinity()
	_check_sigils()
	_check_element_engine()
	_check_element_channels()
	_check_element_output()
	_check_element_mobs()
	_check_element_gate()
	_check_assim_items()
	_check_unique_items()
	_check_visual_layer()
	_check_balance()
	_check_reach_safety()
	_check_spread_channel()
	_check_buff_display()
	_check_wave_bands()
	_check_balance_log()
	_check_dot_contribution()
	_check_assim_gain()
	_check_affinity_floor()
	_check_object_pool()
	_check_boss_death_skills()
	_check_boss_skills()
	_check_round9_boss_terrain()
	_check_mobile_ui()
	_check_unlocks()
	_check_sect_talents()
	if _failed:
		return
	print("SMOKE: status effects OK")
	# 暂停面板内容重建（打开/关闭 + 左右子节点存在）
	_main.toggle_pause()
	await get_tree().process_frame
	if not _main._pause_overlay.visible:
		_fail("暂停面板未打开")
		return
	if _main._pause_left.get_child_count() < 10 or _main._pause_items.get_child_count() < 1:
		_fail("暂停面板属性/道具行未构建")
		return
	# 法宝区（spec 集成点 10）：法宝不占常驻 HUD，暂停面板是局内查看持有/叠层的入口。
	# 直接改字典而不走 apply_artifact：不发 artifact_acquired，避开 toast 队列与图鉴解锁残留
	var pi: Control = _main._pause_items
	if _find_label_text(pi, "法宝") == "":
		_fail("暂停面板缺少法宝分区")
		return
	p2.artifacts_owned["art_notch_blade"] = 1
	p2.artifact_stacks["art_notch_blade"] = 2
	_main._refresh_pause_content()
	# 名字与叠层是两个兄弟 Label（行内左/右），得分开找：
	# 只搜「断刃锋」会先命中名字 Label，拿不到叠层文本
	var art_name := _find_label_text(pi, "断刃锋")
	var art_stack := _find_label_text(pi, "x2 层")
	p2.artifacts_owned.erase("art_notch_blade")
	p2.artifact_stacks.erase("art_notch_blade")
	_main._refresh_pause_content()
	if art_name == "" or art_stack == "":
		_fail("暂停面板法宝区未显示持有法宝与叠层（name='%s' stack='%s'）"
			% [art_name, art_stack])
		return
	# ---- 武器区 / 临时增益区（第 11 轮新增 · 用户需求 5/6）----
	# ⚠️ 必须断言**具体条目**而不能只断言「分区标题在」：武器区第一版插在了
	#    `_pause_items` 的清空循环之前 —— 加完立刻被同函数下面几行删掉，
	#    面板上一行武器都没有；而「标题存在」类断言会跟着标题一起被判绿（都没有）。
	#    用户的诉求本来就是「点武器/道具能看到东西」，所以这里直接找**武器名**。
	if _find_label_text(pi, "临时增益") == "":
		_fail("暂停面板缺少临时增益分区")
		return
	if _find_label_text(pi, "武器") == "":
		_fail("暂停面板缺少武器分区")
		return
	if p2.weapons.is_empty():
		_fail("暂停面板武器区用例前置不成立：玩家此刻一件武器都没有")
		return
	var first_wid := String(p2.weapons[0].type)
	var first_wcfg: Dictionary = Registry.weapons.get(first_wid, {})
	if first_wcfg.is_empty():
		_fail("暂停面板武器区用例前置不成立：Registry 缺武器 %s" % first_wid)
		return
	if _find_label_text(pi, String(first_wcfg.get("name", first_wid))) == "":
		_fail("暂停面板武器区没列出实际持有的武器（%s）—— 多半是被同函数的清空循环删掉了"
			% first_wid)
		return
	_main.toggle_pause()
	# 波末自动回收积压的升级在此清空（触控/移动测试需要稳定的 PLAYING 阶段）
	GameState.level_queue = 0
	GameState.set_phase(GameState.Phase.PLAYING)   # 触控移动测试显式进入战斗阶段
	# 移动端触控层：节点存在、桌面（无触屏）隐藏、touch_move 可驱动玩家
	var tc: Control = _main.get_node("UI/TouchControls")
	if tc == null:
		_fail("缺少 TouchControls 触控层")
		return
	if tc.visible:
		_fail("桌面端 TouchControls 应隐藏")
		return
	GameState.touch_move = Vector2.RIGHT
	await get_tree().physics_frame
	await get_tree().physics_frame
	GameState.touch_move = Vector2.ZERO
	if p2.velocity.x <= 10.0:
		_fail("touch_move 未驱动玩家移动")
		return
	print("SMOKE: items track/sell + pause panel + touch layer OK")
	# 桌面鼠标点触移动：单击朝目标移动 → 到达停下；拖动更新方向；键盘接管取消
	var mm: Control = _main.get_node("UI/MouseMove")
	if mm == null or mm.player != p2:
		_fail("缺少 MouseMove 鼠标移动层或未绑定玩家")
		return
	var saved_pos: Vector2 = p2.global_position
	var saved_vel: Vector2 = p2.velocity
	mm._start(saved_pos + Vector2(240.0, 0.0))
	mm._process(0.016)
	if GameState.mouse_move.x <= 0.5 or absf(GameState.mouse_move.y) > 0.01:
		_fail("鼠标单击未产生朝目标移动输入（%s）" % str(GameState.mouse_move))
		return
	mm._holding = true
	mm._target = saved_pos + Vector2(0.0, 240.0)   # 模拟拖动更新目标
	mm._process(0.016)
	if GameState.mouse_move.y <= 0.5 or absf(GameState.mouse_move.x) > 0.01:
		_fail("鼠标拖动未更新移动方向（%s）" % str(GameState.mouse_move))
		return
	mm._target = saved_pos + Vector2(6.0, 0.0)     # 目标进入到达半径
	mm._process(0.016)
	if mm._active or GameState.mouse_move != Vector2.ZERO:
		_fail("鼠标移动到达目标后未停下")
		return
	mm._start(saved_pos + Vector2(240.0, 0.0))
	Input.action_press("move_left")
	mm._process(0.016)
	Input.action_release("move_left")
	if mm._active or GameState.mouse_move != Vector2.ZERO:
		_fail("键盘输入未取消鼠标移动")
		return
	p2.global_position = saved_pos
	p2.velocity = saved_vel
	mm._cancel()
	print("SMOKE: mouse move OK")
	# ---- 单档存档验证（S4.5 §10.1）：唯一档 → 篡改恢复一致 → 备份兜底 → 清档 + 损档容错 ----
	GameState.slot_id = 1
	# 唯一档只有一个槽：`slot_path` 对 0 / 2 必须返回空串（调用方据此拒绝写入）
	if SaveRun.SLOT_COUNT != 1 or SaveRun.slot_path(0) != "" or SaveRun.slot_path(2) != "":
		_fail("单档化未生效：SLOT_COUNT=%d / slot_path(0)='%s' / slot_path(2)='%s'"
			% [SaveRun.SLOT_COUNT, SaveRun.slot_path(0), SaveRun.slot_path(2)])
		return
	if not SaveRun.exists(1):
		_fail("商店阶段未自动生成存档")
		return
	# checkpoint 口径（§13-29）：进度档必须写 `shop`，否则恢复后会把刚打过的那波重打一遍
	if String(SaveRun.summary(1).get("checkpoint", "")) != SaveRun.CHECKPOINT_SHOP:
		_fail("进度档 checkpoint 不是 shop（实为 '%s'）"
			% SaveRun.summary(1).get("checkpoint", ""))
		return
	# 清档后 restore 必须返回 0 且不动现场（此时才写下面往返比对用的档）
	SaveRun.clear()
	GameState.materials = 555
	if SaveRun.restore(p2) != 0 or GameState.materials != 555:
		_fail("无档时 restore 应返回 0 且不改动现场（mats=%d）" % GameState.materials)
		return
	# 第 7 轮：先种一条升级记账进档，否则下面的往返断言会在「两边都是空」时假绿
	p2.upgrades_owned = { "hp": 2, "berserk": 1 }
	if not SaveRun.save(9, p2):
		_fail("合法波次存档写入失败")
		return
	var s_mats := GameState.materials
	var s_lv := GameState.level
	var s_xp := GameState.xp
	var s_hp: float = p2.hp
	var s_stats: Dictionary = p2.stats.duplicate()
	var s_wcnt: int = p2.weapons.size()
	var s_items: Dictionary = p2.items_owned.duplicate()
	var s_ups: Dictionary = p2.upgrades_owned.duplicate()
	# 篡改现场后从唯一档恢复
	GameState.materials = 7
	GameState.level = 1
	GameState.xp = 5
	p2.hp = 1.0
	p2.weapons = []
	p2.items_owned = {}
	p2.upgrades_owned = {}
	GameState.slot_id = 1
	var nw: int = SaveRun.restore(p2)
	print("SMOKE: save unique wave=%d mats=%d lv=%d xp=%d hp=%.0f weapons=%d items=%d" %
		[nw, GameState.materials, GameState.level, GameState.xp,
		p2.hp, p2.weapons.size(), p2.items_owned.size()])
	if nw != 9:
		_fail("存档波次往返失败（wave=%d）" % nw)
		return
	if GameState.materials != s_mats or GameState.level != s_lv or GameState.xp != s_xp \
			or not is_equal_approx(p2.hp, s_hp) or p2.weapons.size() != s_wcnt:
		_fail("存档恢复后 run/player 基础字段不一致")
		return
	var stats_ok: bool = p2.stats.size() == s_stats.size()
	if stats_ok:
		for k in s_stats:
			if not is_equal_approx(float(s_stats[k]), float(p2.stats[k])):
				stats_ok = false
				break
	if not stats_ok:
		_fail("存档恢复后 stats 不一致")
		return
	var items_ok: bool = p2.items_owned.size() == s_items.size()
	if items_ok:
		for k in s_items:
			if int(p2.items_owned.get(k, -1)) != int(s_items[k]):
				items_ok = false
				break
	if not items_ok:
		_fail("存档恢复后 items_owned 不一致")
		return
	# 第 7 轮：升级记账必须一起往返 —— 丢了这个键，续档后「金/红升级唯一」会**静默**失效
	# （upgrades_owned 归空 → 同一张金升级能再刷一遍），不报错、只是不再唯一。
	var ups_ok: bool = p2.upgrades_owned.size() == s_ups.size()
	if ups_ok:
		for k in s_ups:
			if int(p2.upgrades_owned.get(k, -1)) != int(s_ups[k]):
				ups_ok = false
				break
	if not ups_ok:
		_fail("存档恢复后 upgrades_owned 不一致（存档=%s / 恢复=%s）" % [str(s_ups), str(p2.upgrades_owned)])
		return
	p2.upgrades_owned = {}   # 探针清理：别把这条用例种下的账留给后面的用例
	# 连续保存应保留上一版；正式文件损坏时从该备份恢复。
	SaveRun.clear()
	if not SaveRun.save(8, p2) or not SaveRun.save(9, p2):
		_fail("无法准备存档备份恢复测试")
		return
	var broken_final := FileAccess.open(SaveRun.slot_path(1), FileAccess.WRITE)
	broken_final.store_string("broken")
	broken_final.close()
	if SaveRun.restore(p2) != 8:
		_fail("正式档损坏时未从上一版备份恢复")
		return
	SaveRun.clear()
	if SaveRun.exists(1):
		_fail("清档失败：唯一档仍在")
		return
	# 损档容错：垃圾内容应判定无效
	var fj := FileAccess.open(SaveRun.slot_path(1), FileAccess.WRITE)
	fj.store_string("corrupted{{{")
	fj.close()
	if SaveRun.restore(p2) != 0:
		_fail("损坏存档未被判定为无效")
		return
	SaveRun.clear()
	var malformed := FileAccess.open(SaveRun.slot_path(1), FileAccess.WRITE)
	malformed.store_string(JSON.stringify({"version": 2, "rng_a": 1,
		"run": {"wave": 3, "materials": 0, "kills": 0, "run_time": 0,
			"level": 1, "xp": 0, "level_queue": 0},
		"player": {"hp": 10, "stats": {}, "weapons": [], "items_owned": {}}}))
	malformed.close()
	if SaveRun.restore(p2) != 0:
		_fail("结构完整但深层字段非法的存档未被拒绝")
		return
	SaveRun.clear()
	# 「第 1 波之前没有商店」：手改成 `wave 1 + shop` 的档必须降级为「从第 1 波起跑」，
	# 否则恢复后会去开一个不存在的「第 0 波商店」（`shop_ui.open(0)`）。
	# 注意与下一段互为对照 —— 同一波号、只有 checkpoint 不同，恢复语义必须相反。
	if not SaveRun.save(1, p2, SaveRun.CHECKPOINT_SHOP):
		_fail("wave 1 + shop 存档写入失败")
		return
	if SaveRun.restore(p2) != 1 \
			or SaveRun.restored_checkpoint != SaveRun.CHECKPOINT_WAVE_START:
		_fail("wave 1 + shop 档未被降级为 wave_start（实为 %s）"
			% SaveRun.restored_checkpoint)
		return
	SaveRun.clear()
	# 新局初始档（main.gd `start_run` 之后那次 save(1)）用的就是 wave_start
	if not SaveRun.save(1, p2, SaveRun.CHECKPOINT_WAVE_START) or SaveRun.restore(p2) != 1 \
			or SaveRun.restored_checkpoint != SaveRun.CHECKPOINT_WAVE_START:
		_fail("新局初始档（wave 1 + wave_start）未被原样恢复")
		return
	SaveRun.clear()
	if SaveRun.save(Config.WAVES_TOTAL + 1, p2):
		_fail("非法波次未被拒绝")
		return
	# ---- 武器进化：单分支自动合成 + 多分支待选队列 + 指定进化 ----
	#
	# ⚠️ 2026-09-17 S8 重写（第二次）：S2 时内置 5 把的进化树**指向空气**被清空
	#    （`knife.evolve_branches` 原本指向已迁入工坊包的 `blade`/`blade_ex`），
	#    本段退化成「验证清空后的必然行为」。S8 已按 §4.4 **补回进化形态**，
	#    所以这里恢复成「验证进化真的会发生」，并补上三条新的不变式：
	#      ① **进化体必须自带 element，且与基础体同元素** —— 否则「元素武器 →
	#         无属性武器」把五行体系打穿，而且**完全不报错**，只表现为
	#         「进化后伤害反而不吃关系加成」这种最难查的静默失效。
	#      ② `evolve_need > 0` 与「分支非空」必须同真同假（S2 那条半配置护栏仍然有效）。
	#      ③ 分支目标必须已注册 + `shop_weight == 0` —— 前者防「合成静默失败」，
	#         后者防玩家绕过「凑 3 把」直接在商店买到进化体。
	var p4: Node2D = _main.get_node("Player")
	var saved_weapons4: Array = p4.weapons.duplicate(true)
	for wid in Config.LOADOUT_WEAPONS:
		# 变量名用 wcfg2：本函数上方已有 `wcfg`（武器容器循环里），GDScript 同一作用域不重名
		var wcfg2: Dictionary = Registry.weapons[String(wid)]
		var has_need := int(wcfg2.get("evolve_need", 0)) > 0
		var branches: Array = wcfg2.get("evolve_branches", [])
		if has_need != (not branches.is_empty()):
			_fail("内置武器 %s 的进化配置半残（evolve_need=%d / branches=%d）"
				% [String(wid), int(wcfg2.get("evolve_need", 0)), branches.size()])
			return
		if not has_need:
			_fail("内置武器 %s 缺进化配置（S8 后 5 把基础武器都应可进化）" % String(wid))
			return
		# 单分支 = 波末自动合成；写成多分支会走进化选择 UI，与本轮设计不符
		if branches.size() != 1:
			_fail("内置武器 %s 应恰好 1 个进化分支（实测 %d）" % [String(wid), branches.size()])
			return
		for bid in branches:   # 分支目标必须真实存在，否则合成会静默失败
			if not Registry.weapons.has(String(bid)):
				_fail("内置武器 %s 的进化分支 %s 未注册" % [String(wid), String(bid)])
				return
			var excfg: Dictionary = Registry.weapons[String(bid)]
			var exel := String(excfg.get("element", ""))
			if exel != String(wcfg2.get("element", "")):
				_fail("进化体 %s 的元素「%s」与基础体 %s 的「%s」不一致（会把五行打穿）"
					% [String(bid), exel, String(wid), String(wcfg2.get("element", ""))])
				return
			if float(excfg.get("shop_weight", -1.0)) != 0.0:
				_fail("进化体 %s 的 shop_weight 应为 0（实测 %s），否则商店能直接买到"
					% [String(bid), str(excfg.get("shop_weight", "缺失"))])
				return
	# 凑 3 把金剑 → 单分支应**自动**合成 1 把 knife_ex（且不弹选择 UI）
	p4.weapons = []
	for _i2 in 3:
		p4.weapons.append({ "type": "knife", "cd": 0.1 })
	var evolved0: Array = p4.evolve_weapons()
	if evolved0.size() != 1:
		_fail("凑满 3 把金剑应自动进化 1 次（实得 %d 条公告）" % evolved0.size())
		return
	var evo0: Dictionary = p4.weapons[0]
	if p4.weapons.size() != 1 or String(evo0.get("type", "")) != "knife_ex":
		_fail("进化后应只剩 1 把 knife_ex（实测 %s）" % str(p4.weapons))
		return
	if not p4.pending_evolve_choices().is_empty():
		_fail("单分支进化不该产生待选分支（%s）" % str(p4.pending_evolve_choices()))
		return
	# 反向对照：只凑 2 把时不该进化（否则说明 `evolve_need: 3` 没生效，凑 1 把就进化了）
	p4.weapons = []
	for _i3 in 2:
		p4.weapons.append({ "type": "knife", "cd": 0.1 })
	if not p4.evolve_weapons().is_empty() or p4.weapons.size() != 2:
		_fail("未达 evolve_need 时不该进化（剩 %d 把）" % p4.weapons.size())
		return
	# 指定进化到一个不存在的目标：必须被拒（不能默默吞掉玩家的 3 把武器）
	# ⚠️ 别用 `blade` 当"未注册目标" —— 它如今在工坊包 brotato_lite_core 里是注册着的。
	#    这里用一个语法合法、但任何注册表里都不会有的 id，才能真验到"拒绝"分支。
	p4.weapons = []
	for _i4 in 3:
		p4.weapons.append({ "type": "knife", "cd": 0.1 })
	if p4.evolve_weapon_to("knife", "no_such_weapon_id") != "":
		_fail("向未注册目标进化应失败（no_such_weapon_id）")
		return
	if p4.weapons.size() != 3:
		_fail("失败的进化不该消耗武器（剩 %d 把）" % p4.weapons.size())
		return
	# 指定进化到**合法**目标：进化选择 UI 那条路（`evolve_weapon_to`）也必须成立
	if p4.evolve_weapon_to("knife", "knife_ex") == "" or p4.weapons.size() != 1:
		_fail("指定进化到 knife_ex 应成功（剩 %d 把）" % p4.weapons.size())
		return
	# ---- 需求 3：临时武器槽 + 即时进化（单分支买够 need 把立刻升级）----
	p4.weapons = []
	p4.temp_weapons = []
	# 永久槽放 5 把（2 把金剑 + 3 把水枪），临时槽空 → 此时还能买（进临时槽）
	for _i in 2:
		p4.weapons.append({ "type": "knife", "cd": 0.1 })
	for _i in 3:
		p4.weapons.append({ "type": "frost_staff", "cd": 0.1 })
	p4.add_weapon_to_temp("knife")   # 临时槽 1 把 → 金剑合计 3 把
	p4.refresh_family_synergy()
	if p4.weapon_count("knife") != 3:
		_fail("临时槽路由后金剑合计应为 3（实 %d）" % p4.weapon_count("knife"))
		return
	if p4.weapon_capacity_full():
		_fail("永久5 + 临时1 不应判满（临时槽还能再买）")
		return
	var _evo3: String = p4.instant_evolve("knife")
	if _evo3 == "":
		_fail("买够 3 把金剑（含临时槽）应即时进化")
		return
	if p4.weapon_count("knife") != 0:
		_fail("进化后金剑应被消耗（剩 %d 把）" % p4.weapon_count("knife"))
		return
	if p4.weapon_count("knife_ex") != 1 or p4.temp_weapons.size() != 0 or p4.weapons.size() != 4:
		_fail("进化体应进永久槽、临时槽应清空（weapons=%d knife_ex=%d temp=%d）"
			% [p4.weapons.size(), p4.weapon_count("knife_ex"), p4.temp_weapons.size()])
		return
	# 临时槽半价卖出：退出商店时清掉临时槽并返还材料
	p4.temp_weapons = [{ "type": "frost_staff", "cd": 0.1 }]
	var _got: int = p4.sell_temp_weapons()
	if _got <= 0 or not p4.temp_weapons.is_empty():
		_fail("临时槽半价卖出应返还材料并清空（got=%d）" % _got)
		return
	# 满槽门禁：永久5 + 临时2 → capacity_full 为真（商店据此拦购买）
	p4.weapons = []
	p4.temp_weapons = []
	for _i in 5:
		p4.weapons.append({ "type": "frost_staff", "cd": 0.1 })
	p4.add_weapon_to_temp("knife")
	p4.add_weapon_to_temp("frost_staff")
	if not p4.weapon_capacity_full():
		_fail("永久+临时都满 应判定满槽（商店购买门禁失效）")
		return
	p4.weapons = saved_weapons4   # 还原
	# ---- 局外天赋：购买/效果/槽位 ----
	MetaProgress.reset_for_tests()
	MetaProgress.essence = 1000
	if not MetaProgress.buy_talent("vitality") or MetaProgress.talent_level("vitality") != 1:
		_fail("天赋购买失败")
		return
	if MetaProgress.essence != 940:
		_fail("天赋扣费错误（%d，应 940）" % MetaProgress.essence)
		return
	if not is_equal_approx(MetaProgress.effect_sum("stats", "max_hp"), 15.0):
		_fail("天赋效果合计错误")
		return
	# ⚠️ 期望值取自 Config.WEAPON_SLOTS，不硬编码 —— 槽位数改过一次（6→5，S8），
	#    写死数字会在下次改槽位时又红一次，且红得像「天赋没生效」。
	if MetaProgress.weapon_slots() != Config.WEAPON_SLOTS:
		_fail("未购军火专家时武器槽应为 %d" % Config.WEAPON_SLOTS)
		return
	# 精华不足拒绝：余额清零后尝试购买
	MetaProgress.essence = 0
	if MetaProgress.buy_talent("arsenal"):
		_fail("精华不足不应购入军火专家")
		return
	MetaProgress.essence = 1000
	# 军火专家 = +1 槽，同样绑 Config 而非写死 7（同上）
	if not MetaProgress.buy_talent("arsenal") or MetaProgress.weapon_slots() != Config.WEAPON_SLOTS + 1:
		_fail("军火专家购买后武器槽应为 %d" % (Config.WEAPON_SLOTS + 1))
		return
	# 开局应用：stats 叠加 + 材料入账
	MetaProgress.buy_talent("fortune")
	GameState.set_materials(0)
	var stats_before: Dictionary = p4.stats.duplicate()
	MetaProgress.apply_on_run_start(p4)
	if not is_equal_approx(float(p4.stats.max_hp), float(stats_before.max_hp) + 15.0) \
			or GameState.materials != 40:
		_fail("天赋开局应用错误（max_hp=%.0f mats=%d）" % [p4.stats.max_hp, GameState.materials])
		return
	# 精华结算：无尽按积分 8%
	MetaProgress.reset_for_tests()
	var got_e: int = MetaProgress.grant_run_essence(1000, 5, true)
	if got_e != 80 or MetaProgress.essence != 80 or MetaProgress.total_earned != 80:
		_fail("局末精华结算错误（got=%d）" % got_e)
		return
	MetaProgress.reset_for_tests()
	# 清理写入 user:// 的测试天赋档
	var meta_path := "user://meta_progress.json"
	if FileAccess.file_exists(meta_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(meta_path))
	print("SMOKE: talent + weapon evolution OK")
	# ---- 事件波：判定/三种事件/结算 ----
	GameState.endless = false
	if not Config.is_event_wave(3) or Config.is_event_wave(4) or Config.is_event_wave(10):
		_fail("事件波判定错误（3 应为事件波，10 BOSS 波不触发）")
		return
	GameState.endless = true
	if not Config.is_event_wave(11) or Config.is_event_wave(17) or Config.is_event_wave(20):
		_fail("事件波判定错误（11/15/19 事件，17 常规，20 BOSS 排除）")
		return
	GameState.endless = false
	# 宝箱守卫波：直接驱动 wave_manager 内部状态走完整流程
	var wm3: Node = _main.get_node("WaveManager")
	wm3.start_wave(3)
	await get_tree().process_frame
	if not ["treasure", "hunt", "meteor"].has(wm3.event_kind):
		_fail("事件波未抽取类型（kind=%s）" % wm3.event_kind)
		return
	# 三种事件的选怪逻辑
	var diff_normal: Dictionary = Registry.get_difficulty("normal")
	if wm3.event_kind == "treasure" and wm3._pick_spawn_id(diff_normal) != "chest_guard":
		_fail("宝箱守卫波选怪错误")
		return
	# 强制 treasure 结算路径：清场 → 掉高阶道具
	wm3.event_kind = "treasure"
	var mats_t0: int = GameState.materials
	# 统计「道具总件数」而不是 items_owned.size()：后者是「不同种类数」，
	# 抽到一件已经持有的道具时种类数不变，断言会随机假失败
	var items_t0 := 0
	for k_it in p4.items_owned:
		items_t0 += int(p4.items_owned[k_it])
	wm3.ending_started = true
	wm3.wave_timer = 0.0
	wm3._settle_event_wave()
	await get_tree().process_frame
	var items_t1 := 0
	for k_it2 in p4.items_owned:
		items_t1 += int(p4.items_owned[k_it2])
	if items_t1 <= items_t0:
		_fail("宝箱守卫波清场未掉高阶道具")
		return
	# 强制 hunt 结算路径：0 精英存活给满额奖励
	wm3.event_kind = "hunt"
	wm3._hunt_elites_total = 5
	wm3.wave_timer = 0.0
	var mats_h0: int = GameState.materials
	wm3._settle_event_wave()
	if GameState.materials <= mats_h0:
		_fail("精英狩猎结算未发放奖励")
		return
	# 强制 meteor 结算 + 流星生成
	wm3.event_kind = "meteor"
	wm3._meteor_t = 0.0
	var mats_m0: int = GameState.materials
	wm3._spawn_meteor()
	wm3._settle_event_wave()
	if GameState.materials <= mats_m0:
		_fail("流星雨结算未发放奖励")
		return
	if get_tree().get_nodes_in_group("fx").is_empty():
		_fail("流星未生成预警特效")
		return
	# 清理测试残留：回到安全状态
	wm3.event_kind = ""
	for fx_node in get_tree().get_nodes_in_group("fx"):
		fx_node.queue_free()
	GameState.set_phase(GameState.Phase.PLAYING)
	print("SMOKE: event waves OK")

	# ---- 每日挑战 + BOSS 池 ----
	# 日期哈希稳定：同日期同配置（全服同局的基础）
	var d1: Dictionary = Config.daily_setup("2026-09-08")
	var d2: Dictionary = Config.daily_setup("2026-09-08")
	if d1.seed != d2.seed or d1.character_id != d2.character_id \
			or d1.boss_id != d2.boss_id or d1.difficulty_id != d2.difficulty_id:
		_fail("每日挑战配置不稳定（同日期结果不同）")
		return
	var d3: Dictionary = Config.daily_setup("2026-09-09")
	if d3.seed == d1.seed:
		_fail("不同日期种子应不同")
		return
	if not Registry.characters.has(String(d1.character_id)) \
			or not Registry.difficulties.has(String(d1.difficulty_id)) \
			or not Registry.enemies.has(String(d1.boss_id)):
		_fail("每日挑战配置引用了不存在的内容（%s / %s / %s）"
			% [d1.character_id, d1.difficulty_id, d1.boss_id])
		return
	# 新 BOSS 注册与专属行为
	for bid in ["boss_spiral", "boss_summoner"]:
		if not Registry.enemies.has(bid) or not Registry.enemies[bid].is_boss:
			_fail("新 BOSS 未注册或未标记 is_boss：%s" % bid)
			return
	# BOSS 轮换：daily 模式固定今日 BOSS
	GameState.daily = true
	GameState.daily_date = "2026-09-08"
	var wm_d: Node = _main.get_node("WaveManager")
	var picked_daily: String = wm_d._pick_boss_id()
	if picked_daily != String(d1.boss_id):
		_fail("每日挑战 BOSS 未按日期固定（%s != %s）" % [picked_daily, d1.boss_id])
		return
	# 每日榜：按日期隔离（独立测试目录，防真实榜残留污染）
	Leaderboard.set_storage_root_for_tests("user://tests/lb_daily")
	var endless_cnt: int = Leaderboard.get_list().size()
	if Leaderboard.record(500, 5, "每日A", 10, 60.0, "daily:2026-09-08") != 1:
		_fail("每日榜首次记录应第 1 名")
		return
	if Leaderboard.record(300, 4, "每日B", 8, 50.0, "daily:2026-09-09") != 1:
		_fail("不同日期每日榜应独立")
		return
	if Leaderboard.get_daily_list("2026-09-08").size() != 1 \
			or int(Leaderboard.get_daily_list("2026-09-08")[0].score) != 500:
		_fail("每日榜隔离读取错误")
		return
	if Leaderboard.get_list().size() != endless_cnt:
		_fail("每日榜成绩不应混入无尽总榜")
		return
	Leaderboard.reset_storage_root_after_tests()
	# 清理每日榜测试目录
	var lb_daily_file := "user://tests/lb_daily/leaderboard.json"
	if FileAccess.file_exists(lb_daily_file):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(lb_daily_file))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://tests/lb_daily"))
	# BOSS 实例行为：spiral BOSS 生成螺旋弹、summoner BOSS 召唤小怪
	GameState.daily = false
	GameState.set_phase(GameState.Phase.PLAYING)
	# 清理此前测试累积的敌弹（护栏 150 会拦截新弹，导致误判）
	for b_pre in get_tree().get_nodes_in_group("enemy_bullets"):
		b_pre.queue_free()
	for e_pre in get_tree().get_nodes_in_group("enemies"):
		e_pre.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var p5: Node2D = _main.get_node("Player")
	p5.iframes = 1.0e9
	var sp_boss: Node2D = preload("res://scenes/enemies/enemy.tscn").instantiate()
	sp_boss.setup("boss_spiral", 10)
	sp_boss.position = p5.global_position + Vector2(400, 0)
	_main.add_child(sp_boss)
	sp_boss.player = p5
	sp_boss.ring_cd = 0.0
	# 直接驱动螺旋弹幕（确定性，不依赖物理帧时机）
	sp_boss._fire_spiral_volley()
	await get_tree().physics_frame
	var bullets1: int = get_tree().get_nodes_in_group("enemy_bullets").size()
	if bullets1 <= 0:
		_fail("螺旋 BOSS 未发射弹幕")
		return
	sp_boss.queue_free()
	var sm_boss: Node2D = preload("res://scenes/enemies/enemy.tscn").instantiate()
	sm_boss.setup("boss_summoner", 10)
	sm_boss.position = p5.global_position + Vector2(400, 0)
	_main.add_child(sm_boss)
	sm_boss.player = p5
	# 直接驱动召唤（确定性）
	sm_boss._summon_minions()
	await get_tree().physics_frame
	var enemies1: int = get_tree().get_nodes_in_group("enemies").size()
	if enemies1 <= 0:
		_fail("召唤 BOSS 未召唤小怪")
		return
	sm_boss.queue_free()
	p5.iframes = 0.45
	# 清理召唤物与敌弹
	for e5 in get_tree().get_nodes_in_group("enemies"):
		e5.queue_free()
	for b5 in get_tree().get_nodes_in_group("enemy_bullets"):
		b5.queue_free()
	print("SMOKE: daily challenge + boss pool OK")

	if not Combat.segment_hits_circle(Vector2.ZERO, Vector2(100, 0), Vector2(50, 0), 4.0) \
			or Combat.segment_hits_circle(Vector2.ZERO, Vector2(100, 0), Vector2(50, 20), 4.0):
		_fail("连续线段碰撞判定错误")
		return
	# 大圆圆心更远但边缘更近时，必须按首次进入点而非圆心投影排序。
	var small := SegmentEnemy.new()
	small.radius = 5.0
	small.position = Vector2(100050.0, 100000.0)
	add_child(small)
	small.add_to_group("enemies")
	var large := SegmentEnemy.new()
	large.radius = 20.0
	large.position = Vector2(100060.0, 100000.0)
	add_child(large)
	large.add_to_group("enemies")
	await get_tree().physics_frame
	var first_hit := Combat.first_enemy_hit_on_segment(Vector2(100000.0, 100000.0),
		Vector2(100100.0, 100000.0), 0.0)
	var hit_position: Vector2 = first_hit.get("position", Vector2.ZERO)
	if first_hit.get("enemy") != large or not is_equal_approx(hit_position.x, 100040.0):
		_fail("连续碰撞未按圆边界首次进入点选择目标/命中位置")
		return
	small.position = Vector2(100010.0, 100000.0)
	Combat.update_enemy_position(small)
	if not Combat.enemies_near(small.position, 1.0).has(small):
		_fail("敌人移动后当前帧空间索引未更新")
		return
	if not Combat.enemies_near(Vector2.ZERO, 1.0e12).has(large):
		_fail("超大空间查询未安全退化为实体扫描")
		return
	small.queue_free()
	large.queue_free()
	# Registry 合同：未知 AI 拒绝，普通敌人不能覆盖最终 BOSS，坏刷怪引用拒绝。
	var invalid_enemy := {"id": "smoke_bad_ai", "name": "bad", "hp": 10.0,
		"speed": 10.0, "dmg": 1.0, "r": 10.0, "ai": "unknown"}
	if Registry.register_enemy(invalid_enemy):
		_fail("Registry 接受了未知敌人 AI")
		return
	var normal_enemy := {"id": "smoke_normal", "name": "normal", "hp": 10.0,
		"speed": 10.0, "dmg": 1.0, "r": 10.0, "ai": "chaser"}
	if not Registry.register_enemy(normal_enemy):
		_fail("Registry 拒绝了合法普通敌人")
		return
	Registry.boss_override = "smoke_normal"
	if Registry.boss_id() != "boss" or Registry._valid_spawn_entries([{"item": "missing", "w": 1.0}]):
		_fail("BOSS 覆盖或刷怪表防御校验失效")
		return
	var declared_boss := {"id": "smoke_declared_boss", "name": "boss", "hp": 100.0,
		"speed": 10.0, "dmg": 1.0, "r": 20.0, "ai": "chaser", "is_boss": true}
	if not Registry.register_enemy(declared_boss) \
			or Registry.enemies.smoke_declared_boss.ai != "boss" \
			or not Registry.enemies.smoke_declared_boss.has("ring_count"):
		_fail("声明为 BOSS 的敌人未规范化完整合同")
		return
	Registry.boss_override = "smoke_declared_boss"
	if Registry.boss_id() != "smoke_declared_boss" \
			or Registry._valid_spawn_entries([{"item": "smoke_declared_boss", "w": 1.0}]):
		_fail("规范化 BOSS 无法作为最终 BOSS，或被普通波刷怪表接受")
		return
	var reserved_boss: Dictionary = declared_boss.duplicate(true)
	reserved_boss["id"] = "grunt"
	if Registry.register_enemy(reserved_boss):
		_fail("内置普通敌人 ID 被覆盖为 BOSS")
		return
	var custom_weapon := {"id": "smoke_single", "name": "single", "attack_type": "projectile",
		"cd": 0.5, "dmg": 1.0, "bspeed": 300.0, "pellets": 1}
	if not Registry.register_weapon(custom_weapon):
		_fail("Registry 拒绝了合法自定义弹丸武器")
		return
	var oversized_weapon: Dictionary = custom_weapon.duplicate(true)
	oversized_weapon["id"] = "smoke_oversized"
	oversized_weapon["splash"] = 1.0e12
	if Registry.register_weapon(oversized_weapon):
		_fail("Registry 接受了可阻塞空间查询的超大武器范围")
		return
	var bullets_before := get_tree().get_nodes_in_group("player_bullets").size()
	p2.try_fire({"type": "smoke_single", "cd": 0.0})
	var bullets_after := get_tree().get_nodes_in_group("player_bullets").size()
	if bullets_after != bullets_before + 1:
		_fail("自定义单发武器未生成恰好一颗弹丸")
		return
	Registry.reload_content()
	# 精确整数校验 + 单档布局的两条兼容路径（S4.5 §10.1）：
	#   ① v1 单槽档**原地**就是唯一档（零搬迁）　② 旧三槽布局合并取 `saved_at` 最新的一份
	if not SaveRun.save(4, p2):
		_fail("v1 迁移测试准备存档失败")
		return
	var source_file := FileAccess.open(SaveRun.slot_path(1), FileAccess.READ)
	var source_json := JSON.new()
	if source_file == null or source_json.parse(source_file.get_as_text()) != OK:
		_fail("无法读取迁移测试源存档")
		return
	source_file.close()
	var legacy_data: Dictionary = source_json.data
	# ⚠️ 时间炸弹修复（2026-09-17 踩到）：`legacy_data` 来自**真实** `SaveRun.save()`，
	#    所以它的 `saved_at` 是**当下墙钟**；而 `_migrate_old_layout` 只在
	#    `唯一档.saved_at < 候选.saved_at` 时才覆盖（save_run.gd:506）。
	#    原写法把三个候选档的日期写死成 2026-09-14/15/16 —— 一旦真实时间越过它们，
	#    唯一档就永远"最新"、合并永不发生，断言必红，而病因看着像迁移逻辑坏了。
	#    → 改为**相对当下**的偏移：谁更新由偏移量决定，与日历无关。
	var mig_sec := 86400
	var mig_now := int(Time.get_unix_time_from_system())
	legacy_data["saved_at"] = Time.get_datetime_string_from_unix_time(
			mig_now - 30 * mig_sec, false)   # 唯一档刻意比所有候选都旧
	SaveRun.clear()
	legacy_data["run"]["wave"] = 4.5
	var fractional := FileAccess.open(SaveRun.slot_path(1), FileAccess.WRITE)
	fractional.store_string(JSON.stringify(legacy_data))
	fractional.close()
	if SaveRun.restore(p2) != 0:
		_fail("小数波次绕过了精确整数校验")
		return
	SaveRun.clear()
	# ① v1 老档（单槽文件名 `save_run.json` 就是新唯一档名）→ **原地即唯一档**，零搬迁；
	#    缺 `checkpoint` 键时读出即 `shop`（v1 的语义本来就是「恢复到商店」）
	legacy_data["version"] = 1
	legacy_data.erase("checkpoint")
	legacy_data["run"]["wave"] = 4
	var v1_file := FileAccess.open(SaveRun.slot_path(1), FileAccess.WRITE)
	v1_file.store_string(JSON.stringify(legacy_data))
	v1_file.close()
	SaveRun.migrate_legacy_if_needed(true)   # 单档布局下必须是 no-op
	if SaveRun.restore(p2) != 4 or SaveRun.restored_checkpoint != SaveRun.CHECKPOINT_SHOP:
		_fail("v1 单槽档未被当作唯一档直接读出（cp=%s）" % SaveRun.restored_checkpoint)
		return
	# ② 旧三槽布局 → 唯一档：取 `saved_at` 最新的一份，被吞并的旧文件删除，数据不丢（§13-28）
	# 槽 2（now−10 天）是三个候选里最新的 → 应胜出（W7）。相对偏移，不用绝对日期。
	var slot_waves := [3, 7, 5]
	var slot_times := [
		Time.get_datetime_string_from_unix_time(mig_now - 20 * mig_sec, false),
		Time.get_datetime_string_from_unix_time(mig_now - 10 * mig_sec, false),
		Time.get_datetime_string_from_unix_time(mig_now - 15 * mig_sec, false),
	]
	for mig_i in range(3):
		var mig_slot_data: Dictionary = legacy_data.duplicate(true)
		mig_slot_data["version"] = 2
		mig_slot_data["checkpoint"] = SaveRun.CHECKPOINT_SHOP
		mig_slot_data["saved_at"] = String(slot_times[mig_i])
		mig_slot_data["run"]["wave"] = int(slot_waves[mig_i])
		var mig_file := FileAccess.open(
			TEST_SAVE_ROOT.path_join("save_slot_%d.json" % (mig_i + 1)), FileAccess.WRITE)
		mig_file.store_string(JSON.stringify(mig_slot_data))
		mig_file.close()
	SaveRun.migrate_legacy_if_needed(true)
	var mig_wave := SaveRun.restore(p2)
	if mig_wave != 7:
		_fail("旧三槽合并未取 saved_at 最新的一份（期望槽 2 的 W7，实为 W%d）" % mig_wave)
		return
	for si2 in range(1, 4):
		if FileAccess.file_exists(TEST_SAVE_ROOT.path_join("save_slot_%d.json" % si2)):
			_fail("旧三槽文件 save_slot_%d.json 合并后未删除" % si2)
			return
	# 反向对照：比唯一档更旧的旧槽档**不得**顶掉唯一档（否则「新档被旧档覆盖」不会报错）
	var mig_stale: Dictionary = legacy_data.duplicate(true)
	mig_stale["version"] = 2
	mig_stale["checkpoint"] = SaveRun.CHECKPOINT_SHOP
	# 比唯一档（合并后 = now−10 天）更旧 → 不得顶掉
	mig_stale["saved_at"] = Time.get_datetime_string_from_unix_time(
			mig_now - 40 * mig_sec, false)
	mig_stale["run"]["wave"] = 19
	var mig_stale_file := FileAccess.open(TEST_SAVE_ROOT.path_join("save_slot_3.json"),
		FileAccess.WRITE)
	mig_stale_file.store_string(JSON.stringify(mig_stale))
	mig_stale_file.close()
	SaveRun.migrate_legacy_if_needed(true)
	var mig_stale_wave := SaveRun.restore(p2)
	if mig_stale_wave != 7 or FileAccess.file_exists(TEST_SAVE_ROOT.path_join("save_slot_3.json")):
		_fail("更旧的旧槽档顶掉了唯一档（恢复出 W%d）" % mig_stale_wave)
		return
	SaveRun.clear()
	# 新局选槽必须进入向导，且最终确认前不能清除已有槽。
	if not SaveRun.save(2, p2):
		_fail("主菜单回归测试准备存档失败")
		return
	var menu: Control = preload("res://scenes/ui/main_menu.tscn").instantiate()
	add_child(menu)
	await get_tree().process_frame
	# 图鉴：主菜单入口 + 五类百科（状态来源 / 武器 / 道具 / 升级 / 敌人）
	if menu._codex == null:
		_fail("主菜单未挂载图鉴")
		return
	menu._open_codex()
	if not menu._codex.visible or menu._home.visible:
		_fail("主菜单图鉴入口未打开")
		return
	menu._codex._select_tab("status")
	if menu._codex._list_btns.size() != Config.status_ids().size():
		_fail("图鉴状态数量不对（%d）" % menu._codex._list_btns.size())
		return
	# 统计/成就/toast：本局运行已累计击杀并达成 first_blood
	if CodexData.stat("kills") <= 0 or not CodexData.achievement_unlocked("first_blood"):
		_fail("统计/成就未随战斗累计（kills=%d）" % CodexData.stat("kills"))
		return
	if _main._toast_count <= 0:
		_fail("图鉴/成就解锁未弹出 toast")
		return
	# 成就奖励：新达成的成就按配置发放土豆精华（MetaProgress 全程隔离到测试路径）
	var essence_before: int = MetaProgress.essence
	CodexData.achievements.erase("boss_hunter")   # 保证本次必然触发一次新达成
	CodexData._rewarded.erase("boss_hunter")
	var unlocked_before := {}
	for aid in CodexData.achievements:
		unlocked_before[aid] = true
	CodexData.add_stat("boss_kills", 1)
	var reward_sum := 0
	for aid in CodexData.achievements:
		if not unlocked_before.has(aid):
			reward_sum += CodexData.achievement_reward(String(aid))
	if reward_sum < CodexData.achievement_reward("boss_hunter") \
			or MetaProgress.essence != essence_before + reward_sum:
		_fail("成就奖励精华发放错误（+%d，应为 +%d）"
			% [MetaProgress.essence - essence_before, reward_sum])
		return
	MetaProgress.grant_essence(7)
	if MetaProgress.essence != essence_before + reward_sum + 7:
		_fail("grant_essence 直接发放失败")
		return
	# 幂等：重复补判不会重复发奖
	CodexData._check_achievements()
	if MetaProgress.essence != essence_before + reward_sum + 7:
		_fail("重复补判重复发放了成就奖励")
		return
	# 未解锁灰态 / 筛选 / 搜索：从全锁状态开始验证
	CodexData.reset_for_tests()
	menu._codex._select_tab("status")
	if menu._codex._count_label.text.find("已解锁 0/") != 0:
		_fail("图鉴初始解锁计数不对（%s）" % menu._codex._count_label.text)
		return
	menu._codex._select_entry("burn")
	if _node_text(menu._codex._detail).find("尚未解锁") < 0 \
			or _node_text(menu._codex._detail).find("解锁奖励") < 0:
		_fail("未解锁条目未显示灰态占位/解锁奖励")
		return
	menu._codex._set_filter("locked")
	if menu._codex._list_btns.size() != Config.status_ids().size():
		_fail("图鉴未解锁筛选数量不对（%d）" % menu._codex._list_btns.size())
		return
	menu._codex._set_filter("unlocked")
	if not menu._codex._list_btns.is_empty():
		_fail("全锁状态下已解锁筛选应为空")
		return
	menu._codex._set_filter("all")
	menu._codex._select_tab("weapon")
	# ⚠️ S2：原先搜「手枪」命中 `pistol`（已迁入工坊包）。改搜内置武器的名字。
	#
	# ⚠️ 2026-09-17 S8 二改：S8 补回进化形态后，「金剑」会**额外命中**进化体「庚金剑域」
	#    （名字里也含「金剑」）→ 写死「1 条 / 首条是 knife」必红。
	#    期望集改为**从被测数据算出**（名字含「金剑」的已注册武器），这样：
	#      · 以后再加进化体/工坊武器，只要名字含关键词就会自动进期望集，不会假红；
	#      · 它仍是真断言 —— `knife` 必须在期望集里，且若搜索失效会返回全表 33 条。
	menu._codex._on_search_changed("金剑")
	var kw_expect: Array = []
	for kwid in Registry.weapons:
		if String(Registry.weapons[kwid].get("name", "")).find("金剑") >= 0:
			kw_expect.append(String(kwid))
	if menu._codex._list_btns.size() != kw_expect.size() or not kw_expect.has("knife"):
		_fail("图鉴搜索未按名称过滤（%d 条，期望 %d 条：%s）"
			% [menu._codex._list_btns.size(), kw_expect.size(), ", ".join(kw_expect)])
		return
	# 反向对照：搜一个任何武器名都不含的词应为空 —— 否则上面那条是「搜索根本没生效」的假绿
	menu._codex._on_search_changed("绝不可能出现的武器名zzz")
	if not menu._codex._list_btns.is_empty():
		_fail("图鉴搜索命中了不存在的词（%d 条）" % menu._codex._list_btns.size())
		return
	menu._codex._on_search_changed("")
	# 图鉴解锁奖励：首次解锁发精华，重复解锁/重复补判都不重复发
	var unlock_ess_before: int = MetaProgress.essence
	CodexData.unlock("status", "burn")
	var unlock_gain := CodexData.unlock_reward("status")
	if unlock_gain <= 0 or MetaProgress.essence != unlock_ess_before + unlock_gain:
		_fail("图鉴解锁未发放精华（+%d）" % (MetaProgress.essence - unlock_ess_before))
		return
	CodexData.unlock("status", "burn")
	if MetaProgress.essence != unlock_ess_before + unlock_gain:
		_fail("重复解锁重复发放图鉴精华")
		return
	CodexData._check_unlock_rewards()
	if MetaProgress.essence != unlock_ess_before + unlock_gain:
		_fail("图鉴奖励补判重复发放")
		return
	# 解锁后续详情断言所需条目（模拟局内已接触）
	#
	# ⚠️ S2：`pistol` 已迁入工坊包 → 改用开局的兜底武器（`Config.FALLBACK_WEAPON`）。
	#    这样即使哪天再换默认武器，也只需改 `Config` 一处。
	for sid in Config.STATUS:
		CodexData.unlock("status", String(sid))
	CodexData.unlock("weapon", Config.FALLBACK_WEAPON)
	CodexData.unlock("item", "i-ember")
	CodexData.unlock("enemy", "grunt")
	CodexData.unlock("enemy", "boss")
	menu._codex._select_tab("status")
	var burn_src: Dictionary = Registry.status_sources("burn")
	var burn_wids: Array = []
	for w in burn_src.get("weapons", []):
		burn_wids.append(String(w.get("id", "")))
	# ⚠️ S2：原断言要求 burn 来源里有 `flamethrower` + `rocket`。`rocket`（火箭筒）已迁入
	#    工坊包 → 内置侧只剩 `flamethrower` 一把。改为断言「内置武器里 burn 来源恰好是
	#    flamethrower」，再单独处理工坊包那部分（存在就一并列出，不存在不报错）。
	if not burn_wids.has("flamethrower"):
		_fail("图鉴燃烧武器来源缺失内置喷火枪（%s）" % str(burn_wids))
		return
	for wid_b in Config.LOADOUT_WEAPONS:
		var st_b := String(Registry.weapons[String(wid_b)].get("status", ""))
		if (st_b == "burn") != (String(wid_b) == "flamethrower"):
			_fail("内置武器 %s 的 burn 归属与预期不符（status=%s）" % [String(wid_b), st_b])
			return
	if Registry.weapons.has("rocket") and not burn_wids.has("rocket"):
		_fail("工坊包已加载但 rocket 未出现在 burn 来源里（%s）" % str(burn_wids))
		return
	var burn_iids: Array = []
	for it in burn_src.get("items", []):
		burn_iids.append(String(it.get("id", "")))
	if not burn_iids.has("i-ember"):
		_fail("图鉴燃烧道具来源缺失 i-ember（%s）" % str(burn_iids))
		return
	var freeze_src: Dictionary = Registry.status_sources("freeze")
	var fz_wids: Array = []
	for w in freeze_src.get("weapons", []):
		fz_wids.append(String(w.get("id", "")))
	# ⚠️ S2：原断言写「freeze 来源必须含 frost_staff」—— 那是按旧 `frost_staff` 的
	#    status 写的。S2-a 把水枪的 status 定为 **slow**（水系＝减速，冻结留给法宝/反应），
	#    所以它在 `slow` 来源里、不在 `freeze` 来源里。
	#    → 改为**按每把内置武器的实际 status 推导期望**：这才是本断言真正要守的东西
	#      （「来源筛选按 status 精确匹配，不串味」），且换武器/改 status 都不会误报。
	for wid_f in Config.LOADOUT_WEAPONS:
		var w_f: Dictionary = Registry.weapons[String(wid_f)]
		var st_f := String(w_f.get("status", ""))
		if st_f == "":
			continue   # 无状态武器（木弓）不该出现在任何状态来源里
		var src_f: Dictionary = Registry.status_sources(st_f)
		var ids_f: Array = []
		for wf in src_f.get("weapons", []):
			ids_f.append(String(wf.get("id", "")))
		if not ids_f.has(String(wid_f)):
			_fail("内置武器 %s 未出现在其状态 %s 的来源里（%s）" % [String(wid_f), st_f, str(ids_f)])
			return
	# 反向：无状态武器不得出现在任何状态来源里（防"配漏 status 被当成默认状态"）
	for sid_f in Config.STATUS:
		var src_all: Dictionary = Registry.status_sources(String(sid_f))
		for wf2 in src_all.get("weapons", []):
			if String(wf2.get("id", "")) == "blight_bow":
				_fail("无状态武器 blight_bow 出现在 %s 来源里" % String(sid_f))
				return
	# 筛选不串味：burn 来源里不得出现非 burn 武器
	if fz_wids.has("flamethrower") or burn_wids.has("frost_staff"):
		_fail("状态来源筛选串味（burn=%s freeze=%s）" % [str(burn_wids), str(fz_wids)])
		return
	if Registry.status_sources("stun").get("items", []).is_empty():
		_fail("图鉴眩晕道具来源缺失（雷击石）")
		return
	for b in menu._codex._list_btns:
		menu._codex._select_entry(String(b.get_meta("id")))
		if menu._codex._detail.get_child_count() < 6:
			_fail("图鉴状态详情内容不足（%s）" % String(b.get_meta("id")))
			return
	# 武器页：数量对齐注册表，详情含基础伤害 + 进化
	menu._codex._select_tab("weapon")
	if menu._codex._list_btns.size() != Registry.weapons.size():
		_fail("图鉴武器数量不对（%d/%d）" % [menu._codex._list_btns.size(), Registry.weapons.size()])
		return
	# ⚠️ S2：`pistol` 已迁入工坊包 → 改用开局兜底武器。
	#    另注意「进化」段：S2 时进化树被清空，S8（2026-09-17）**已补回** ——
	#    兜底武器 knife 现在有 `evolve_need: 3` + 单分支，详情里**该**有「进化」段。
	#    断言写成「基础伤害必在」+「进化段**按配置条件**出现」而不是写死有无，
	#    正是为了扛住这种来回：写死"必有"会在 S2~S8 之间一直红，写死"没有"会在 S8 后失效。
	menu._codex._select_entry(Config.FALLBACK_WEAPON)
	var wtext := _node_text(menu._codex._detail)
	var fb: Dictionary = Registry.weapons[Config.FALLBACK_WEAPON]
	if wtext.find("基础伤害") < 0:
		# ⚠️ 失败信息别用 substr 截断：关键字段往往在截断点之后，
		#    报错里看不到反而会误导排查方向。这里给长度 + 命中情况。
		_fail("图鉴武器详情缺「基础伤害」字段（全文 %d 字）" % wtext.length())
		return
	var fb_has_evo := int(fb.get("evolve_need", 0)) > 0 \
		and not (fb.get("evolve_branches", []) as Array).is_empty()
	if fb_has_evo != (wtext.find("进化") >= 0):
		_fail("图鉴详情「进化」段与武器配置不一致（配置 %s / 详情 %s）"
			% ["有" if fb_has_evo else "无", "有" if wtext.find("进化") >= 0 else "无"])
		return
	if menu._codex._page_tween == null or not menu._codex._page_tween.is_valid():
		_fail("图鉴详情未创建翻页 Tween")
		return
	# 条件轮询而非固定 sleep：翻页 tween 只有 0.16s，headless 下帧间隔抖动会让
	# 「等 0.24s 再断言」偶发地在 tween 跑完前就检查，造成跑一次过、跑两次挂的假失败。
	# 改为「tween 不再 running 就立即继续」，2s 上限内还没停才算真失败。
	var anim_waited := 0.0
	while anim_waited < 2.0:
		var tw: Tween = menu._codex._page_tween
		if tw == null or not tw.is_valid() or not tw.is_running():
			break
		await get_tree().create_timer(0.02).timeout
		anim_waited += 0.02
	if absf(menu._codex._detail.modulate.a - 1.0) > 0.01 \
			or menu._codex._detail.scale != Vector2.ONE \
			or absf(menu._codex._detail.rotation) > 0.0001:
		_fail("图鉴翻页动画未恢复最终状态（a=%.3f scale=%s rot=%.5f waited=%.2f running=%s）"
			% [menu._codex._detail.modulate.a, str(menu._codex._detail.scale),
			menu._codex._detail.rotation, anim_waited,
			str(menu._codex._page_tween != null and menu._codex._page_tween.is_valid()
				and menu._codex._page_tween.is_running())])
		return
	# 道具页 / 升级页：数量对齐注册表，道具显示关联状态
	menu._codex._select_tab("item")
	if menu._codex._list_btns.size() != Registry.items.size():
		_fail("图鉴道具数量不对（%d/%d）" % [menu._codex._list_btns.size(), Registry.items.size()])
		return
	menu._codex._select_entry("i-ember")
	if _node_text(menu._codex._detail).find("关联状态") < 0:
		_fail("图鉴道具详情未显示关联状态")
		return
	menu._codex._select_tab("upgrade")
	if menu._codex._list_btns.size() != Registry.upgrades.size():
		_fail("图鉴升级数量不对（%d/%d）" % [menu._codex._list_btns.size(), Registry.upgrades.size()])
		return
	# 敌人页：追击者出现在第 1 波，BOSS 标注轮换池
	menu._codex._select_tab("enemy")
	if menu._codex._list_btns.size() != Registry.enemies.size():
		_fail("图鉴敌人数量不对（%d/%d）" % [menu._codex._list_btns.size(), Registry.enemies.size()])
		return
	menu._codex._select_entry("grunt")
	var etext := _node_text(menu._codex._detail)
	if etext.find("出现波次") < 0 or etext.find("第 1") < 0:
		_fail("图鉴敌人详情缺出现波次（%s）" % etext.substr(0, 60))
		return
	menu._codex._select_entry("boss")
	if _node_text(menu._codex._detail).find("BOSS") < 0:
		_fail("图鉴 BOSS 详情未标注")
		return
	# 成就页：统计总览 + 成就进度 + 达成筛选（kills=100 → first_blood/slayer_100，best_wave=6 → survivor_5）
	var toast_before: int = _main._toast_count
	CodexData.add_stat("kills", 100)
	CodexData.set_stat_max("best_wave", 6)
	if not CodexData.achievement_unlocked("slayer_100") \
			or not CodexData.achievement_unlocked("survivor_5"):
		_fail("成就未按统计阈值达成")
		return
	if _main._toast_count <= toast_before:
		_fail("成就达成未弹出 toast")
		return
	menu._codex._select_tab("achieve")
	if menu._codex._list_btns.size() != CodexData.ACHIEVEMENTS.size() + 1:
		_fail("成就页条目数量不对（%d）" % menu._codex._list_btns.size())
		return
	if menu._codex._achieve_bar == null or not menu._codex._achieve_bar.visible:
		_fail("成就页未显示完成度进度条")
		return
	if int(menu._codex._achieve_bar.max_value) != CodexData.ACHIEVEMENTS.size() \
			or int(menu._codex._achieve_bar.value) != CodexData.unlocked_achievement_count():
		_fail("成就完成度进度条数值不对（%d/%d）"
			% [int(menu._codex._achieve_bar.value), int(menu._codex._achieve_bar.max_value)])
		return
	menu._codex._select_entry("_stats")
	var stats_text := _node_text(menu._codex._detail)
	if stats_text.find("累计击杀") < 0 or stats_text.find("成就奖励") < 0 \
			or stats_text.find("图鉴奖励") < 0:
		_fail("统计总览缺少累计击杀/成就奖励/图鉴奖励")
		return
	if stats_text.find("完成度") < 0 or stats_text.find("下一目标") < 0:
		_fail("统计总览缺少完成度/下一目标图表")
		return
	var next_ach: String = menu._codex._next_achievement_id()
	if next_ach == "" or not CodexData.ACHIEVEMENTS.has(next_ach) \
			or CodexData.achievement_unlocked(next_ach):
		_fail("下一目标成就计算错误（%s）" % next_ach)
		return
	menu._codex._select_entry("first_blood")
	var ach_text := _node_text(menu._codex._detail)
	if ach_text.find("已达成") < 0 or ach_text.find("精华") < 0:
		_fail("已达成成就未显示达成态/奖励")
		return
	menu._codex._set_filter("unlocked")
	if menu._codex._list_btns.size() < 2:
		_fail("成就页已达成筛选数量不对（%d）" % menu._codex._list_btns.size())
		return
	menu._codex._set_filter("all")
	menu._codex._select_tab("status")
	if menu._codex._achieve_bar.visible:
		_fail("非成就页未隐藏完成度进度条")
		return
	menu._codex._close()
	if menu._codex.visible or not menu._home.visible:
		_fail("图鉴关闭后主菜单未恢复")
		return
	print("SMOKE: codex OK")
	# 开发者面板状态速览：平台后端 / 待上报 / 图鉴 / 成就计数
	var dev: Control = _main.get_node("UI/DevPanel")
	dev._refresh_status()
	if dev._status_label == null or dev._status_label.text.find("平台成就") < 0 \
			or dev._status_label.text.find("图鉴") < 0 \
			or dev._status_label.text.find("成就") < 0:
		_fail("开发者面板状态速览缺失")
		return
	print("SMOKE: dev panel status OK")
	# S4.5 §10.2：向导 3 步；「开始游戏」**直接**进向导（不再有选槽弹窗），且不提前清旧档
	if menu.TOTAL_STEPS != 3 or String(menu.STEP_TITLES[2]) != "选择难度":
		_fail("向导应为 3 步且第 3 步是「选择难度」（实为 %d 步 / '%s'）"
			% [menu.TOTAL_STEPS, menu.STEP_TITLES[2]])
		return
	if not SaveRun.exists(1):
		_fail("主菜单回归测试的准备档不见了")
		return
	menu._open_wizard(false)
	await get_tree().process_frame
	if not menu._wizard.visible or not SaveRun.exists(1):
		_fail("「开始游戏」未直接进入向导，或提前清除了旧档")
		return
	# 首页入口清单：模式步移出向导后，「无尽炼狱」必须在首页；
	# 「每日挑战」**必须不在**（§3.2.5 整体冻结，守门断言 50b）
	var home_titles: Array = []
	for sp in menu._home_specs():
		home_titles.append(String(sp[0]))
	if not home_titles.has("开 始 游 戏") or not home_titles.has("无 尽 炼 狱"):
		_fail("首页缺少 开始游戏 / 无尽炼狱 入口（%s）" % str(home_titles))
		return
	if home_titles.has("每 日 挑 战"):
		_fail("每日挑战入口应已冻结摘除（%s）" % str(home_titles))
		return
	# 角色选择卡：每张卡内含程序化专属头像（CharacterAvatar）
	# ⚠️ 期望值**取自被测数据**（当前 Registry.characters 的规模），不写死数字：
	# 内置池只有 6 人（工坊包已移出 mods/），写死 7 会红得像「头像丢了」，其实是内容池缩了。
	# 三向对照：卡片数 == 头像数 == 角色数，任意一项掉队都算失败；空池另判（防 0==0 假绿）
	var char_total: int = Registry.characters.size()
	if char_total <= 0:
		_fail("角色池为空，无法校验角色卡头像")
		return
	var avatar_cnt := 0
	for card in menu._options.get_children():
		for box_child in card.get_child(0).get_children():
			if box_child is CharacterAvatar:
				avatar_cnt += 1
	var card_cnt: int = menu._options.get_child_count()
	if card_cnt != char_total or avatar_cnt != char_total:
		_fail("角色卡 / 头像 / 角色数不齐（卡 %d / 头像 %d / 角色 %d）" % [card_cnt, avatar_cnt, char_total])
		return
	# 向导各步排版：网格必须横向铺满面板（最小分辨率下不留大块空白），
	# 且卡片尺寸落在合理区间 —— 防「固定列数导致内容少时四周留白」回归
	for st in range(menu.TOTAL_STEPS):
		menu._step = st
		menu._build_step()
		await get_tree().process_frame
		var cards: int = menu._options.get_child_count()
		if cards <= 0:
			_fail("向导第 %d 步无任何选项卡" % (st + 1))
			return
		var card_w: float = menu._options.get_child(0).custom_minimum_size.x
		var cols: int = menu._options.columns
		var rows: int = int(ceil(float(cards) / float(cols)))
		var used_w: float = float(cols) * card_w + float(cols - 1) * 10.0
		# 允许少许余量（面板内边距 / 滚动条），但填不满 85% 就是明显的横向留白
		if used_w < menu.WIZARD_W * 0.85:
			_fail("向导第 %d 步横向留白过大（%d 列 ×%.0f = %.0f / %.0f，共 %d 张）" % [
				st + 1, cols, card_w, used_w, menu.WIZARD_W, cards])
			return
		if card_w < menu.CARD_W_MIN - 0.5 or card_w > menu.CARD_W_MAX + 0.5:
			_fail("向导第 %d 步卡片宽度越界（%.1f）" % [st + 1, card_w])
			return
		var card_h: float = menu._options.get_child(0).custom_minimum_size.y
		if card_h < menu.CARD_H_MIN - 0.5 or card_h > menu.CARD_H_MAX + 0.5:
			_fail("向导第 %d 步卡片高度越界（%.1f）" % [st + 1, card_h])
			return
		# 每步都应挑到「空槽最少」的列数：末行残缺不得超过一整行
		if cols * rows - cards >= cols:
			_fail("向导第 %d 步列数选择不佳（%d 列 %d 行装 %d 张，空 %d 槽）" % [
				st + 1, cols, rows, cards, cols * rows - cards])
			return
	menu._step = 0
	menu._build_step()
	await get_tree().process_frame
	var accept := InputEventAction.new()
	accept.action = "ui_accept"
	accept.pressed = true
	menu._unhandled_input(accept)
	if menu._step != 1:
		_fail("手柄确认已选中的默认向导卡未进入下一步")
		return
	# ---- S4.5 难度解锁（§9.4 / 守门断言 27）----
	# ⚠️ 先把本角色的通关记录摘掉再改写：`clear_*` 会被前面的**通关结算用例**跨用例改写，
	#    不摘的话「未通关时困难应灰化」会随运行历史间歇性变红 ——
	#    期望值一旦依赖「本局之前发生过什么」，就必须在断言里把它消掉。
	var dl_char := "potato"
	var dl_prev := CodexData.stat("clear_" + dl_char)
	var dl_step := func() -> void:
		menu._sel_char = dl_char
		menu._step = 2
		menu._build_step()
	var dl_cards := func() -> Dictionary:
		var out := {}
		for dl_node in menu._options.get_children():
			out[String(dl_node.get_meta("id"))] = dl_node
		return out
	CodexData.stats["clear_" + dl_char] = 0
	menu._sel_diff = "nightmare"      # 故意选一个未解锁档，顺便验证会被夹回
	dl_step.call()
	await get_tree().process_frame
	var dl_cards_none: Dictionary = dl_cards.call()
	if not dl_cards_none.has("normal") or not dl_cards_none.has("hard") \
			or not dl_cards_none.has("nightmare"):
		_fail("难度步缺卡（%s）" % str(dl_cards_none.keys()))
		return
	if dl_cards_none["normal"].disabled or not dl_cards_none["normal"].button_pressed:
		_fail("未通关时简单档应可选、并被夹回选中态")
		return
	if not dl_cards_none["hard"].disabled or not dl_cards_none["nightmare"].disabled:
		_fail("未通关时困难/噩梦档应灰化")
		return
	if String(menu._sel_diff) != "normal":
		_fail("未通关时 _sel_diff 未夹回简单档（%s）" % menu._sel_diff)
		return
	CodexData.stats["clear_" + dl_char] = 1
	dl_step.call()
	await get_tree().process_frame
	var dl_cards_hard: Dictionary = dl_cards.call()
	if dl_cards_hard["normal"].disabled or dl_cards_hard["hard"].disabled:
		_fail("通关简单后 简单/困难 都应可选")
		return
	if not dl_cards_hard["nightmare"].disabled:
		_fail("只通关简单时噩梦档应仍锁定")
		return
	CodexData.stats["clear_" + dl_char] = 3
	dl_step.call()
	await get_tree().process_frame
	var dl_cards_all: Dictionary = dl_cards.call()
	if dl_cards_all["normal"].disabled or dl_cards_all["hard"].disabled \
			or dl_cards_all["nightmare"].disabled:
		_fail("通关噩梦后三档应全开")
		return
	# 角色卡追加「已通关最高难度 N」（§10.2）：未通关**不出现**该行
	CodexData.stats["clear_" + dl_char] = 0
	var dl_desc_none: String = menu._character_card_desc(Registry.get_character(dl_char))
	CodexData.stats["clear_" + dl_char] = 2
	var dl_desc_hard: String = menu._character_card_desc(Registry.get_character(dl_char))
	CodexData.stats["clear_" + dl_char] = dl_prev      # 还原现场
	if dl_desc_none.find("已通关") >= 0:
		_fail("未通关角色卡不应出现已通关标记")
		return
	if dl_desc_hard.find("已通关") < 0 or dl_desc_hard.find("困难") < 0:
		_fail("角色卡未显示最高通关难度（%s）" % dl_desc_hard.replace("\n", " / "))
		return
	menu.queue_free()
	print("SMOKE: save isolation + contracts + menu wizard OK")
	_check_run_rules()
	# 无论断言是否失败都要还原规则状态：_check_run_rules 会打开自定义规则并把
	# 波次总数改成 18，留着会污染后续 BOSS 波 / 无尽用例（曾因此出现假失败）
	_restore_run_rules()
	_check_shop_diminishing()
	if _failed:
		return
	await _check_endless()
	if _failed:
		return   # 协程内已 _fail（quit(1) 已排队），不再覆盖退出码
	_cleanup_test_storage(true)
	print("SMOKE: PASS")
	get_tree().quit(0)

## 规则用例的现场（active/values 备份），由 _check_run_rules 写入、_restore 读取
var _rules_ctx: Dictionary = {}

## 还原 RunRules 到用例前的状态，并清掉测试注入的合成难度条目
func _restore_run_rules() -> void:
	if _rules_ctx.is_empty():
		return
	Registry.difficulties.erase(RunRules.CUSTOM_DIFF_ID)
	RunRules.active = bool(_rules_ctx.get("active", false))
	RunRules.values = (_rules_ctx.get("values", {}) as Dictionary).duplicate(true)
	_rules_ctx = {}

## 自定义开局规则：挑战码往返 / clamp 边界 / 合成难度条目 / 存档往返 / 消费点生效
func _check_run_rules() -> void:
	# 现场备份交给调用方（_restore_run_rules）还原 —— 本函数中途 _fail 会 return，
	# 把还原放在函数末尾会漏执行，从而污染后续用例
	_rules_ctx = { "active": RunRules.active, "values": RunRules.values.duplicate(true) }
	# 1) 挑战码往返：改一批参数 → encode → decode 必须回到同一组值
	RunRules.active = true
	RunRules.base_difficulty_id = "hard"
	RunRules.reset_to_defaults()
	RunRules.set_value("enemy_hp", 1.7)
	RunRules.set_value("enemy_dmg", 2.2)
	RunRules.set_value("waves", 16)
	RunRules.set_value("weapon_slots", 8)
	RunRules.set_value("no_reroll", 1)
	var code := RunRules.encode()
	if not code.begins_with("BTL2-"):
		_fail("挑战码前缀错误：" + code)
		return
	RunRules.reset_to_defaults()
	RunRules.active = false
	RunRules.base_difficulty_id = "normal"
	if not RunRules.decode(code):
		_fail("挑战码解码失败：" + code)
		return
	# 基准难度必须随码往返 —— 否则分享出去会从「困难 + 规则」变成「普通 + 规则」
	if RunRules.base_difficulty_id != "hard":
		_fail("挑战码未携带基准难度（期望 hard，实际 %s）" % RunRules.base_difficulty_id)
		return
	for key in ["enemy_hp", "enemy_dmg", "waves", "weapon_slots", "no_reroll"]:
		var want: float = RunRules.clamp_value(key, RunRules.get_value(key))
		if not is_equal_approx(RunRules.get_value(key), want):
			_fail("挑战码往返后参数漂移：" + key)
			return
	if not is_equal_approx(RunRules.get_value("enemy_hp"), 1.7) \
			or not is_equal_approx(RunRules.get_value("enemy_dmg"), 2.2) \
			or RunRules.get_int("waves") != 16 \
			or RunRules.get_int("weapon_slots") != 8 \
			or not RunRules.get_bool("no_reroll"):
		_fail("挑战码往返数值不一致（hp=%.2f dmg=%.2f waves=%d slots=%d）" % [
			RunRules.get_value("enemy_hp"), RunRules.get_value("enemy_dmg"),
			RunRules.get_int("waves"), RunRules.get_int("weapon_slots")])
		return
	# 2) 非法码永不崩溃、且不改动现有参数
	var hp_before := RunRules.get_value("enemy_hp")
	for bad in ["", "BTL1", "BTL2", "BTL1-1|2", "XXXX-1|2|3|4|5|6|7|8|9|10|11",
			"BTL2-a|b|c", "BTL1-a|b|c"]:
		if RunRules.decode(String(bad)):
			_fail("非法挑战码被误判为有效：" + String(bad))
			return
	if not is_equal_approx(RunRules.get_value("enemy_hp"), hp_before):
		_fail("非法挑战码解码后污染了现有参数")
		return
	# 2b) v1 旧码仍可解析（基准按 normal），保证已分享出去的码不作废
	RunRules.base_difficulty_id = "nightmare"
	if not RunRules.decode("BTL1-0|0|1|0|10|0|6|0|0|0|0"):
		_fail("v1 旧挑战码不再可解析（向后兼容被破坏）")
		return
	if RunRules.base_difficulty_id != "normal":
		_fail("v1 旧码的基准难度应为 normal（实际 %s）" % RunRules.base_difficulty_id)
		return
	# 3) clamp 边界：越界值被夹进区间，且按 step 对齐
	RunRules.set_value("enemy_hp", 99.0)
	if not is_equal_approx(RunRules.get_value("enemy_hp"), 3.0):
		_fail("enemy_hp 未 clamp 到上限 3.0（实际 %.3f）" % RunRules.get_value("enemy_hp"))
		return
	RunRules.set_value("enemy_hp", -5.0)
	if not is_equal_approx(RunRules.get_value("enemy_hp"), 0.5):
		_fail("enemy_hp 未 clamp 到下限 0.5")
		return
	RunRules.set_value("waves", 1.0)
	if RunRules.get_int("waves") != 5:
		_fail("waves 未 clamp 到下限 5")
		return
	# 4) 合成难度条目：字段完整 + 与规则值一致 + 无浮点尾差
	# 最终值 = 基准值 × 规则值（与 4b 同口径）。⚠️ 第 14 轮起 normal 曾把 dmg_mult 砍到 0.9
	# （第 15 轮又回调到 1.0），**基准难度不保证是"四维全 1.0 的恒等基准"**，
	# 所以这里**不能**写死 1.3 —— 一律按基准继承校验。
	RunRules.base_difficulty_id = "normal"
	RunRules.set_value("enemy_hp", 1.8)
	RunRules.set_value("enemy_dmg", 1.3)
	RunRules.set_value("spawn_density", 1.6)
	RunRules.set_value("elite_chance", 0.25)
	var injected := RunRules.inject_difficulty()
	var nrm_base := Registry.get_difficulty("normal")
	for field in ["id", "name", "hp_mult", "dmg_mult", "spawn_mult", "elite_chance"]:
		if not injected.has(field):
			_fail("合成难度条目缺字段：" + field)
			return
	if String(injected.id) != RunRules.CUSTOM_DIFF_ID \
			or not is_equal_approx(float(injected.hp_mult), float(nrm_base.hp_mult) * 1.8) \
			or not is_equal_approx(float(injected.dmg_mult), float(nrm_base.dmg_mult) * 1.3) \
			or not is_equal_approx(float(injected.spawn_mult), float(nrm_base.spawn_mult) * 1.6) \
			or not is_equal_approx(float(injected.elite_chance), float(nrm_base.elite_chance) + 0.25):
		_fail("合成难度条目数值与规则不一致（基准 normal 时应等于 基准值×规则值）")
		return
	# 4b) **方案 A 核心：基准难度继承 + 倍率叠乘**
	# 噩梦 hp 2.2 / dmg 1.6 / spawn 1.5 / elite 0.20；规则倍率 1.8 / 1.3 / 1.6 / +0.25
	# 期望：血 2.2*1.8=3.96 · 伤 1.6*1.3=2.08 · 密度 1.5*1.6=2.4 · 精英 0.20+0.25=0.45
	RunRules.base_difficulty_id = "nightmare"
	var nm := RunRules.inject_difficulty()
	var nm_base := Registry.get_difficulty("nightmare")
	if not is_equal_approx(float(nm.hp_mult),
			float(nm_base.hp_mult) * RunRules.get_value("enemy_hp")) \
			or not is_equal_approx(float(nm.dmg_mult),
				float(nm_base.dmg_mult) * RunRules.get_value("enemy_dmg")) \
			or not is_equal_approx(float(nm.spawn_mult),
				float(nm_base.spawn_mult) * RunRules.get_value("spawn_density")) \
			or not is_equal_approx(float(nm.elite_chance),
				clampf(float(nm_base.elite_chance) + RunRules.get_value("elite_chance"), 0.0, 1.0)):
		_fail("方案 A 基准继承失败（噩梦 hp=%.3f 应=%.3f · dmg=%.3f 应=%.3f）" % [
			float(nm.hp_mult), float(nm_base.hp_mult) * RunRules.get_value("enemy_hp"),
			float(nm.dmg_mult), float(nm_base.dmg_mult) * RunRules.get_value("enemy_dmg")])
		return
	# 噩梦基准 + 规则全默认 → 必须等于噩梦本身（而不是普通）。这正是修掉的旧缺陷：
	# 旧实现无论选什么难度都从 1.0 起算，选噩梦却只调了个波次就会被静默降级成普通
	var backup_waves := RunRules.get_value("waves")
	RunRules.reset_to_defaults()
	RunRules.set_value("waves", 12)   # 只动节奏，不碰难度组
	RunRules.base_difficulty_id = "nightmare"
	var pure := RunRules.inject_difficulty()
	if not is_equal_approx(float(pure.hp_mult), float(nm_base.hp_mult)) \
			or not is_equal_approx(float(pure.dmg_mult), float(nm_base.dmg_mult)) \
			or not is_equal_approx(float(pure.spawn_mult), float(nm_base.spawn_mult)) \
			or not is_equal_approx(float(pure.elite_chance), float(nm_base.elite_chance)):
		_fail("规则只改节奏时未沿用基准难度（噩梦被降级：hp=%.2f 应=%.2f）" % [
			float(pure.hp_mult), float(nm_base.hp_mult)])
		return
	# 非内置基准 id → 安全回落 normal
	RunRules.base_difficulty_id = "not_a_real_difficulty"
	if String(RunRules.base_difficulty().get("id", "")) != "normal":
		_fail("非法基准难度未回落 normal")
		return
	RunRules.base_difficulty_id = "normal"
	RunRules.set_value("waves", backup_waves)
	RunRules.set_value("enemy_hp", 1.8)
	RunRules.set_value("enemy_dmg", 1.3)
	RunRules.set_value("spawn_density", 1.6)
	RunRules.set_value("elite_chance", 0.25)
	# 5) Registry 通道生效：enemy/wave_manager 读到的就是这套值
	# 显式重新注入 —— 上面 4b 最后一次注入用的是噩梦基准，不重注入会读到那次的条目
	RunRules.inject_difficulty()
	var via_registry := Registry.get_difficulty(RunRules.CUSTOM_DIFF_ID)
	if via_registry.is_empty() or not is_equal_approx(float(via_registry.hp_mult), float(nrm_base.hp_mult) * 1.8) \
			or not is_equal_approx(float(via_registry.dmg_mult), float(nrm_base.dmg_mult) * 1.3) \
			or not is_equal_approx(float(via_registry.spawn_mult), float(nrm_base.spawn_mult) * 1.6) \
			or not is_equal_approx(float(via_registry.elite_chance), float(nrm_base.elite_chance) + 0.25):
		_fail("Registry 未能读到自定义难度条目（难度系统未接通；hp=%.3f 应=%.3f）" % [
			float(via_registry.get("hp_mult", -1.0)), float(nrm_base.hp_mult) * 1.8])
		return
	# 6) apply_to_run：启用 → 返回 "custom" 且记录基准；关闭 → 原样返回内置 id
	RunRules.active = true   # 步骤 1 的往返测试把 active 关掉了，这里显式恢复
	if RunRules.apply_to_run("hard") != RunRules.CUSTOM_DIFF_ID:
		_fail("启用规则时 apply_to_run 未返回 custom")
		return
	if RunRules.base_difficulty_id != "hard":
		_fail("apply_to_run 未记录基准难度（实际 %s）" % RunRules.base_difficulty_id)
		return
	RunRules.active = false
	if RunRules.apply_to_run("hard") != "hard":
		_fail("未启用规则时 apply_to_run 篡改了难度 id")
		return
	# 未启用时也要记录基准：玩家可能在向导里选了噩梦但没开规则，
	# 若 base 停留旧值，之后开规则会继承到错误难度
	if RunRules.base_difficulty_id != "hard":
		_fail("未启用规则时基准难度未同步（实际 %s）" % RunRules.base_difficulty_id)
		return
	RunRules.active = true
	# 7) 消费点：波次总数 / 时长倍率 / 武器槽 / 材料 / 商店价 / 禁用项
	# no_reroll 显式归零：步骤 1 的挑战码里带着它，不重置会让下面的 reroll_disabled 断言误判
	RunRules.set_value("waves", 18)
	RunRules.set_value("wave_time", 1.5)
	RunRules.set_value("weapon_slots", 7)
	RunRules.set_value("materials", 2.0)
	RunRules.set_value("shop_price", 1.5)
	RunRules.set_value("no_heal", 1)
	RunRules.set_value("no_reroll", 0)
	if RunRules.wave_total(Config.WAVES_TOTAL) != 18 \
			or not is_equal_approx(RunRules.wave_duration_mult(), 1.5) \
			or RunRules.weapon_slots_total() != 7 + int(MetaProgress.effect_sum("slot")) \
			or not is_equal_approx(RunRules.materials_bonus(), 1.0) \
			or not is_equal_approx(RunRules.shop_price_mult(), 1.5) \
			or not RunRules.heal_disabled() or RunRules.reroll_disabled():
		_fail("规则消费点返回值不符合预期（waves=%d 时长=%.2f 槽=%d 材料=%.2f 价=%.2f 禁回血=%s 禁刷新=%s）" % [
			RunRules.wave_total(Config.WAVES_TOTAL), RunRules.wave_duration_mult(),
			RunRules.weapon_slots_total(), RunRules.materials_bonus(),
			RunRules.shop_price_mult(), str(RunRules.heal_disabled()),
			str(RunRules.reroll_disabled())])
		return
	# 8) BOSS 波跟随波次总数：18 波局的 BOSS 波 = 18，而非 10
	if not Config.is_boss_wave(18) or Config.is_boss_wave(10):
		_fail("自定义波次总数下 BOSS 波判定未跟随（18 波局应在第 18 波出 BOSS）")
		return
	# 9) 竞技性闸门：启用规则即失去排行资格
	if RunRules.is_competitive():
		_fail("启用自定义规则后仍被判定为可参与竞技")
		return
	RunRules.active = false
	if not RunRules.is_competitive():
		_fail("未启用规则时被误判为不可竞技")
		return
	# 10) 存档往返：to_save → apply_from_save 重建参数 + 基准难度，并重新注入难度条目
	RunRules.active = true
	RunRules.base_difficulty_id = "nightmare"
	RunRules.set_value("enemy_hp", 2.4)
	RunRules.set_value("waves", 22)
	var packed := RunRules.to_save()
	if String(packed.get("base", "")) != "nightmare":
		_fail("to_save 未把基准难度写进存档（base=%s）" % str(packed.get("base", "<缺失>")))
		return
	RunRules.active = false
	RunRules.reset_to_defaults()
	RunRules.base_difficulty_id = "normal"
	Registry.difficulties.erase(RunRules.CUSTOM_DIFF_ID)   # 模拟"新进程里条目不存在"
	RunRules.apply_from_save(packed)
	if not RunRules.active or not is_equal_approx(RunRules.get_value("enemy_hp"), 2.4) \
			or RunRules.get_int("waves") != 22:
		_fail("读档未能恢复自定义规则参数")
		return
	if RunRules.base_difficulty_id != "nightmare":
		_fail("读档未恢复基准难度（应 nightmare，实为 %s）" % RunRules.base_difficulty_id)
		return
	if not Registry.difficulties.has(RunRules.CUSTOM_DIFF_ID):
		_fail("读档后未重新注入 custom 难度条目（会回落 normal）")
		return
	# 方案 A：重新注入的条目必须仍以恢复后的基准打底 —— 噩梦血量 2.2 × 规则 2.4
	var restored_hp := float(Registry.get_difficulty(RunRules.CUSTOM_DIFF_ID).hp_mult)
	if not is_equal_approx(restored_hp, 2.2 * 2.4):
		_fail("读档后合成条目未按恢复的基准叠乘（期望 %.2f，实为 %.2f）" % [2.2 * 2.4, restored_hp])
		return
	# 10b) 旧存档无 base 字段 → 基准回落 normal（旧档没有"继承基准"语义）
	RunRules.apply_from_save({ "active": true, "values": { "enemy_hp": 2.0 } })
	if RunRules.base_difficulty_id != "normal" or not is_equal_approx(RunRules.get_value("enemy_hp"), 2.0):
		_fail("旧存档（无 base 字段）未回落 normal 基准（base=%s）" % RunRules.base_difficulty_id)
		return
	if not is_equal_approx(float(Registry.get_difficulty(RunRules.CUSTOM_DIFF_ID).hp_mult), 2.0):
		_fail("旧存档回落 normal 后未按 normal 基准叠乘（期望 2.0）")
		return
	# 11) 损坏存档：非字典输入回落默认、不崩溃
	RunRules.apply_from_save("garbage")
	if RunRules.active or not RunRules.is_default():
		_fail("损坏的规则存档未被安全回落")
		return
	# 12) 手改越界值：apply_from_save 逐键 clamp
	RunRules.apply_from_save({ "active": true, "values": { "enemy_hp": 999.0, "waves": -3 } })
	if not is_equal_approx(RunRules.get_value("enemy_hp"), 3.0) or RunRules.get_int("waves") != 5:
		_fail("手改越界的规则存档未被 clamp")
		return
	# ⚠️ 收尾复位（本条用例必须自己善后）：上面把 active/values/基准难度都改成了极端值
	#    （enemy_hp=3.0 / waves=5）。不复位的话会**泄漏到后续用例**，而且症状极具迷惑性：
	#      · `WaveManager.start_wave(n)` 会按 `RunRules.wave_total` **夹断**波号
	#        → 后面「通关 BOSS 波 → 继续无尽」整条流程跑在错误的波号上；
	#      · `Config.is_boss_wave` 也跟着 `wave_total` 走 → BOSS 出现在意想不到的波。
	#    曾经它"碰巧"还能过（两个错误互相抵消），改成 20 波制后立刻暴露。
	RunRules.apply_from_save("garbage")
	print("SMOKE: run rules OK")

## 第 13 轮：商店刷新的「边际递减」+「补短板」倾向
## 起因：范围类属性收益是**面积**（DPS ∝ (1+b)²），边际收益随投入递增 —— 越叠越强；
## 而 dmg_mult 之类是线性的。对策是按当前投入降低它继续出现的概率。
## ⚠️ 全部走**纯函数**断言（不抽商店、不看刷到了什么），避免随机性进断言。
func _check_shop_diminishing() -> void:
	var p: Node2D = _main.get_node("Player")
	var stats_backup: Dictionary = p.stats.duplicate()
	var e_geo := { "effects": { "aoe_radius_bonus": 0.20 } }
	var e_lin := { "effects": { "dmg_mult": 0.20 } }
	# ---- ① 免费额度内完全不衰减（期望取自被测常量，不写死数值）----
	var st: Dictionary = stats_backup.duplicate()
	st["aoe_radius_bonus"] = Config.DIM_GEO_FREE
	var m_free: float = Config.diminish_mult(e_geo, st)
	if m_free > 1.001:
		_fail("边际递减：免费额度内不该衰减（得到 %.3f）" % m_free)
		return
	# ---- ② 超过免费额度后确实下降，且极端投入不击穿下限 ----
	st["aoe_radius_bonus"] = Config.DIM_GEO_FREE + Config.DIM_GEO_SOFT
	var m_mid: float = Config.diminish_mult(e_geo, st)
	if m_mid >= m_free - 0.001:
		_fail("边际递减：投入增加后权重未下降（%.3f → %.3f）" % [m_free, m_mid])
		return
	st["aoe_radius_bonus"] = 100.0   # 极端投入
	var m_max: float = Config.diminish_mult(e_geo, st)
	if m_max < Config.DIM_GEO_FLOOR - 0.001 or m_max >= m_mid:
		_fail("边际递减：极端投入未落在下限（%.3f，下限 %.3f）" % [m_max, Config.DIM_GEO_FLOOR])
		return
	# ---- ③ 几何类必须比线性类衰减更狠（同类属性，同投入）----
	#    dmg_mult 是 **1.0 基准的倍率**，投入量要按 `stats - 1.0` 算，
	#    这里刻意给到与几何例相同的「投入量」，才能做同尺度比较。
	st["dmg_mult"] = 1.0 + Config.DIM_GEO_FREE + Config.DIM_GEO_SOFT
	var m_lin: float = Config.diminish_mult(e_lin, st)
	if m_lin <= m_mid:
		_fail("边际递减：几何类未比线性类更狠（geo=%.3f lin=%.3f）" % [m_mid, m_lin])
		return
	# ---- ④ 反向对照：dmg_mult 若被当成 0 基准，投入量会多算 1.0 → 这里就不该还是 1.0 ----
	st["dmg_mult"] = 1.0 + Config.DIM_LIN_FREE + Config.DIM_LIN_SOFT
	if Config.diminish_mult(e_lin, st) >= 1.0:
		_fail("边际递减：dmg_mult 未按 1.0 基准计入投入")
		return
	# ---- ⑤ 负值（代价）不该被抑制，否则「带代价的强力道具」会反向更好刷 ----
	st["dmg_mult"] = 1.0 - 0.5
	var e_neg := { "effects": { "dmg_mult": -0.10 } }
	if Config.diminish_mult(e_neg, st) < 0.999:
		_fail("边际递减：负值（代价）不应被抑制")
		return
	# ---- ⑥ 复合条目取**最狠的一档**而非连乘（连乘会双重惩罚，可强度并没翻倍）----
	var st2: Dictionary = stats_backup.duplicate()
	st2["aoe_radius_bonus"] = 2.0
	st2["dmg_mult"] = 1.0   # 线性侧零投入 → 该侧不衰减
	var m_mix: float = Config.diminish_mult(
		{ "effects": { "aoe_radius_bonus": 0.10, "dmg_mult": 0.10 } }, st2)
	var m_geo_only: float = Config.diminish_mult(
		{ "effects": { "aoe_radius_bonus": 0.10 } }, st2)
	if absf(m_mix - m_geo_only) > 0.001:
		_fail("边际递减：复合条目应取最狠一档而非连乘（%.3f vs %.3f）" % [m_mix, m_geo_only])
		return
	# ---- ⑦ 补短板：投入最少的维度提权，最多的不提权 ----
	var counts := { "offense": 9, "area": 3, "tank": 0, "utility": 4 }
	var s_tank: float = Config.shortfall_mult({ "effects": { "max_hp": 20.0 } }, counts)
	var s_off: float = Config.shortfall_mult({ "effects": { "dmg_mult": 0.10 } }, counts)
	if s_tank <= 1.0:
		_fail("补短板：投入最少的维度未提权（%.3f）" % s_tank)
		return
	if s_off > 1.001:
		_fail("补短板：投入最多的维度不该提权（%.3f）" % s_off)
		return
	# 反向对照：没有任何投入记录（刚开局）→ 不做引导
	if Config.shortfall_mult({ "effects": { "max_hp": 20.0 } }, {}) > 1.001:
		_fail("补短板：无投入记录时不该引导")
		return
	# ---- ⑧ 波次放宽：后期波次免费额度更大 → 同一投入被压得更轻 ----
	var st_w: Dictionary = stats_backup.duplicate()
	st_w["aoe_radius_bonus"] = Config.DIM_GEO_FREE + Config.DIM_GEO_SOFT
	var m_w1: float = Config.diminish_mult(e_geo, st_w, 1)
	var m_w20: float = Config.diminish_mult(e_geo, st_w, 20)
	if m_w1 > 1.001:
		_fail("波次放宽：前期免费额度内不应衰减（w1=%.3f）" % m_w1)
		return
	if m_w20 <= m_w1 + 0.001:
		_fail("波次放宽：后期波次未比前期压得更轻（w1=%.3f w20=%.3f）" % [m_w1, m_w20])
		return
	# ---- ⑨ 角标键：投入超该波免费额度时返回受抑属性名，未超额时为空 ----
	var keys_sup := Config.dim_suppressed_keys({ "effects": { "aoe_radius_bonus": 0.20 } }, st_w, 1)
	if keys_sup.is_empty():
		_fail("边际递减角标：超额度未返回受抑属性键")
		return
	var keys_free: PackedStringArray = Config.dim_suppressed_keys(
		{ "effects": { "aoe_radius_bonus": 0.20 } }, st_w, 20)
	if not keys_free.is_empty():
		_fail("边际递减角标：后期波次免费额度内不应仍标为受抑")
		return
	p.stats = stats_backup
	print("SMOKE: shop diminishing + shortfall OK")

## HUD 状态图例：无来源隐藏 / 同状态武器取最大命中率 / 道具独立概率合并 / 强化加成行
func _check_status_legend() -> void:
	var hud: Control = _main.get_node("UI/HUD")
	var p2: Node2D = _main.get_node("Player")
	if hud._status_panel == null or hud._status_box == null:
		_fail("HUD 缺少状态图例节点")
		return
	var w_backup: Array = p2.weapons.duplicate(true)
	var items_backup: Dictionary = p2.items_owned.duplicate()
	var stats_backup: Dictionary = p2.stats.duplicate()
	# 无状态来源 → 图例隐藏
	p2.weapons = []
	p2.items_owned = {}
	for sid in Config.STATUS:
		p2.stats["on_hit_" + String(sid)] = 0.0
	p2.stats.status_chance = 0.0
	p2.stats.status_dmg_mult = 0.0
	p2.stats.status_dur_mult = 0.0
	hud._status_key = ""
	hud._refresh_status_legend()
	if hud._status_panel.visible:
		_fail("无状态来源时 HUD 图例应隐藏")
		return
	# 双燃烧武器：命中率取最大，来源计数 2
	#
	# ⚠️ S2：原用例用「火焰喷射器 + 火箭筒」两把不同武器。`rocket` 已迁入工坊包，
	#    内置只剩 `flamethrower` 一把带 burn → 改用**同一把武器放两格**。
	#    `status_sources` 的 count 是按 weapons 条目累加的（player.gd:489），
	#    所以"两格同状态 → count=2"这个语义照样被验到，且不依赖任何 mod。
	#    「取最大命中率」的语义改由下一组断言（道具独立概率合并）承担 ——
	#    因为两格同款武器的 chance 必然相等，取 max 与取任一无法区分。
	p2.weapons = [{ "type": "flamethrower", "cd": 0.3 }, { "type": "flamethrower", "cd": 0.3 }]
	var flame_ch := clampf(float(Registry.weapons["flamethrower"].get("status_chance", 1.0)), 0.0, 1.0)
	hud._status_key = ""
	hud._refresh_status_legend()
	var src: Dictionary = p2.status_sources()
	if not src.has("burn") or int(src["burn"]["count"]) != 2:
		_fail("status_sources 未合并同状态武器（count=%d）"
			% int(src.get("burn", {}).get("count", 0)))
		return
	if not is_equal_approx(float(src["burn"]["chance"]), flame_ch):
		_fail("同状态武器命中率不对（%.2f ≠ %.2f）" % [float(src["burn"]["chance"]), flame_ch])
		return
	if not hud._status_panel.visible or hud._status_box.get_child_count() < 2:
		_fail("有状态来源时 HUD 图例未显示（children=%d）" % hud._status_box.get_child_count())
		return
	# 再叠余烬：概率按 1-(1-a)(1-b) 独立合并，来源计数 3（两格喷火 + 一件道具）
	# 这也正是"取最大 vs 独立合并"两种语义的分界：武器之间取 max，道具走独立概率。
	p2.apply_item("i-ember")
	var merged := 1.0 - (1.0 - flame_ch) * (1.0 - 0.20)
	hud._status_key = ""
	hud._refresh_status_legend()
	var src2: Dictionary = p2.status_sources()
	if not src2.has("burn") or int(src2["burn"]["count"]) != 3:
		_fail("道具未并入状态来源（count=%d）" % int(src2.get("burn", {}).get("count", 0)))
		return
	if not is_equal_approx(float(src2["burn"]["chance"]), merged):
		_fail("状态来源概率合并不对（%.3f ≠ %.3f）" % [float(src2["burn"]["chance"]), merged])
		return
	# 强化加成行：伤害/时长 > 0 时图例追加说明（末尾已追加五行反应节，按引用取）
	p2.stats.status_dmg_mult = 0.25
	p2.stats.status_dur_mult = 0.10
	hud._status_key = ""
	hud._refresh_status_legend()
	var bonus: Label = hud._bonus_label
	if bonus == null or String(bonus.text).find("伤害") < 0 \
			or String(bonus.text).find("时长") < 0:
		_fail("状态强化加成行未显示")
		return
	if String(bonus.text).find("传染") >= 0:
		_fail("无中毒来源时不应显示传染加成")
		return
	# 瘟疫之心（中毒传染）：存在中毒来源时才追加显示
	#
	# ⚠️ S2：原用例挂 `venom_dagger`（毒牙匕首）取得中毒来源，但该武器已迁入工坊包
	#    `brotato_lite_core`。内置 5 把五行武器里**没有中毒载体**（毒属于木，
	#    但木弓 `blight_bow` 不带 status），所以改用**通用来源通路**
	#    `stats.on_hit_poison`（见 player.status_sources 第二个循环）——
	#    这条通路与武器无关，测的是同一个「中毒来源 → 显示传染加成」的判定。
	p2.weapons = [{ "type": "flamethrower", "cd": 0.4 }]
	var poison_ch_bak := float(p2.stats.get("on_hit_poison", 0.0))
	p2.stats["on_hit_poison"] = 0.5
	p2.stats.status_spread = 1.0
	hud._status_key = ""
	hud._refresh_status_legend()
	if hud._bonus_label == null or String(hud._bonus_label.text).find("传染") < 0:
		p2.stats["on_hit_poison"] = poison_ch_bak
		_fail("中毒传染加成未显示")
		return
	p2.stats["on_hit_poison"] = poison_ch_bak
	# 还原构筑，避免影响后续存档/结算断言
	p2.weapons = w_backup
	p2.items_owned = items_backup
	p2.stats = stats_backup
	hud._status_key = ""
	hud._refresh_status_legend()
	print("SMOKE: status legend OK")

## 五行反应系统：数据表自洽 / 每种反应的触发连通性 / Registry 注册校验 /
## 相生不消耗层数 / 相克消耗+AOE 爆发 / 限时 debuff / 处决 / BOSS 抗性 /
## 图鉴解锁 / 音效与打击感 / HUD 折叠页
func _check_reactions() -> void:
	if _failed:
		return
	var p2: Node2D = _main.get_node("Player")
	# ---- 数据表自洽：10 种（5 相生 + 5 相克），key 必须按五行字母序书写 ----
	if Config.REACTIONS.size() != 10:
		_fail("五行反应数量不对（%d，期望 10）" % Config.REACTIONS.size())
		return
	if Config.STATUS_ELEMENT.size() != Config.STATUS.size():
		_fail("五行归属未覆盖全部状态（%d/%d）"
			% [Config.STATUS_ELEMENT.size(), Config.STATUS.size()])
		return
	var gen_cnt := 0
	for rkey in Config.REACTIONS:
		var r: Dictionary = Config.REACTIONS[rkey]
		var parts := String(rkey).split("+")
		if parts.size() != 2 \
				or Config.reaction_key(String(parts[0]), String(parts[1])) != String(rkey):
			_fail("反应 key 未按五行字母序书写，运行时永远查不到（%s）" % String(rkey))
			return
		for field in ["id", "name", "ico", "type", "desc", "effect", "rarity", "sfx"]:
			if not r.has(field):
				_fail("反应 %s 缺少字段 %s" % [String(rkey), String(field)])
				return
		if float(r.get("shake", 0.0)) <= 0.0:
			_fail("反应 %s 未配置震屏强度" % String(rkey))
			return
		if String(r.type) == "generate":
			gen_cnt += 1
		elif String(r.type) != "overcome":
			_fail("反应 type 非法（%s=%s）" % [String(rkey), String(r.type)])
			return
	if gen_cnt != 5:
		_fail("相生/相克配比不对（相生 %d，期望 5）" % gen_cnt)
		return
	var elem_seen := {}
	for sid in Config.STATUS_ELEMENT:
		var el := Config.get_element(String(sid))
		if not Config.ELEMENTS.has(el) or not Config.ELEMENT_COLOR.has(el) \
				or not Config.ELEMENT_NAME.has(el):
			_fail("状态 %s 归属的五行 %s 缺少配色/中文名" % [String(sid), el])
			return
		elem_seen[el] = true
	if elem_seen.size() != Config.ELEMENTS.size():
		_fail("五行未被状态全覆盖（%s）" % str(elem_seen.keys()))
		return
	# 同五行不反应（冰冻/减速都属水）；key 推导必须对称
	if not Config.get_reaction("freeze", "slow").is_empty() \
			or Config.reaction_key("water", "water") != "" \
			or Config.reaction_key("fire", "wood") != Config.reaction_key("wood", "fire"):
		_fail("reaction_key 对称性/同五行判定错误")
		return
	# ---- 每种反应都能被至少一对状态触发（key 写错会在这里暴露）----
	var reachable := {}
	for sid_a in Config.STATUS:
		for sid_b in Config.STATUS:
			if String(sid_a) == String(sid_b):
				continue
			var found: Dictionary = Registry.find_reaction(String(sid_a), String(sid_b))
			if not found.is_empty():
				reachable[String(found.get("id", ""))] = true
	if reachable.size() != Config.REACTIONS.size():
		var missing: Array = []
		for rkey2 in Config.REACTIONS:
			if not reachable.has(String(Config.REACTIONS[rkey2].get("id", ""))):
				missing.append(String(rkey2))
		_fail("有反应无法被任何状态对触发（缺 %s）" % str(missing))
		return
	# ---- Registry：内置反应全量注册，双向查询命中 ----
	if Registry.reactions.size() != Config.REACTIONS.size() \
			or Registry.reaction_list().size() != Registry.reactions.size() \
			or Registry.get_reaction("fire_water").is_empty():
		_fail("Registry 反应注册/查询 API 不完整")
		return
	if String(Registry.find_reaction("burn", "poison").get("id", "")) != "wood_fire" \
			or String(Registry.find_reaction("poison", "burn").get("id", "")) != "wood_fire" \
			or not Registry.find_reaction("freeze", "slow").is_empty():
		_fail("Registry.find_reaction 双向查询/同五行判定错误")
		return
	# ---- Registry 校验：非法条目全部拒登 ----
	var bad_reactions: Array = [
		{ "id": "smoke_r1", "name": "坏类型", "type": "boom", "key": "fire+wood",
			"effect": { "add_stacks": { "burn": 1 } } },
		{ "id": "smoke_r2", "name": "key 未按字母序", "type": "generate", "key": "wood+fire",
			"effect": { "add_stacks": { "burn": 1 } } },
		{ "id": "smoke_r3", "name": "坏稀有度", "type": "generate", "key": "fire+wood",
			"rarity": "godly", "effect": { "add_stacks": { "burn": 1 } } },
		{ "id": "smoke_r4", "name": "相生带消耗键", "type": "generate", "key": "fire+wood",
			"effect": { "consume": { "burn": 1 } } },
		{ "id": "smoke_r5", "name": "空效果", "type": "overcome", "key": "fire+water",
			"effect": {} },
		{ "id": "smoke_r6", "name": "相克缺消耗", "type": "overcome", "key": "fire+water",
			"effect": { "aoe_dmg_scale": 2.0 } },
		{ "id": "smoke_r7", "name": "未知状态 id", "type": "generate", "key": "fire+wood",
			"effect": { "add_stacks": { "nope": 1 } } },
		{ "id": "smoke_r8", "name": "半径越界", "type": "overcome", "key": "fire+water",
			"effect": { "consume": { "burn": 1 }, "aoe_radius": 9999.0 } },
	]
	for bad in bad_reactions:
		if Registry.register_reaction((bad as Dictionary).duplicate(true)):
			_fail("Registry 接受了非法五行反应（%s）" % String(bad.get("name", "")))
			return
	if Registry.reactions.size() != Config.REACTIONS.size():
		_fail("非法反应污染了注册表（%d）" % Registry.reactions.size())
		return
	# 合法条目可注册，并能用同 key 覆盖内置反应（mod 换皮的前提）
	var ok_reaction := { "id": "smoke_reaction", "name": "测试反应", "ico": "☯",
		"type": "generate", "rarity": "common", "key": "fire+wood", "desc": "冒烟测试用",
		"effect": { "add_stacks": { "burn": 2 } }, "sfx": "reaction_wood_fire", "shake": 1.0 }
	if not Registry.register_reaction(ok_reaction):
		_fail("Registry 拒绝了合法五行反应")
		return
	if String(Registry.find_reaction("burn", "poison").get("id", "")) != "smoke_reaction":
		_fail("mod 反应未覆盖同 key 内置反应")
		return
	var restore: Dictionary = Config.REACTIONS["fire+wood"].duplicate(true)
	restore["key"] = "fire+wood"
	Registry.reactions.erase("smoke_reaction")
	if not Registry.register_reaction(restore) \
			or String(Registry.find_reaction("poison", "burn").get("id", "")) != "wood_fire" \
			or Registry.reactions.size() != Config.REACTIONS.size():
		_fail("内置五行反应还原失败")
		return
	# ---- 反应触发与效果（全程同步执行，不跨帧，避开 AI/DoT 干扰）----
	var reaction_hits: Array = []
	var reaction_cb := func(rid: String, _pos: Vector2, targets: Array) -> void:
		reaction_hits.append([rid, targets.size()])
	EventBus.element_reaction.connect(reaction_cb)
	var far_corner := Vector2(float(Config.WORLD.w) - 150.0, float(Config.WORLD.h) - 150.0)
	var e_r: Node2D = _spawn_reaction_target("grunt", far_corner, p2)
	var e_n: Node2D = _spawn_reaction_target("grunt", far_corner + Vector2(60.0, 0.0), p2)
	var codex_before: int = CodexData.stat("reactions")
	var juice_before: int = _main._reaction_count
	_main._reaction_juice_cd = 0
	_main._reaction_popup_cd.clear()
	# 相生「木生火」：中毒(木) + 燃烧(火) → 燃烧 +1 层、时长 ×1.5，双方层数不消耗
	e_r.apply_status("poison", 2, 0.0, 30.0, 1.0)
	e_r.apply_status("burn", 2, 0.0, 50.0, 1.0)
	if reaction_hits.size() != 1 or String(reaction_hits[0][0]) != "wood_fire" \
			or int(reaction_hits[0][1]) != 1:
		_fail("木生火未触发或信号载荷错误（%s）" % str(reaction_hits))
		return
	if not e_r.has_status("poison") or int(e_r.statuses.poison.stacks) != 2:
		_fail("相生反应不应消耗层数（poison=%s）" % str(e_r.statuses.get("poison", {})))
		return
	if int(e_r.statuses.burn.stacks) != 3 \
			or not is_equal_approx(float(e_r.statuses.burn.remaining), 4.5):
		_fail("木生火加层/延时错误（stacks=%d remaining=%.2f，期望 3 / 4.50）"
			% [int(e_r.statuses.burn.stacks), float(e_r.statuses.burn.remaining)])
		return
	# 图鉴解锁 + 统计 + 数据源
	if not CodexData.is_unlocked("reaction", "wood_fire") \
			or CodexData.stat("reactions") != codex_before + 1:
		_fail("反应未解锁图鉴/未计入统计（unlocked=%s stat=%d）"
			% [str(CodexData.is_unlocked("reaction", "wood_fire")), CodexData.stat("reactions")])
		return
	if CodexData.total_entries("reaction") != Registry.reactions.size() \
			or CodexData.display_name("reaction", "wood_fire") != "木生火" \
			or CodexData.display_icon("reaction", "wood_fire") != "🌿🔥":
		_fail("图鉴 reaction 分类数据源不对")
		return
	# 打击感：震屏/顿帧计数 + 屏幕中央提示
	if _main._reaction_count != juice_before + 1 or not _main._reaction_label.visible \
			or String(_main._reaction_label.text).find("木生火") < 0:
		_fail("反应打击感/中央提示未触发（count=%d text=%s）"
			% [_main._reaction_count, String(_main._reaction_label.text)])
		return
	# 相生「金生水」：流血(金) + 冰冻(水) → 冰冻 +0.3s；流血转冰伤会再上冰冻，
	# 必须被“执行中反应”拦住，否则同一反应会递归到深度上限
	reaction_hits.clear()
	e_r.statuses.clear()
	e_r.apply_status("bleed", 2, 0.0, 40.0, 1.0)
	e_r.apply_status("freeze", 1, 0.0, 0.0, 1.0)
	if reaction_hits.size() != 1 or String(reaction_hits[0][0]) != "metal_water":
		_fail("金生水自我递归或未触发（%s）" % str(reaction_hits))
		return
	if int(e_r.statuses.bleed.stacks) != 2 \
			or not is_equal_approx(float(e_r.statuses.freeze.remaining), 1.4):
		_fail("金生水延时/不消耗错误（bleed=%d freeze=%.2f，期望 2 / 1.40）"
			% [int(e_r.statuses.bleed.stacks), float(e_r.statuses.freeze.remaining)])
		return
	# 相生「水生木」：冰冻(水) + 中毒(木) → 中毒扩散给半径 100 内邻居
	reaction_hits.clear()
	e_r.statuses.clear()
	e_n.statuses.clear()
	e_r.apply_status("poison", 2, 0.0, 30.0, 1.0)
	e_r.apply_status("freeze", 1, 0.0, 0.0, 1.0)
	if not _has_reaction_hit(reaction_hits, "water_wood"):
		_fail("水生木未触发（%s）" % str(reaction_hits))
		return
	if not e_n.has_status("poison"):
		_fail("水生木未把中毒扩散给半径内邻居")
		return
	if int(e_r.statuses.poison.stacks) != 2:
		_fail("相生扩散不应消耗自身层数")
		return
	# 相克「水克火」：燃烧(火) + 冰冻(水) → 消耗双方 + 蒸气爆炸（半径 120，强度×2.5）
	reaction_hits.clear()
	e_r.statuses.clear()
	e_n.statuses.clear()
	var hp_r: float = e_r.hp
	var hp_n: float = e_n.hp
	e_r.apply_status("burn", 2, 0.0, 50.0, 1.0)
	e_r.apply_status("freeze", 1, 0.0, 0.0, 1.0)
	if not _has_reaction_hit(reaction_hits, "fire_water"):
		_fail("水克火未触发（%s）" % str(reaction_hits))
		return
	if not e_r.statuses.is_empty():
		_fail("相克反应未消耗状态层数（%s）" % str(e_r.statuses.keys()))
		return
	# 爆发 = Σ(power × stacks) × 2.5 = (50×2 + 0×1) × 2.5 = 250，自身与邻居各吃一份
	if not is_equal_approx(hp_r - e_r.hp, 250.0):
		_fail("水克火自身爆发伤害错误（%.2f，期望 250.00）" % (hp_r - e_r.hp))
		return
	if not is_equal_approx(hp_n - e_n.hp, 250.0):
		_fail("水克火未对半径内邻居造成 AOE（%.2f，期望 250.00）" % (hp_n - e_n.hp))
		return
	# 相克「火克金」：燃烧(火) + 流血(金) → 消耗双方 + 熔金（受伤 +50%，持续 3s）
	reaction_hits.clear()
	e_r.statuses.clear()
	e_r.apply_status("burn", 2, 0.0, 50.0, 1.0)
	e_r.apply_status("bleed", 1, 0.0, 40.0, 1.0)
	if not _has_reaction_hit(reaction_hits, "fire_metal"):
		_fail("火克金未触发（%s）" % str(reaction_hits))
		return
	if e_r.reaction_debuffs.size() != 1 or not is_equal_approx(e_r._damage_taken_mult(), 1.5):
		_fail("火克金未施加受伤提升 debuff（×%.2f，期望 ×1.50）" % e_r._damage_taken_mult())
		return
	# 回归（2026-09-19）：同类 debuff **重复触发不得累乘**。旧实现是 append + 取用时整体
	# ∏，第 N 次火克金 = 1.5^N、金克木 = 2.0^N，两者叠加进 DoT 通道就是 3^k ——
	# 实测第 11 波单波状态伤害 4.3e11、占该波 100%。现按 reaction_id 建唯一槽位。
	e_r.statuses.clear()
	e_r.apply_status("burn", 1, 0.0, 50.0, 1.0)
	e_r.apply_status("bleed", 1, 0.0, 40.0, 1.0)
	if e_r.reaction_debuffs.size() != 1 \
			or not is_equal_approx(e_r._damage_taken_mult(), 1.5):
		_fail("重复触发火克金导致 debuff 累乘（槽位 %d、倍率 ×%.2f，期望 1 / ×1.50）"
			% [e_r.reaction_debuffs.size(), e_r._damage_taken_mult()])
		return
	e_r._tick_statuses(3.1)
	if not e_r.reaction_debuffs.is_empty() \
			or not is_equal_approx(e_r._damage_taken_mult(), 1.0):
		_fail("反应 debuff 未按时到期")
		return
	# 回归（2026-09-19）：状态的 DoT 提伤（火生土：燃烧 ×1.3）只应「取大一档」，
	# 既不连乘（1.3^k）也不累加（反复触发爬到封顶）
	e_r.statuses.clear()
	e_r.reaction_debuffs.clear()
	e_r.apply_status("burn", 1, 0.0, 100.0, 1.0)
	e_r.apply_status("stun", 1, 0.0, 100.0, 1.0)
	var burn_pow1 := float(e_r.statuses.burn.power)
	e_r.apply_status("burn", 1, 0.0, 100.0, 1.0)   # 再上燃烧 → 再触发一次火生土
	if not is_equal_approx(burn_pow1, 130.0) \
			or not is_equal_approx(float(e_r.statuses.burn.power), 130.0):
		_fail("火生土 DoT 提伤被反复叠乘/累加（%.2f → %.2f，期望恒为 130.00）"
			% [burn_pow1, float(e_r.statuses.burn.power)])
		return
	e_r.statuses.clear()
	e_r.reaction_debuffs.clear()
	# 相克「金克木」：流血(金) + 中毒(木) → 各消耗 1 层 + 持续伤害翻倍 4s
	reaction_hits.clear()
	e_r.statuses.clear()
	e_r.apply_status("bleed", 2, 0.0, 40.0, 1.0)
	e_r.apply_status("poison", 1, 0.0, 0.0, 1.0)
	if not _has_reaction_hit(reaction_hits, "metal_wood"):
		_fail("金克木未触发（%s）" % str(reaction_hits))
		return
	if not is_equal_approx(e_r._reaction_dot_mult(), 2.0):
		_fail("金克木未提升持续伤害（×%.2f，期望 ×2.00）" % e_r._reaction_dot_mult())
		return
	if e_r.has_status("poison") or int(e_r.statuses.bleed.stacks) != 1:
		_fail("金克木消耗层数错误（bleed=%d，期望 1；poison 应清空）"
			% int(e_r.statuses.get("bleed", {}).get("stacks", -1)))
		return
	# 翻倍后的流血跳伤：40 × 0.12 × 1 层 × 2 = 9.6
	var hp_dot: float = e_r.hp
	e_r._tick_statuses(0.6)
	if not is_equal_approx(hp_dot - e_r.hp, 9.6):
		_fail("反应翻倍后的流血跳伤错误（%.2f，期望 9.60）" % (hp_dot - e_r.hp))
		return
	# 相克「土克水」：眩晕(土) + 冰冻/减速(水)；满血只消耗层数，不处决也不掉血
	reaction_hits.clear()
	e_r.statuses.clear()
	var hp_full: float = e_r.hp
	e_r.apply_status("stun", 1, 0.0, 0.0, 1.0)
	e_r.apply_status("slow", 1, 0.0, 0.0, 1.0)
	if not _has_reaction_hit(reaction_hits, "earth_water"):
		_fail("土克水未触发（%s）" % str(reaction_hits))
		return
	if e_r.statuses.has("stun") or e_r.statuses.has("slow") \
			or not is_equal_approx(e_r.hp, hp_full):
		_fail("满血土克水应只消耗层数、不处决也不掉血（hp=%.0f/%.0f）" % [e_r.hp, hp_full])
		return
	# 血量低于 20% 时土克水直接碎裂
	var e_x: Node2D = _spawn_reaction_target("grunt", far_corner + Vector2(-320.0, 0.0), p2)
	e_x.hp = e_x.max_hp * 0.1
	reaction_hits.clear()
	e_x.apply_status("stun", 1, 0.0, 0.0, 1.0)
	e_x.apply_status("freeze", 1, 0.0, 0.0, 1.0)
	if not _has_reaction_hit(reaction_hits, "earth_water"):
		_fail("低血土克水未触发（%s）" % str(reaction_hits))
		return
	if e_x.hp > 0.0 or not e_x.is_queued_for_deletion():
		_fail("土克水未处决低血量目标（hp=%.2f）" % e_x.hp)
		return
	# BOSS 抗性：status_resist 不止减免状态时长，也削减反应爆发伤害
	var boss_id := Registry.boss_id()
	var boss_resist := clampf(float(Registry.enemies[boss_id].get("status_resist", 0.0)), 0.0, 0.95)
	if boss_resist <= 0.0:
		_fail("BOSS %s 未配置 status_resist，反应抗性无从生效" % boss_id)
		return
	var e_b: Node2D = _spawn_reaction_target(boss_id,
		Vector2(150.0, float(Config.WORLD.h) - 150.0), p2, boss_resist)
	reaction_hits.clear()
	var boss_hp: float = e_b.hp
	e_b.apply_status("burn", 2, 0.0, 50.0, 1.0)
	e_b.apply_status("freeze", 1, 0.0, 0.0, 1.0)
	var boss_expected := 100.0 * 2.5 * (1.0 - boss_resist)
	if not _has_reaction_hit(reaction_hits, "fire_water"):
		_fail("BOSS 未触发水克火（%s）" % str(reaction_hits))
		return
	if not is_equal_approx(boss_hp - e_b.hp, boss_expected):
		_fail("BOSS status_resist 未削减反应伤害（%.2f，期望 %.2f）"
			% [boss_hp - e_b.hp, boss_expected])
		return
	# 连锁预算与“执行中”标记必须复位，否则后续反应全部被卡死
	if Enemy._reaction_depth != 0 or not e_r._reaction_active.is_empty():
		_fail("反应深度/执行中标记未复位（depth=%d active=%s）"
			% [Enemy._reaction_depth, str(e_r._reaction_active.keys())])
		return
	e_b.queue_free()
	e_r.queue_free()
	e_n.queue_free()
	e_x.queue_free()
	# ---- HUD 五行反应折叠页 ----
	var hud: Control = _main.get_node("UI/HUD")
	var w_backup: Array = p2.weapons.duplicate(true)
	var items_backup: Dictionary = p2.items_owned.duplicate()
	var stats_backup: Dictionary = p2.stats.duplicate()
	# 火焰喷射器(火) + 霜冻法杖(水)：当前构筑只应算出「水克火」一种
	p2.weapons = [{ "type": "flamethrower", "cd": 0.1 }, { "type": "frost_staff", "cd": 0.8 }]
	p2.items_owned = {}
	for sid2 in Config.STATUS:
		p2.stats["on_hit_" + String(sid2)] = 0.0
	p2.stats.status_chance = 0.0
	hud._reaction_open = false
	hud._status_key = ""
	hud._refresh_status_legend()
	var avail: Array = hud._available_reactions(p2.status_sources())
	if avail.size() != 1 or String(avail[0].get("id", "")) != "fire_water":
		_fail("HUD 可触发反应数量算错（%s）" % str(avail))
		return
	var head := _find_reaction_head(hud)
	if head == null or String(head.text).find("五行反应 1/%d" % Registry.reactions.size()) < 0 \
			or String(head.text).find("▸") < 0:
		_fail("HUD 反应折叠标题未显示可触发数量（%s）"
			% ("<缺失>" if head == null else String(head.text)))
		return
	# hud 声明为 Control，_status_box 属动态访问返回 Variant，必须显式标注类型
	var folded_children: int = hud._status_box.get_child_count()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	hud._on_reaction_head_input(click)
	if not hud._reaction_open or hud._status_box.get_child_count() <= folded_children:
		_fail("点击标题未展开五行反应表（open=%s children=%d→%d）"
			% [str(hud._reaction_open), folded_children, hud._status_box.get_child_count()])
		return
	var head2 := _find_reaction_head(hud)
	if head2 == null or String(head2.text).find("▾") < 0:
		_fail("展开态折叠标题未切换箭头")
		return
	hud._on_reaction_head_input(click)
	if hud._reaction_open or hud._status_box.get_child_count() != folded_children:
		_fail("再次点击未收起五行反应表")
		return
	# 还原构筑与折叠态，避免影响后续存档/结算断言
	p2.weapons = w_backup
	p2.items_owned = items_backup
	p2.stats = stats_backup
	hud._reaction_open = false
	hud._status_key = ""
	hud._refresh_status_legend()
	# ---- 反应音效：10 种全部程序生成注册，同名 160ms 节流 ----
	for rkey3 in Config.REACTIONS:
		var sfx_id := String(Config.REACTIONS[rkey3].get("sfx", ""))
		if sfx_id == "" or not Sfx._streams.has(sfx_id):
			_fail("反应音效未注册（%s）" % sfx_id)
			return
	Sfx._reaction_cd.clear()
	EventBus.element_reaction.emit("wood_fire", Vector2.ZERO, [])
	var rcd0 := int(Sfx._reaction_cd.get("wood_fire", 0))
	EventBus.element_reaction.emit("wood_fire", Vector2.ZERO, [])
	if rcd0 <= 0 or int(Sfx._reaction_cd.get("wood_fire", 0)) != rcd0:
		_fail("反应音效节流失效")
		return
	EventBus.element_reaction.disconnect(reaction_cb)
	# 顿帧会把 Engine.time_scale 压到 0.18，而本函数全程同步不跨帧，
	# 没有 _process 去收尾；不复位会让后续所有用例都在慢放里跑
	_main._hit_stop_until_ms = 0
	_main._end_hit_stop()
	print("SMOKE: element reactions OK")

## ============================================================
## Phase 2 主题包内容验证（五行阵营：10 敌人 + 3 BOSS + 20 条元素关系）
##
## ⚠️ S2 口径收缩：本函数原本还顺带断言「12 角色 / 22 武器 / 8 把 Phase 2 武器」，
##    这些内容已在 S2 迁入工坊包 `brotato_lite_core`（内置只剩 6 角色 / 5 武器）。
##    → 角色数与武器数改由 `_check_phase3_content` 断言（那里是「内容清单」的归属地）；
##      本函数现在**只查 Phase 2 遗留且仍在内置的部分**，即敌人表与元素关系表。
##      这样做的好处：断言不会因为「内容搬家」而误红 —— 搬家的东西不该留两处口径。
## ============================================================
func _check_phase2_content() -> void:
	if _failed:
		return
	# ---- 内置五行阵营敌人（Phase 2 遗留，S3 会在此基础上重建 5 元素基础怪） ----
	var new_enemies := ["fire_imp", "fire_shaman", "wood_sprite", "vine_beast",
		"metal_puppet", "blade_monk", "water_nymph", "ice_witch",
		"earth_golem", "stone_titan"]
	for eid in new_enemies:
		if not Registry.enemies.has(eid):
			_fail("Phase 2 敌人未注册：%s" % eid)
			return
		var e: Dictionary = Registry.enemies[eid]
		if bool(e.get("is_boss", false)) or String(e.get("ai", "")) == "boss":
			_fail("敌人 %s 不应标记为 BOSS" % eid)
			return
		if float(e.get("status_resist", 0.0)) <= 0.0:
			_fail("敌人 %s 的 status_resist 必须 > 0（五行阵营特征）" % eid)
			return
	if Registry.enemies.size() < 23:
		_fail("敌人总数不足 23（%d）" % Registry.enemies.size())
		return
	# ---- 验证点 2：BOSS_POOL 完整性（3 → 6） ----
	if Config.BOSS_POOL.size() != 6:
		_fail("BOSS_POOL 大小不对（%d，期望 6）" % Config.BOSS_POOL.size())
		return
	var new_bosses := ["boss_phoenix", "boss_leviathan", "boss_titan"]
	for bid in new_bosses:
		if not Config.BOSS_POOL.has(bid):
			_fail("BOSS_POOL 缺少新 BOSS：%s" % bid)
			return
		if not Registry.enemies.has(bid):
			_fail("BOSS %s 未注册到 Registry" % bid)
			return
		var b: Dictionary = Registry.enemies[bid]
		if not (bool(b.get("is_boss", false)) or String(b.get("ai", "")) == "boss"):
			_fail("BOSS %s 未标记为 boss" % bid)
			return
		if not Config.BOSS_TITLES.has(bid):
			_fail("BOSS %s 缺少称号" % bid)
			return
	# boss_leviathan 召唤物必须是已注册敌人
	var leviathan: Dictionary = Registry.enemies["boss_leviathan"]
	var summon_type := String(leviathan.get("summon_type", ""))
	if summon_type == "" or not Registry.enemies.has(summon_type):
		_fail("boss_leviathan 召唤类型非法：%s" % summon_type)
		return
	# ---- 验证点 3：每日挑战合法性（chars 12 / boss_id 在 BOSS_POOL） ----
	for date_str in ["2026-09-09", "2026-12-31", "2027-01-01", "2027-06-15"]:
		var setup: Dictionary = Config.daily_setup(date_str)
		var daily_char := String(setup.get("character_id", ""))
		if not Registry.characters.has(daily_char):
			_fail("每日挑战 %s 角色不存在：%s" % [date_str, daily_char])
			return
		var daily_boss := String(setup.get("boss_id", ""))
		if not Registry.enemies.has(daily_boss):
			_fail("每日挑战 %s BOSS 不存在：%s" % [date_str, daily_boss])
			return
		var boss_entry: Dictionary = Registry.enemies[daily_boss]
		if not (bool(boss_entry.get("is_boss", false)) \
				or String(boss_entry.get("ai", "")) == "boss"):
			_fail("每日挑战 %s BOSS %s 不是有效 BOSS" % [date_str, daily_boss])
			return
	# ---- 验证点 4：波次组合合法性（W1-15 非 BOSS 波） ----
	for w in range(1, 16):
		if Config.is_boss_wave(w):
			continue
		var comp: Array = Registry.wave_composition(w)
		if comp.is_empty():
			_fail("第 %d 波组合为空" % w)
			return
		for entry in comp:
			if typeof(entry) != TYPE_DICTIONARY:
				_fail("第 %d 波组合条目不是字典" % w)
				return
			var eid2 := String(entry.get("item", ""))
			if not Registry.enemies.has(eid2):
				_fail("第 %d 波组合含未注册敌人：%s" % [w, eid2])
				return
			if bool(Registry.enemies[eid2].get("is_boss", false)) \
					or String(Registry.enemies[eid2].get("ai", "")) == "boss":
				_fail("第 %d 波组合含 BOSS：%s" % [w, eid2])
				return
			if float(entry.get("w", 0.0)) <= 0.0:
				_fail("第 %d 波组合权重 ≤ 0（%s）" % [w, eid2])
				return
	# W6+ 必须至少含 1 只 Phase 2 新敌人
	var found_new := false
	for entry2 in Registry.wave_composition(6):
		if new_enemies.has(String(entry2.get("item", ""))):
			found_new = true
			break
	if not found_new:
		_fail("W6 波次组合未引入 Phase 2 新敌人")
		return
	# W10+ 必须至少含 5 只 Phase 2 新敌人（五行全覆盖）
	var new_in_w10 := 0
	for entry3 in Registry.wave_composition(10):
		if new_enemies.has(String(entry3.get("item", ""))):
			new_in_w10 += 1
	if new_in_w10 < 5:
		_fail("W10 波次组合 Phase 2 新敌人不足（%d < 5）" % new_in_w10)
		return
	# ---- 验证点 5：精英池合法性（含 ice_witch / stone_titan） ----
	var elite_ids := []
	for entry4 in Config.ELITE_POOL:
		var eid3 := String(entry4.get("item", ""))
		if not Registry.enemies.has(eid3):
			_fail("精英池含未注册敌人：%s" % eid3)
			return
		if bool(Registry.enemies[eid3].get("is_boss", false)):
			_fail("精英池含 BOSS：%s" % eid3)
			return
		if float(entry4.get("w", 0.0)) <= 0.0:
			_fail("精英池权重 ≤ 0（%s）" % eid3)
			return
		elite_ids.append(eid3)
	if not elite_ids.has("ice_witch") or not elite_ids.has("stone_titan"):
		_fail("精英池未包含 Phase 2 新精英怪（ice_witch/stone_titan）")
		return
	# ---- 验证点 6：五行武器覆盖（S8 第 7 轮**重写**）----
	# ⚠️ 原口径是「每个五行 ≥ 2 把武器」，且按 `status → 元素`（`Config.get_element`）推导。
	#    那是**收缩前 28 把**时代的覆盖目标（每系都有两把以上带状态的武器），
	#    并**靠工坊包里的旧武器凑数**。收缩到内置 10 把之后：
	#      · 「一个元素正好一把基础武器 + 一个进化形态」就是**设计本身**；
	#      · 木弓 `blight_bow` 与它的进化体**刻意不带 status**（定位是「高单发 + 续航」
	#        而非上异常）→ 按旧口径 wood 恒为 0。
	#    于是原断言只剩「工坊包在不在」这一个含义 —— 包一停用就必然红，
	#    而它红的原因跟五行覆盖毫无关系。
	#    → 改成当前设计真正的不变式：按武器自身 `element` 字段统计，
	#      **5 把开局武器必须恰好覆盖五行、不重不漏**（这才是「五行 = 一个元素一把」）。
	var elem_coverage := {"fire": 0, "wood": 0, "metal": 0, "water": 0, "earth": 0}
	var elem_cov_total := 0
	for wid_cov in Config.LOADOUT_WEAPONS:
		var w_el := String(Config.WEAPONS.get(String(wid_cov), {}).get("element", ""))
		if elem_coverage.has(w_el):
			elem_coverage[w_el] = int(elem_coverage[w_el]) + 1
			elem_cov_total += 1
	for el_cov in ["fire", "wood", "metal", "water", "earth"]:
		if int(elem_coverage[el_cov]) != 1:
			_fail("开局武器未做到「一个五行恰好一把」（%s 有 %d 把）"
				% [el_cov, int(elem_coverage[el_cov])])
			return
	if elem_cov_total != Config.ELEMENTS.size():
		_fail("开局武器覆盖的元素数 %d ≠ 五行数 %d（有武器没写 element 或写了非法值）"
			% [elem_cov_total, Config.ELEMENTS.size()])
		return
	# ---- 验证点 7（额外）：全量角色 stats 都在 STAT_LIMITS 范围内 ----
	# 遍历 `Registry.characters` 全量（内置 6 个 + 示例 mod + 工坊包（若已启用）），
	# 顺带覆盖 mod 角色的合法性 ——
	# ⚠️ 2026-09-17（第 7 轮）：工坊包 `brotato_lite_core` 已停用，所以现在常态只有内置 6 个；
	#    这条断言仍然遍历**全量**而不是内置 6 个 —— 它守的是「任何注册进来的角色都不能越界」，
	#    工坊包一旦被重新启用，那 11 个会自动回到覆盖范围里，不需要改这里。
	# register_character 虽有校验，但那是注册期的事，这里再钉一遍数值区间。
	for cid2 in Registry.characters:
		var stats: Dictionary = Registry.characters[cid2].get("stats", {})
		for key in stats:
			if not Registry.STAT_LIMITS.has(key):
				_fail("角色 %s 的 stats 含未登记键：%s" % [cid2, key])
				return
			var lim: Vector2 = Registry.STAT_LIMITS[key]
			var v := float(stats[key])
			if v < lim.x or v > lim.y:
				_fail("角色 %s 的 %s=%.2f 超出限制 [%.2f, %.2f]"
					% [cid2, key, v, lim.x, lim.y])
				return
	print("SMOKE: Phase 2 content OK")

## ============================================================
## Phase 3 法宝系统验证（15 件 / 触发式特效 / 三渠道获取 / 存档 / 图鉴）
## 10 个验证点，与 spec 第七章测试计划逐条对应。
## 全程同步执行（不 await，不让 WaveManager 有机会刷怪），并把 RNG 状态、击杀统计、
## 玩家持有/属性在结尾成对还原：本用例的 120 次掉落抽样会吃掉大量随机数，
## 不回滚会让后续所有依赖 GameRng 序列的断言漂移。
## ============================================================
func _check_phase3_artifacts() -> void:
	if _failed:
		return
	var p2: Node2D = _main.get_node("Player")
	var sys: Node = _main.get_node("ArtifactSystem")
	if sys == null:
		_fail("main.tscn 缺少 ArtifactSystem 触发执行器节点")
		return
	if sys.player != p2 or not sys.is_in_group("artifact_system"):
		_fail("ArtifactSystem 未绑定玩家或未入 artifact_system 组（enemy 反查会失效）")
		return
	# 接线自检：少订阅一个信号就是一整类法宝变死代码
	if not EventBus.element_reaction.is_connected(sys._on_element_reaction) \
			or not EventBus.enemy_died.is_connected(sys._on_enemy_died) \
			or not EventBus.boss_killed.is_connected(sys._on_boss_killed) \
			or not EventBus.status_applied.is_connected(sys._on_status_applied) \
			or not EventBus.player_damaged.is_connected(sys._on_player_damaged) \
			or not EventBus.wave_ended.is_connected(sys._on_wave_ended) \
			or not EventBus.wave_started.is_connected(sys._on_wave_started) \
			or not EventBus.run_started.is_connected(sys._on_run_started):
		_fail("ArtifactSystem 信号接线不完整")
		return
	# ---- 快照（结尾统一还原）----
	var rng_a: int = GameRng._a
	var phase_before: int = GameState.phase
	var kills_before: int = GameState.kills
	var codex_kills_before: int = CodexData.stat("kills")
	var mats_before: int = GameState.materials
	var slot_before: int = GameState.slot_id
	var owned_before: Dictionary = p2.artifacts_owned.duplicate(true)
	var stacks_before: Dictionary = p2.artifact_stacks.duplicate(true)
	var stats_before: Dictionary = p2.stats.duplicate(true)
	var weapons_before: Array = p2.weapons.duplicate(true)
	var items_before: Dictionary = p2.items_owned.duplicate(true)
	var hp_before: float = p2.hp
	var made: Array = []   # 本用例生成的敌人
	var loot_before: Array = get_tree().get_nodes_in_group("loot")
	GameState.set_phase(GameState.Phase.PLAYING)   # 触发闸门 _active() 要求局内
	var far_corner := Vector2(float(Config.WORLD.w) - 150.0, float(Config.WORLD.h) - 150.0)

	# ---- 验证点 1：数据完整性（数量与 Config 声明一致 + 五行 / 品阶覆盖）----
	# 数量不硬编码：以 Config 声明为准，避免每次扩充内容都要回来改测试
	if Config.ARTIFACTS.size() < 15:
		_fail("法宝数量低于下限 15（%d）" % Config.ARTIFACTS.size())
		return
	if Registry.artifacts.size() != Config.ARTIFACTS.size():
		_fail("Registry 法宝数（%d）与 Config 声明（%d）不一致"
			% [Registry.artifacts.size(), Config.ARTIFACTS.size()])
		return
	if Registry.artifact_list().size() != Config.ARTIFACTS.size():
		_fail("artifact_list 未返回全部法宝（%d / %d）"
			% [Registry.artifact_list().size(), Config.ARTIFACTS.size()])
		return
	var elem_cnt := {}
	var rarity_cnt := {}
	var trigger_cnt := {}
	for aid in Registry.artifacts:
		var a: Dictionary = Registry.artifacts[aid]
		for field in ["id", "name", "ico", "desc", "element", "rarity",
				"trigger", "params", "effect"]:
			if not a.has(field):
				_fail("法宝 %s 缺少字段 %s" % [String(aid), String(field)])
				return
		var price := int(a.get("price", 0))
		if price <= 0 or price > 400:
			_fail("法宝 %s 的 price 越界（%d，合法区间 [1, 400]）" % [String(aid), price])
			return
		if float(a.get("shop_weight", 0.0)) <= 0.0:
			_fail("法宝 %s 的 shop_weight 必须 > 0（否则永远抽不到）" % String(aid))
			return
		elem_cnt[String(a.element)] = int(elem_cnt.get(String(a.element), 0)) + 1
		rarity_cnt[String(a.rarity)] = int(rarity_cnt.get(String(a.rarity), 0)) + 1
		trigger_cnt[String(a.trigger)] = int(trigger_cnt.get(String(a.trigger), 0)) + 1
	for el in Config.ELEMENTS:
		if int(elem_cnt.get(String(el), 0)) < 3:
			_fail("五行 %s 的法宝不足 3 件（%d）" % [String(el), int(elem_cnt.get(String(el), 0))])
			return
	# 四档品阶都要有货（rare 档曾是空缺，补齐后不再允许某档为 0）
	for rar in ["common", "rare", "epic", "legendary"]:
		if int(rarity_cnt.get(rar, 0)) < 3:
			_fail("品阶 %s 的法宝不足 3 件（%d）" % [rar, int(rarity_cnt.get(rar, 0))])
			return
	if trigger_cnt.size() < 4:
		_fail("触发器种类过少（%s），法宝系统会退化成单一玩法" % str(trigger_cnt.keys()))
		return

	# ---- 验证点 2：参数合法性（trigger 白名单 + element/key/status 引用真实存在）----
	for aid2 in Registry.artifacts:
		var a2: Dictionary = Registry.artifacts[aid2]
		if String(a2.trigger) not in Config.ARTIFACT_TRIGGERS:
			_fail("法宝 %s 的 trigger 不在白名单：%s" % [String(aid2), String(a2.trigger)])
			return
		if String(a2.element) not in Config.ELEMENTS:
			_fail("法宝 %s 的 element 非法：%s" % [String(aid2), String(a2.element)])
			return
		var params2: Dictionary = a2.params
		var effect2: Dictionary = a2.effect
		if effect2.is_empty():
			_fail("法宝 %s 的 effect 为空（永远不会生效）" % String(aid2))
			return
		for pk in params2:
			if String(pk) not in Registry.ARTIFACT_PARAM_KEYS:
				_fail("法宝 %s 的 params 含未登记键：%s" % [String(aid2), String(pk)])
				return
		for ek in effect2:
			if String(ek) not in Registry.ARTIFACT_EFFECT_KEYS:
				_fail("法宝 %s 的 effect 含未登记键：%s" % [String(aid2), String(ek)])
				return
		if params2.has("key") and not Config.REACTIONS.has(String(params2.key)):
			_fail("法宝 %s 引用了不存在的五行反应：%s" % [String(aid2), String(params2.key)])
			return
		if params2.has("status") and not Config.STATUS.has(String(params2.status)):
			_fail("法宝 %s 引用了不存在的状态：%s" % [String(aid2), String(params2.status)])
			return
		if params2.has("element") and String(params2.element) not in Config.ELEMENTS:
			_fail("法宝 %s 的 params.element 非法" % String(aid2))
			return
		if effect2.has("apply_status") \
				and not Config.STATUS.has(String(effect2.apply_status)):
			_fail("法宝 %s 要施加的状态不存在：%s"
				% [String(aid2), String(effect2.apply_status)])
			return
		if effect2.has("stat") and not Registry.STAT_LIMITS.has(String(effect2.stat)):
			_fail("法宝 %s 叠加的属性不可叠：%s" % [String(aid2), String(effect2.stat)])
			return
		# patch 类法宝必须真的改动了目标反应，否则是挂在表里的死数据
		if effect2.has("patch"):
			if not params2.has("key"):
				_fail("法宝 %s 是 patch 类却没给 params.key" % String(aid2))
				return
			var origin: Dictionary = Config.REACTIONS[String(params2.key)].get("effect", {})
			if Config.apply_patch(origin, effect2.patch) == origin:
				_fail("法宝 %s 的 patch 未改变反应 %s 的效果"
					% [String(aid2), String(params2.key)])
				return

	# ---- 验证点 3：Registry 拒登（12 条非法条目全部被挡下）----
	var base_art := { "id": "art_smoke_bad", "name": "非法样本", "ico": "🔮",
		"element": "fire", "rarity": "common", "trigger": "on_kill", "params": {},
		"effect": { "heal_pct": 0.1 }, "price": 110, "shop_weight": 1.0, "desc": "冒烟" }
	var vary := func(over: Dictionary) -> Dictionary:
		var d: Dictionary = base_art.duplicate(true)
		d.merge(over, true)
		return d
	var bad_arts: Array = [
		["未知 trigger", vary.call({ "trigger": "on_moon" })],
		["非法 element", vary.call({ "element": "void" })],
		["非法 rarity", vary.call({ "rarity": "godly" })],
		["名称为空", vary.call({ "name": "   " })],
		["price 超上限", vary.call({ "price": 999 })],
		["params.key 不存在", vary.call({ "params": { "key": "fire+void" } })],
		["params.status 不存在", vary.call({ "params": { "status": "nope" } })],
		["hp_below 越界", vary.call({ "params": { "hp_below": 1.5 } })],
		["radius 越界", vary.call({ "effect": { "chance": 0.5, "radius": 9999.0 } })],
		["未知 effect 键", vary.call({ "effect": { "do_evil": 1 } })],
		["叠满超出属性区间", vary.call({ "effect": { "stat": "crit_ch",
			"per_stack": 0.5, "stack_max": 100 } })],
		["patch 缺 key", vary.call({ "effect": { "patch": { "set": { "armor_break": 0.9 } } } })],
	]
	for bad in bad_arts:
		if Registry.register_artifact((bad[1] as Dictionary).duplicate(true)):
			_fail("Registry 接受了非法法宝（%s）" % String(bad[0]))
			return
	if Registry.artifacts.size() != Config.ARTIFACTS.size():
		_fail("非法法宝污染了注册表（%d，应为 %d）"
			% [Registry.artifacts.size(), Config.ARTIFACTS.size()])
		return

	# ---- 验证点 4：合法注册 + 清理还原 ----
	var ok_art := { "id": "art_smoke_ok", "name": "冒烟法宝", "ico": "🧪", "element": "wood",
		"rarity": "rare", "trigger": "on_wave_end", "params": {},
		"effect": { "heal_pct": 0.05 }, "price": 150, "shop_weight": 1.0, "desc": "测试用" }
	if not Registry.register_artifact(ok_art.duplicate(true)):
		_fail("Registry 拒绝了合法法宝")
		return
	if Registry.artifacts.size() != Config.ARTIFACTS.size() + 1 \
			or Registry.get_artifact("art_smoke_ok").is_empty():
		_fail("合法法宝未进入注册表（%d）" % Registry.artifacts.size())
		return
	Registry.artifacts.erase("art_smoke_ok")
	if Registry.artifacts.size() != Config.ARTIFACTS.size() \
			or not Registry.get_artifact("art_smoke_ok").is_empty():
		_fail("清理临时法宝后注册表未还原（%d）" % Registry.artifacts.size())
		return

	# ---- 验证点 5：获取规则（抽取池 / BOSS 权重 / 三渠道常量 / 精英掉落实跑）----
	# 品阶门槛（Phase 6 平衡）：低波次高品阶权重为 0，法宝池只含白/蓝；
	# 到后期（wave>=9）全部品阶解锁，池才完整
	var low_rarity_count := 0
	for a in Config.ARTIFACTS:
		if String(a.get("rarity", "common")) in ["common", "rare"]:
			low_rarity_count += 1
	if Registry.artifact_pool({}, 1, false).size() != low_rarity_count:
		_fail("初始抽取池应只含白/蓝品阶法宝（%d / %d）"
			% [Registry.artifact_pool({}, 1, false).size(), low_rarity_count])
		return
	if Registry.artifact_pool({}, 9, false).size() != Config.ARTIFACTS.size():
		_fail("后期抽取池不是全部法宝（%d / %d）"
			% [Registry.artifact_pool({}, 9, false).size(), Config.ARTIFACTS.size()])
		return
	var pool_less: Array = Registry.artifact_pool({ "art_cinder_seal": 1 }, 9, false)
	if pool_less.size() != Config.ARTIFACTS.size() - 1 or _pool_has(pool_less, "art_cinder_seal"):
		_fail("抽取池未排除已持有法宝（%d 件）" % pool_less.size())
		return
	var owned_all := {}
	for aid3 in Registry.artifacts:
		owned_all[String(aid3)] = 1
	if not Registry.artifact_pool(owned_all, 1, false).is_empty():
		_fail("全部持有时抽取池应为空（BOSS 兜底补偿分支走不到）")
		return
	var w_norm := _pool_weight(Registry.artifact_pool({}, 10, false), "art_titan_core")
	var w_boss := _pool_weight(Registry.artifact_pool({}, 10, true), "art_titan_core")
	var c_norm := _pool_weight(Registry.artifact_pool({}, 10, false), "art_cinder_seal")
	var c_boss := _pool_weight(Registry.artifact_pool({}, 10, true), "art_cinder_seal")
	if w_norm <= 0.0 or not is_equal_approx(w_boss, w_norm * Config.ARTIFACT_BOSS_LEGENDARY_MULT):
		_fail("BOSS 池 legendary 权重未按倍率提升（%.4f -> %.4f）" % [w_norm, w_boss])
		return
	if not is_equal_approx(c_norm, c_boss):
		_fail("BOSS 池不应改动非 legendary 权重（%.4f -> %.4f）" % [c_norm, c_boss])
		return
	if Config.ARTIFACT_ELITE_DROP_CHANCE <= 0.0 or Config.ARTIFACT_ELITE_DROP_CHANCE > 0.5 \
			or Config.ARTIFACT_SHOP_CHANCE <= 0.0 or Config.ARTIFACT_SHOP_CHANCE > 0.5 \
			or Config.ARTIFACT_DUP_MATERIALS <= 0:
		_fail("获取渠道常量越界（elite=%.2f shop=%.2f dup=%d）"
			% [Config.ARTIFACT_ELITE_DROP_CHANCE, Config.ARTIFACT_SHOP_CHANCE,
				Config.ARTIFACT_DUP_MATERIALS])
		return
	if Registry.artifact_pool(p2.artifacts_owned, sys.wave, false).is_empty():
		_fail("精英掉落前置不成立：玩家已集齐全部法宝")
		return
	# 精英掉落实跑：直接调 _drop_loot 而非 die()，避开击杀统计与 AI 副作用。
	# 120 次抽样下「一件不掉」的概率 = 0.88^120 ≈ 2e-7，足以判定概率生效
	var e_elite: Node2D = _spawn_reaction_target("grunt", far_corner, p2)
	made.append(e_elite)
	e_elite.elite = true
	var art_drops := 0
	var loot_pre: Array = get_tree().get_nodes_in_group("loot")
	for i in 120:
		e_elite._drop_loot()
	for l in get_tree().get_nodes_in_group("loot"):
		if loot_pre.has(l):
			continue
		if String(l.kind) == "artifact":
			art_drops += 1
			if not Registry.artifacts.has(String(l.artifact_id)):
				_fail("精英掉落的法宝 id 非法：%s" % String(l.artifact_id))
				return
		# 立即出组：queue_free 要到帧末才生效，而本用例全程同步不跨帧，
		# 不出组的话下一轮 diff 会把这批旧掉落当成新掉落，反证用例必假失败
		l.remove_from_group("loot")
		l.queue_free()
	if art_drops <= 0:
		_fail("精英怪 120 次掉落未产出任何法宝（概率 %.2f 未生效）"
			% Config.ARTIFACT_ELITE_DROP_CHANCE)
		return
	# 反证：普通怪不掉法宝（elite 标志位是唯一判据，不按敌人类型）
	e_elite.elite = false
	var loot_pre2: Array = get_tree().get_nodes_in_group("loot")
	for i2 in 40:
		e_elite._drop_loot()
	for l2 in get_tree().get_nodes_in_group("loot"):
		if loot_pre2.has(l2):
			continue
		if String(l2.kind) == "artifact":
			_fail("非精英怪不应掉法宝（elite 标志位判定失效）")
			return
		l2.remove_from_group("loot")
		l2.queue_free()

	# ---- 验证点 6：apply_artifact 幂等 + 重复转材料补偿 ----
	# 刻意不硬编码法宝 id：前置的精英掉落与波末自动回收会随机送出法宝，
	# 一旦硬编码的那件已经被玩家拿到，本用例必然失败（5 件常驻普品 → 约 1/5 概率）。
	# 这里动态取一件当前确定未持有的法宝
	var fresh_artifact := ""
	for cand in Registry.artifacts:
		if not p2.artifacts_owned.has(String(cand)):
			fresh_artifact = String(cand)
			break
	if fresh_artifact == "":
		_fail("找不到未持有的法宝用于幂等验证")
		return
	var acquired: Array = []
	var acq_cb := func(id: String) -> void:
		acquired.append(id)
	EventBus.artifact_acquired.connect(acq_cb)
	if not p2.apply_artifact(fresh_artifact):
		_fail("apply_artifact 首次获得应返回 true（%s）" % fresh_artifact)
		return
	if p2.artifacts_owned.size() != owned_before.size() + 1 or acquired.size() != 1:
		_fail("首次获得未入账/未发 artifact_acquired（%d 件，信号 %d 次）"
			% [p2.artifacts_owned.size(), acquired.size()])
		return
	var mats_first: int = GameState.materials
	if p2.apply_artifact(fresh_artifact):
		_fail("重复获得应返回 false")
		return
	if p2.artifacts_owned.size() != owned_before.size() + 1:
		_fail("重复获得不应增加持有数")
		return
	if GameState.materials != mats_first + Config.ARTIFACT_DUP_MATERIALS:
		_fail("重复获得未转材料补偿（%d -> %d，期望 +%d）"
			% [mats_first, GameState.materials, Config.ARTIFACT_DUP_MATERIALS])
		return
	if acquired.size() != 1:
		_fail("重复获得不应再发 artifact_acquired（会重复弹 toast）")
		return
	if p2.apply_artifact("art_not_exist"):
		_fail("非法法宝 id 不应入账")
		return
	EventBus.artifact_acquired.disconnect(acq_cb)

	# ---- 验证点 7：图鉴集成 ----
	if not CodexData.CATEGORIES.has("artifact"):
		_fail("图鉴分类缺少 artifact")
		return
	if CodexData.total_entries("artifact") != Registry.artifacts.size():
		_fail("图鉴 artifact 条目数不对（%d）" % CodexData.total_entries("artifact"))
		return
	if CodexData.display_name("artifact", "art_cinder_seal") != "焚天印" \
			or CodexData.display_icon("artifact", "art_cinder_seal") != "🔥":
		_fail("图鉴 artifact 数据源不对")
		return
	if not CodexData.is_unlocked("artifact", fresh_artifact):
		_fail("获得法宝未解锁图鉴（%s）" % fresh_artifact)
		return
	var art_reward: int = CodexData.unlock_reward("artifact")
	if art_reward < 4 or art_reward > 7:
		_fail("法宝图鉴解锁奖励超出平衡范围（%d）" % art_reward)
		return

	# ---- 验证点 9：触发器实跑（熔金炉把火克金强化到 80% / 5s）----
	var base_fm: Dictionary = Config.REACTIONS["fire+metal"].get("effect", {})
	if not is_equal_approx(float(base_fm.get("armor_break", 0.0)), 0.5):
		_fail("火克金基准破甲不是 50%%，法宝断言失去参照（%s）" % str(base_fm))
		return
	p2.apply_artifact("art_molten_crucible")
	var patched: Dictionary = ArtifactSystem.patch_reaction_effect(p2, "fire+metal", base_fm)
	if not is_equal_approx(float(patched.get("armor_break", 0.0)), 0.8) \
			or not is_equal_approx(float(patched.get("armor_break_duration", 0.0)), 5.0):
		_fail("熔金炉未把火克金强化到 80%%/5s（%s）" % str(patched))
		return
	if not is_equal_approx(float(base_fm.get("armor_break", 0.0)), 0.5):
		_fail("patch 污染了 Config 原数据（下一局会从错误基准开始）")
		return
	# 端到端：目标真的吃到 ×1.8 受伤
	var e_m: Node2D = _spawn_reaction_target("grunt", far_corner + Vector2(-60.0, 0.0), p2)
	made.append(e_m)
	e_m.apply_status("burn", 2, 0.0, 50.0, 1.0)
	e_m.apply_status("bleed", 1, 0.0, 40.0, 1.0)
	if not is_equal_approx(e_m._damage_taken_mult(), 1.8):
		_fail("熔金炉未在实战中生效（×%.2f，期望 ×1.80）" % e_m._damage_taken_mult())
		return

	# ---- 焚天印：火系反应追加 40% 攻击力伤害 ----
	# 前置（2026-09-19）：loot 预算闸（Config.LOOT_MAX）让击杀经验可即时入账，
	# 测试走到这里时可能已弹出升级卡（phase=LEVEL_UP）——而法宝反应处理要求战斗态
	# （_active() 判 is_running()）。“升级卡打开时战斗暂停”是正确设计，这里按现实
	# 流程收尾：恢复战斗态 + 清掉积压的选卡队列，回到可以验证反应伤害的上下文。
	GameState.level_queue = 0   # 先清队列：防止 set_phase(PLAYING) 触发补弹又开一张卡
	if GameState.phase != GameState.Phase.PLAYING:
		GameState.set_phase(GameState.Phase.PLAYING)
	var _lu2: Control = _main.get_node("UI/LevelUp")
	_lu2.visible = false        # 已弹出的升级卡收掉，回到干净的战斗上下文
	var e_c: Node2D = _spawn_reaction_target("grunt", far_corner + Vector2(-120.0, 0.0), p2)
	made.append(e_c)
	var ap: float = ArtifactSystem.attack_power(p2)
	if ap <= 0.0:
		_fail("攻击力基准为 0，焚天印无法验证（玩家是否装备武器）")
		return
	var hp_c: float = e_c.hp
	sys._on_element_reaction("fire_metal", e_c.global_position, [e_c])
	if not is_equal_approx(hp_c - e_c.hp, ap * 0.40):
		_fail("焚天印追加伤害错误（%.2f，期望 %.2f）" % [hp_c - e_c.hp, ap * 0.40])
		return
	if int(sys.proc_log.get("art_cinder_seal", 0)) <= 0:
		_fail("焚天印未计入 proc_log（%s）" % str(sys.proc_log))
		return

	# ---- 玄武核：土系反应叠「磐石」（run 档，wave 重置不动它）----
	p2.apply_artifact("art_titan_core")
	var armor_base: float = float(p2.stats.armor)
	sys._on_element_reaction("earth_water", e_c.global_position, [e_c])
	if int(p2.artifact_stacks.get("art_titan_core", 0)) != 1 \
			or not is_equal_approx(float(p2.stats.armor), armor_base + 1.5):
		_fail("玄武核未叠磐石（层数 %d，护甲 %.2f，期望 1 / %.2f）"
			% [int(p2.artifact_stacks.get("art_titan_core", 0)),
				float(p2.stats.armor), armor_base + 1.5])
		return

	# ---- 验证点 10：断刃锋 on_kill 实跑 + wave/run 两档层数重置 ----
	p2.apply_artifact("art_notch_blade")
	var crit_base: float = float(p2.stats.crit_ch)
	# ⚠️ 2026-09-17（第 7 轮）：期望值原先硬编码 `crit_base + 0.04` —— 本轮把
	#    `art_notch_blade.effect.per_stack` 减半（0.04 → 0.02）后这条就会红，
	#    而红的原因不是"叠层没生效"，是"断言抄了一份会过期的数字"。
	#    → 改为**从被测条目自身读**，以后调数值不再需要动断言。
	var notch_per: float = float(
		Registry.get_artifact("art_notch_blade").get("effect", {}).get("per_stack", 0.0))
	var e_kill: Node2D = _spawn_reaction_target("grunt", far_corner + Vector2(-180.0, 0.0), p2)
	made.append(e_kill)
	e_kill.hp = 1.0
	e_kill.apply_status("bleed", 1, 0.0, 40.0, 1.0)
	e_kill.take_damage(50.0, false, false)   # 走真实 die()，验证 enemy_died 确实发出
	if int(p2.artifact_stacks.get("art_notch_blade", 0)) != 1 \
			or not is_equal_approx(float(p2.stats.crit_ch), crit_base + notch_per):
		_fail("断刃锋击杀流血敌人未叠暴击（层数 %d，暴击 %.3f，期望 1 / %.3f）"
			% [int(p2.artifact_stacks.get("art_notch_blade", 0)),
				float(p2.stats.crit_ch), crit_base + notch_per])
		return
	# params.status 过滤：击杀不带流血的敌人不叠层
	var e_plain: Node2D = _spawn_reaction_target("grunt", far_corner + Vector2(-240.0, 0.0), p2)
	made.append(e_plain)
	e_plain.hp = 1.0
	e_plain.take_damage(50.0, false, false)
	if int(p2.artifact_stacks.get("art_notch_blade", 0)) != 1:
		_fail("params.status 过滤失效：击杀非流血敌人也叠了层")
		return
	# 直接调 _on_wave_started/_on_run_started 而非发全局信号：避免波次状态被本用例打乱
	sys._on_wave_started(5)
	if int(p2.artifact_stacks.get("art_notch_blade", 0)) != 0 \
			or not is_equal_approx(float(p2.stats.crit_ch), crit_base):
		_fail("wave 档层数未随波次开始重置（%s crit=%.3f）"
			% [str(p2.artifact_stacks), float(p2.stats.crit_ch)])
		return
	if int(p2.artifact_stacks.get("art_titan_core", 0)) != 1:
		_fail("run 档叠层被 wave_started 误清")
		return
	sys._on_run_started()
	if int(p2.artifact_stacks.get("art_titan_core", 0)) != 0 \
			or not is_equal_approx(float(p2.stats.armor), armor_base):
		_fail("run_started 未清空 run 档层数/属性（armor=%.2f，期望 %.2f）"
			% [float(p2.stats.armor), armor_base])
		return
	if sys.wave != 1 or not sys.proc_log.is_empty():
		_fail("run_started 未重置波次与触发计数")
		return

	# ---- 验证点 8：存档往返（含非法 id 丢弃）----
	# 必须换独立存储根：本用例的 clear/save 会抹掉商店阶段写进槽 1 的自动存档，
	# 而后续「三槽存档验证」断言 SaveRun.exists(1) —— 同根跑必然假失败。
	# current_run_owns_slot 是跨根的全局标志（save/restore 置真、clear 置假），一并快照归还。
	var owns_before: bool = SaveRun.current_run_owns_slot
	SaveRun.set_storage_root_for_tests(TEST_SAVE_ROOT + "_artifact")
	p2.apply_artifact("art_notch_blade")
	p2.add_artifact_stacks("art_notch_blade", 3)
	var crit_saved: float = float(p2.stats.crit_ch)
	GameState.slot_id = 1
	SaveRun.clear()
	if not SaveRun.save(5, p2):
		_fail("含法宝的存档写入失败")
		return
	var slot_path := SaveRun.slot_path(1)
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(slot_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail("存档 JSON 解析失败")
		return
	var pdata: Dictionary = parsed
	var pl_save: Dictionary = pdata.get("player", {})
	if not pl_save.has("artifacts_owned") or not pl_save.has("artifact_stacks"):
		_fail("存档未序列化法宝持有表/层数（叠层属性会重复加成）")
		return
	if not (pl_save.artifacts_owned as Dictionary).has("art_notch_blade") \
			or int((pl_save.artifact_stacks as Dictionary).get("art_notch_blade", 0)) != 3:
		_fail("存档里的法宝层数不对（%s）" % str(pl_save.artifact_stacks))
		return
	p2.artifacts_owned = {}
	p2.artifact_stacks = {}
	if SaveRun.restore(p2) != 5:
		_fail("含法宝的存档恢复失败")
		return
	if not p2.artifacts_owned.has("art_notch_blade") \
			or int(p2.artifact_stacks.get("art_notch_blade", 0)) != 3 \
			or not is_equal_approx(float(p2.stats.crit_ch), crit_saved):
		_fail("存档往返后法宝/层数/属性丢失（%s / %s / %.3f）"
			% [str(p2.artifacts_owned.keys()), str(p2.artifact_stacks), float(p2.stats.crit_ch)])
		return
	# mod 卸载后存档里的法宝失效：静默丢弃，不崩档
	(pl_save.artifacts_owned as Dictionary)["art_ghost"] = 1
	(pl_save.artifact_stacks as Dictionary)["art_ghost"] = 7
	var fw := FileAccess.open(slot_path, FileAccess.WRITE)
	if fw == null:
		_fail("无法回写存档做非法 id 用例")
		return
	fw.store_string(JSON.stringify(pdata))
	fw.close()
	p2.artifacts_owned = {}
	p2.artifact_stacks = {}
	if SaveRun.restore(p2) != 5:
		_fail("含非法法宝 id 的存档应仍能恢复波次")
		return
	if p2.artifacts_owned.has("art_ghost") or p2.artifact_stacks.has("art_ghost"):
		_fail("非法法宝 id 未被丢弃（mod 卸载会崩档）")
		return
	if not p2.artifacts_owned.has("art_notch_blade"):
		_fail("丢弃非法 id 时误伤了合法法宝")
		return
	SaveRun.clear()
	SaveRun.set_storage_root_for_tests(TEST_SAVE_ROOT)
	SaveRun.current_run_owns_slot = owns_before

	# ---- 还原：RNG / 计数器 / 玩家状态一律回滚，本用例对后续断言零残留 ----
	for e in made:
		if e != null and is_instance_valid(e):
			e.queue_free()
	for l3 in get_tree().get_nodes_in_group("loot"):
		if not loot_before.has(l3):
			l3.queue_free()
	GameRng._a = rng_a
	GameState.kills = kills_before
	GameState.set_materials(mats_before)
	GameState.slot_id = slot_before
	CodexData.add_stat("kills", codex_kills_before - CodexData.stat("kills"))
	p2.artifacts_owned = owned_before
	p2.artifact_stacks = stacks_before
	p2.stats = stats_before
	p2.weapons = weapons_before
	p2.items_owned = items_before
	p2.hp = hp_before
	GameState.set_phase(phase_before)
	print("SMOKE: Phase 3 artifacts OK")

## Phase 3 内容填充验收（规划第 1-5 项）：数量下限 + 新增 id 齐全 + 数据自洽。
## 最有价值的是「effect/stats 键必须能被 player.stats 接住」——
## 键名写错不会报错，只会往 stats 里塞一个永远不参与计算的垃圾键，属于静默失效
func _check_phase3_content() -> void:
	var p3: Node2D = _main.get_node("Player")
	# ---- 数量下限（取规划 Phase 3 目标区间的下沿）----
	#
	# ⚠️⚠️ 「内置」与「Registry 总量」必须分开 —— 这是 S2 反复踩的同一个坑：
	#    `Registry.characters/weapons` 是**内置 + 所有已加载 mod** 的合并结果，
	#    而 S2 的验收目标是「**内置**恰好 6 角色 / 5 武器」。直接拿 Registry 总量去比
	#    内置目标，会在工坊包加载后必然失败（实测 17 角色 / 29 武器）。
	#    → 内置判据：条目**不带 `source` 字段**（`_apply_manifest` 只给 mod 条目打
	#      `entry["source"] = mod_name`，`_register_builtin` 不打）。
	var chars := 0
	for cid in Registry.characters:
		if not Registry.characters[cid].has("source"):
			chars += 1
	var weapons := 0
	for wid in Registry.weapons:
		if not Registry.weapons[wid].has("source"):
			weapons += 1
	var mod_chars: int = Registry.characters.size() - chars
	var mod_weapons: int = Registry.weapons.size() - weapons
	var items: int = Registry.items.size()
	var enemies: int = Registry.enemies.size()
	var bosses := 0
	for eid in Registry.enemies:
		var ecfg: Dictionary = Registry.enemies[eid]
		if bool(ecfg.get("is_boss", false)) or String(ecfg.get("ai", "")) == "boss":
			bosses += 1
	var plain_enemies := enemies - bosses
	# S2 验收锚：内置角色必须**恰好**是 6；内置武器必须**恰好**是 `Config.WEAPONS` 全表
	# —— 既能抓「收缩漏了」，也能抓「哪天又往内置塞回去」。
	#
	# ⚠️ 2026-09-17 S8：武器这条的口径从「== `LOADOUT_WEAPONS.size()`（5）」改成
	#    「== `Config.WEAPONS.size()`」—— S8 补回了 5 个五行**进化形态**，它们是
	#    内置条目但不进开局池，所以内置武器从 5 变 10，写死 5 必红。
	#    ⚠️ 只把 5 改成 10 也是错的：`Config.WEAPONS.size()` 才能顺带抓住
	#    「进化形态被 Registry 静默拒登」（数值越界 → 跳过 → 数量对不上）。
	if chars != 6:
		_fail("内置角色应为 6（S2 收缩目标），实为 %d（另加 mod %d 个）" % [chars, mod_chars])
		return
	if weapons != Config.WEAPONS.size():
		_fail("内置武器应为 %d（5 五行 + 5 进化形态），实为 %d（另加 mod %d 把）"
			% [Config.WEAPONS.size(), weapons, mod_weapons])
		return
	# 开局池必须严格是「5 把基础五行武器」：进化形态只能靠合成拿，不能开局白送
	for lod_wid in Config.LOADOUT_WEAPONS:
		var lod_cfg: Dictionary = Config.WEAPONS.get(String(lod_wid), {})
		if lod_cfg.is_empty():
			_fail("开局武器 %s 不在 Config.WEAPONS 里" % String(lod_wid))
			return
		if int(lod_cfg.get("evolve_need", 0)) <= 0:
			_fail("开局武器 %s 缺进化配置（S8 后 5 把基础武器都应可进化）" % String(lod_wid))
			return
		if float(lod_cfg.get("shop_weight", 0.0)) <= 0.0:
			_fail("开局武器 %s 的 shop_weight 必须 > 0（刷不到就永远凑不满 3 把）" % String(lod_wid))
			return
	# 工坊包与示例 mod 必须真的加载进来（否则上面两条会因为"没有 mod"而恰好相等，
	# 把「mod 链路断了」伪装成「收缩成功」）
	if mod_weapons < 1 or not Registry.weapons.has("laser"):
		_fail("示例 mod 武器 laser 未加载（mod 武器数 %d）" % mod_weapons)
		return
	# ⚠️ 2026-09-17（第 7 轮）：官方工坊包 `brotato_lite_core`（11 个旧角色 + 23 把旧武器）
	#    已按用户要求**移出** `game/mods/`，搬到 `game/mods_disabled/brotato_lite_core/`。
	#    生效机制：`_load_mod_dir` 只扫 `res://mods` / `user://mods` 两个 base
	#    （`registry.gd:146`），所以放回 mods/ 之外 = 彻底不加载。
	#    原断言「mod_chars >= 11」是**那个阶段**的验收锚，现在要守的是相反的事：
	#    「哪天有人把目录挪回去，池子会悄悄又长回来」——所以改成反向断言。
	#    ⚠️ 两侧缺一不可：只留上面的 `laser` 会把「包被挪回来」判绿；
	#       只留这条会把「mod 链路整条断了」判绿。必须一正一反同真。
	if Registry.characters.has("pyromancer") or Registry.weapons.has("pistol"):
		_fail("工坊包 brotato_lite_core 已移出 game/mods/，其角色/武器不该再注册（pyromancer=%s / pistol=%s）"
			% [str(Registry.characters.has("pyromancer")), str(Registry.weapons.has("pistol"))])
		return
	if items < 30:
		_fail("道具数量未达 Phase 3 目标（%d < 30）" % items)
		return
	if plain_enemies < 10 or bosses < 2:
		_fail("敌人/BOSS 数量未达 Phase 3 目标（普通 %d / BOSS %d）"
			% [plain_enemies, bosses])
		return
	if Config.MAP_THEMES.size() < 2:
		_fail("地图主题未达 Phase 3 目标（%d < 2）" % Config.MAP_THEMES.size())
		return
	print("SMOKE: phase3 counts chars=%d weapons=%d items=%d enemies=%d bosses=%d themes=%d"
		% [chars, weapons, items, plain_enemies, bosses, Config.MAP_THEMES.size()])
	# ---- 自洽 0：Config 里声明的内容必须全部通过注册校验 ----
	# 注册表对数值有范围约束（如 bspeed ≤ 1200、price ≤ 300），越界只会 push_warning 后跳过，
	# 如果没人断言，武器就「悄悄消失」了——本次 railgun 弹速写 1500 就这么被吞掉过
	if Registry.weapons.size() < Config.WEAPONS.size():
		_fail("有武器未通过注册校验（Registry %d < Config %d），检查数值是否越界"
			% [Registry.weapons.size(), Config.WEAPONS.size()])
		return
	if Registry.items.size() < Config.ITEMS.size():
		_fail("有道具未通过注册校验（Registry %d < Config %d）"
			% [Registry.items.size(), Config.ITEMS.size()])
		return
	if Registry.upgrades.size() < Config.UPGRADES.size():
		_fail("有升级未通过注册校验（Registry %d < Config %d）"
			% [Registry.upgrades.size(), Config.UPGRADES.size()])
		return
	if Registry.enemies.size() < Config.ENEMIES.size():
		_fail("有敌人未通过注册校验（Registry %d < Config %d）"
			% [Registry.enemies.size(), Config.ENEMIES.size()])
		return
	# ---- 新增内容 id 齐全（S2 后：内置只认 6 角色 + 5 武器；冻结内容归工坊包）----
	for cid in ["potato", "metal_adept", "wood_adept", "water_adept", "fire_adept", "earth_adept"]:
		if not Registry.characters.has(cid):
			_fail("内置角色缺失：%s" % cid)
			return
	for wid in Config.LOADOUT_WEAPONS:
		if not Registry.weapons.has(String(wid)):
			_fail("内置五行武器缺失：%s" % String(wid))
			return
	for iid in ["i-warden", "i-hunter", "i-lodestone", "i-thorn", "i-feather",
			"i-focus", "i-plaguevial", "i-sunstone"]:
		if not Registry.items.has(iid):
			_fail("新增道具缺失：%s" % iid)
			return
	# ---- 自洽 1：每个角色都必须带合法专属特性（特性是角色差异化的唯一载体）----
	for cid2 in Registry.characters:
		var c: Dictionary = Registry.characters[cid2]
		var tr2: Dictionary = c.get("trait", {})
		if tr2.is_empty() or String(tr2.get("kind", "")) not in Registry.TRAIT_KINDS:
			_fail("角色 %s 的专属特性缺失或 kind 非法" % String(cid2))
			return
	# ---- 自洽 2：所有 effects / stats 键都必须落在 player.stats 已知键内 ----
	var valid := {}
	for k in p3.stats:
		valid[String(k)] = true
	valid["heal_flat"] = true   # apply_effects / apply_upgrade 的两个特例键
	valid["heal_pct"] = true
	var bad: Array = []
	for iid2 in Registry.items:
		for k2 in Registry.items[iid2].get("effects", {}):
			if not valid.has(String(k2)):
				bad.append("item %s → %s" % [String(iid2), String(k2)])
	for up in Registry.upgrades:
		for k3 in Registry.upgrades[up].get("effects", {}):
			if not valid.has(String(k3)):
				bad.append("upgrade %s → %s" % [String(up), String(k3)])
	for cid3 in Registry.characters:
		for k4 in Registry.characters[cid3].get("stats", {}):
			if not valid.has(String(k4)):
				bad.append("character %s → %s" % [String(cid3), String(k4)])
	if not bad.is_empty():
		_fail("存在拼写错误/未接线的效果键：%s" % ", ".join(bad))
		return
	print("SMOKE: effect keys OK (%d valid keys)" % valid.size())
	# ---- 自洽 3：武器价格与商店权重已内联进 WEAPONS（单表真值），注册后必须可读 ----
	for wid2 in Config.WEAPONS:
		var wdata: Dictionary = Registry.weapons.get(String(wid2), {})
		if not wdata.has("price") or not wdata.has("shop_weight"):
			_fail("武器 %s 注册后缺少 price 或 shop_weight" % String(wid2))
			return
		if float(wdata.get("shop_weight", -1.0)) < 0.0:
			_fail("武器 %s 的 shop_weight 为负" % String(wid2))
			return
	# ---- 自洽 4：每日挑战角色池必须覆盖全部已注册角色（防新增角色漏加，漏了完全静默）----
	#
	# ⚠️ 五行体系第 6 轮拍板：**每日挑战整体冻结**（§3.2.5）。
	#    `Config.DAILY_CHARACTERS` 保留常量但**不再被读取** —— 冻结期它的内容与
	#    当前角色池无关，若继续断言「池子 == 注册数」，就会在收缩到 6 角色时误报红。
	#    故改为：**池子只允许包含已注册角色**（这是它解冻后仍必须成立的不变式），
	#    同时断言「冻结使得它未被读取」这一状态 —— 见下方 daily_setup 的守卫断言。
	var pool_unknown: Array = []
	for cid_d in Config.DAILY_CHARACTERS:
		if not Registry.characters.has(String(cid_d)):
			pool_unknown.append(String(cid_d))
	if not pool_unknown.is_empty():
		_fail("每日挑战角色池含未注册角色：%s（解冻前须与内置角色池对齐）"
			% ", ".join(pool_unknown))
		return
	print("SMOKE: phase 3 content OK")

## 江湖奇遇事件卡（Phase 4）：数据完整性 / 抽取池 / UI 可负担性 / 效果执行 / 图鉴 / 触发门控
## 注意：不在这里真正走 shop_ui.next_wave() → start_wave()，否则会把当前波次重置，
## 后续「触控驱动移动」「暂停面板」等用例会因阶段退回 INTRO 而误报。
## 波次推迟的契约由 _suppress_event_cards + _pending_wave_after_event 归零共同验证。
func _check_event_cards() -> void:
	# S3.5 起为 11 张（新增 `ev_origin_dao`，覆盖第 5 区块主题「归元道场」——
	# 主题扩到 5 个后若不加卡，`theme_seen` 的覆盖断言会先红，且第五区全程无奇遇）
	if Config.EVENT_CARDS.size() != 11:
		_fail("奇遇事件卡数量不对（%d，应为 11）" % Config.EVENT_CARDS.size())
		return
	var choice_total := 0
	var theme_seen := {}
	for ec in Config.EVENT_CARDS:
		var cid := String(ec.get("id", ""))
		if cid == "" or String(ec.get("title", "")) == "" or String(ec.get("desc", "")) == "":
			_fail("奇遇卡缺少 id/title/desc（%s）" % cid)
			return
		var theme_id := String(ec.get("theme", ""))
		if not Config.MAP_THEMES.has(theme_id):
			_fail("奇遇卡 theme 非法（%s → %s）" % [cid, theme_id])
			return
		theme_seen[theme_id] = true
		if not Config.RARITIES.has(String(ec.get("rarity", ""))):
			_fail("奇遇卡 rarity 非法（%s → %s）" % [cid, String(ec.get("rarity", ""))])
			return
		var cs: Array = ec.get("choices", [])
		if cs.size() != 3:
			_fail("奇遇卡选项数不是 3（%s → %d）" % [cid, cs.size()])
			return
		for ch in cs:
			if String(ch.get("text", "")) == "" or String(ch.get("hint", "")) == "":
				_fail("奇遇选项缺少 text/hint（%s）" % cid)
				return
			if typeof(ch.get("effect")) != TYPE_DICTIONARY:
				_fail("奇遇选项 effect 不是字典（%s）" % cid)
				return
		choice_total += cs.size()
	if theme_seen.size() != Config.MAP_THEMES.size():
		_fail("奇遇卡未覆盖全部地图主题（%d/%d）" % [theme_seen.size(), Config.MAP_THEMES.size()])
		return
	# 每张卡至少有一个无前置消耗的选项：资源枯竭时全部禁用会让玩家卡在事件里
	for ec2 in Config.EVENT_CARDS:
		var free_ok := false
		for ch2 in ec2.get("choices", []):
			var ef: Dictionary = ch2.get("effect", {})
			if int(ef.get("cost_materials", 0)) <= 0 and float(ef.get("hp_pct_cost", 0.0)) <= 0.0:
				free_ok = true
				break
		if not free_ok:
			_fail("奇遇卡没有免费选项，资源不足时会卡死（%s）" % String(ec2.get("id", "")))
			return
	print("SMOKE: event cards data OK (%d cards / %d choices)"
		% [Config.EVENT_CARDS.size(), choice_total])
	# ---- 抽取池：10 张全覆盖，已见的被排除 ----
	var pool_all: Array = Config.event_card_pool([], 1)
	if pool_all.size() != Config.EVENT_CARDS.size():
		_fail("奇遇抽取池未覆盖全部卡（%d）" % pool_all.size())
		return
	var first_id := String(Config.EVENT_CARDS[0].get("id", ""))
	if Config.event_card_pool([first_id], 1).size() != Config.EVENT_CARDS.size() - 1:
		_fail("奇遇抽取池未排除已出现的卡")
		return
	var pulled: Dictionary = GameRng.weighted_pick(pool_all)
	if pulled.is_empty() or String(pulled.get("id", "")) == "":
		_fail("奇遇加权抽取未返回合法卡片")
		return
	# ---- 概率与每局上限（验证点：30% + 3~5 次）----
	if not is_equal_approx(Config.EVENT_CARD_CHANCE, 0.30):
		_fail("奇遇触发概率不是 30%%（当前 %.2f）" % Config.EVENT_CARD_CHANCE)
		return
	if Config.EVENT_CARD_MIN != 3 or Config.EVENT_CARD_MAX != 5:
		_fail("奇遇每局上限区间不是 3~5（%d~%d）"
			% [Config.EVENT_CARD_MIN, Config.EVENT_CARD_MAX])
		return
	if GameState.event_card_cap < Config.EVENT_CARD_MIN \
			or GameState.event_card_cap > Config.EVENT_CARD_MAX:
		_fail("奇遇每局上限未落在区间内（%d）" % GameState.event_card_cap)
		return
	# ---- 触发门控：次数顶满应当拒绝 ----
	var cap_before: int = GameState.event_card_cap
	var cnt_before: int = GameState.event_card_count
	GameState.event_card_count = GameState.event_card_cap
	if _main.try_trigger_event_card(2):
		_fail("奇遇次数已达上限仍然触发")
		return
	GameState.event_card_count = cnt_before
	# ---- UI：三选一构建 + 代价类选项的可负担性 ----
	var ui: Control = _main.event_card_ui
	if ui == null:
		_fail("主场景未挂载奇遇事件卡 UI")
		return
	var paid_card := Config.event_card("ev_ghost_lantern")   # 选项 0 = 消耗 60 ◆
	if paid_card.is_empty():
		_fail("找不到含代价选项的奇遇卡 ev_ghost_lantern")
		return
	var mats_saved: int = GameState.materials
	var hp_saved: float = _main.get_node("Player").hp
	GameState.set_materials(0)
	ui.open(paid_card)
	if ui.choice_count() != 3:
		_fail("奇遇 UI 未构建 3 个选项（%d）" % ui.choice_count())
		return
	if ui.is_choice_enabled(0):
		_fail("材料不足时消耗型选项应禁用")
		return
	if not ui.is_choice_enabled(1):
		_fail("免费选项不应被禁用")
		return
	GameState.set_materials(1000)
	ui.open(paid_card)
	if not ui.is_choice_enabled(0):
		_fail("材料充足时消耗型选项应可选")
		return
	ui.visible = false
	GameState.set_materials(mats_saved)
	# ---- 效果执行：逐个载荷键 ----
	var p_ev: Node2D = _main.get_node("Player")
	var m0: int = GameState.materials
	_main._execute_event_effect({ "grant_materials": 55 })
	if GameState.materials != m0 + 55:
		_fail("奇遇 grant_materials 未生效（%d → %d）" % [m0, GameState.materials])
		return
	m0 = GameState.materials
	_main._execute_event_effect({ "cost_materials": 30 })
	if GameState.materials != m0 - 30:
		_fail("奇遇 cost_materials 未扣费（%d → %d）" % [m0, GameState.materials])
		return
	var dmg0: float = float(p_ev.stats.dmg_mult)
	_main._execute_event_effect({ "effects": { "dmg_mult": 0.18 } })
	if not is_equal_approx(float(p_ev.stats.dmg_mult), dmg0 + 0.18):
		_fail("奇遇属性增益未生效（%.2f → %.2f）" % [dmg0, float(p_ev.stats.dmg_mult)])
		return
	# 生命代价必须保底 1 点：代价型选项不能变成自杀键
	p_ev.hp = 50.0
	_main._execute_event_effect({ "hp_pct_cost": 0.90 })
	if _main.get_node("Player").hp < 1.0:
		_fail("奇遇生命代价把玩家扣到 %.1f（应保底 1）" % _main.get_node("Player").hp)
		return
	# 按品阶发道具
	var item_total := 0
	for k_item in p_ev.items_owned:
		item_total += int(p_ev.items_owned[k_item])
	_main._execute_event_effect({ "grant_item_rarity": "epic" })
	var item_after := 0
	for k_item2 in p_ev.items_owned:
		item_after += int(p_ev.items_owned[k_item2])
	if item_after != item_total + 1:
		_fail("奇遇 grant_item_rarity 未按品阶发放（%d → %d）" % [item_total, item_after])
		return
	# 下波额外精英 + 免费升级（立即还原，避免污染后续升级 UI 与波次流程）
	var elite0: int = GameState.next_wave_elite
	_main._execute_event_effect({ "next_wave_elite": 2 })
	if GameState.next_wave_elite != elite0 + 2:
		_fail("奇遇 next_wave_elite 未累计（%d）" % GameState.next_wave_elite)
		return
	GameState.next_wave_elite = elite0
	var q0: int = GameState.level_queue
	_main._execute_event_effect({ "free_upgrade": 1 })
	if GameState.level_queue != q0 + 1:
		_fail("奇遇 free_upgrade 未入队（%d）" % GameState.level_queue)
		return
	GameState.level_queue = q0
	print("SMOKE: event card effects OK")
	# ---- 图鉴：event 分类 + 10 条目 + 解锁奖励与幂等 ----
	if not CodexData.CATEGORIES.has("event"):
		_fail("图鉴缺少 event 分类")
		return
	if CodexData.total_entries("event") != Config.EVENT_CARDS.size():
		_fail("图鉴奇遇条目数不对（%d）" % CodexData.total_entries("event"))
		return
	var ev_cat: String = "event"
	var ev_ess0: int = MetaProgress.essence
	if not CodexData.unlock(ev_cat, "ev_blood_moon"):
		_fail("图鉴奇遇解锁未生效")
		return
	if MetaProgress.essence <= ev_ess0:
		_fail("奇遇图鉴解锁未发放精华（%d → %d）" % [ev_ess0, MetaProgress.essence])
		return
	if CodexData.unlock(ev_cat, "ev_blood_moon"):
		_fail("重复解锁奇遇未保持幂等")
		return
	# ---- 完整链路：open → 三选一 → 效果 + 信号 + pending 消费 ----
	var sig_hits: Array = []
	var probe := func(cid2: String, choice2: String) -> void:
		sig_hits.append([cid2, choice2])
	EventBus.event_card_triggered.connect(probe)
	var chain_card := Config.event_card("ev_bamboo_spring")   # 选项 2 = 获得 55 ◆
	_main._pending_wave_after_event = 0   # 置零：收尾不应启动任何波次，避免扰动后续用例
	GameState.set_materials(0)
	ui.open(chain_card)
	ui._choose(2)
	EventBus.event_card_triggered.disconnect(probe)
	if ui.visible:
		_fail("奇遇选择后 UI 未关闭")
		return
	if sig_hits.size() != 1 or String(sig_hits[0][0]) != "ev_bamboo_spring":
		_fail("event_card_triggered 未按契约广播（%s）" % str(sig_hits))
		return
	if GameState.materials != 55:
		_fail("奇遇选项效果未执行（材料 %d，应为 55）" % GameState.materials)
		return
	if not CodexData.is_unlocked("event", "ev_bamboo_spring"):
		_fail("奇遇触发后未登记图鉴")
		return
	if _main._pending_wave_after_event != 0:
		_fail("奇遇收尾未消费 pending wave（%d）" % _main._pending_wave_after_event)
		return
	if CodexData.stat("events") <= 0:
		_fail("奇遇未累计统计 events")
		return
	# ---- 还原现场，避免污染后续用例 ----
	GameState.set_materials(mats_saved)
	GameState.event_card_cap = cap_before
	GameState.event_card_count = cnt_before
	p_ev.hp = minf(hp_saved, float(p_ev.stats.max_hp))
	print("SMOKE: event cards OK")

## 地图主题化（Phase 5）：主题数据 / 波次映射 / 氛围粒子。
## 地形（障碍物）系统已于 2026-09-14 整体移除，本检查随之收缩为
## 「主题表结构 + 波次映射 + 粒子装配」三件事，不再涉及地形几何。
func _check_map_themes() -> void:
	var wm: Node = _main.get_node("WaveManager")
	# ---- 主题数据与波次映射 ----
	if Config.MAP_THEMES.size() != 5 or Config.MAP_THEME_ORDER.size() != 5:
		_fail("地图主题数量不对（%d/%d，应为 5 = BLOCK_COUNT）"
			% [Config.MAP_THEMES.size(), Config.MAP_THEME_ORDER.size()])
		return
	if Config.MAP_THEMES.size() != Config.BLOCK_COUNT:
		_fail("主题数 %d 应等于区块数 %d（一区一景）"
			% [Config.MAP_THEMES.size(), Config.BLOCK_COUNT])
		return
	for tid in Config.MAP_THEMES:
		var t: Dictionary = Config.MAP_THEMES[tid]
		for key in ["name", "bg", "grid", "accent", "particle", "waves"]:
			if not t.has(key):
				_fail("地图主题 %s 缺字段 %s" % [String(tid), key])
				return
		# 反向断言：obstacle 字段必须保持不存在（地形系统已移除），防止死字段悄悄回流
		if t.has("obstacle"):
			_fail("地图主题 %s 仍带已废弃的 obstacle 字段（地形系统已移除）" % String(tid))
			return
	# 波 → 主题映射：**与 block_of 同源**（区块 1→bamboo … 区块 5→origin）。
	# 表里刻意包含每个区块的**首尾两波**（4/5、8/9、12/13、16/17 这些跨越点）——
	# 只测区块中段的话，`block_of` 的整除边界写错（例如 `/` 写成向上取整）也测不出来。
	var expect := { 1: "bamboo", 4: "bamboo", 5: "temple", 8: "temple",
		9: "nether", 12: "nether", 13: "blade", 16: "blade",
		17: "origin", 20: "origin" }
	for w_key in expect:
		if Config.map_theme_for_wave(int(w_key)) != String(expect[w_key]):
			_fail("第 %d 波主题映射错误（%s，期望 %s）"
				% [int(w_key), Config.map_theme_for_wave(int(w_key)), String(expect[w_key])])
			return
	# 无尽模式超出主题表区间后必须回落到合法主题（不能返回空）
	for w2 in [11, 20, 99]:
		if not Config.MAP_THEMES.has(Config.map_theme_for_wave(w2)):
			_fail("无尽第 %d 波主题越界（%s）" % [w2, Config.map_theme_for_wave(w2)])
			return
	# 背景色各主题必须两两不同，否则「换景」没有意义。
	# ⚠️ 原先写死比较 bgs[0..2]，扩到 5 个主题后会**漏检** 3/4 号 —— 改成两两比较。
	var bgs: Array = []
	var tids: Array = []
	for tid2 in Config.MAP_THEME_ORDER:
		tids.append(String(tid2))
		bgs.append(String(Config.MAP_THEMES[tid2].get("bg", "")))
	if bgs.size() != Config.MAP_THEMES.size():
		_fail("主题序与主题表数量不符（%d/%d）" % [bgs.size(), Config.MAP_THEMES.size()])
		return
	for i in bgs.size():
		for j in range(i + 1, bgs.size()):
			if bgs[i] == bgs[j]:
				_fail("地图主题背景色重复（%s 与 %s 同为 %s）"
					% [String(tids[i]), String(tids[j]), String(bgs[i])])
				return
	# BOSS 波判定（障碍物削减上限断言已随地形系统移除）
	if not Config.is_boss_wave(Config.BOSS_WAVE):
		_fail("第 %d 波未被判定为 BOSS 波" % Config.BOSS_WAVE)
		return
	# 当前主题应当与当前波次一致（start_wave 写入 GameState）
	if GameState.map_theme != Config.map_theme_for_wave(wm.wave):
		_fail("当前主题与波次不符（wave=%d theme=%s）" % [wm.wave, GameState.map_theme])
		return
	print("SMOKE: map themes mapping OK (%s @ wave %d)" % [GameState.map_theme, wm.wave])
	# ---- 氛围粒子：每主题脚本匹配且登记进 fx 组 ----
	for tid3 in Config.MAP_THEME_ORDER:
		_main._apply_map_theme(String(tid3))
		var fx: Node2D = _main._theme_fx
		if fx == null or not is_instance_valid(fx):
			_fail("主题 %s 未创建氛围粒子" % String(tid3))
			return
		var scr: Script = fx.get_script()
		var want := String(Config.MAP_THEMES[tid3].get("particle", ""))
		if scr == null or String(scr.resource_path).find(want) < 0:
			_fail("主题 %s 氛围粒子脚本不匹配（%s）"
				% [String(tid3), String(scr.resource_path) if scr != null else "null"])
			return
		if not fx.is_in_group("ambient_fx"):
			_fail("主题 %s 氛围粒子未登记进 ambient_fx 组（不得混进打击感 fx 组）"
				% String(tid3))
			return
		if fx.is_in_group("fx"):
			_fail("主题 %s 氛围粒子混进了打击感 fx 组（会污染全程特效计数）" % String(tid3))
			return
	print("SMOKE: theme particles OK (%s)" % str(Config.MAP_THEME_ORDER))
	# ---- 还原：切回当前波次的主题（氛围粒子随之重建）----
	_main._apply_map_theme(GameState.map_theme)
	print("SMOKE: map themes OK")

## 递归找第一个文本包含 frag 的 Label，返回其完整文本（找不到返回空串）
func _find_label_text(node: Node, frag: String) -> String:
	if node is Label and String((node as Label).text).contains(frag):
		return String((node as Label).text)
	for c in node.get_children():
		var got := _find_label_text(c, frag)
		if got != "":
			return got
	return ""

## 抽取池里是否含指定法宝 id
func _pool_has(pool: Array, id: String) -> bool:
	for e in pool:
		if typeof(e) == TYPE_DICTIONARY and String((e as Dictionary).get("item", "")) == id:
			return true
	return false

## 抽取池里指定法宝的权重（不存在返回 0）
func _pool_weight(pool: Array, id: String) -> float:
	for e in pool:
		if typeof(e) == TYPE_DICTIONARY and String((e as Dictionary).get("item", "")) == id:
			return float((e as Dictionary).get("w", 0.0))
	return 0.0

## 反应测试用标靶：高血量 + 指定状态抗性 + 已写入空间索引（AOE/扩散查得到）
## resist 默认 0，让爆发伤害可精确计算；BOSS 抗性用例须把配置值显式传回来
## 角色专属特性（Character Trait）：数据完整性 / 种类分布 / 四类运行时行为
## 运行时验证直接复用主玩家实例：把 trait 临时换成待测特性再还原。
## 这样不必新建玩家（新建会重跑 _ready 的角色 stats 注入，污染其他用例的数值假设）
func _check_character_traits() -> void:
	var p: Node2D = _main.get_node("Player")
	var saved_trait: Dictionary = p.char_trait
	var saved_kills: int = GameState.kills
	var saved_crit: float = float(p.stats.crit_ch)
	var saved_lh: float = float(p.stats.low_hp_dmg_bonus)
	var saved_mom: float = float(p.stats.momentum_dmg_bonus)
	# ---- 1. 数据结构：全部角色都必须带完整、可执行的特性 ----
	var kinds := {}
	var trait_ids := {}
	var bad: Array = []
	for cid in Registry.characters:
		var c: Dictionary = Registry.characters[cid]
		var t: Dictionary = c.get("trait", {})
		var cname := String(cid)
		if t.is_empty():
			bad.append("%s 无特性" % cname)
			continue
		var miss := ""
		for f in ["id", "name", "ico", "desc", "kind"]:
			if not t.has(f) or String(t[f]).strip_edges().is_empty():
				miss = String(f)
				break
		if miss != "":
			bad.append("%s 缺字段 %s" % [cname, miss])
			continue
		var k := String(t.kind)
		if k not in Registry.TRAIT_KINDS:
			bad.append("%s kind=%s" % [cname, k])
			continue
		kinds[k] = int(kinds.get(k, 0)) + 1
		var tid := String(t.id)
		if trait_ids.has(tid):
			bad.append("特性 id 重复：%s（%s / %s）" % [tid, String(trait_ids[tid]), cname])
		trait_ids[tid] = cname
	if not bad.is_empty():
		_fail("角色特性数据异常：%s" % ", ".join(bad))
		return
	# 四类机制都必须**接上代码** —— 少了任何一类就说明新机制没接线。
	#
	# ⚠️ 2026-09-17（第 7 轮）：原口径是「注册表里必须有角色在用这四类 kind」，
	#    但那在内置五行池里**从来就不成立** —— potato + 5 修士全是 `stats`，
	#    aura / thorns / momentum 一直是 S2 的已知缺口（印记语义错位、构筑亲和恒空）。
	#    此前这条能绿，只是因为工坊包里的旧角色**恰好**补上了这三类；
	#    包一停用，它就退化成「在验工坊包在不在」，而它想守的是「机制有没有接线」。
	#    → 改成**双来源覆盖**：内容侧（有角色在用）**或**机制侧（本函数下半段
	#      §3 光环 / §5 战意 / §6 荆棘 会用临时 `char_trait` 各实跑一遍）。
	#      两边都没有 = 这一类真的没人验 → 仍然报错（这才是它要守的东西）。
	var kind_covered := {}
	for k2 in Registry.TRAIT_KINDS:
		if int(kinds.get(k2, 0)) > 0:
			kind_covered[String(k2)] = "content"
	for mk in ["aura", "momentum", "thorns"]:
		if not kind_covered.has(mk):
			kind_covered[mk] = "mechanism"
	for k2 in Registry.TRAIT_KINDS:
		if not kind_covered.has(String(k2)):
			_fail("特性类别 %s 既没有角色在用、也没有机制侧实跑（新机制没接线）" % String(k2))
			return
	# ---- 2. stats 类特性的 effects 键必须已接线（写错字只会静默失效）----
	var valid := {}
	for k3 in p.stats:
		valid[String(k3)] = true
	var bad2: Array = []
	for cid2 in Registry.characters:
		var t2: Dictionary = Registry.characters[cid2].get("trait", {})
		if String(t2.get("kind", "")) != "stats":
			continue
		for ek in t2.get("effects", {}):
			if not valid.has(String(ek)):
				bad2.append("%s → %s" % [String(cid2), String(ek)])
	if not bad2.is_empty():
		_fail("角色特性 effects 存在未接线键：%s" % ", ".join(bad2))
		return
	print("SMOKE: traits %d (stats=%d aura=%d thorns=%d momentum=%d)" % [
		Registry.characters.size(), int(kinds.get("stats", 0)), int(kinds.get("aura", 0)),
		int(kinds.get("thorns", 0)), int(kinds.get("momentum", 0))])
	# ---- 3. 光环：范围内敌人获得状态，范围外不受影响 ----
	p.char_trait = { "id": "t_aura", "name": "测试光环", "ico": "❄", "desc": "",
		"kind": "aura", "status": "slow", "radius": 200.0, "interval": 0.5, "dmg": 0.0 }
	var e_in: Node2D = _spawn_reaction_target("grunt", p.global_position + Vector2(80.0, 0.0), p)
	var e_out: Node2D = _spawn_reaction_target("grunt", p.global_position + Vector2(260.0, 0.0), p)
	await get_tree().physics_frame
	p._apply_aura()
	if not e_in.has_status("slow"):
		_fail("光环未对范围内敌人施加状态")
		e_in.queue_free()
		e_out.queue_free()
		p.char_trait = saved_trait
		return
	if e_out.has_status("slow"):
		_fail("光环误伤了范围外的敌人")
		e_in.queue_free()
		e_out.queue_free()
		p.char_trait = saved_trait
		return
	print("SMOKE: aura trait OK (radius=%d)" % roundi(p.aura_radius()))
	e_in.queue_free()
	e_out.queue_free()
	await get_tree().process_frame
	# ---- 4. 残血增伤：伤害随缺失生命线性提升 ----
	p.char_trait = {}
	p.stats.crit_ch = 0.0
	p.stats.momentum_dmg_bonus = 0.0
	p.stats.low_hp_dmg_bonus = 0.5
	p.hp = float(p.stats.max_hp)
	var full_dmg: float = float(p._roll_damage(100.0).dmg)
	p.hp = 1.0
	var low_dmg: float = float(p._roll_damage(100.0).dmg)
	if low_dmg <= full_dmg * 1.30:
		_fail("残血增伤未生效（满血 %.1f → 残血 %.1f）" % [full_dmg, low_dmg])
		p.hp = float(p.stats.max_hp)
		p.char_trait = saved_trait
		return
	print("SMOKE: low-hp trait %d → %d" % [roundi(full_dmg), roundi(low_dmg)])
	p.hp = float(p.stats.max_hp)
	# ---- 5. 战意：本波击杀累积增伤 + 上限封顶 + 换波归零 ----
	p.char_trait = { "id": "t_mom", "name": "测试战意", "ico": "🔺", "desc": "",
		"kind": "momentum", "per_kills": 8, "per_stack": 0.04, "max_bonus": 0.50 }
	p.stats.momentum_dmg_bonus = 0.0
	GameState.kills = saved_kills
	p._momentum_base_kills = saved_kills
	GameState.kills = saved_kills + 40   # 40 杀 / 每 8 杀一层 × 4% = 20%
	p._trait_tick(0.016)
	if absf(float(p.stats.momentum_dmg_bonus) - 0.20) > 0.005:
		_fail("战意累积不正确（%.3f，应为 0.200）" % float(p.stats.momentum_dmg_bonus))
		GameState.kills = saved_kills
		p.char_trait = saved_trait
		return
	GameState.kills = saved_kills + 10000
	p._trait_tick(0.016)
	if float(p.stats.momentum_dmg_bonus) > 0.501:
		_fail("战意未受上限约束（%.3f）" % float(p.stats.momentum_dmg_bonus))
		GameState.kills = saved_kills
		p.char_trait = saved_trait
		return
	p.on_wave_start()
	if float(p.stats.momentum_dmg_bonus) > 0.001:
		_fail("战意未在换波时归零（%.3f）" % float(p.stats.momentum_dmg_bonus))
		GameState.kills = saved_kills
		p.char_trait = saved_trait
		return
	GameState.kills = saved_kills
	print("SMOKE: momentum trait OK")
	# ---- 6. 荆棘反击：受击对周围敌人造成伤害 ----
	p.char_trait = { "id": "t_thorn", "name": "测试荆棘", "ico": "🌵", "desc": "",
		"kind": "thorns", "dmg": 1.0, "radius": 160.0 }
	var e_t: Node2D = _spawn_reaction_target("grunt", p.global_position + Vector2(70.0, 0.0), p)
	await get_tree().physics_frame
	var hp_before: float = float(e_t.hp)
	p._trait_on_hurt()
	await get_tree().process_frame
	if float(e_t.hp) >= hp_before:
		_fail("荆棘反击未对范围内敌人造成伤害（%.0f → %.0f）" % [hp_before, float(e_t.hp)])
		e_t.queue_free()
		p.char_trait = saved_trait
		return
	print("SMOKE: thorns trait OK")
	e_t.queue_free()
	await get_tree().process_frame
	# ---- 还原现场：trait / 击杀数 / 属性 / 生命 ----
	p.char_trait = saved_trait
	p.stats.crit_ch = saved_crit
	p.stats.low_hp_dmg_bonus = saved_lh
	p.stats.momentum_dmg_bonus = saved_mom
	p.hp = float(p.stats.max_hp)
	GameState.kills = saved_kills
	print("SMOKE: character traits OK")

## 武器外观族（Registry.WEAPON_FX）：映射完整性 / 与攻击方式匹配 / 未知值回退 / 数据链路。
## 外观本身画不出断言，但「武器 → 外观族 → 弹丸/刀光实例」这条链路可以 ——
## 漏映射、配错族、回退失败这三种情况都会让武器静默退化成默认外观（玩家只会觉得「没特效」）
func _check_weapon_fx() -> void:
	# ---- 1. 映射表与武器表一一对应 ----
	var missing: Array = []
	for wid in Config.WEAPONS:
		if not Registry.WEAPON_FX.has(String(wid)):
			missing.append(String(wid))
	if not missing.is_empty():
		_fail("武器缺少外观族映射：%s" % ", ".join(missing))
		return
	# ⚠️ S2：「孤儿映射」的判据必须是 **Registry.weapons**（内置 + 已加载 mod），
	#    不能是 `Config.WEAPONS`（只剩内置 10 把）。
	#    `WEAPON_FX` 是**保留全量**的：内置 10 把 + 工坊包 23 把，全都写在这张表里
	#    —— 这样武器迁出内置后，只要工坊包还在，外观族就不会静默劣化成兜底族。
	#    若这里拿 `Config.WEAPONS` 当白名单，工坊包那 23 条会被误判成悬空映射。
	#
	# ⚠️ 2026-09-17（第 7 轮）：工坊包已移出 `game/mods/` → 那 23 条**当下确实未注册**，
	#    但它们仍是「保留全量」设计的合法条目。判据因此变成三选一：
	#    已注册 / 在 `Registry.FROZEN_PACK_WEAPONS` 白名单里 / 否则就是幽灵 id。
	#    没有这份白名单，「包被停用」与「表里写错一个 id」会给出完全一样的报错。
	var orphans: Array = []
	for wid2 in Registry.WEAPON_FX:
		if Registry.weapons.has(String(wid2)):
			continue
		if Registry.FROZEN_PACK_WEAPONS.has(String(wid2)):
			continue   # 合法的冻结条目（包已停用，见 Registry.FROZEN_PACK_WEAPONS）
		orphans.append(String(wid2))
	if not orphans.is_empty():
		_fail("外观族映射指向不存在的武器：%s" % ", ".join(orphans))
		return
	# 反向对照：白名单自己也得对得上 —— 否则上面那条会退化成「白名单写多宽都能绿」。
	# 少写 → 合法冻结条目被误判成幽灵；多写 → 给不存在的武器开后门。两侧都在这里钉住。
	var frozen_hit := 0
	for fw in Registry.FROZEN_PACK_WEAPONS:
		if Registry.WEAPON_FX.has(String(fw)):
			frozen_hit += 1
	if frozen_hit != Registry.FROZEN_PACK_WEAPONS.size():
		_fail("WEAPON_FX 里的冻结工坊包条目数 %d ≠ 白名单 %d（两边必须一一对应）"
			% [frozen_hit, Registry.FROZEN_PACK_WEAPONS.size()])
		return
	if Registry.FROZEN_PACK_WEAPONS.size() != Registry.WEAPON_FX.size() \
			- Config.WEAPONS.size():
		_fail("白名单 %d + 内置武器 %d ≠ WEAPON_FX 全量 %d（有武器既不在内置也不在白名单）"
			% [Registry.FROZEN_PACK_WEAPONS.size(), Config.WEAPONS.size(),
				Registry.WEAPON_FX.size()])
		return
	# ---- 2. 外观族必须与攻击方式匹配（近战配投射族 = 永远画不出来）----
	var melee_fx := ["slash", "whip", "smash"]
	var shoot_fx := ["bolt", "pellet", "flame", "rocket", "lance", "frost",
		"thunder", "vine", "bell"]
	for wid3 in Config.WEAPONS:
		var fx := String(Registry.WEAPON_FX[wid3])
		if fx not in Registry.WEAPON_FX_KINDS:
			_fail("武器 %s 的外观族不在白名单：%s" % [String(wid3), fx])
			return
		var is_melee := String(Config.WEAPONS[wid3].get("attack_type", "projectile")) == "melee"
		if is_melee and fx not in melee_fx:
			_fail("近战武器 %s 配了投射外观族 %s" % [String(wid3), fx])
			return
		if not is_melee and fx in melee_fx:
			_fail("投射武器 %s 配了近战外观族 %s" % [String(wid3), fx])
			return
	for wid4 in Registry.weapons:
		if not Registry.weapons[wid4].has("fx"):
			_fail("已注册武器 %s 缺少 fx 字段" % String(wid4))
			return
	print("SMOKE: weapon fx map OK (%d weapons / %d kinds)" % [
		Registry.WEAPON_FX.size(), Registry.WEAPON_FX_KINDS.size()])
	# ---- 3. 未知 fx 只回退、不拒登（外观写错不该让武器不可用）----
	var probe := { "id": "__fx_probe", "name": "外观探针", "cd": 0.5, "dmg": 1.0,
		"attack_type": "projectile", "fx": "no_such_fx" }
	if not Registry.register_weapon(probe):
		_fail("未知 fx 导致武器被拒登（应回退默认外观并保留武器）")
		return
	if String(Registry.weapons["__fx_probe"].get("fx", "x")) != "":
		_fail("未知 fx 未被回退为空")
		Registry.weapons.erase("__fx_probe")
		return
	Registry.weapons.erase("__fx_probe")
	# ---- 4. 数据链路：武器配置 → 弹丸 / 刀光实例 ----
	var bt: Node2D = preload("res://scenes/weapons/bullet.tscn").instantiate()
	_main.add_child(bt)
	bt.setup(Vector2.ZERO, 0.0, Registry.weapons["flamethrower"], { "dmg": 1.0, "crit": false })
	if String(bt.fx) != "flame":
		_fail("火焰喷射器的弹丸未取到 flame 外观族（%s）" % String(bt.fx))
		bt.queue_free()
		return
	var burn_col := Color(String(Config.STATUS.burn.color))
	if absf(bt.col.r - burn_col.r) > 0.01 or absf(bt.col.g - burn_col.g) > 0.01:
		_fail("火焰喷射器的弹丸未按燃烧状态配色")
		bt.queue_free()
		return
	bt.queue_free()
	var sl := Slash.new()
	_main.add_child(sl)
	# ⚠️ S2：原用例读 `Registry.weapons["blade"]`（太刀）取 fx。`blade` 已迁入工坊包，
	#    虽然 mod 加载后仍能取到，但那样这条断言就变成"依赖 mod 存在"的假保证
	#    —— 内置链路一旦坏掉，只要工坊包还在就照样绿。改用内置的 `knife`（fx=slash）。
	sl.setup(Vector2.ZERO, 0.0, 100.0, 1.9, String(Registry.weapons["knife"].get("fx", "")))
	if String(sl.fx) != "slash":
		_fail("金剑的刀光未取到 slash 外观族（%s）" % String(sl.fx))
		sl.queue_free()
		return
	sl.queue_free()
	await get_tree().process_frame
	print("SMOKE: weapon fx wiring OK")

## 弹道预判（B4）：远程武器必须瞄「交会点」而非敌人当前位置。
## 用一个真实敌人放在玩家正右侧 300px，敌人速度朝玩家 —— 解析解可手工算出：
##   交会时刻 t = dist / (bspeed + espeed)，命中点 x = ex − espeed·t
## 无目标 / 零速度时必须原样返回（不预判）。
func _check_ballistic_lead() -> void:
	var player: Node2D = _main.get_node("Player")
	var old_pos: Vector2 = player.global_position
	var old_aim = player._aim_target
	var e := preload("res://scenes/enemies/enemy.tscn").instantiate()
	e.setup("grunt", 1)
	_main.add_child(e)
	e.player = player
	# 布局：玩家 (600,400)，敌人 (900,400)，敌人朝玩家移动
	# （不 await 物理帧 —— 敌人一旦跑 _physics_process 就会移动，交会点不再是解析解）
	player.global_position = Vector2(600.0, 400.0)
	e.global_position = Vector2(900.0, 400.0)
	player._aim_target = e
	var espeed: float = float(e.speed)
	# ---- 1. 有目标：命中点必须朝玩家方向偏移，且与解析解一致 ----
	var lead: Vector2 = player._lead_target({ "bspeed": 100.0 }, Vector2(900.0, 400.0))
	var expect_t := 300.0 / (100.0 + espeed)
	var expect := Vector2(900.0 - espeed * expect_t, 400.0)
	if lead.distance_to(expect) > 1.0:
		_fail("弹道预判交会点不准（%s，期望 %s，敌速 %s）" % [str(lead), str(expect), str(espeed)])
		player._aim_target = old_aim
		player.global_position = old_pos
		e.queue_free()
		return
	if lead.x >= 900.0:
		_fail("弹道预判未朝目标运动方向偏移")
		player._aim_target = old_aim
		player.global_position = old_pos
		e.queue_free()
		return
	# ---- 2. 慢弹丸 + 快目标（追不上的极端情形）：不崩、给有限点 ----
	var lead2: Vector2 = player._lead_target({ "bspeed": 2.0 }, Vector2(900.0, 400.0))
	if not is_finite(lead2.x) or not is_finite(lead2.y):
		_fail("弹道预判在追不上时返回了非有限值（%s）" % str(lead2))
		player._aim_target = old_aim
		player.global_position = old_pos
		e.queue_free()
		return
	# ---- 3. 无目标：原样返回，不预判 ----
	player._aim_target = null
	var lead3: Vector2 = player._lead_target({ "bspeed": 100.0 }, Vector2(900.0, 400.0))
	if lead3 != Vector2(900.0, 400.0):
		_fail("无目标时预判修改了瞄准点（%s）" % str(lead3))
		player._aim_target = old_aim
		player.global_position = old_pos
		e.queue_free()
		return
	player._aim_target = old_aim
	player.global_position = old_pos
	e.queue_free()
	await get_tree().physics_frame
	print("SMOKE: ballistic lead OK (espeed=%s, hit x=%.1f)" % [str(espeed), lead.x])

## 构筑亲和（Config.affinity_tags / entry_tags / affinity_mult）：
## 「商店 / 升级 / 法宝抽取向当前角色与武器靠拢」的核心。
## 标签必须能从数据自动推导正确，加权必须真的改变池权重，且不能把池子算空
func _check_affinity() -> void:
	# ---- 1. entry_tags：按 effects / element / params 自动打标 ----
	var samples: Array = [
		[{ "effects": { "on_hit_burn": 0.2 } }, "burn"],
		[{ "effects": { "melee_range_bonus": 0.2 } }, "melee"],
		[{ "effects": { "bullet_speed_bonus": 0.2 } }, "speed"],
		[{ "effects": { "aoe_radius_bonus": 0.2 } }, "aoe"],
		[{ "effects": { "crit_mult": 0.3 } }, "crit"],
		[{ "effects": { "armor": 2.0 } }, "tank"],
		[{ "effects": { "harvesting": 0.2 } }, "economy"],
		[{ "element": "fire", "params": {} }, "burn"],
		[{ "element": "wood", "params": { "status": "poison" } }, "poison"],
	]
	for s in samples:
		var cfg0: Dictionary = s[0]
		var tags: Array = Config.entry_tags(cfg0)
		if not (String(s[1]) in tags):
			_fail("entry_tags 未能推导出 %s（得到 %s）" % [String(s[1]), str(tags)])
			return
	# ---- 2. 亲和推导：武器形态 / 武器状态 / 角色光环 / 已持有法宝 ----
	# ⚠️ S2：本组原用 `blade`（近战）与 `venom_dagger`（poison）当样本，两者都已迁入
	#    工坊包。它们加载后依然能推出标签，但那样验的是"工坊包在不在"，不是"推导逻辑对不对"。
	#    → 改为「内置武器 + 临时注册探针武器」：既能覆盖同一批推导分支，又不依赖任何 mod。
	if not ("melee" in Config.affinity_tags("potato", [{ "type": "knife" }], {})):
		_fail("近战武器未推导出 melee 亲和")
		return
	# 内置 5 把里没有带 poison 的（金剑=bleed / 喷火=burn / 水枪=slow / 土弹=stun），
	# 但 poison 标签通路本身必须还在（毒系道具/法宝/未来内容都靠它）。临时注册一把探针。
	Registry.weapons["__poison_probe"] = {
		"id": "__poison_probe", "status": "poison", "attack_type": "ranged",
	}
	if not ("poison" in Config.affinity_tags("potato", [{ "type": "__poison_probe" }], {})):
		_fail("带毒武器未推导出 poison 亲和")
		Registry.weapons.erase("__poison_probe")
		return
	Registry.weapons.erase("__poison_probe")
	# ⚠️ 已知缺口（不在 S2 范围，留给 S3/S4 决策）：
	#    `kind == "aura"` 是角色推元素亲和的唯一通路，而**内置 6 角色没有一个 aura**
	#    （potato 无元素；5 修士 trait.kind 全是 "stats"）→ 对内置角色，② 号通路恒空。
	#
	# ⚠️ 2026-09-17（第 7 轮）：原先借 `pyromancer`（工坊包，aura+burn）验这条通路，
	#    但工坊包已移出 `game/mods/` → 该角色不再注册，这条会直接红。
	#    → 改为**临时注册探针角色**，与上面 `__poison_probe`（探针武器）同一手法：
	#      验的是「aura 推导逻辑本身」，而不是「某个包在不在」。用完立刻 erase，
	#      不给后面「遍历 Registry.characters」的用例留下污染源。
	#    等到 S3/S4 给修士补元素光环（或给 stats kind 也加 element→status 推导）时，
	#    这条断言应改回内置角色。
	Registry.characters["__aura_probe"] = {
		"id": "__aura_probe", "name": "探针", "trait": { "kind": "aura", "status": "burn" },
	}
	if not ("burn" in Config.affinity_tags("__aura_probe", [], {})):
		_fail("aura 角色的光环未推导出 burn 亲和")
		Registry.characters.erase("__aura_probe")
		return
	Registry.characters.erase("__aura_probe")
	if not ("stun" in Config.affinity_tags("potato", [], { "art_stone_skin": 1 })):
		_fail("已持有土系法宝未推导出 earth→stun 亲和")
		return
	print("SMOKE: affinity derivation OK")
	# ---- 3. 加权：命中标签的条目必须高于无关条目，且按上限封顶 ----
	var aff: Array = ["melee", "range"]
	var w_hit: float = Config.affinity_mult(
		Config.entry_tags({ "effects": { "melee_range_bonus": 0.2 } }), aff)
	var w_miss: float = Config.affinity_mult(
		Config.entry_tags({ "effects": { "harvesting": 0.2 } }), aff)
	if w_hit <= w_miss or not is_equal_approx(w_miss, 1.0):
		_fail("亲和倍率异常（命中 %.2f / 无关 %.2f）" % [w_hit, w_miss])
		return
	var all_tags: Array = ["melee", "range", "aoe", "speed", "crit", "tank"]
	var cap := 1.0 + Config.AFFINITY_BONUS * float(Config.AFFINITY_MAX_TAGS)
	if Config.affinity_mult(all_tags, all_tags) > cap + 0.001:
		_fail("亲和倍率未按 AFFINITY_MAX_TAGS 封顶")
		return
	print("SMOKE: affinity weighting OK (hit=%.2f miss=%.2f)" % [w_hit, w_miss])
	# ---- 4. 端到端：同一件法宝在「亲和 stun」下的池权重必须更高 ----
	var w_plain := _pool_weight(Registry.artifact_pool({}, 1, false, []), "art_stone_skin")
	var w_aff := _pool_weight(Registry.artifact_pool({}, 1, false, ["stun"]), "art_stone_skin")
	if w_aff <= w_plain:
		_fail("亲和未提高对应法宝的池权重（%.2f → %.2f）" % [w_plain, w_aff])
		return
	if Registry.artifact_pool({}, 1, false, ["burn", "melee"]).is_empty():
		_fail("亲和加权后法宝池为空")
		return
	print("SMOKE: affinity artifact pool OK")
	# ---- 5. 升级池在亲和加权后仍然可用（加权不能把任何条目算成 0）----
	# 用 LV10 测：品阶门槛（LV1 只出白/蓝）会把高品阶升级权重算成 0，
	# 那是在验「品阶解锁曲线」而非「亲和加权」，两者分开验
	var counted := 0
	for u in Registry.upgrade_list():
		var w: float = Config.rarity_weight(String(u.get("rarity", "common")), 10) \
			* Config.affinity_mult(Config.entry_tags(u), ["melee", "burn"])
		if w <= 0.0:
			_fail("升级 %s 亲和加权后权重非正" % String(u.id))
			return
		counted += 1
	if counted == 0:
		_fail("亲和加权后升级池为空")
		return
	print("SMOKE: affinity OK")

## 角色印记（SIGIL）：表完整性 / 推导规则 / 显式声明优先 / 是否真的传到弹丸与刀光
func _check_sigils() -> void:
	# ---- 1. 表完整性 ----
	if Config.SIGILS.is_empty():
		_fail("SIGILS 表为空")
		return
	for sid in Config.SIGILS:
		var s: Dictionary = Config.SIGILS[sid]
		for key in ["name", "color", "glyph"]:
			if not s.has(key):
				_fail("印记 %s 缺少字段 %s" % [String(sid), key])
				return
		if not (String(s.glyph) in Config.SIGIL_GLYPHS):
			_fail("印记 %s 的 glyph 非法：%s" % [String(sid), String(s.glyph)])
			return
		if not Color.html_is_valid(String(s.color)):
			_fail("印记 %s 的颜色非法：%s" % [String(sid), String(s.color)])
			return
	# ---- 2. 每个角色都能推导出合法印记（空串合法 = 刻意无印记）----
	#
	# ⚠️ S2 口径变化：本组的覆盖门槛原为「≥8 种印记被使用」，那是按旧 17 角色池定的。
	#    内容收缩后内置只剩 6 个角色，且 5 修士的 trait.kind 都是 `stats`，
	#    `sigil_for` 的 `aura` 分支（唯一能推五行印记的入口）对内置角色**永不命中** →
	#    印记只能从 effects 反推，得到的是**风格印记**：
	#        potato="" / metal_adept="luck" / wood_adept="wood" / water_adept="wood"
	#        fire_adept="wood" / earth_adept="guard"   → 共 3 种
	#    → 门槛改为「内置 6 角色不得推得非法印记，且至少推出 1 种非空印记」。
	#      覆盖面门槛挪到 §12 的 S3/S4「5 元素怪 + 抗性模型」阶段随内容一起定。
	#
	# ⚠️ 顺带记一个**真实语义错位**（不是本用例能修的，留给 S3/S4）：
	#    「赤焰修士」的印记被推成 `wood`（青瘴）而非 `fire`，因为它是 `stats` kind，
	#    只能从 effects 的 `status_dmg_mult` 反推。同理「鎏金修士」→ `luck`。
	#    等修士补上元素光环（或给 stats kind 也加 element→sigil 推导）后，
	#    这里应改回逐个断言 `fire/wood/water/metal/earth`。
	var used := {}
	var blank := 0
	for cid in Registry.characters:
		var sg := Config.sigil_for(String(cid))
		if not Config.sigil_valid(sg):
			_fail("角色 %s 推导出非法印记：%s" % [String(cid), sg])
			return
		if sg == "":
			blank += 1
		else:
			used[sg] = true
	if used.is_empty():
		_fail("没有角色推导出任何印记（推导链整条失效）")
		return
	var builtin_used := {}
	var builtin_blank := 0
	for cid in ["potato", "metal_adept", "wood_adept", "water_adept", "fire_adept", "earth_adept"]:
		var sg2 := Config.sigil_for(cid)
		if sg2 == "":
			builtin_blank += 1
		else:
			builtin_used[sg2] = true
	if builtin_used.is_empty():
		_fail("内置 6 角色没有一个推导出印记（内置内容整条推导链失效）")
		return
	if builtin_blank >= 6:
		_fail("内置角色全部无印记（potato 应刻意无印记，其余应至少推出风格印记）")
		return
	if blank >= Registry.characters.size():
		_fail("所有角色都没有印记")
		return
	# ---- 3. 显式声明优先：土豆勇者 effects 里有 speed_mult，
	# 不显式写空串就会被推成「疾风」，与「均衡之道」的定位矛盾 ----
	if Config.sigil_for("potato") != "":
		_fail("显式声明的空印记未生效（土豆勇者实得 %s）" % Config.sigil_for("potato"))
		return
	if Config.sigil_for("nobody_here") != "":
		_fail("未知角色应推导出空印记")
		return
	# ---- 4. 推导规则抽查：光环按元素、剑客按 effects、荆棘按定位 ----
	# ⚠️ S2：内置 6 角色里没有 aura / thorns / momentum 三种 kind（potato + 5 stats 修士），
	#    而这三条分支正是 `sigil_for` 的语义核心，不能没人看住。
	#    → 拆成两组：
	#      ① 内置角色：钉死当前实测值（含刻意空印记），作为回归基线；
	#      ② aura / thorns / momentum 三条分支：**用探针角色临时注册**来验。
	#
	# ⚠️ 2026-09-17（第 7 轮）：② 组原先借工坊包角色（pyromancer / swordmaster /
	#    guardian / warlord / tidecaller）当被测对象，并在「包没加载」时**故意报错**。
	#    工坊包现已按用户要求移出 `game/mods/` → 那种"报错即信号"的写法不再成立，
	#    否则就变成「一跑冒烟就红」。改成与上面 `__aura_probe` / `__poison_probe`
	#    同一手法：临时注册探针 → 断言 → 立刻 erase。
	#    期望值取自 `Config.sigil_for` 的分支定义本身（aura → 元素印记 / thorns → guard /
	#    momentum → blade），不是另抄一份字面量。
	var builtin_expects := {
		"potato": "",            # 显式声明无印记（均衡之道）
		"metal_adept": "luck",   # stats kind → 从 effects.crit_ch 反推
		"wood_adept": "wood",    # stats kind → 从 effects.status_dmg_mult 反推
		"water_adept": "wood",   # stats kind → 从 effects.status_dur_mult 反推
		"fire_adept": "wood",    # stats kind → 从 effects.status_dmg_mult 反推
		"earth_adept": "guard",  # stats kind → 从 effects.armor 反推
	}
	for cid3 in builtin_expects:
		var got_b := Config.sigil_for(String(cid3))
		if got_b != String(builtin_expects[cid3]):
			_fail("内置角色 %s 的印记应为 %s（实得 %s）"
				% [String(cid3), String(builtin_expects[cid3]), got_b])
			return
	var probes := {
		"__sigil_aura": { "kind": "aura", "status": "burn", "want": "fire" },
		"__sigil_thorns": { "kind": "thorns", "want": "guard" },
		"__sigil_momentum": { "kind": "momentum", "want": "blade" },
	}
	var checked_branches := 0
	for pid in probes:
		var pr: Dictionary = probes[pid]
		Registry.characters[String(pid)] = { "id": String(pid), "name": "探针",
			"trait": { "kind": String(pr["kind"]), "status": String(pr.get("status", "")) } }
		var got := Config.sigil_for(String(pid))
		Registry.characters.erase(String(pid))   # 立刻归还，别污染后面遍历 characters 的用例
		if got != String(pr["want"]):
			_fail("印记分支 %s 推导失效（应为 %s，实得 %s）"
				% [String(pr["kind"]), String(pr["want"]), got])
			return
		checked_branches += 1
	if checked_branches == 0:
		_fail("aura/thorns/momentum 三条印记分支无被测对象")
		return
	# ---- 5. 数据链路：印记必须真的到达弹丸与刀光实例 ----
	var b = preload("res://scenes/weapons/bullet.tscn").instantiate()
	b.setup(Vector2.ZERO, 0.0, { "fx": "bolt", "bspeed": 500.0 },
		{ "dmg": 1.0, "crit": false, "sigil": "fire" }, Color(0, 0, 0, 0))
	if String(b.sigil) != "fire":
		_fail("弹丸未接收印记（实得 %s）" % String(b.sigil))
		b.free()
		return
	b.free()
	var sl := Slash.new()
	sl.setup(Vector2.ZERO, 0.0, 100.0, 1.5, "slash", Color(0, 0, 0, 0),
		Color(1, 1, 1), "water")
	if String(sl.sigil) != "water":
		_fail("刀光未接收印记（实得 %s）" % String(sl.sigil))
		sl.free()
		return
	sl.free()
	# ---- 6. 玩家侧：player.sigil 与 _roll_damage 的打包 ----
	var pl: Node = _main.get_node("Player")
	var want := Config.sigil_for(GameState.character_id)
	if String(pl.sigil) != want:
		_fail("player.sigil 与当前角色不符（%s vs %s）" % [String(pl.sigil), want])
		return
	var roll: Dictionary = pl._roll_damage(10.0, {})
	if String(roll.get("sigil", "")) != want:
		_fail("_roll_damage 未打包印记")
		return
	print("SMOKE: sigils OK (%d kinds in use / %d blank)" % [used.size(), blank])

## ============================================================
## 五行对抗引擎（§13 断言 43~51）
##
## 目的：把「双向元素修正模型」的每一条算术都钉死。
##   - 相生相克表方向正确（不依赖 REACTIONS 的 id 约定，那张表方向是反的）
##   - 输出侧 6 档 / 受击侧 4 档的**刻意不对称**确实成立
##   - §2.3-C 木角色标定（-90 / -75 / 0 / -50）逐条对得上
##   - 关系基数与 cap 分列（写错语义就会冒出「相生两侧落 other 档」的错值）
##   - 区域元素序末位是同属（否则 90% cap 永远触发不了）
## ============================================================
func _check_element_engine() -> void:
	# ---- 43. 相生相克表：完整覆盖 5 行，且与「木→火→土→金→水→木」一致 ----
	var gen_want := { "wood": "fire", "fire": "earth", "earth": "metal",
		"metal": "water", "water": "wood" }
	var ovc_want := { "wood": "earth", "earth": "water", "water": "fire",
		"fire": "metal", "metal": "wood" }
	for e in Config.ELEMENTS:
		if String(Config.GENERATES.get(e, "")) != String(gen_want[e]):
			_fail("GENERATES[%s] 应为 %s，实为 %s"
				% [String(e), String(gen_want[e]), String(Config.GENERATES.get(e, ""))])
			return
		if String(Config.OVERCOMES.get(e, "")) != String(ovc_want[e]):
			_fail("OVERCOMES[%s] 应为 %s，实为 %s"
				% [String(e), String(ovc_want[e]), String(Config.OVERCOMES.get(e, ""))])
			return
	# ---- 44. 关系枚举：6 档齐全，字段（out/hit/hcap）都是数值 ----
	for rid in ["i_beat", "gen_me", "same", "i_gen", "beats_me", "other"]:
		if not Config.ELEMENT_RELATION.has(rid):
			_fail("ELEMENT_RELATION 缺少关系 %s" % rid)
			return
		for f in ["out", "hit", "hcap"]:
			if not Config.ELEMENT_RELATION[rid].has(f):
				_fail("关系 %s 缺少字段 %s" % [rid, f])
				return
	# ---- 45. element_relation：穷举 5×5，逐项对照 §2.3-A/§2.3-B 表 ----
	# 木角色视角：土 i_beat / 水 gen_me / 木 same / 火 i_gen / 金 beats_me
	var want_rel := { "earth": "i_beat", "water": "gen_me", "wood": "same",
		"fire": "i_gen", "metal": "beats_me" }
	for tgt in want_rel:
		var got := Config.element_relation("wood", String(tgt))
		if got != String(want_rel[tgt]):
			_fail("木→%s 应为 %s，实为 %s" % [String(tgt), String(want_rel[tgt]), got])
			return
	# 方向性：反向关系必须互换或落到对称档
	if Config.element_relation("earth", "wood") != "beats_me":
		_fail("土→木 应为 beats_me（木克土的逆）")
		return
	if Config.element_relation("water", "wood") != "i_gen":
		_fail("水→木 应为 i_gen（木生水的逆）")
		return
	# 空元素 / 非法元素一律 other
	if Config.element_relation("", "fire") != "other" or Config.element_relation("wood", "") != "other":
		_fail("空元素应判为 other")
		return
	if Config.element_relation("void", "wood") != "other":
		_fail("非法元素应判为 other")
		return
	# ---- 46. 输出侧 6 档：木角色逐项对 §2.3-A ----
	var want_out := { "earth": +0.25, "water": +0.15, "wood": +0.10,
		"fire": -0.15, "metal": -0.25 }
	for tgt2 in want_out:
		var got_o := Config.out_mult("wood", String(tgt2))
		if not is_equal_approx(got_o, float(want_out[tgt2])):
			_fail("输出 木→%s 应为 %+.2f，实为 %+.2f"
				% [String(tgt2), float(want_out[tgt2]), got_o])
			return
	# ---- 47. 受击侧 4 档：基数 + cap 分列，且相生两侧与 other 同为 0/0.50 ----
	# 参考系说明：hit_base/hit_cap 的第一参数是**攻击方**，第二参数是**防御方**（木）。
	# 表读的是防御方视角的关系，故这里必须写 hit_base(来袭元素, "wood")。
	var want_hit := { "earth": -0.25, "water": 0.00, "wood": -0.10,
		"fire": 0.00, "metal": +0.25 }
	var want_cap := { "earth": 0.75, "water": 0.50, "wood": 0.90,
		"fire": 0.50, "metal": 0.25 }
	for atk in want_hit:
		var got_h := Config.hit_base(String(atk), "wood")
		var got_c := Config.hit_cap(String(atk), "wood")
		if not is_equal_approx(got_h, float(want_hit[atk])):
			_fail("受击基数 木受%s 应为 %+.2f，实为 %+.2f"
				% [String(atk), float(want_hit[atk]), got_h])
			return
		if not is_equal_approx(got_c, float(want_cap[atk])):
			_fail("受击 cap 木受%s 应为 %.2f，实为 %.2f"
				% [String(atk), float(want_cap[atk]), got_c])
			return
	# 参考系必须真的按防御方解，写反了会静默算错（这里正面钉死）
	if Config.hit_relation("earth", "wood") != "i_beat":
		_fail("受击参考系错误：木受土应为 i_beat（木克土），实为 %s"
			% Config.hit_relation("earth", "wood"))
		return
	if Config.element_relation("earth", "wood") != "beats_me":
		_fail("攻击侧参考系应保持 attacker-first（土打木 = beats_me）")
		return
	# 受击侧 4 档归一是**数据自然导出**：相生两侧 + other 必须落同一档
	if Config.hit_tier("water", "wood") != "other" or Config.hit_tier("fire", "wood") != "other":
		_fail("相生两侧应归入受击 other 档")
		return
	if Config.hit_tier("wood", "wood") != "same" \
			or Config.hit_tier("earth", "wood") != "i_beat" \
			or Config.hit_tier("metal", "wood") != "beats_me":
		_fail("受击 4 档归一错误")
		return
	# 空元素：hit_tier 返回空串（不在 UI 上伪装成「其他」），hit_mult 返回 0
	if Config.hit_tier("", "wood") != "" or Config.hit_tier("wood", "") != "":
		_fail("空元素的受击档位应为空串")
		return
	if not is_equal_approx(Config.hit_mult("", "wood", 1.0), 0.0):
		_fail("空元素时 hit_mult 应为 0（不参与修正）")
		return
	# ---- 48. hit_mult 公式：clamp(基数 − 同化度, −cap, +∞) ----
	# 木角色对土（i_beat，基数 -0.25，cap 0.75）：同化度 0 → -0.25；0.5 → -0.75；1.0 → 封顶 -0.75
	if not is_equal_approx(Config.hit_mult("earth", "wood", 0.0), -0.25) \
			or not is_equal_approx(Config.hit_mult("earth", "wood", 0.5), -0.75) \
			or not is_equal_approx(Config.hit_mult("earth", "wood", 1.0), -0.75):
		_fail("hit_mult 木受土 未按 clamp(基数−同化度, −cap) 解算")
		return
	# 木受木（same，基数 -0.10，cap 0.90）：同化度 0.8 → -0.90；0.95 → 仍 -0.90
	if not is_equal_approx(Config.hit_mult("wood", "wood", 0.8), -0.90) \
			or not is_equal_approx(Config.hit_mult("wood", "wood", 0.95), -0.90):
		_fail("hit_mult 同属 cap 90%% 未生效")
		return
	# 木受金（beats_me，基数 +0.25，cap 0.25）：同化度 0.25 → 0；0.5 → 仍 0（不能转成减伤）
	if not is_equal_approx(Config.hit_mult("metal", "wood", 0.0), +0.25) \
			or not is_equal_approx(Config.hit_mult("metal", "wood", 0.25), 0.0) \
			or not is_equal_approx(Config.hit_mult("metal", "wood", 0.9), 0.0):
		_fail("hit_mult 克我 未在 0 处封顶（同化度不该把增伤变成减伤）")
		return
	# 木受水 / 受火（相生两侧与 other）：基数 0，cap 0.50 → 满同化度最多 -0.50
	if not is_equal_approx(Config.hit_mult("water", "wood", 0.0), 0.0) \
			or not is_equal_approx(Config.hit_mult("water", "wood", 0.5), -0.50) \
			or not is_equal_approx(Config.hit_mult("water", "wood", 1.0), -0.50):
		_fail("hit_mult 相生两侧 未按 0 → -50%% 解算")
		return
	# ---- 49. §2.3-C 木角色标定：受土 -75 / 受木 -90 / 受金 0 / 受水 -50 / 受火 -50 ----
	var calibrate := { "earth": -0.75, "wood": -0.90, "metal": 0.0,
		"water": -0.50, "fire": -0.50 }
	for tgt4 in calibrate:
		var got_cal := Config.hit_mult(String(tgt4), "wood", 1.0)
		if not is_equal_approx(got_cal, float(calibrate[tgt4])):
			_fail("§2.3-C 标定 木满同化受 %s 应为 %+.2f，实为 %+.2f"
				% [String(tgt4), float(calibrate[tgt4]), got_cal])
			return
	# ---- 50. apply_out_mult / apply_hit_mult：空元素必须完全不参与（倍率 1.0）----
	if not is_equal_approx(Config.apply_out_mult(100.0, "", "wood"), 100.0) \
			or not is_equal_approx(Config.apply_out_mult(100.0, "wood", ""), 100.0) \
			or not is_equal_approx(Config.apply_hit_mult(100.0, "", "wood"), 100.0) \
			or not is_equal_approx(Config.apply_hit_mult(100.0, "wood", ""), 100.0):
		_fail("空元素时元素修正应为恒等（倍率 1.0）")
		return
	# 木打土（i_beat +0.25）：100 → 125；木打金（beats_me -0.25）：100 → 75
	if not is_equal_approx(Config.apply_out_mult(100.0, "wood", "earth"), 125.0) \
			or not is_equal_approx(Config.apply_out_mult(100.0, "wood", "metal"), 75.0):
		_fail("apply_out_mult 未按 §2.3-A 解算")
		return
	# ---- 50b. 敌表 element：写下的每一条都必须是合法五行 ----
	for eid in Config.ENEMIES:
		var ee := String(Config.ENEMIES[eid].get("element", ""))
		if ee != "" and not Config.ELEMENTS.has(ee):
			_fail("敌人 %s 的 element 非法：%s" % [String(eid), ee])
			return
	# 主题包 10 条必须五行齐全，否则「区块元素序」在某个区块会刷不出本区块的怪
	var themed := { "fire": 0, "wood": 0, "metal": 0, "water": 0, "earth": 0 }
	for eid2 in Config.ENEMIES:
		var e2 := String(Config.ENEMIES[eid2].get("element", ""))
		if e2 != "" and not String(eid2).begins_with("boss"):
			themed[e2] = int(themed[e2]) + 1
	for k in themed:
		if int(themed[k]) < 2:
			_fail("五行 %s 的普通怪不足 2 种（实际 %d）" % [String(k), int(themed[k])])
			return
	# BOSS 池六条必须都有 element（同属 BOSS 是 90% cap 的唯一实战触发源）
	for bid in Config.BOSS_POOL:
		if String(Config.ENEMIES[bid].get("element", "")) == "":
			_fail("BOSS %s 缺少 element（同属 BOSS 是 90%% cap 的唯一触发源）" % String(bid))
			return
	# ---- 50c. 区域元素序：末位必须是 same（同属），否则 90% cap 永远触发不了 ----
	if String(Config.REGION_SLOT_RELATIONS[Config.REGION_SLOT_RELATIONS.size() - 1]) != "same":
		_fail("区域关系序末位不是 same —— 同属 BOSS 拿不到 90%% cap")
		return
	# 关系序是「每区块一个」，长度 = 区块数（5），不是每区波数（4）
	if Config.REGION_SLOT_RELATIONS.size() != Config.BLOCK_COUNT:
		_fail("区域关系序长度 %d 应等于区块数 %d"
			% [Config.REGION_SLOT_RELATIONS.size(), Config.BLOCK_COUNT])
		return
	if Config.BLOCK_COUNT * Config.BLOCK_WAVES != 20:
		_fail("区块数 %d × 每区波数 %d 应等于 20（§8 定稿的 20 波结构）"
			% [Config.BLOCK_COUNT, Config.BLOCK_WAVES])
		return
	# S3.5 收口：WAVES_TOTAL 到此**硬等价**（S1 阶段留的 [note] 软提示已到期）。
	# 为什么值得一条硬断言：上面只校验了 BLOCK_COUNT × BLOCK_WAVES == 20 这条**结构**等式，
	# 却没校验波次上限**用的是不是这个结构** —— 若有人把 WAVES_TOTAL 改回 10，
	# 区块表照样按 5×4 出怪、主题照样 5 景区，但游戏在第 10 波就通关了，
	# 后 10 波的编排（含 W20 同属 BOSS 的 90% cap）全部变成死代码且无人报错。
	if Config.WAVES_TOTAL != Config.BLOCK_COUNT * Config.BLOCK_WAVES:
		_fail("WAVES_TOTAL(%d) 与区块结构（%d 区 × %d 波 = %d）不一致"
			% [Config.WAVES_TOTAL, Config.BLOCK_COUNT, Config.BLOCK_WAVES,
				Config.BLOCK_COUNT * Config.BLOCK_WAVES])
		return
	# BOSS_WAVE 必须落在标准局最后一波，否则 `is_boss_wave` 的 `w == BOSS_WAVE` 会
	# 指向一个根本不存在的波次（通关波没有 BOSS = 玩家打不完）。
	if Config.BOSS_WAVE != Config.WAVES_TOTAL:
		_fail("BOSS_WAVE(%d) 应等于标准局最后一波 WAVES_TOTAL(%d)"
			% [Config.BOSS_WAVE, Config.WAVES_TOTAL])
		return
	# 木角色的区域序：土→水→火→金→木
	var seq: Array = Config.REGION_SEQUENCE_WOOD
	if seq.size() != Config.BLOCK_COUNT:
		_fail("木角色区域序长度应为 %d" % Config.BLOCK_COUNT)
		return
	if String(seq[seq.size() - 1]) != "wood":
		_fail("木角色区域序末位应为木（同属），实为 %s" % String(seq[seq.size() - 1]))
		return
	# block_of：W1-4→1，W5→2，W20→5
	if Config.block_of(1) != 1 or Config.block_of(4) != 1 \
			or Config.block_of(5) != 2 or Config.block_of(20) != 5:
		_fail("block_of 区块划分错误（W1=%d W4=%d W5=%d W20=%d）"
			% [Config.block_of(1), Config.block_of(4), Config.block_of(5), Config.block_of(20)])
		return
	# ---- 50d. S3.5 区块轮转：推导链 / 区块池 / 区块加权 / 渐入 / 区域加成幂等 ----
	# ⚠️ 这一段是**后来补上的**，起因是复核时发现：
	#    上面 `REGION_SEQUENCE_WOOD` 只被检查了「长度」和「末位是木」，
	#    而它存在的**全部意义**是「推导结果 == 手写期望」的交叉校验 ——
	#    缺了那条比对，`region_sequence()` 等一整套 S3.5 推导链等于没有任何断言覆盖。
	# 1) 推导 == 手写期望（木角色）
	var derived: Array = Config.region_sequence("wood")
	if derived != Config.REGION_SEQUENCE_WOOD:
		_fail("木角色区域序推导结果与手写期望不符（推导 %s / 期望 %s）"
			% [str(derived), str(Config.REGION_SEQUENCE_WOOD)])
		return
	# 2) 推广到**任意**角色元素：逐位验证「该位元素与 owner 的关系 == 该位应处的关系」。
	#    这条才是真正的不变量 —— 它保证 5 个元素角色共用一套关系序，
	#    而不是只对「木」写死一张表（§9.3 的思路，也是为什么不需要 5 张表）。
	for owner6 in Config.ELEMENTS:
		var seq_own: Array = Config.region_sequence(String(owner6))
		if seq_own.size() != Config.REGION_SLOT_RELATIONS.size():
			_fail("角色元素 %s 的区域序长度不对（%d）" % [String(owner6), seq_own.size()])
			return
		for i6 in seq_own.size():
			var slot_rel := String(Config.REGION_SLOT_RELATIONS[i6])
			var got_rel := Config.element_relation(String(owner6), String(seq_own[i6]))
			if got_rel != slot_rel:
				_fail("区域序推导错位：%s 角色第 %d 位应处于 %s，实际元素 %s 的关系是 %s"
					% [String(owner6), i6 + 1, slot_rel, String(seq_own[i6]), got_rel])
				return
	# 3) 白板回落木序 —— 但**回落不等于获得了木属性**（对照组必须保持空元素）
	if Config.region_sequence("") != Config.REGION_SEQUENCE_WOOD:
		_fail("白板角色的区域序应回落木序（纯内容编排默认值）")
		return
	if Config.element_for_character("potato") != "":
		_fail("土豆勇者的元素必须保持空串 —— 回落区域序不等于给它补了五行归属")
		return
	# 4) wave_area_element：区块内恒定、跨区块必变
	if Config.wave_area_element("wood", 1) != Config.wave_area_element("wood", 4) \
			or Config.wave_area_element("wood", 4) == Config.wave_area_element("wood", 5):
		_fail("wave_area_element 未按区块跳变（W1=%s W4=%s W5=%s）"
			% [Config.wave_area_element("wood", 1), Config.wave_area_element("wood", 4),
				Config.wave_area_element("wood", 5)])
		return
	# 5) W10-20 **不掉进无尽公式**（§8.2 点名的头号坑）。
	#    判据刻意选「区块内逐项稳定」而不是「与无尽结果不相等」：
	#    旧的无尽公式权重**每波都在变**（`t` 随波次爬升），所以「W10 == W11」
	#    本身就是「W10-20 走的是区块表」的证据，出问题时诊断信息也更有指向性。
	GameState.endless = false
	if Config.wave_composition(10) != Config.wave_composition(11):
		_fail("标准局区块内出怪池不稳定（W10 ≠ W11）—— W10-20 可能掉进了无尽公式")
		return
	if Config.wave_composition(8) == Config.wave_composition(9):
		_fail("区块边界未换池（W8 与 W9 相同，跨的是区块 2 → 3）")
		return
	for tid5 in Config.THEMED_POOL_LADDER[Config.BLOCK_COUNT - 1]:
		if not _comp_ids(Config.wave_composition(20)).has(String(tid5)):
			_fail("标准局 W20 应含区块 5 的阵营怪 %s（区块表未生效到最后一波）" % String(tid5))
			return
	# 5.5) 前期（W2 / W6）远程怪占比显著低于区块 3（W10）——「1.8 关前降低弹幕怪概率」需求。
	#    直接比 ranged 名单合计权重占比，而不是只验「表里有值」这种弱断言。
	var _c2 := Config.wave_composition(2)
	var _c6 := Config.wave_composition(6)
	var _c10 := Config.wave_composition(10)
	var _share2 := _ranged_share_of(_c2)
	var _share6 := _ranged_share_of(_c6)
	var _share10 := _ranged_share_of(_c10)
	if _share2 >= _share10 or _share6 >= _share10:
		_fail("前期远程怪占比未低于区块3（W2/W6 ≥ W10）：%.3f / %.3f / %.3f"
			% [_share2, _share6, _share10])
		return
	# 6) compose_pool 区块加权：本区区域元素那只元素怪 ×2，其余一律不动。
	#    木角色区块 2（W5-8）的区域元素是水 → 只有 `water_splitter` 翻倍。
	#    ⚠️ 「其余不动」这半条不能省：只验翻倍的话，实现写成「所有元素怪都翻倍」也照样通过。
	var area5 := Config.wave_area_element("wood", 5)
	var mob5 := String(Config.ELEMENT_MOB_FOR.get(area5, ""))
	var base5: Array = Config.wave_composition(5)
	var pool5: Array = Config.compose_pool(5, "wood")
	if mob5 == "" or pool5.size() != base5.size():
		_fail("compose_pool 不应改变条目数（mob=%s base=%d pool=%d）"
			% [mob5, base5.size(), pool5.size()])
		return
	var base_w := _pool_weight(base5, mob5)
	if base_w <= 0.0 \
			or not is_equal_approx(_pool_weight(pool5, mob5), base_w * Config.BLOCK_WEIGHT_MULT):
		_fail("区块加权未生效（%s：%.4f → %.4f，期望 ×%.1f）"
			% [mob5, base_w, _pool_weight(pool5, mob5), Config.BLOCK_WEIGHT_MULT])
		return
	for mid6 in Config.ELEMENT_MOB_IDS:
		if String(mid6) == mob5:
			continue
		if not is_equal_approx(_pool_weight(pool5, String(mid6)), _pool_weight(base5, String(mid6))):
			_fail("非本区主元素的元素怪 %s 被误加权（「主元素突出」变成了「全都翻倍」）"
				% String(mid6))
			return
	# 7) W2 元素怪渐入白名单：恰好只放最温和的两只（理由见 `ELEMENT_MOB_W2_IDS` 注释）
	var w2_mobs: Array = []
	for mid7 in _comp_ids(Config.wave_composition(2)):
		if Config.ELEMENT_MOB_IDS.has(String(mid7)):
			w2_mobs.append(String(mid7))
	w2_mobs.sort()
	var want_w2: Array = (Config.ELEMENT_MOB_W2_IDS as Array).duplicate()
	want_w2.sort()
	if w2_mobs != want_w2:
		_fail("W2 元素怪与渐入白名单不符（实际 %s / 期望 %s）" % [str(w2_mobs), str(want_w2)])
		return
	# 8) 区域加成（§5.5.3）：进新区首波发一次，**同区块重复调用必须无效**。
	#    这是「反复读档就能反复白拿同化度」的唯一护栏，必须有行为断言 ——
	#    光看 `_grant_area_bonus` 里那个 `block > area_bonus_block` 是看不出漏洞的。
	var pl_r: Node = _main.get_node("Player")
	var blk_bak: int = GameState.area_bonus_block
	var area_bak := String(GameState.area_element)
	var key_r := "assim_earth"
	var stat_bak: float = float(pl_r.stats.get(key_r, 0.0))
	GameState.area_element = "earth"
	GameState.area_bonus_block = 0
	pl_r.stats[key_r] = 0.0
	_main._grant_area_bonus(1)
	var after_first: float = float(pl_r.stats.get(key_r, 0.0))
	_main._grant_area_bonus(1)   # 同一区块再来一次：必须无效
	var after_second: float = float(pl_r.stats.get(key_r, 0.0))
	pl_r.stats[key_r] = stat_bak          # 先还原再断言，避免中途 return 污染后续用例
	GameState.area_bonus_block = blk_bak
	GameState.area_element = area_bak
	if not is_equal_approx(after_first, Config.AREA_BONUS):
		_fail("区域加成未发放（assim_earth = %.4f，应为 %.2f）"
			% [after_first, Config.AREA_BONUS])
		return
	if not is_equal_approx(after_second, after_first):
		_fail("区域加成不幂等：同一区块重复领取（%.4f → %.4f）" % [after_first, after_second])
		return
	# ---- 51. 角色五行推导：空串合法，非空必须合法，且金印记不再缺失 ----
	for cid in Registry.characters:
		var ce := Config.element_for_character(String(cid))
		if ce != "" and not Config.ELEMENTS.has(ce):
			_fail("角色 %s 推导出非法五行：%s" % [String(cid), ce])
			return
	for elem in Config.ELEMENTS:
		if not Config.SIGILS.has(elem):
			_fail("五行印记缺失：%s（每个五行都要有印记，否则该行角色无印记可配）" % String(elem))
			return
	print("SMOKE: element engine OK (5x5 关系解算 / 标定 / 区域序推导 / 区块轮转 / 区域加成幂等 全部对上 §2.3+§8)")

## 五行伤害通道：8 条通道是否真的把元素传到了终点。
## 分两半 —— 输出侧（玩家→怪）与受击侧（怪→玩家），各自拿真实节点跑一次。
func _check_element_channels() -> void:
	var pl: Node = _main.get_node("Player")
	# ---- 输出侧：_roll_damage 打包 element / assim ----
	var roll: Dictionary = pl._roll_damage(10.0, {})
	if not roll.has("element") or not roll.has("assim"):
		_fail("_roll_damage 未打包 element/assim（输出侧元素通道断了）")
		return
	if String(roll.element) != String(pl.element):
		_fail("_roll_damage 的元素（%s）与玩家归属（%s）不符"
			% [String(roll.element), String(pl.element)])
		return
	# 武器显式声明 element 时应当覆盖角色归属
	var roll_w: Dictionary = pl._roll_damage(10.0, { "element": "fire" })
	if String(roll_w.element) != "fire":
		_fail("武器自带 element 未覆盖角色归属（得 %s）" % String(roll_w.element))
		return
	# ---- 受击侧（怪物）：同一发 100 点伤害，按元素打出不同结果 ----
	# 木怪受金（金克木 → 基 +25%）应为 125；受土（木克土 → 基 -25%）应为 75；
	# 无属性怪恒定 100；木怪带 0.50 抗性受水（相生 0 → 关系 1.0，抗性 0.50）应为 50。
	var cases := [
		{ "e": "wood", "atk": "metal", "resist": 0.0,  "want": 125.0, "why": "木受金（克我 +25%）" },
		{ "e": "wood", "atk": "earth", "resist": 0.0,  "want": 75.0,  "why": "木受土（我克 -25%）" },
		{ "e": "",     "atk": "metal", "resist": 0.0,  "want": 100.0, "why": "无属性不吃修正" },
		{ "e": "wood", "atk": "water", "resist": 0.50, "want": 50.0,  "why": "木受水（相生 0 × 抗性 50%）" },
		{ "e": "wood", "atk": "wood",  "resist": 0.40, "want": 54.0,  "why": "木受木（同属 -10% × 抗性 40%）" },
	]
	for c in cases:
		var en := _spawn_test_enemy(String(c.e), 1, float(c.resist))
		if en == null:
			return
		en.take_damage(100.0, false, true, String(c.atk))
		var lost: float = 100000.0 - en.hp
		en.queue_free()
		if absf(lost - float(c.want)) > 0.7:
			_fail("%s 应扣 %.0f，实扣 %.2f" % [String(c.why), float(c.want), lost])
			return
	# ---- 受击侧（玩家）：收 element 参数且真的修正 ----
	var pl_elem := String(pl.element)
	if pl_elem != "":
		# 找出「克我」的元素，无同化度时应吃 +25%
		var nemesis := ""
		for oe in Config.ELEMENTS:
			if Config.element_relation(String(oe), pl_elem) == "beats_me":
				nemesis = String(oe)
				break
		if nemesis != "":
			var saved_hp: float = pl.hp
			var saved_ifr: float = pl.iframes
			var saved_dodge: float = float(pl.stats.dodge)
			var saved_armor: float = float(pl.stats.armor)
			var saved_assim: float = float(pl.stats.get("assim_" + nemesis, 0.0))
			pl.iframes = 0.0
			pl.stats.dodge = 0.0
			pl.stats.armor = 0.0
			pl.stats["assim_" + nemesis] = 0.0
			pl.hp = 100000.0
			pl.take_damage(100.0, nemesis)
			var took: float = 100000.0 - pl.hp
			if took < 120.0:
				_fail("玩家受「克我」元素（%s）应吃 +25%%，实扣 %.2f" % [nemesis, took])
				pl.hp = saved_hp
				pl.iframes = saved_ifr
				pl.stats.dodge = saved_dodge
				pl.stats.armor = saved_armor
				pl.stats["assim_" + nemesis] = saved_assim
				return
			# 同化度拉满 → 增伤被压回 0（不该变成减伤）
			pl.stats["assim_" + nemesis] = 1.0
			pl.hp = 100000.0
			pl.take_damage(100.0, nemesis)
			var took2: float = 100000.0 - pl.hp
			if absf(took2 - 100.0) > 0.6:
				_fail("玩家满同化度受「克我」应恰好扛平（100），实扣 %.2f" % took2)
			pl.hp = saved_hp
			pl.iframes = saved_ifr
			pl.stats.dodge = saved_dodge
			pl.stats.armor = saved_armor
			pl.stats["assim_" + nemesis] = saved_assim
	print("SMOKE: element channels OK (输出侧 roll / 受击侧 enemy+player 共 8 条通道)")

## 输出侧元素修正真正「乘进 dmg」（§12-S1.5 / §13 第 4 条）。
##
## 与 _check_element_channels 的分工：
##   · channels 验的是「元素**传到了**终点」（打包 element/assim、受击侧解算）；
##   · 这里验的是「元素**算出分差**了」（角色元素 × 武器元素 → dmg 真的不一样）。
## 两者缺一不可 —— 上一步的 E25/E26 只验打包，即使 out_mult 全程为 0 也照样绿，
## 那正是 S1.5 要补的洞（"输出侧不接，六个角色的差异就只剩减伤"）。
##
## 断言刻意用**比值**而非绝对值：所有公式里都有 dmg_mult 这个公因子，
## 断言比值就与角色平衡数值（0.92 / 0.95 / 1.05…）解耦 ——
## 以后调角色强度不会把这条断言调红，但它照样能抓到 out_mult 算错。
##
## ⚠️⚠️ **暴击是一个独立随机乘区，必须在断言里消掉**。
##     曾在此处直接比较两发 `_roll_damage` 的 dmg，结果恰好其中一发暴击（× crit_mult），
##     断言以「实现错了」的面目报红 —— 而实现其实是对的。随机性不该参与断言。
##     做法：所有必需数值一律改用非暴击基准 `crit_ch = 0` 取（见 _roll_base 注释）。
func _check_element_output() -> void:
	var pl: Node = _main.get_node("Player")
	var saved_elem := String(pl.element)
	var saved_crit: float = float(pl.stats.crit_ch)
	var saved_assim: Dictionary = {}
	for e in Config.ELEMENTS:
		saved_assim[String(e)] = float(pl.stats.get("assim_" + String(e), 0.0))
		pl.stats["assim_" + String(e)] = 0.0
	pl.stats.crit_ch = 0.0   # 关掉暴击：见上方说明，随机性不得进入断言

	# ---- E29：§2.3-A 木角色 5 档，逐条对上 out_mult ----
	# 木 vs 土 我克 +25% / 水 生我 +15% / 木 同属 +10% / 火 我生 -15% / 金 克我 -25%
	pl.element = "wood"
	var spec := [
		{ "w": "earth", "rel": "i_beat",   "want": +0.25 },
		{ "w": "water", "rel": "gen_me",   "want": +0.15 },
		{ "w": "wood",  "rel": "same",     "want": +0.10 },
		{ "w": "fire",  "rel": "i_gen",    "want": -0.15 },
		{ "w": "metal", "rel": "beats_me", "want": -0.25 },
	]
	# 先算一遍基准（同 base、同 dmg_mult），后面比值断言要用
	var dmg_of: Dictionary = {}
	for c in spec:
		var w := String(c.w)
		if Config.element_relation("wood", w) != String(c.rel):
			_fail("木 vs %s 的关系应为 %s，实为 %s"
				% [w, String(c.rel), Config.element_relation("wood", w)])
			_restore_element_output(pl, saved_elem, saved_crit, saved_assim)
			return
		if absf(Config.out_mult("wood", w) - float(c.want)) > 1e-6:
			_fail("out_mult(木, %s) 应为 %+.2f，实为 %+.2f"
				% [w, float(c.want), Config.out_mult("wood", w)])
			_restore_element_output(pl, saved_elem, saved_crit, saved_assim)
			return
		var r: Dictionary = pl._roll_damage(100.0, { "element": w })
		# roll 必须带回 out_mult（不吃暴击：暴击是独立乘区，会污染比值）
		if not r.has("out_mult"):
			_fail("_roll_damage 未回传 out_mult（输出侧无处可验）")
			_restore_element_output(pl, saved_elem, saved_crit, saved_assim)
			return
		if absf(float(r.out_mult) - float(c.want)) > 1e-6:
			_fail("木持 %s：roll.out_mult 应为 %+.2f，实为 %+.2f"
				% [w, float(c.want), float(r.out_mult)])
			_restore_element_output(pl, saved_elem, saved_crit, saved_assim)
			return
		if bool(r.crit):
			_fail("crit_ch 已置 0，_roll_damage 仍暴击（随机源没被真正压住）")
			_restore_element_output(pl, saved_elem, saved_crit, saved_assim)
			return
		dmg_of[w] = float(r.dmg)

	# ---- E30：§13 第 4 条 —— 木持土 vs 木持金，同目标伤害比值 1.25/0.75 ----
	# 这一条是规格书里逐字写下的口径，也是「武器选择真的影响输出」的最小证据
	var ratio: float = float(dmg_of["earth"]) / maxf(0.0001, float(dmg_of["metal"]))
	if absf(ratio - (1.25 / 0.75)) > 0.01:
		_fail("木持土 / 木持金 伤害比值应为 %.3f，实为 %.3f（土 %.2f 金 %.2f）"
			% [1.25 / 0.75, ratio, float(dmg_of["earth"]), float(dmg_of["metal"])])
		_restore_element_output(pl, saved_elem, saved_crit, saved_assim)
		return

	# ---- E31：相生两侧的方向 —— gen_me 为正、i_gen 为负 ----
	# 受击侧区分不了这两档（同基数 0），只有输出侧能验，故必须在这里验
	if not (float(dmg_of["water"]) > float(dmg_of["wood"])):
		_fail("木持水（生我 +15%%）应高于木持木（同属 +10%%）：%.2f vs %.2f"
			% [float(dmg_of["water"]), float(dmg_of["wood"])])
		_restore_element_output(pl, saved_elem, saved_crit, saved_assim)
		return
	if not (float(dmg_of["fire"]) < float(dmg_of["wood"])):
		_fail("木持火（我生 -15%%）应低于木持木（同属 +10%%）：%.2f vs %.2f"
			% [float(dmg_of["fire"]), float(dmg_of["wood"])])
		_restore_element_output(pl, saved_elem, saved_crit, saved_assim)
		return

	# ---- E32：武器不声明 element 时，沿用角色元素（且与「显式同元素」等价）----
	var r_implicit: Dictionary = pl._roll_damage(100.0, {})
	if String(r_implicit.element) != "wood":
		_fail("武器未声明元素时应沿用角色元素 wood，实为 %s" % String(r_implicit.element))
		_restore_element_output(pl, saved_elem, saved_crit, saved_assim)
		return
	if absf(float(r_implicit.out_mult) - float(dmg_of_want_same())) > 1e-6:
		_fail("武器未声明元素时 out_mult 应为同属档，实为 %+.4f" % float(r_implicit.out_mult))
		_restore_element_output(pl, saved_elem, saved_crit, saved_assim)
		return
	if absf(float(r_implicit.dmg) - float(dmg_of["wood"])) > 1e-4:
		_fail("武器未声明元素（%.2f）应与显式声明同元素（%.2f）完全等价"
			% [float(r_implicit.dmg), float(dmg_of["wood"])])
		_restore_element_output(pl, saved_elem, saved_crit, saved_assim)
		return

	# ---- E33：白板角色不吃任何输出侧修正（土豆勇者不该有五行红利）----
	pl.element = ""
	var r_blank: Dictionary = pl._roll_damage(100.0, { "element": "earth" })
	var dmg_blank: float = float(r_blank.dmg)
	if absf(float(r_blank.out_mult)) > 1e-6:
		_fail("白板角色 out_mult 应为 0，实为 %+.4f" % float(r_blank.out_mult))
		_restore_element_output(pl, saved_elem, saved_crit, saved_assim)
		return
	pl.element = "wood"
	# 白板（无修正）应当**低于**木持土（+25%）
	if not (dmg_blank < float(dmg_of["earth"])):
		_fail("白板角色（%.2f）应低于木持土（%.2f）" % [dmg_blank, float(dmg_of["earth"])])
		_restore_element_output(pl, saved_elem, saved_crit, saved_assim)
		return

	# ---- E34：⚠️ 回归 —— _roll_damage 绝不能回写成员变量 element ----
	# 这是 S1.5 实施时真实踩到的坑：早期版本让 atk_element 覆盖了 element，
	# 于是「木角色装土武器」之后连**受击侧**的减伤都跟着变成土（按土元素算被克），
	# 输出侧与受击侧同时错、且完全静默。这里把它钉死。
	if String(pl.element) != "wood":
		_fail("_roll_damage 回写了角色元素：期望仍为 wood，实为 %s"
			% String(pl.element))
		_restore_element_output(pl, saved_elem, saved_crit, saved_assim)
		return

	# ---- E35：同化度取「武器元素」那一列，不是「角色元素」那一列（S8 拍板 · 体检表 §4 决策 B）----
	# 同化度 = 你跟这个元素的亲和度：用它打人更痛（输出侧）、挨它打更抗（受击侧），两侧都是加算。
	# 木角色持**土武器**，堆 assim_earth=0.5 → out_mult(+0.25) + assim(0.50) = +0.75
	# 若误取 assim_wood（角色先天五行那列）就只剩 +0.25，差 0.50
	pl.stats["assim_earth"] = 0.5
	var r_assim: Dictionary = pl._roll_damage(100.0, { "element": "earth" })
	if absf(float(r_assim.out_mult) - 0.75) > 1e-6:
		_fail("同化度应取武器元素（assim_earth=0.5 → +0.75），实为 %+.4f"
			% float(r_assim.out_mult))
		_restore_element_output(pl, saved_elem, saved_crit, saved_assim)
		return
	# 同化度落在 dmg 上也要对得上：满 0.5 的相对增益 = (1+0.75)/(1+0.25) = 1.4
	var want_assim_ratio: float = (1.0 + 0.75) / (1.0 + 0.25)
	var got_assim_ratio: float = float(r_assim.dmg) / maxf(0.0001, float(dmg_of["earth"]))
	if absf(got_assim_ratio - want_assim_ratio) > 0.01:
		_fail("同化度未传导致 dmg：比值应 %.3f，实为 %.3f" % [want_assim_ratio, got_assim_ratio])
		_restore_element_output(pl, saved_elem, saved_crit, saved_assim)
		return
	pl.stats["assim_earth"] = 0.0
	# 反向对照：堆的是**角色**元素（assim_wood）→ 不该影响输出（那条只走受击侧口径）。
	# ⚠️ 没有这条反向断言，上面那个 0.75 有可能只是「碰巧两边都读了」的假绿。
	pl.stats["assim_wood"] = 0.5
	var r_assim2: Dictionary = pl._roll_damage(100.0, { "element": "earth" })
	if absf(float(r_assim2.out_mult) - 0.25) > 1e-6:
		_fail("输出修正不得读 assim_<角色元素>（应仍为 +0.25，实为 %+.4f）"
			% float(r_assim2.out_mult))
		_restore_element_output(pl, saved_elem, saved_crit, saved_assim)
		return
	pl.stats["assim_wood"] = 0.0

	_restore_element_output(pl, saved_elem, saved_crit, saved_assim)
	print("SMOKE: element output OK (5 档标定 / 木土金比值 1.67 / 相生方向 / 白板 / 不回写 / 同化度取列)")

## 木 vs 木（同属）的输出倍率，供 E32 的等价断言引用
func dmg_of_want_same() -> float:
	return Config.out_mult("wood", "wood")

## 还原 _check_element_output 动过的玩家字段（元素快照 + 暴击率 + 全五系同化度）
func _restore_element_output(pl: Node, elem: String, crit: float, assim: Dictionary) -> void:
	pl.element = elem
	pl.stats.crit_ch = crit
	for e in assim:
		pl.stats["assim_" + String(e)] = float(assim[e])

## 造一只测试用敌人并挂到主场景（受击结算需要 parent 与 player 引用）。
## 沿用冒烟测试既有约定：走 enemy.tscn 实例化（而非 Enemy.new()），保证子节点齐备。
func _spawn_test_enemy(elem: String, wave: int, resist: float) -> Node:
	var container: Node = _main
	var wm: Node = _main.get_node_or_null("Enemies")
	if wm != null:
		container = wm
	var en = preload("res://scenes/enemies/enemy.tscn").instantiate()
	container.add_child(en)
	en.setup("wood_sprite" if elem == "wood" else "grunt", wave)
	en.element = elem
	en.element_resist = resist
	en.hp = 100000.0
	en.max_hp = 100000.0
	en.player = _main.get_node_or_null("Player")
	return en


## 五行基础怪 + 怪物抗性模型（五行 §12-S3）。四块：
##   ① 5 只元素怪的清单（ELEMENT_MOB_FOR / ELEMENT_MOB_IDS）自洽，且每只的归属与机制字段在位
##   ② 抗性曲线 `Config.mob_resist` 逐条对 §5.5.2 标定（简单/困难/噩梦 + 同属 BOSS 光环）
##   ③ 抗性 cap 表 `Config.mob_cap` 与玩家侧**只有 same 一行**不同
##   ④ 元素怪真的进了刷怪表，且机制**真的被消费**（只查字段存在抓不到「声明了没人读」）
func _check_element_mobs() -> void:
	# ---- S3-1：唯一的元素怪清单必须自洽（散写 id 就会散架）----
	if Config.ELEMENT_MOB_FOR.size() != 5:
		_fail("ELEMENT_MOB_FOR 应有 5 条（每元素一名代言怪），实为 %d" % Config.ELEMENT_MOB_FOR.size())
		return
	if Config.ELEMENT_MOB_IDS.size() != 5:
		_fail("ELEMENT_MOB_IDS 应有 5 条，实为 %d" % Config.ELEMENT_MOB_IDS.size())
		return
	var ids_sorted: Array = Config.ELEMENT_MOB_IDS.duplicate()
	ids_sorted.sort()
	var from_map: Array = []
	for e0 in Config.ELEMENTS:
		if not Config.ELEMENT_MOB_FOR.has(String(e0)):
			_fail("ELEMENT_MOB_FOR 缺少元素 %s" % String(e0))
			return
		from_map.append(String(Config.ELEMENT_MOB_FOR[String(e0)]))
	from_map.sort()
	if from_map != ids_sorted:
		_fail("ELEMENT_MOB_IDS 与 ELEMENT_MOB_FOR 不一致：%s vs %s"
			% [str(ids_sorted), str(from_map)])
		return

	# ---- S3-2：5 只元素怪注册齐，且 element 与归属一致 ----
	# ⚠️ element 必须显式声明且落在 ELEMENTS 内：写错一个字母会被 Enemy.setup 静默清空，
	#    表现为「这只怪不吃元素修正」，且全程无报错。
	for e1 in Config.ELEMENTS:
		var mid := String(Config.ELEMENT_MOB_FOR[String(e1)])
		if not Registry.enemies.has(mid):
			_fail("元素怪 %s（%s）未注册" % [mid, String(e1)])
			return
		var ecfg: Dictionary = Registry.enemies[mid]
		if String(ecfg.get("element", "")) != String(e1):
			_fail("元素怪 %s 的 element 应为 %s，实为「%s」"
				% [mid, String(e1), String(ecfg.get("element", ""))])
			return

	# ---- S3-3：每只元素怪的「机制代言字段」必须在位 ----
	# 这一段是「字段写错/漏写」的拦截 —— `_valid()` 不拒绝未知字段，
	# 所以写错的机制字段会**静默注册成功**，然后以「内容表里有、游戏里没效果」的面目出现。
	var mech := {
		"metal_guard": ["shield", "shield_resist", "armor_pierce"],
		"wood_healer": ["regen", "regen_delay"],
		"water_splitter": ["split_on_death"],
	}
	for mid2 in mech:
		if not Registry.enemies.has(String(mid2)):
			_fail("机制字段清单里有未注册的怪：%s" % String(mid2))
			return
		var mcfg: Dictionary = Registry.enemies[String(mid2)]
		for f0 in mech[mid2]:
			if not mcfg.has(String(f0)):
				_fail("%s 缺少机制字段 %s（会被静默注册，但游戏里没效果）" % [String(mid2), String(f0)])
				return
	if float(Registry.enemies["metal_guard"].get("shield", 0.0)) <= 0.0:
		_fail("金甲卫 shield 必须 > 0（否则机制形同虚设）")
		return
	if float(Registry.enemies["wood_healer"].get("regen", 0.0)) <= 0.0:
		_fail("回春灵 regen 必须 > 0")
		return
	if float(Registry.enemies["wood_healer"].get("regen_delay", 0.0)) <= 0.0:
		_fail("回春灵 regen_delay 必须 > 0（没有受击停顿就是打不死的怪）")
		return
	var sp = Registry.enemies["water_splitter"].get("split_on_death", {})
	if not (sp is Dictionary) or (sp as Dictionary).is_empty():
		_fail("分裂水灵 split_on_death 必须是非空字典")
		return
	if String((sp as Dictionary).get("type", "")) != "water_splitter":
		_fail("分裂水灵应分裂成自己，实为 %s" % String((sp as Dictionary).get("type", "")))
		return
	if String(Registry.enemies["fire_caster"].get("ai", "")) != "shooter":
		_fail("赤焰法师应是 shooter（复用既有 AI，不新增形态）")
		return
	# 土·岩卫是刻意的**无机制对照组**：它一旦带上机制，「基础解」这个基准就不存在了
	for f1 in ["shield", "shield_resist", "armor_pierce", "regen", "regen_delay", "split_on_death"]:
		if Registry.enemies["earth_bulwark"].has(String(f1)):
			_fail("岩卫应是无机制对照组，却带了 %s" % String(f1))
			return

	# ---- S3-4：抗性曲线 §5.5.2 —— 逐条对难度标定 ----
	# ⚠️ 这一组断言的**真正目的是钉死「难度 × 波次成长 = 乘法」**。
	#    若有人照规划正文的笔误改回加法，三档在 W20 全部撞上 0.75，
	#    下面的单调断言立刻报红（这正是判据该抓的东西）。
	var r_normal := Config.mob_resist(20, 0.45)
	var r_hard := Config.mob_resist(20, 0.60)
	var r_night := Config.mob_resist(20, 0.75)
	if absf(r_normal - 0.45) > 1e-6 or absf(r_hard - 0.60) > 1e-6 or absf(r_night - 0.75) > 1e-6:
		_fail("W20 抗性应为 0.45 / 0.60 / 0.75，实为 %.3f / %.3f / %.3f"
			% [r_normal, r_hard, r_night])
		return
	if not (r_normal < r_hard and r_hard < r_night):
		_fail("三档难度在 W20 必须单调可分（0.45 < 0.60 < 0.75）—— 全相等说明公式退回加法了")
		return
	if absf(Config.mob_resist(1, 0.75)) > 1e-6:
		_fail("W1 抗性必须为 0（起始波不该有元素抗性）")
		return
	if absf(Config.mob_resist(20, 0.75, 0.0, 0.15, Config.CAP_MOB_SAME_BOSS) - 0.90) > 1e-6:
		_fail("噩梦 W20 同属 BOSS 光环应到 0.90（全项目唯一的 90%% 通道）")
		return
	if absf(Config.mob_resist(20, 0.75, 0.10, 0.15, 0.75) - 0.75) > 1e-6:
		_fail("普通怪抗性必须被 0.75 cap 封住（区块偏置 + 光环不得越界）")
		return

	# ---- S3-5：抗性 cap 表 §5.5.1 —— 与玩家侧只有 same 一行不同 ----
	for atk in Config.ELEMENTS:
		var rel := Config.element_relation("wood", String(atk))   # 防御方 = 木
		var mcap := Config.mob_cap(String(atk), "wood")
		if rel == "same":
			if absf(mcap - 0.75) > 1e-6:
				_fail("普通怪同属 cap 应为 0.75（玩家才是 0.90），实为 %.2f" % mcap)
				return
			if absf(Config.mob_cap(String(atk), "wood", true) - 0.90) > 1e-6:
				_fail("同属 BOSS 吃光环时 cap 应提到 0.90，实为 %.2f"
					% Config.mob_cap(String(atk), "wood", true))
				return
		elif absf(mcap - Config.hit_cap(String(atk), "wood")) > 1e-6:
			_fail("怪侧 cap(%s → 木) 应与玩家侧同为 %.2f，实为 %.2f（两侧只允许 same 一行不同）"
				% [String(atk), Config.hit_cap(String(atk), "wood"), mcap])
			return
	if absf(Config.mob_cap("", "wood")) > 1e-6 or absf(Config.mob_cap("wood", "")) > 1e-6:
		_fail("空元素抗性 cap 必须为 0（无属性攻击不吃元素减伤）")
		return

	# ---- S3-6：元素怪真的进了刷怪表（内容表里有、刷怪表里没有 = 白做）----
	var w1_ids := _comp_ids(Registry.wave_composition(1))
	for mid3 in Config.ELEMENT_MOB_IDS:
		if w1_ids.has(String(mid3)):
			_fail("W1 不应出现元素怪（%s）—— 开局是 95px 近战，首杀窗口会被拖长" % String(mid3))
			return
	var w3_ids := _comp_ids(Registry.wave_composition(3))
	var n3 := 0
	for mid4 in Config.ELEMENT_MOB_IDS:
		if w3_ids.has(String(mid4)):
			n3 += 1
	if n3 < 3:
		_fail("W3 至少应含 3 只元素怪（实际 %d）—— 五行克制要早期就能被感受到" % n3)
		return
	for wnum in [4, 10]:
		var ids: Array = _comp_ids(Registry.wave_composition(int(wnum)))
		for mid5 in Config.ELEMENT_MOB_IDS:
			if not ids.has(String(mid5)):
				_fail("W%d 五行应齐全，缺少 %s" % [int(wnum), String(mid5)])
				return

	# ---- S3-7：机制真的被消费（行为断言）----
	# ① 穿甲：只在内容表里写 `armor_pierce` 是抓不到 bug 的（字段会被静默注册，
	#    而玩家侧根本读不到）。这里把「声明 → 结算」整条链钉死。
	# ② 断言用的是**比值**：法宝减伤等公因子会被约掉，与玩家配装解耦。
	var pl2: Node = _main.get_node("Player")
	var sv_armor: float = float(pl2.stats.armor)
	var sv_dodge: float = float(pl2.stats.dodge)
	var sv_hp: float = pl2.hp
	var sv_ifr: float = pl2.iframes
	pl2.stats.dodge = 0.0     # 关掉闪避：随机性不得进入断言
	pl2.stats.armor = 10.0    # 显式给护甲，否则穿甲再怎么变都不影响伤害
	# ⚠️ 探测前先摘掉玩家身上的法宝：
	#    `player.take_damage` 里 armor = stats.armor + ArtifactSystem.armor_bonus()，
	#    岩肤符（art_stone_skin）在「生命 ≥ 70%」时 +4 护甲；而 _probe_player_hit
	#    每次把 hp 顶到 1e6 → 这条加成必然生效。玩家这一局到底捡到哪件法宝随实机
	#    掉落/走位变化，于是写死的 1-10/18 = 2.25 会间歇性变成 1-14/22 = 2.75，
	#    报错还指向「穿甲实现错了」—— 典型的假红。（同样的坑也埋在后面
	#    「护甲为 0 时穿甲应无差别」那条：0 + 4 仍然要穿。）
	#    摘掉之后本用例自足：期望值只由 stats.armor 决定。
	var art_sv: Dictionary = (pl2.artifacts_owned as Dictionary).duplicate(true)
	var stk_sv: Dictionary = (pl2.artifact_stacks as Dictionary).duplicate(true)
	pl2.artifacts_owned = {}
	pl2.artifact_stacks = {}
	var d_no := _probe_player_hit(pl2, 100.0, 0.0)
	var d_full := _probe_player_hit(pl2, 100.0, 1.0)
	pl2.stats.armor = 0.0     # 护甲为 0 时，穿甲必须无差别（穿的是护甲，不是伤害）
	var d_zero_no := _probe_player_hit(pl2, 100.0, 0.0)
	var d_zero_full := _probe_player_hit(pl2, 100.0, 1.0)
	# 探针跑完立刻还原：下面两个断言都是 _fail 后 return，
	# 把还原子句放在它们之后会漏掉，污染后续用例的玩家状态。
	pl2.artifacts_owned = art_sv
	pl2.artifact_stacks = stk_sv
	pl2.stats.armor = sv_armor
	pl2.stats.dodge = sv_dodge
	pl2.hp = sv_hp
	pl2.iframes = sv_ifr
	var want_ratio := 1.0 / (1.0 - 10.0 / 18.0)   # 护甲 10 被穿光 / 完全不穿
	var got_ratio := d_full / maxf(0.0001, d_no)
	if absf(got_ratio - want_ratio) > 0.05:
		_fail("穿甲量纲不对：护甲 10 下 pierce1/pierce0 应为 %.3f，实为 %.3f（%.2f vs %.2f）"
			% [want_ratio, got_ratio, d_no, d_full])
		return
	if absf(d_zero_full - d_zero_no) > 0.01:
		_fail("护甲为 0 时穿甲不应改变伤害（说明削的是最终伤害而不是护甲）：%.2f vs %.2f"
			% [d_zero_no, d_zero_full])
		return

	print("SMOKE: element mobs OK (5 元素怪 / 抗性曲线 0.45-0.60-0.75 / 怪侧 cap 只差 same / 穿甲已消费)")

## ---- S4：元素出场闸门（§9.2 / §9.3）----
## 这一整套守的是「**难度 = 元素出场节奏**」：数值难度改错了看得出来，
## 闸门改错了只会表现成「简单难度怎么还有金怪」，不报错、也不影响通关。
func _check_element_gate() -> void:
	# ---- 4-1：木角色的三档闸门逐格对照 §9.2 的**手写禁止集** ----
	# 这里刻意写死规划原文翻译出来的表（而不是从代码反推）—— 那正是它存在的意义：
	# 推导链（ELEMENT_GATE → gate_allowed_relations → banned_elements）一旦改错，
	# 只有一份独立的手写期望才能发现。
	var expect := {
		"normal": [["wood", "metal", "water", "fire"], ["wood", "metal"], ["metal"],
			["metal"], []],
		"hard": [["wood", "metal"], ["metal"], ["metal"], [], []],
		"nightmare": [["wood", "metal"], [], [], [], []],
	}
	for diff in expect:
		for bi in range(Config.BLOCK_COUNT):
			var got := Config.banned_elements("wood", String(diff), bi + 1)
			var want: Array = expect[diff][bi]
			for e1 in Config.ELEMENTS:
				if bool(got.has(e1)) != want.has(e1):
					_fail("闸门表对不上 §9.2（%s / 区块 %d / %s）推导禁=%s 期望禁=%s"
						% [String(diff), bi + 1, e1, str(got.keys()).replace(",", ""),
							str(want).replace(",", "")])
					return

	# ---- 4-2：单调性 —— 难度递增禁得更少、区块递增禁得更少 ----
	# 「解锁区块号抄错一行」（例如把 normal 的 same_block 抄到 nightmare）在这里暴露。
	for bi2 in range(1, Config.BLOCK_COUNT + 1):
		var n_b: Dictionary = Config.banned_elements("wood", "normal", bi2)
		var h_b: Dictionary = Config.banned_elements("wood", "hard", bi2)
		var x_b: Dictionary = Config.banned_elements("wood", "nightmare", bi2)
		for e2 in Config.ELEMENTS:
			if bool(x_b.has(e2)) and not bool(h_b.has(e2)):
				_fail("难度单调性破坏：噩梦禁了 %s，困难却放行（区块 %d）" % [e2, bi2])
				return
			if bool(h_b.has(e2)) and not bool(n_b.has(e2)):
				_fail("难度单调性破坏：困难禁了 %s，简单却放行（区块 %d）" % [e2, bi2])
				return
	for diff2 in ["normal", "hard", "nightmare"]:
		for b3 in range(2, Config.BLOCK_COUNT + 1):
			var prev_b: Dictionary = Config.banned_elements("wood", diff2, b3 - 1)
			var cur_b: Dictionary = Config.banned_elements("wood", diff2, b3)
			for e3 in Config.ELEMENTS:
				if bool(cur_b.has(e3)) and not bool(prev_b.has(e3)):
					_fail("区块单调性破坏：%s 在区块 %d 禁了 %s，上一区块却放行"
						% [diff2, b3, e3])
					return

	# ---- 4-3：闸门只依赖「关系」，不依赖具体元素（§9.3 最关键的一步）----
	# 把木角色的禁止集**按关系**翻译到其它 4 个角色，必须逐元素完全一致 ——
	# 这条同时验证 `element_relation` 与 `element_with_relation` 互为逆运算；
	# 一旦有人给某个角色单独写了张表，这里立刻不一致。
	for pe in ["water", "fire", "metal", "earth"]:
		for diff3 in ["normal", "hard", "nightmare"]:
			for b4 in range(1, Config.BLOCK_COUNT + 1):
				# ⚠️ 只翻译「木角色**确实被禁**的那些元素」——
				#    从全部 5 个元素翻译过去会得到全集，断言就成了永真。
				var ref: Dictionary = Config.banned_elements("wood", diff3, b4)
				var want4 := {}
				for e4 in Config.ELEMENTS:
					if not bool(ref.has(e4)):
						continue
					# 木角色里 e4 相对木的关系 → 在本角色身上对应哪个元素
					var rel4 := Config.element_relation("wood", String(e4))
					want4[Config.element_with_relation(String(pe), rel4)] = true
				var got4: Dictionary = Config.banned_elements(String(pe), diff3, b4)
				for e5 in Config.ELEMENTS:
					if bool(got4.has(e5)) != bool(want4.has(e5)):
						_fail("闸门对 %s 不是「按关系映射」的结果（%s / 区块 %d / %s）"
							% [pe, diff3, b4, e5])
						return

	# ---- 4-4：基础池必须全无元素 ----
	# 这是「闸门永远不会把池子删空」的前提，也是 4-5 的前提。
	for ladder in Config.BASE_POOL_LADDER:
		for entry in ladder:
			var bid := String((entry as Dictionary).get("item", ""))
			if Config.mob_element(bid) != "":
				_fail("基础池出现了带元素的怪（%s = %s）：闸门会把它删掉，池子会越删越空"
					% [bid, Config.mob_element(bid)])
				return

	# ---- 4-5：池子永不被闸门清空（6 种角色 × 3 档难度 × 20 波）----
	for pe5 in ["", "wood", "water", "fire", "metal", "earth"]:
		for diff5 in ["normal", "hard", "nightmare"]:
			for w5 in range(1, Config.WAVES_TOTAL + 1):
				if Config.wave_composition(w5, diff5, String(pe5)).is_empty():
					_fail("闸门把出怪池清空了（角色=%s / %s / W%d）"
						% [pe5 if pe5 != "" else "白板", diff5, w5])
					return

	# ---- 4-6：闸门真的作用在整张池上（含阵营怪）----
	# 只过滤那 5 只基础元素怪的实现会在这里挂 —— 阵营怪同样带 element。
	var gated_block1 := _comp_ids(Config.wave_composition(4, "normal", "wood"))
	var ungated_has_other := false
	for mid_u in _comp_ids(Config.wave_composition(4)):
		var el_u := Config.mob_element(mid_u)
		if el_u != "" and el_u != "earth":
			ungated_has_other = true
	if not ungated_has_other:
		_fail("不设闸门时 W4 本应含非土元素怪 —— 4-6 失去对照（池子本身空了？）")
		return
	for mid_g in gated_block1:
		var el_g := Config.mob_element(mid_g)
		if el_g != "" and el_g != "earth":
			_fail("简单档区块 1 对木角色不该出「%s」属性怪（%s）—— 闸门漏穿了" % [el_g, mid_g])
			return
	# 区块 2 简单档仍禁金；区块 5 必须解禁金（末位那一格真的生效）
	for mid_2 in _comp_ids(Config.wave_composition(8, "normal", "wood")):
		if Config.mob_element(mid_2) == "metal":
			_fail("简单档区块 2 不该出金怪（%s）—— 克我应等到区块 5" % mid_2)
			return
	var late_metal := false
	for mid_5 in _comp_ids(Config.wave_composition(20, "normal", "wood")):
		if Config.mob_element(mid_5) == "metal":
			late_metal = true
	if not late_metal:
		_fail("简单档区块 5 应解禁「克我」= 金怪（§9.2）—— 末位那一格没生效")
		return
	# 噩梦提前到区块 2 就全开
	var early_metal := false
	for mid_7 in _comp_ids(Config.wave_composition(8, "nightmare", "wood")):
		if Config.mob_element(mid_7) == "metal":
			early_metal = true
	if not early_metal:
		_fail("噩梦档区块 2 应已全开（含金怪）——「最难档危险元素最早」没生效")
		return

	# ---- 4-7：Registry 与 Config 同一道闸门（mod spawn_table 也不能绕过）----
	for w8 in [4, 10, 20]:
		if _comp_ids(Registry.wave_composition(w8, "normal", "wood")) \
				!= _comp_ids(Config.wave_composition(w8, "normal", "wood")):
			_fail("Registry.wave_composition 与 Config 结果不一致（W%d）—— "
				% w8 + "mod spawn_table 覆盖路径绕过了闸门")
			return

	# ---- 4-8：真实出怪路径确实带上了难度与玩家元素（接线断言）----
	# 漏传难度时闸门静默失效（数值难度照旧生效，所以"感觉不出来"）—— 这条守住那根线。
	var wm_g: Node = _main.wave_manager
	var sv_diff: String = GameState.difficulty_id
	var sv_wave: int = wm_g.wave
	var sv_endless: bool = GameState.endless
	var sv_el := ""
	var pl_g = _main.get_node_or_null("Player")
	if pl_g != null:
		sv_el = String(pl_g.element)
		pl_g.element = "wood"
	GameState.difficulty_id = "normal"
	GameState.endless = false
	wm_g.wave = 4
	var wired := _comp_ids(wm_g._spawn_pool())
	var expect_wired := _comp_ids(Config.compose_pool(4, "wood", "normal"))
	if pl_g != null:
		pl_g.element = sv_el
	GameState.difficulty_id = sv_diff
	GameState.endless = sv_endless
	wm_g.wave = sv_wave
	if wired != expect_wired:
		_fail("出怪池没带上难度/玩家元素：实际 %s / 期望 %s —— 闸门在真实路径上失效"
			% [str(wired), str(expect_wired)])
		return

	# ---- 4-9：难度档位序号与通关记录（§9.4）----
	if RunRules.difficulty_index("normal") != 1 or RunRules.difficulty_index("hard") != 2 \
			or RunRules.difficulty_index("nightmare") != 3:
		_fail("难度档位序号错（%d/%d/%d）"
			% [RunRules.difficulty_index("normal"), RunRules.difficulty_index("hard"),
				RunRules.difficulty_index("nightmare")])
		return
	if RunRules.difficulty_index("custom") != 0 or RunRules.difficulty_index("") != 0:
		_fail("非内置难度必须返回 0，否则自定义局会白送解锁")
		return
	# 只增不减：先通噩梦（3），再通简单（1）不得把记录拉回 1
	var ck := "clear_wood_adept"
	var ck_before: int = CodexData.stat(ck)
	CodexData.set_stat_max(ck, 3)
	if CodexData.stat(ck) != 3:
		_fail("通关记录未写入（%s=%d）" % [ck, CodexData.stat(ck)])
		return
	CodexData.set_stat_max(ck, 1)
	if CodexData.stat(ck) != 3:
		_fail("通关记录被低难度回退（%s=%d）—— 解锁会随再通关降级" % [ck, CodexData.stat(ck)])
		return
	CodexData.stats[ck] = ck_before

	# ---- 4-10：难度只改显示名、id 不动（§9.1）----
	var n_d: Dictionary = Registry.get_difficulty("normal")
	if String(n_d.get("name", "")) != "简单" or String(n_d.get("id", "")) != "normal":
		_fail("简单档显示名或 id 不对（%s）—— id 是存档/颜色/规则表的键，只能改 name" % str(n_d))
		return

	print("SMOKE: element gate OK (三档闸门逐格对上 §9.2 / 关系同构 / 单调 / 池非空 / "
		+ "接线 / 通关记录只增不减)")

## 把 wave_composition 的条目收成 id 数组（元素怪注入断言用）
func _comp_ids(comp: Array) -> Array:
	var out: Array = []
	for entry in comp:
		if typeof(entry) == TYPE_DICTIONARY:
			out.append(String((entry as Dictionary).get("item", "")))
	return out

## 玩家受击探针：顶满血、清无敌帧后打一发固定伤害，返回这一发实际掉了多少血。
## ⚠️ 每次都要重设 iframes 与 hp —— `take_damage` 会自己写这两个值，
##    不重置就会拿上一次的残局（无敌帧未过 → 掉 0 血，断言会以"穿甲没生效"的面目报红）。
func _probe_player_hit(pl: Node, raw: float, pierce: float) -> float:
	pl.iframes = 0.0
	pl.hp = 1.0e6
	var before: float = pl.hp
	pl.take_damage(raw, "", pierce)
	return before - pl.hp

## 亲和保底：单靠加权只是「更常出现」，保底把关联性变成承诺。
## 这里直接对保底函数做确定性验证 —— 不依赖随机抽到什么，断言永远可复现
func _check_affinity_floor() -> void:
	# ---- 1. 升级三选一：三张全不契合时必须换出至少一张契合项 ----
	var lu: Node = _main.get_node("UI/LevelUp")
	# 模拟近战构筑：否则「武器类型过滤」会把 melee 向升级拦掉，保底无从谈起
	var aff_p: Node2D = _main.get_node("Player")
	var aff_p_saved: Array = aff_p.weapons.duplicate(true)
	aff_p.weapons = [{ "type": "knife", "cd": 0.1 }]
	var cold: Array = []
	for u in Registry.upgrade_list():
		if not ("melee" in Config.entry_tags(u)):
			cold.append(u)
		if cold.size() >= 3:
			break
	if cold.size() < 3:
		_fail("找不到 3 个非近战升级用于保底测试")
		return
	lu._choices = [cold[0], cold[1], cold[2]]
	lu._ensure_affinity_choice(["melee"])
	var filled := false
	for c in lu._choices:
		if "melee" in Config.entry_tags(c):
			filled = true
	if not filled:
		_fail("升级保底未生效：三张全不契合时没有换出契合项")
		return
	# ---- 2. 已有契合项时不得干预（否则每级都塞同一类卡，build 会变窄而非变丰富）----
	var hot: Dictionary = {}
	for u2 in Registry.upgrade_list():
		if "melee" in Config.entry_tags(u2):
			hot = u2
			break
	if hot.is_empty():
		_fail("升级池里没有近战向条目")
		return
	lu._choices = [hot, cold[0], cold[1]]
	lu._ensure_affinity_choice(["melee"])
	if String(lu._choices[1].id) != String(cold[0].id) \
			or String(lu._choices[2].id) != String(cold[1].id):
		_fail("已有契合项时保底仍然替换了卡片")
		return
	# ---- 3. 无亲和标签时不得干预 ----
	lu._choices = [cold[0], cold[1], cold[2]]
	lu._ensure_affinity_choice([])
	if String(lu._choices[2].id) != String(cold[2].id):
		_fail("无亲和标签时保底不应改动卡片")
		return
	lu._choices = []
	# ---- 4. 商店保底：整店无契合时必须塞一格 ----
	var shop: Node = _main.get_node("UI/Shop")
	var saved_aff: Array = shop._affinity_cache
	var saved_goods: Array = shop.goods
	shop._affinity_cache = ["melee"]   # 直接喂亲和标签，把变量控住
	var cold_items: Array = []
	for it in Registry.item_list():
		if not ("melee" in Config.entry_tags(it)):
			cold_items.append(it)
		if cold_items.size() >= 4:
			break
	if cold_items.size() < 4:
		_fail("找不到 4 个非近战道具用于保底测试")
		shop._affinity_cache = saved_aff
		return
	shop.goods = _cold_goods(cold_items, 0)
	shop._ensure_affinity_goods()
	var last: Dictionary = shop.goods[shop.goods.size() - 1]
	if not bool(last.get("forced_synergy", false)) or int(last.get("synergy", 0)) <= 0:
		_fail("商店保底未生效：整店无契合时最后一格未被替换")
		shop.goods = saved_goods
		shop._affinity_cache = saved_aff
		return
	# ---- 5. 已有契合商品时不得干预 ----
	shop.goods = _cold_goods(cold_items, 1)
	shop._ensure_affinity_goods()
	if bool(shop.goods[shop.goods.size() - 1].get("forced_synergy", false)):
		_fail("已有契合商品时保底仍然替换")
		shop.goods = saved_goods
		shop._affinity_cache = saved_aff
		return
	shop.goods = saved_goods
	shop._affinity_cache = saved_aff
	aff_p.weapons = aff_p_saved   # 还原近战构筑模拟
	print("SMOKE: affinity floor OK (level-up + shop)")

## 对象池：acquire/release 的复用与复位。用真实弹丸场景验证 setup 能完整重置
func _check_object_pool() -> void:
	ObjectPool.clear()
	var bs: PackedScene = preload("res://scenes/weapons/bullet.tscn")
	var parent := _main
	# 首次 acquire：实例化新节点，池应为空
	var a = ObjectPool.acquire("test_bullet", bs, parent)
	if not is_instance_valid(a) or ObjectPool.idle_count() != 0:
		_fail("首次 acquire 未实例化（或池不为空）")
		return
	# release：进入池、移出场景树
	ObjectPool.release("test_bullet", a)
	if ObjectPool.idle_count() != 1:
		_fail("release 后未进入池（idle=%d）" % ObjectPool.idle_count())
		return
	if a.is_inside_tree():
		_fail("release 后节点仍在场景树中")
		return
	# 再次 acquire：必须复用同一实例
	var b = ObjectPool.acquire("test_bullet", bs, parent)
	if b != a:
		_fail("第二次 acquire 未复用同一实例")
		return
	if ObjectPool.idle_count() != 0:
		_fail("复用后池未清空")
		return
	# 复用节点的 setup 必须完整复位（位置/伤害等运行时字段）
	b.setup(Vector2(100.0, 100.0), 1.0, { "fx": "bolt", "bspeed": 700.0 },
		{ "dmg": 5.0, "crit": false, "sigil": "" }, Color(0, 0, 0, 0))
	if b.position != Vector2(100.0, 100.0) or float(b.dmg) != 5.0:
		_fail("复用弹丸 setup 未完整复位（pos=%s dmg=%s）" % [str(b.position), str(b.dmg)])
		ObjectPool.release("test_bullet", b)
		return
	ObjectPool.release("test_bullet", b)
	ObjectPool.clear()
	print("SMOKE: object pool OK")

## 第 9 轮 · 需求 4：每 4 波一个 BOSS + 场景属性地形区域。
## 覆盖三块最容易静默出错的地方：①标准/自定义/无尽三态的 BOSS 波判定与"最终 vs 中间"分流；
## ②地形区域必须是**纯函数**（读档/每日挑战全服一致）且不覆盖出生点；
## ③临时同化度必须**进出可逆**（不可逆 = 把一片地的加成永久镀进存档，且完全不报错）。
func _check_round9_boss_terrain() -> void:
	# ⚠️ 本用例对波次总数有硬期望（标准局 20 波），而 `is_boss_wave` 会读
	#    `RunRules.wave_total()` —— 上游只要有任何一处把自定义规则泄漏出来，
	#    断言的失败面就会变成"每 4 波判定坏了"。先复位、用例结束再还原。
	var rules_ctx := { "active": RunRules.active, "values": RunRules.values.duplicate(true) }
	var endless_bak: bool = GameState.endless
	RunRules.active = false
	GameState.endless = false
	var total := RunRules.wave_total(Config.WAVES_TOTAL)
	# ---- 1. 标准局：每 BLOCK_WAVES 波一个 BOSS，最后一波恒为 BOSS ----
	if not Config.is_boss_wave(4) or not Config.is_boss_wave(8) \
			or not Config.is_boss_wave(12) or not Config.is_boss_wave(16):
		_fail("标准局未按每 %d 波出 BOSS（W4/8/12/16）" % Config.BLOCK_WAVES)
		return
	if Config.is_boss_wave(1) or Config.is_boss_wave(5) or Config.is_boss_wave(19):
		_fail("标准局把非 %d 倍数的波误判为 BOSS 波" % Config.BLOCK_WAVES)
		return
	if not Config.is_boss_wave(total):
		_fail("标准局最后一波（%d）必须是 BOSS 波" % total)
		return
	# `0 % 4 == 0` 的坑：0 / 负数波次不许被判成 BOSS 波
	if Config.is_boss_wave(0) or Config.is_boss_wave(-4):
		_fail("is_boss_wave 把 0 / 负数波次误判为 BOSS（0 %% %d == 0 的坑）" % Config.BLOCK_WAVES)
		return
	# ---- 2. 最终 vs 中间的分叉（这是"W4 打完直接通关"的唯一闸门）----
	if not Config.is_final_boss_wave(total) or Config.is_final_boss_wave(4):
		_fail("is_final_boss_wave 判定错误（只有最后一波才是最终 BOSS）")
		return
	if not Config.is_mid_boss_wave(4) or Config.is_mid_boss_wave(total):
		_fail("is_mid_boss_wave 判定错误（最后一波不是中间 BOSS）")
		return
	# ---- 3. 无尽不受影响：仍是每 10 波，且**不**被当成中间 BOSS（否则会被限时）----
	GameState.endless = true
	if not Config.is_boss_wave(30) or Config.is_boss_wave(4) or Config.is_boss_wave(28):
		_fail("无尽 BOSS 节奏被改坏（应仍是每 10 波）")
		return
	if Config.is_mid_boss_wave(30) or Config.is_final_boss_wave(30):
		_fail("无尽 BOSS 被误判为中间/最终 BOSS（会被限时或直接通关）")
		return
	GameState.endless = false
	# ---- 4. 血量随波次成长 + 最终波锚点 0.85（第 14 轮再砍 15%）+ 中间 BOSS 有时限 ----
	if not is_equal_approx(Config.boss_hp_scale(total), 0.85):
		_fail("最终 BOSS 血量锚点应为 0.85（第 14 轮 W20 再砍 15%），实为 %.3f" % Config.boss_hp_scale(total))
		return
	var s4 := Config.boss_hp_scale(4)
	var s8 := Config.boss_hp_scale(8)
	var s16 := Config.boss_hp_scale(16)
	if not (s4 > 0.0 and s4 < s8 and s8 < s16 and s16 < 1.0):
		_fail("中间 BOSS 血量未随波次成长（W4=%.3f W8=%.3f W16=%.3f）" % [s4, s8, s16])
		return
	if Config.midboss_duration(4) <= Config.wave_duration(4):
		_fail("中间 BOSS 限时未比同波普通波宽（%.1f vs %.1f）"
			% [Config.midboss_duration(4), Config.wave_duration(4)])
		return
	# ---- 4a. ⭐ 流星雨削弱（第 13+ 轮需求 7）：两颗 count:3 的 BOSS 流星雨必须均布散开、范围更小 ----
	#    直接核技能表字段：spread_radius 已接入 _cast_nova + radius<95 + warn≥0.9（易躲、落点分开）。
	for _bid in ["boss_summoner", "boss_phoenix"]:
		var _sk: Array = Registry.enemies.get(_bid, {}).get("skills", [])
		var _nova: Dictionary = {}
		for _s in _sk:
			if String(_s.get("type", "")) == "nova" and int(_s.get("count", 0)) == 3:
				_nova = _s
		if _nova.is_empty():
			_fail("%s 缺少 count:3 的 nova 流星雨技能" % _bid)
			return
		if not _nova.has("spread_radius") or float(_nova.get("radius", 999.0)) >= 95.0 \
				or float(_nova.get("warn", 0.0)) < 0.9:
			_fail("%s 流星雨未削弱（需 spread_radius + radius<95 + warn≥0.9）：%s" % [_bid, str(_nova)])
			return
	# ---- 4b. ⭐ **消费点**断言：`boss_hp_scale` 必须被真实实例消费，不能只在 Config 里躺着 ----
	# ⚠️⚠️ 这是第 9 轮的真实教训：本函数当时**没有任何游戏代码调用它** —— 中间 BOSS 与
	#    最终 BOSS 血量完全相同（56 万~90 万），却多背 105~195s 限时，必然打不死。
	#    上面 4 那几条只断言纯函数返回值，**抓不到「声明了没人读」**这种缺陷。
	#    期望值一律从被测数据算（BOSS 基础血量 × 本波 frac × 当前难度 hp_mult），不硬编码。
	var bcfg: Dictionary = Registry.enemies.get("boss", {})
	var bmult: float = float(Registry.get_difficulty(GameState.difficulty_id).get("hp_mult", 1.0))
	var probe_mid: Node2D = preload("res://scenes/enemies/enemy.tscn").instantiate()
	_main.add_child(probe_mid)
	probe_mid.setup("boss", 4)
	var want_mid: float = float(bcfg.get("hp", 0.0)) * Config.boss_hp_scale(4) * bmult
	if not is_equal_approx(probe_mid.max_hp, want_mid):
		_fail("中间 BOSS 血量未按 boss_hp_scale 压缩（实为 %.0f，期望 %.0f）"
			% [probe_mid.max_hp, want_mid])
		probe_mid.queue_free()
		return
	# 反向对照：中间 BOSS 必须**真的更轻** —— 否则「压缩」只是没生效的空操作，
	# 而上面那条 is_equal_approx 在 frac==1.0 时也会假绿。
	var probe_final: Node2D = preload("res://scenes/enemies/enemy.tscn").instantiate()
	_main.add_child(probe_final)
	probe_final.setup("boss", total)
	var mid_hp: float = probe_mid.max_hp
	var final_hp: float = probe_final.max_hp
	probe_mid.queue_free()
	probe_final.queue_free()
	if final_hp <= mid_hp:
		_fail("中间 BOSS 未比最终 BOSS 更轻（%.0f vs %.0f）" % [mid_hp, final_hp])
		return
	# 反向对照 2：非 BOSS 波（W10）造出来的 BOSS **不受**压缩影响 —— 任意波次造 BOSS 是
	# 测试/工具的常规做法，那里被压会连带压小 dmg_cap（见 config.boss_hp_scale 注释）。
	var probe_off: Node2D = preload("res://scenes/enemies/enemy.tscn").instantiate()
	_main.add_child(probe_off)
	probe_off.setup("boss", 10)
	var off_hp: float = probe_off.max_hp
	probe_off.queue_free()
	if not is_equal_approx(off_hp, float(bcfg.get("hp", 0.0)) * bmult):
		_fail("非 BOSS 波（W10）的 BOSS 血量被中间 BOSS 压缩误伤（%.0f）" % off_hp)
		return
	# ---- 5. 地形区域：属性跟随本区区域元素 / 圆心是纯函数 / 不覆盖出生点 ----
	var z5: Dictionary = Config.terrain_zone_for_wave("wood", 5)
	var z5b: Dictionary = Config.terrain_zone_for_wave("wood", 5)
	if z5.is_empty() \
			or String(z5.get("element", "")) != Config.wave_area_element("wood", 5):
		_fail("地形区域属性未跟随本区区域元素（%s）" % str(z5.get("element", "<空>")))
		return
	if Vector2(z5.get("center", Vector2.ZERO)) != Vector2(z5b.get("center", Vector2.ONE)):
		_fail("地形区域圆心不是纯函数（同参数两次调用结果不同）")
		return
	# 同一区块四波必须完全一致：玩家要能记住"这片地在这"，否则它退化成随机踩点
	var z7: Dictionary = Config.terrain_zone_for_wave("wood", 7)
	if Vector2(z7.get("center", Vector2.ZERO)) != Vector2(z5.get("center", Vector2.ONE)) \
			or String(z7.get("element", "")) != String(z5.get("element", "")):
		_fail("同一区块内地形区域发生漂移（W5 与 W7 应完全一致）")
		return
	# 换区（每 BLOCK_WAVES 波）必须换位置/属性（否则"每 4 波一个新地形"名存实亡）。
	# ⚠️ 比较对象必须**跨区块**：W5 与 W6 同属区块 2，元素与圆心本来就该一模一样 ——
	#    拿它们比会以"换区没生效"报红，而实际是实现完全正确。
	var z4: Dictionary = Config.terrain_zone_for_wave("wood", 4)
	var z6: Dictionary = Config.terrain_zone_for_wave("wood", Config.BLOCK_WAVES + 2)
	if String(z4.get("element", "")) == String(z6.get("element", "")) \
			and Vector2(z4.get("center", Vector2.ZERO)) == Vector2(z6.get("center", Vector2.ONE)):
		_fail("换区后地形区域未发生变化（属性与位置都相同）")
		return
	var arena_center := Vector2(Config.WORLD.w, Config.WORLD.h) * 0.5
	if arena_center.distance_to(Vector2(z5.get("center", Vector2.ZERO))) \
			<= float(z5.get("radius", 0.0)):
		_fail("地形区域覆盖了玩家出生点（开局白送一档同化度）")
		return
	# ---- 6. 玩家侧临时同化度：进出必须可逆（不可逆 = 静默镀金）----
	var p2: Node2D = _main.get_node("Player")
	var elem := String(z5.get("element", ""))
	var akey := "assim_" + elem
	var base := float(p2.stats.get(akey, 0.0))
	p2.set_zone_assim(elem, Config.TERRAIN_ZONE_BONUS)
	var mid := float(p2.stats.get(akey, 0.0))
	if mid <= base:
		_fail("站进地形区未获得同化度（%.3f → %.3f）" % [base, mid])
		return
	p2.set_zone_assim("", 0.0)
	if not is_equal_approx(float(p2.stats.get(akey, 0.0)), base):
		_fail("离开地形区后同化度未复原（%.3f → %.3f，期望 %.3f）"
			% [base, float(p2.stats.get(akey, 0.0)), base])
		return
	# 顶到上限时也必须只撤「实际生效量」：按"想要写的量"撤会把玩家的固有同化度吃掉
	p2.stats[akey] = 2.0
	p2.set_zone_assim(elem, Config.TERRAIN_ZONE_BONUS)
	p2.set_zone_assim("", 0.0)
	if not is_equal_approx(float(p2.stats.get(akey, 0.0)), 2.0):
		_fail("同化度已到上限时进出地形区吃掉了固有值（%.3f，期望 2.000）"
			% float(p2.stats.get(akey, 0.0)))
		return
	p2.stats[akey] = base
	p2.set_zone_assim("", 0.0)
	# ---- 7. 怪物侧地形加成进 mob_resist 的加法项，且被 cap 吃掉（"不超过上限"）----
	if absf(Config.mob_resist(1, 0.0, 0.0, 0.0, 0.75, Config.TERRAIN_ZONE_BONUS)
			- Config.TERRAIN_ZONE_BONUS) > 1e-6:
		_fail("地形加成未进入 mob_resist 的加法项")
		return
	if not is_equal_approx(
			Config.mob_resist(20, 0.75, 0.0, 0.0, 0.75, Config.TERRAIN_ZONE_BONUS), 0.75):
		_fail("地形加成未被 mob_resist 的 cap 约束（噩梦 W20 普通怪仍应 ≤ 0.75）")
		return
	# ---- 8. 集成：中间 BOSS 的收尾分流 + 盒子发放点必须**早于** wave_ended ----
	# ⚠️ 这里**直调**两个处理函数（而不是 emit boss_killed），并临时摘掉 wave_ended 的监听：
	#    `wave_manager._on_boss_killed` 会立刻 emit wave_ended → main 开商店 + 进化流程 + **写存档**。
	#    那会把测试跑出来的假进度写进玩家的真实存档槽（本项目专门为此栽过一次）。
	# 说明：这一步会顺手让场上敌人退场 + 清空弹丸。跑到这里时**全部与存活/弹丸相关的
	#    断言都已经跑过**（本用例在 `_check_items` 清单里，晚于实战段），所以不会掩盖任何结论。
	var wm_b: Node = _main.get_node("WaveManager")
	var wave_bak: int = wm_b.wave
	var boxes_bak: int = GameState.boss_boxes
	var phase_bak = GameState.phase
	var boss_bak = wm_b.boss
	var dead_bak: bool = wm_b.boss_dead
	var ending_bak: bool = wm_b.ending_started
	var flee_bak: Array = []
	for e in get_tree().get_nodes_in_group("enemies"):
		flee_bak.append([e, float(e.flee)])
	var wend_hooked: bool = EventBus.wave_ended.is_connected(_main._on_wave_ended)
	if wend_hooked:
		EventBus.wave_ended.disconnect(_main._on_wave_ended)
	# 探针：记下 wave_ended 触发**那一刻**的盒子数 —— 这才是"波末流程看不看得见盒子"的真判据。
	# 盒子若发在 main 那侧（晚于 wave_manager），这里读到的还是旧值。
	var box_at_wend := [-1]
	var probe := func(_w: int) -> void:
		box_at_wend[0] = GameState.boss_boxes
	EventBus.wave_ended.connect(probe)
	wm_b.wave = 4
	GameState.boss_boxes = boxes_bak
	wm_b._on_boss_killed()
	var got_box: bool = GameState.boss_boxes == boxes_bak + 1
	var now_boxes: int = GameState.boss_boxes
	var boss_cleared: bool = wm_b.boss == null
	_main._on_boss_killed()   # 同一波上 main 的处理：不许落到通关分支
	var not_won: bool = GameState.phase != GameState.Phase.VICTORY
	# 现场还原（**必须**）：这场"BOSS"没真的打过，不许它改到下游用例的状态
	EventBus.wave_ended.disconnect(probe)
	if wend_hooked:
		EventBus.wave_ended.connect(_main._on_wave_ended)
	GameState.boss_boxes = boxes_bak
	GameState.phase = phase_bak
	wm_b.wave = wave_bak
	wm_b.boss = boss_bak
	wm_b.boss_dead = dead_bak
	wm_b.ending_started = ending_bak
	for pair in flee_bak:
		if is_instance_valid(pair[0]):
			pair[0].flee = float(pair[1])
	# `_main._on_boss_killed` 会顺手撤掉当前地形区域（"本波结束前必须撤"的路径之一），
	# 但这一波并没有真的结束 → 按同一波次把它重建回来，别让现场少一片地。
	_main._setup_terrain_zone(wave_bak)
	GameState.endless = endless_bak
	RunRules.active = bool(rules_ctx.get("active", false))
	RunRules.values = (rules_ctx.get("values", {}) as Dictionary).duplicate(true)
	if not got_box:
		_fail("中间 BOSS 击破未发放法宝盒子（%d → %d）" % [boxes_bak, now_boxes])
		return
	if int(box_at_wend[0]) != boxes_bak + 1:
		_fail("盒子发放晚于 wave_ended（波末读到的盒子数=%d，应为 %d）—— 发放点必须在 wave_ended 之前"
			% [int(box_at_wend[0]), boxes_bak + 1])
		return
	if not boss_cleared:
		_fail("中间 BOSS 击破后 boss 引用未清空（HUD 会一直显示已死 BOSS 的血条）")
		return
	if not not_won:
		_fail("中间 BOSS 击破误入通关结算（第 4 波就会 VICTORY）")
		return
	print("SMOKE: 第 9 轮 每 %d 波 BOSS（中间/最终分流 · 盒子早于 wave_ended · 血量随波成长 · 限时）"
		% Config.BLOCK_WAVES + " + 地形区域（纯函数圆 · 加成可逆且不越上限）OK")


## BOSS 死亡技能：数据完整性 / 凤凰涅槃拦截 / 死亡技能确实产生弹幕
func _check_boss_death_skills() -> void:
	# ---- 1. 每个 BOSS 都有合法死亡技能 ----
	var valid := ["ring", "double_ring", "miasma", "rebirth", "shockwave"]
	for bid in Config.BOSS_POOL:
		var bcfg: Dictionary = Config.ENEMIES.get(String(bid), {})
		var ds := String(bcfg.get("death_skill", ""))
		if ds == "" or not (ds in valid):
			_fail("BOSS %s 的死亡技能非法：%s" % [String(bid), ds])
			return
	# ---- 2. 凤凰涅槃：第一次死不触发 boss_killed 且回血复活；第二次死才触发 ----
	# 断开系统对 boss_killed 的处理（标准=通关结算 VICTORY / 无尽=进商店），二者都会改 phase；
	# 只保留本测试的监听，用标志收集断言结果，统一恢复后再判失败，避免 return 漏恢复
	var wm = _main.get_node("WaveManager")
	EventBus.boss_killed.disconnect(_main._on_boss_killed)
	EventBus.boss_killed.disconnect(wm._on_boss_killed)
	var restore := func() -> void:
		EventBus.boss_killed.connect(_main._on_boss_killed)
		EventBus.boss_killed.connect(wm._on_boss_killed)
	var killed := [0]
	var cb := func() -> void:
		killed[0] += 1
	EventBus.boss_killed.connect(cb)
	var phx = preload("res://scenes/enemies/enemy.tscn").instantiate()
	_main.add_child(phx)
	phx.setup("boss_phoenix", 10)
	phx.player = _main.get_node("Player")
	var max_hp: float = phx.max_hp
	# 巨额抗性（dmg_cap_pct）让单发伤害无法秒 BOSS —— 把血量压到 1 再打出致命一击
	phx.hp = 1.0
	phx.take_damage(max_hp * 10.0, false)
	var ok_first: bool = killed[0] == 0 and phx.hp > 0.0 \
		and is_equal_approx(phx.hp, max_hp * 0.5)
	phx.hp = 1.0
	phx.take_damage(phx.max_hp * 10.0, false)
	var ok_second: bool = killed[0] == 1
	EventBus.boss_killed.disconnect(cb)
	restore.call()
	phx.queue_free()
	if not ok_first:
		_fail("凤凰第一次死亡应回血复活（killed=%d hp=%.0f/%.0f）" % [killed[0], phx.hp, max_hp])
		return
	if not ok_second:
		_fail("凤凰第二次死亡应触发 boss_killed（实际 %d 次）" % killed[0])
		return
	# ---- 3. ring 死亡技能确实产生敌弹 ----
	var before := get_tree().get_nodes_in_group("enemy_bullets").size()
	var b2 = preload("res://scenes/enemies/enemy.tscn").instantiate()
	_main.add_child(b2)
	b2.setup("boss", 10)
	b2.player = _main.get_node("Player")
	b2._execute_death_skill()
	var after := get_tree().get_nodes_in_group("enemy_bullets").size()
	if after <= before:
		_fail("ring 死亡技能未产生敌弹（%d → %d）" % [before, after])
		b2.queue_free()
		return
	b2.queue_free()
	# 清理死亡技能残留的敌弹，避免污染后续压测
	for eb in get_tree().get_nodes_in_group("enemy_bullets"):
		eb.queue_free()
	print("SMOKE: boss death skills OK")

## BOSS 技能系统 + 巨额抗性：
## ① 每个 BOSS 的 skills 配置合法且注册后保留；② dmg_cap_pct 单次伤害上限生效
## （防爆发秒杀 + 堵死土克水处决秒 BOSS 的漏洞）；③ 狂暴减伤 ×0.8；
## ④ 四种技能形态都能真实出手（fan 产弹 / aimed 进队列 / nova 落预警圈 / charge 进蓄力）
func _check_boss_skills() -> void:
	# ---- 1. 配置完整性：每个 BOSS 至少 2 个技能，类型在白名单 ----
	for bid in Config.BOSS_POOL:
		var bcfg: Dictionary = Registry.enemies.get(String(bid), {})
		var skills: Array = bcfg.get("skills", [])
		if skills.size() < 2:
			_fail("BOSS %s 技能不足 2 个（%d）" % [String(bid), skills.size()])
			return
		for sk in skills:
			if String(sk.get("type", "")) not in Registry.BOSS_SKILL_TYPES:
				_fail("BOSS %s 技能类型非法：%s" % [String(bid), String(sk.get("type", "?"))])
				return
	# ---- 2. 巨额抗性：单发巨伤被 dmg_cap_pct 截断，BOSS 不被秒 ----
	var player: Node2D = _main.get_node("Player")
	var b = preload("res://scenes/enemies/enemy.tscn").instantiate()
	_main.add_child(b)
	b.setup("boss", 10)
	b.player = player
	var cap: float = b.max_hp * float(b.cfg.get("dmg_cap_pct", 0.005))
	var hp0: float = b.hp
	b.take_damage(b.max_hp * 5.0, false)   # 5 倍最大生命的单发，理论上必秒
	var lost: float = hp0 - b.hp
	if lost > cap * 1.01 or b.hp <= 0.0:
		_fail("巨额抗性未生效：单发掉血 %.0f 超过上限 %.0f（或 BOSS 被秒）" % [lost, cap])
		b.queue_free()
		return
	# 处决路径（土克水 take_damage(hp+1)）同样被截断 —— BOSS 免机制秒杀。
	# 注意测试血量必须高于 cap：处决伤害恒为 hp+1，只有「cap < 当前 hp」时截断才能保命
	b.hp = b.max_hp * 0.15
	b.take_damage(b.hp + 1.0, false)
	if b.hp <= 0.0:
		_fail("BOSS 被处决路径秒杀（dmg_cap 应拦截）")
		b.queue_free()
		return
	b.hp = b.max_hp
	# ---- 3. 狂暴减伤：enraged 后同等伤害 ×0.8 ----
	b.enraged = true
	var hp1: float = b.hp
	b.take_damage(1000.0, false)
	var lost_normal: float = hp1 - b.hp
	if lost_normal <= 0.0 or absf(lost_normal - 1000.0 * 0.8) > 1.0:
		_fail("狂暴减伤不符（掉血 %.1f，期望 %.1f）" % [lost_normal, 800.0])
		b.queue_free()
		return
	# ---- 4. 技能运行时：冷却数组与 cfg 对齐 ----
	if b._skill_cds.size() != b.cfg.get("skills", []).size():
		_fail("BOSS 技能冷却数组未按 cfg 初始化（%d vs %d）"
			% [b._skill_cds.size(), b.cfg.get("skills", []).size()])
		b.queue_free()
		return
	# fan：立刻产生敌弹
	var eb0 := get_tree().get_nodes_in_group("enemy_bullets").size()
	b._cast_boss_skill({ "type": "fan", "count": 5, "arc": 0.9, "bspeed": 300.0, "dmg_mult": 0.5 })
	var eb1 := get_tree().get_nodes_in_group("enemy_bullets").size()
	if eb1 < eb0 + 5:
		_fail("fan 技能未按数产弹（%d → %d）" % [eb0, eb1])
		b.queue_free()
		return
	# aimed：进入连发队列（首发出弹在下一物理帧，这里只验队列）
	b._cast_boss_skill({ "type": "aimed", "count": 3, "interval": 0.1, "bspeed": 400.0, "dmg_mult": 0.5 })
	if b._aimed_left != 3:
		_fail("aimed 技能未进入连发队列（left=%d）" % b._aimed_left)
		b.queue_free()
		return
	# nova：fx 组新增 Meteor 预警圈
	var fx0 := get_tree().get_nodes_in_group("fx").size()
	b._cast_boss_skill({ "type": "nova", "count": 2, "radius": 100.0, "warn": 0.8, "dmg_mult": 0.5 })
	var meteors := 0
	for n in get_tree().get_nodes_in_group("fx"):
		if n is Meteor:
			meteors += 1
	if meteors < 2:
		_fail("nova 技能未生成预警圈（Meteor 仅 %d 个）" % meteors)
		b.queue_free()
		return
	# charge：进入蓄力预警态，方向朝玩家
	b._cast_boss_skill({ "type": "charge", "warn": 0.5, "duration": 0.4, "speed_mult": 6.0 })
	if b._charge_state != 1 or b._charge_dir == Vector2.ZERO:
		_fail("charge 技能未进入蓄力预警（state=%d）" % b._charge_state)
		b.queue_free()
		return
	b.queue_free()
	# 清理技能测试产生的弹幕与预警圈
	for eb2 in get_tree().get_nodes_in_group("enemy_bullets"):
		eb2.queue_free()
	for m in get_tree().get_nodes_in_group("fx"):
		if m is Meteor:
			m.queue_free()
	print("SMOKE: boss skills + resistance OK")


## 构造 4 格假商品（synergy 固定为 v），供保底测试用
func _cold_goods(entries: Array, v: int) -> Array:
	var out: Array = []
	for e in entries:
		out.append({ "kind": "item", "id": e.id, "ico": e.ico, "name": e.name,
			"desc": e.desc, "rarity": e.rarity, "base_price": int(e.price),
			"synergy": v, "sold": false, "locked": false })
	return out

func _spawn_reaction_target(type_id: String, pos: Vector2, p2: Node2D,
		resist: float = 0.0) -> Node2D:
	var e: Node2D = preload("res://scenes/enemies/enemy.tscn").instantiate()
	e.setup(type_id, 1)
	e.max_hp = 100000.0
	e.hp = 100000.0
	e.position = pos
	_main.add_child(e)
	e.player = p2
	e.status_resist = resist
	e.statuses.clear()
	e.reaction_debuffs.clear()
	Combat.update_enemy_position(e)
	return e

## 反应信号命中里是否包含指定反应（扩散/AOE 会连带邻居反应，不能卡总数）
func _has_reaction_hit(hits: Array, reaction_id: String) -> bool:
	for h in hits:
		if h is Array and not (h as Array).is_empty() and String(h[0]) == reaction_id:
			return true
	return false

## 在图例里找五行反应折叠标题（每次重建都是新节点，只能按文本找）
func _find_reaction_head(hud: Control) -> Label:
	for c in hud._status_box.get_children():
		if c is Label and String((c as Label).text).find("五行反应") >= 0:
			return c as Label
	return null

## 解锁系统：数据完整性 / 阈值推导 / check_new 一次性庆祝 / 默认解锁
func _check_unlocks() -> void:
	# 数据完整性：每条锁定条目有合法 stat 键（白名单内）与非空 hint
	for pair in [["character", Config.CHARACTER_UNLOCKS], ["weapon", Config.WEAPON_UNLOCKS]]:
		var kind: String = pair[0]
		var tbl: Dictionary = pair[1]
		for id in tbl:
			var e: Dictionary = Config.unlock_entry(kind, String(id))
			if e.is_empty():
				_fail("解锁条目 %s:%s 查不到" % [kind, String(id)])
				return
			if String(e.get("stat", "")) not in Config.UNLOCK_STAT_KEYS:
				_fail("解锁条目 %s:%s 的 stat 键不在白名单" % [kind, String(id)])
				return
			if String(e.get("hint", "")).is_empty():
				_fail("解锁条目 %s:%s 缺少 hint" % [kind, String(id)])
				return
	# 未列入表的默认解锁（基础内容 + mod）
	#
	# ⚠️ S2：原用例断言 `pistol` 默认解锁 —— 它已迁入工坊包，改为断言开局池首把
	#    （`Config.FALLBACK_WEAPON`，也是 player / save_run 的空值兜底值）。
	if not Unlocks.is_unlocked("character", "potato"):
		_fail("基础角色 potato 应默认解锁")
		return
	if not Unlocks.is_unlocked("weapon", Config.FALLBACK_WEAPON):
		_fail("兜底武器 %s 应默认解锁" % Config.FALLBACK_WEAPON)
		return
	# 阈值推导：快照统计 → 清零 → 精确断言 → 还原（不受前置用例的统计污染）
	#
	# ⚠️ S2 口径：`CHARACTER_UNLOCKS` / `WEAPON_UNLOCKS` 现已清空
	#    （内置 6 角色 + 5 武器全部默认解锁，见 config.gd 的注释），
	#    原用例锁定的 warlord / gold_scepter 都已迁入工坊包。
	#    → 这里改为断言**新口径的必然结果**，而不是删掉整段：
	#      ① 内置全部角色 + 开局池武器在统计清零时也**必须**解锁（这是新口径的核心承诺）
	#      ② check_new 在这种情况下应返回 0（没有"待解锁"的东西可庆祝）
	#    真正的阈值推导逻辑因此在本轮**失去了被测对象** —— 保留断言是为了让
	#    「解锁表清空」这件事被机器看住：谁哪天偷偷加回一条锁定，这里就会红。
	var saved := {}
	for k in Config.UNLOCK_STAT_KEYS:
		saved[k] = CodexData.stat(k)
		CodexData.stats[k] = 0
	Unlocks.reset_for_tests()
	for cid in Registry.characters:
		if not Unlocks.is_unlocked("character", String(cid)):
			_restore_unlock_stats(saved)
			_fail("内置角色 %s 应在统计清零时仍默认解锁（解锁表应已清空）" % String(cid))
			return
	for wid in Config.LOADOUT_WEAPONS:
		if not Unlocks.is_unlocked("weapon", String(wid)):
			_restore_unlock_stats(saved)
			_fail("开局池武器 %s 应默认解锁（解锁表应已清空）" % String(wid))
			return
	# 解锁表留空是 S2 的刻意决策：任何残留条目都会让下面这条断言失败
	if not Config.CHARACTER_UNLOCKS.is_empty() or not Config.WEAPON_UNLOCKS.is_empty():
		_restore_unlock_stats(saved)
		_fail("内置解锁表应为空（角色 %d 条 / 武器 %d 条）"
			% [Config.CHARACTER_UNLOCKS.size(), Config.WEAPON_UNLOCKS.size()])
		return
	if Unlocks.check_new() != 0:
		_restore_unlock_stats(saved)
		_fail("解锁表为空时 check_new 应返回 0")
		return
	_restore_unlock_stats(saved)
	Unlocks.reset_for_tests()
	print("SMOKE: unlocks OK")

func _restore_unlock_stats(saved: Dictionary) -> void:
	for k in saved:
		CodexData.stats[k] = int(saved[k])

## 门派天赋树：数据完整性 / effect 键合法 / sect_for / buy_sect 扣费持久化 / 仅对应角色生效
func _check_sect_talents() -> void:
	# 5 门派齐全 + 数据合法
	if MetaProgress.SECT_TALENTS.size() != 5:
		_fail("门派天赋应有 5 个（实际 %d）" % MetaProgress.SECT_TALENTS.size())
		return
	for sid in MetaProgress.SECT_TALENTS:
		var t: Dictionary = MetaProgress.SECT_TALENTS[sid]
		var chid := String(t.get("character", ""))
		if not Registry.characters.has(chid):
			_fail("门派 %s 的 character %s 不存在" % [String(sid), chid])
			return
		if int(t.get("max_lv", 0)) <= 0:
			_fail("门派 %s 缺少 max_lv" % String(sid))
			return
		var eff: Dictionary = t.get("effect", {})
		if not eff.has("stats") or typeof(eff.stats) != TYPE_DICTIONARY:
			_fail("门派 %s 缺少 effect.stats" % String(sid))
			return
		for k in eff.stats:
			if not Registry.STAT_LIMITS.has(String(k)):
				_fail("门派 %s 的 effect 键 %s 不在 STAT_LIMITS" % [String(sid), String(k)])
				return
	# sect_for 映射
	#
	# ⚠️ S2：`SECT_TALENTS` 的 5 个 `character` 已从旧角色（pyromancer / druid /
	#    swordmaster / tidecaller / guardian）**重指向 5 元素修士**。旧指向是一处
	#    真实的悬空引用 —— 角色迁入工坊包后 `sect_for()` 恒返回空串，
	#    导致 6 个可用角色一个都吃不到门派天赋，且**全程无任何报错**。
	if MetaProgress.sect_for("fire_adept") != "fire":
		_fail("sect_for(fire_adept) 应返回 fire")
		return
	if MetaProgress.sect_for("potato") != "":
		_fail("非门派角色 potato 应无门派")
		return
	# buy_sect 扣费 + 持久化
	MetaProgress.reset_for_tests()
	MetaProgress.essence = 500
	var cost0 := MetaProgress.sect_cost("fire")   # 本级价格（sect_cost 随等级递增，须在购买前取值）
	if not MetaProgress.buy_sect("fire"):
		_fail("buy_sect(fire) 应成功（精华 500）")
		return
	if MetaProgress.sect_level("fire") != 1:
		_fail("buy_sect 后 fire 等级应为 1")
		return
	if MetaProgress.essence != 500 - cost0:
		_fail("buy_sect 后精华扣除不正确（%d ≠ %d）" % [MetaProgress.essence, 500 - cost0])
		return
	MetaProgress._save()
	MetaProgress.reset_for_tests()
	MetaProgress._load()
	if MetaProgress.sect_level("fire") != 1:
		_fail("门派天赋未持久化（load 后 fire 等级 %d）" % MetaProgress.sect_level("fire"))
		return
	# 仅对应角色生效：用全新玩家实例，避免污染主玩家的 stats
	var saved_cid: String = GameState.character_id
	MetaProgress.reset_for_tests()
	MetaProgress.essence = 500
	MetaProgress.buy_sect("fire")
	# fire_adept（赤焰修士）吃到 fire 门派天赋
	GameState.character_id = "fire_adept"
	var p_pyro: Node2D = preload("res://scenes/characters/player.tscn").instantiate()
	_main.add_child(p_pyro)
	var base_dmg: float = p_pyro.stats.status_dmg_mult
	MetaProgress.apply_on_run_start(p_pyro)
	if not is_equal_approx(float(p_pyro.stats.status_dmg_mult), base_dmg + 0.15):
		_fail("门派天赋未对 fire_adept 生效（%.3f ≠ %.3f）"
			% [float(p_pyro.stats.status_dmg_mult), base_dmg + 0.15])
		p_pyro.queue_free()
		GameState.character_id = saved_cid
		MetaProgress.reset_for_tests()
		return
	p_pyro.queue_free()
	# potato 不吃 fire 门派天赋
	GameState.character_id = "potato"
	var p_potato: Node2D = preload("res://scenes/characters/player.tscn").instantiate()
	_main.add_child(p_potato)
	MetaProgress.apply_on_run_start(p_potato)
	if not is_equal_approx(float(p_potato.stats.status_dmg_mult), 0.0):
		_fail("potato 被误加了 fire 门派天赋（%.3f）" % float(p_potato.stats.status_dmg_mult))
		p_potato.queue_free()
		GameState.character_id = saved_cid
		MetaProgress.reset_for_tests()
		return
	p_potato.queue_free()
	GameState.character_id = saved_cid
	MetaProgress.reset_for_tests()
	print("SMOKE: sect talents OK")

## 无尽炼狱模式回归：标准通关→继续无尽、BOSS 波判定/积分公式/排行榜、
## BOSS 击破 → 商店衔接 → 通关波+1 的存档/恢复、240 敌群性能压测、死亡入榜
##
## ⚠️ 通关波随"标准局 = 20 波"改为 W20：本用例全程走 `Config.BOSS_WAVE` 推导，
## 不写死破关波号 —— 波次结构再变时这里不用跟着改（写死 10 的那版已经因此失效过一次）。
## S5（道具池）：同化度道具 + 五行之悟升级 + 开局白名单收敛
func _check_assim_items() -> void:
	# 1) 5 件基础同化度道具（§6.2）：效果键 = assim_<元素>，值 +0.15
	var base := { "i-assim-metal": "metal", "i-assim-wood": "wood", "i-assim-water": "water",
		"i-assim-fire": "fire", "i-assim-earth": "earth" }
	for id in base:
		var it: Dictionary = Registry.items.get(id, {})
		if it.is_empty():
			_fail("S5: 同化度道具 %s 未注册进 Registry" % id)
			return
		var key := "assim_" + String(base[id])
		if not it.get("effects", {}).has(key):
			_fail("S5: %s 缺少效果键 %s" % [id, key])
			return
		if absf(float(it.effects[key]) - 0.15) > 1e-6:
			_fail("S5: %s 的 %s 应为 0.15，实为 %s" % [id, key, str(it.effects[key])])
			return

	# 2) 5 件五行精华（§6.2）：对应元素 +0.30
	for el in Config.ELEMENTS:
		var gid := "i-assim-greater-" + String(el)
		var git: Dictionary = Registry.items.get(gid, {})
		if git.is_empty():
			_fail("S5: 五行精华 %s 未注册" % gid)
			return
		var gkey := "assim_" + String(el)
		if absf(float(git.get("effects", {}).get(gkey, -1.0)) - 0.30) > 1e-6:
			_fail("S5: %s 的 %s 应为 0.30，实为 %s" % [gid, gkey, str(git.get("effects", {}).get(gkey, "缺失"))])
			return

	# 3) 五行归一石（§6.2）：全元素 +0.08
	var allit: Dictionary = Registry.items.get("i-assim-all", {})
	if allit.is_empty():
		_fail("S5: 五行归一石 i-assim-all 未注册")
		return
	for el in Config.ELEMENTS:
		var akey := "assim_" + String(el)
		if absf(float(allit.get("effects", {}).get(akey, -1.0)) - 0.08) > 1e-6:
			_fail("S5: i-assim-all 的 %s 应为 0.08" % akey)
			return

	# 4) 5 条五行之悟升级（§7.4）：对应元素 +0.12
	for el in Config.ELEMENTS:
		var wid := "wu_" + String(el)
		var w: Dictionary = Registry.upgrades.get(wid, {})
		if w.is_empty():
			_fail("S5: 之悟升级 %s 未注册" % wid)
			return
		var wkey := "assim_" + String(el)
		if absf(float(w.get("effects", {}).get(wkey, -1.0)) - 0.12) > 1e-6:
			_fail("S5: %s 的 %s 应为 0.12，实为 %s" % [wid, wkey, str(w.get("effects", {}).get(wkey, "缺失"))])
			return

	# 5) 功能验证：装 i-assim-fire → assim_fire +0.15；逼近上限时夹紧到 2.0
	#    ⚠️ 受控、可还原：期望值依赖本局 assim_fire 状态，必须先把现场存下、用完还原（铁律）
	var pl := _main.get_node("Player")
	var saved_fire: float = float(pl.stats.get("assim_fire", 0.0))
	var saved_items: Dictionary = pl.items_owned.duplicate()
	pl.apply_item("i-assim-fire")
	var got_fire: float = float(pl.stats.get("assim_fire", 0.0))
	if absf(got_fire - (saved_fire + 0.15)) > 1e-4:
		_fail("S5: 装 i-assim-fire 后 assim_fire 应为 %.2f，实为 %.2f" % [saved_fire + 0.15, got_fire])
		pl.stats["assim_fire"] = saved_fire
		pl.items_owned = saved_items
		return
	# 上限夹紧：顶到 1.95 再装一次（+0.15 应被 _sanitize_stats 夹紧到 2.0，而非 2.10）
	pl.stats["assim_fire"] = 1.95
	pl.apply_item("i-assim-fire")
	var capped: float = float(pl.stats.get("assim_fire", 0.0))
	if absf(capped - 2.0) > 1e-4:
		_fail("S5: assim_fire 超过 2.0 上限未夹紧（实为 %.4f）" % capped)
	# 还原
	pl.stats["assim_fire"] = saved_fire
	pl.items_owned = saved_items
	pl._sanitize_stats()

	# 6) 开局白名单收敛（§6.1）：恰好 29 件基础属性道具；不含任何冻结的元素/on-hit 件
	var whitelist := [
		"i-hp", "i-bread", "i-dmg", "i-as", "i-focus", "i-spd", "i-boots", "i-feather",
		"i-crit", "i-hunter", "i-arm", "i-warden", "i-thorn", "i-dod", "i-mag", "i-lodestone",
		"i-harv", "i-luckypouch", "i-reg", "i-sunstone", "i-ls", "i-sanguine", "i-goldcore",
		"i-crown", "i-titan", "i-fortress", "i-gale", "i-immortal", "i-dragonsoul",
	]
	if Config.LOADOUT_ITEMS.size() != whitelist.size():
		_fail("S5: LOADOUT_ITEMS 应为 %d 件，实为 %d" % [whitelist.size(), Config.LOADOUT_ITEMS.size()])
		return
	var wl_set := {}
	for x in whitelist:
		wl_set[x] = true
	for x in Config.LOADOUT_ITEMS:
		if not wl_set.has(x):
			_fail("S5: LOADOUT_ITEMS 含非白名单项 %s" % String(x))
			return
	for frozen in ["i-ember", "i-venom", "i-hemo", "i-tar", "i-frost", "i-thunder",
			"i-pyro", "i-plague", "i-ragecloak", "i-flint"]:
		if Config.LOADOUT_ITEMS.has(frozen):
			_fail("S5: LOADOUT_ITEMS 不应含冻结元素件 %s" % frozen)
			return

	print("SMOKE: S5 同化度道具 + 之悟升级 + 白名单收敛 OK")


## 第 7 轮：金（mythic）/ 红（legendary）= 「唯一件」——升级 / 道具全来源本局各限 1 件
## （事件卡**本身**已有排重，见 ⑧）。语义与法宝 artifacts_owned 一致，只是过去只盖住了法宝。
## ⚠️ 断言纪律：① 样本从 Registry 扫出来（不硬编码 id）；② 每条正向断言配反向对照
## （common 品阶必须仍在池里 / 仍可叠加），否则「池子空了」也会判绿；
## ③ 全程可还原 —— 现场先留档，结束前一次性还原，不给后面的用例留脏状态。
func _check_unique_items() -> void:
	var err := ""
	# ① 品阶判定 + 反向对照（不能每个品阶都算唯一）
	if not Config.is_unique_rarity("mythic") or not Config.is_unique_rarity("legendary"):
		err = "唯一件：mythic / legendary 应判为唯一品阶"
	elif Config.is_unique_rarity("common") or Config.is_unique_rarity("rare") \
			or Config.is_unique_rarity("epic"):
		err = "唯一件：common / rare / epic 不该被判为唯一品阶"

	var pl := _main.get_node("Player")
	var shop: Control = _main.get_node("UI/Shop")
	# ② 样本（带 entry_weapon_relevant 过滤：本来就不进池的条目拿来断言会误红）
	var mid := ""
	var pid := ""
	for it in Registry.item_list():
		if not Config.entry_weapon_relevant(it, pl.weapons):
			continue
		if mid == "" and Config.is_unique_rarity(String(it.get("rarity", "common"))):
			mid = String(it.get("id", ""))
		elif pid == "" and String(it.get("rarity", "common")) == "common" \
				and not it.get("effects", {}).is_empty():
			pid = String(it.get("id", ""))
	var uid := ""
	var puid := ""
	for u in Registry.upgrade_list():
		if not Config.entry_weapon_relevant(u, pl.weapons):
			continue
		if uid == "" and Config.is_unique_rarity(String(u.get("rarity", "common"))):
			uid = String(u.get("id", ""))
		elif puid == "" and String(u.get("rarity", "common")) == "common":
			puid = String(u.get("id", ""))
	if err == "" and (mid == "" or pid == "" or uid == "" or puid == ""):
		err = "唯一件：样本不足（金道具=%s / common 道具=%s / 金红升级=%s / common 升级=%s）" \
			% [mid, pid, uid, puid]

	# ③ 现场留档
	var s_stats: Dictionary = pl.stats.duplicate()
	var s_items: Dictionary = pl.items_owned.duplicate()
	var s_ups: Dictionary = pl.upgrades_owned.duplicate()
	var s_mats: int = GameState.materials

	if err == "":
		# ④ 池闸门（道具）：持有金道具后必须从池里消失，而 common 道具仍在
		pl.items_owned = { mid: 1 }
		var has_mid := false
		var has_pid := false
		for e in shop._rarity_pool(Registry.item_list(), pl.items_owned):
			var eid := String(e.get("item", {}).get("id", ""))
			if eid == mid:
				has_mid = true
			elif eid == pid:
				has_pid = true
		if has_mid:
			err = "唯一件：已持有的金道具 %s 仍出现在道具抽取池" % mid
		elif not has_pid:
			err = "唯一件：common 道具 %s 被误剔出池（反向对照失败）" % pid

	if err == "":
		# ⑤ 硬闸门（道具）：第二次 apply_item 必须被拒，且 stats 一个键都不能动
		pl.items_owned = {}
		pl.stats = s_stats.duplicate()
		var ok1: bool = pl.apply_item(mid)
		var stats1: Dictionary = pl.stats.duplicate()
		var ok2: bool = pl.apply_item(mid)
		if not ok1:
			err = "唯一件：首次 apply_item(%s) 就该成功" % mid
		elif ok2:
			err = "唯一件：第二次 apply_item(%s) 应被拒（硬闸门失效）" % mid
		elif int(pl.items_owned.get(mid, 0)) != 1:
			err = "唯一件：金道具 %s 持有数应为 1，实为 %d" % [mid, int(pl.items_owned.get(mid, 0))]
		else:
			for k in stats1:
				if not is_equal_approx(float(stats1[k]), float(pl.stats.get(k, 1e9))):
					err = "唯一件：被拒的那次 apply_item 仍改动了 stats[%s]" % k
					break

	if err == "":
		# ⑥ 反向对照（道具）：common 品阶必须仍能叠加
		pl.items_owned = {}
		var n1: bool = pl.apply_item(pid)
		var n2: bool = pl.apply_item(pid)
		var ncnt: int = int(pl.items_owned.get(pid, 0))
		if not n1 or not n2 or ncnt != 2:
			err = "唯一件反向对照：common 道具 %s 应可叠到 2（ok=%s/%s cnt=%d）" \
				% [pid, str(n1), str(n2), ncnt]

	if err == "":
		# ⑦ 硬闸门（升级）：金红升级同理，且 upgrades_owned 要记上
		pl.upgrades_owned = {}
		var u1: bool = pl.apply_upgrade(uid)
		var u2: bool = pl.apply_upgrade(uid)
		var ucnt: int = int(pl.upgrades_owned.get(uid, 0))
		if not u1 or u2 or ucnt != 1:
			err = "唯一件：金红升级 %s 应首次成功、二次被拒（ok=%s/%s cnt=%d）" \
				% [uid, str(u1), str(u2), ucnt]

	if err == "":
		# ⑧ 池闸门（升级）：同一批断言搬到升级池
		pl.upgrades_owned = { uid: 1 }
		var has_u := false
		var has_pu := false
		for e2 in shop._rarity_pool(Registry.upgrade_list(), pl.upgrades_owned):
			var eid2 := String(e2.get("item", {}).get("id", ""))
			if eid2 == uid:
				has_u = true
			elif eid2 == puid:
				has_pu = true
		if has_u:
			err = "唯一件：已获得的金红升级 %s 仍出现在升级抽取池" % uid
		elif not has_pu:
			err = "唯一件：common 升级 %s 被误剔出池（反向对照失败）" % puid

	if err == "":
		# ⑨ 事件卡：**不新增机制**，钉住既有的 events_seen 排重（每张每局一次）这个约定
		var epool: Array = Config.event_card_pool([], 12)
		if epool.is_empty():
			err = "唯一件：事件卡池为空，无法校验排重"
		else:
			var first_id := String(epool[0].get("item", {}).get("id", ""))
			for e3 in Config.event_card_pool([first_id], 12):
				if String(e3.get("item", {}).get("id", "")) == first_id:
					err = "唯一件：事件卡 %s 已看过却仍出现在池里" % first_id
					break

	_restore_unique_probe(pl, s_stats, s_items, s_ups, s_mats)
	if err != "":
		_fail(err)
		return
	print("SMOKE: 金红唯一件 OK（硬闸门 道具+升级 / 池闸门 / 反向对照 / 事件卡排重）")

## 还原「唯一件」探针动过的现场（stats / items_owned / upgrades_owned / 材料）
func _restore_unique_probe(pl: Node, stats: Dictionary, items: Dictionary,
		ups: Dictionary, mats: int) -> void:
	pl.stats = stats
	pl.items_owned = items
	pl.upgrades_owned = ups
	pl.hp = minf(float(pl.hp), float(pl.stats.max_hp))
	pl._sanitize_stats()
	GameState.materials = mats
	pl.queue_redraw()



## §16 / §15 视觉层落地验收（S7）：特效统一入口、注册表、接口表、生克链方向、菜单动画不挡输入。
func _check_visual_layer() -> void:
	# ① Fx 三入口可调用（视觉层零判定，只经 Config 取色，不抛错；未知值静默 no-op）
	if not ("fire" in Config.ELEMENTS):
		_fail("S7: Config.ELEMENTS 缺 fire，无法验收 Fx")
		return
	Fx.hit_burst("fire", Vector2.ZERO)
	Fx.element_aura("wood", Node2D.new())
	Fx.reaction_burst("wood_fire", Vector2.ZERO)
	Fx.hit_burst("__nope__", Vector2.ZERO)      # 未知元素：静默 no-op
	Fx.reaction_burst("__nope__", Vector2.ZERO) # 未知反应：静默 no-op

	# ② main.gd 的 AMBIENT_FX 注册表含三键（match 硬分支已改为注册表查找）
	var fx_tbl: Variant = _main.get("AMBIENT_FX")
	if fx_tbl == null or not (fx_tbl is Dictionary):
		_fail("S7: main.AMBIENT_FX 不存在或非字典")
		return
	for k in ["bamboo_leaf", "incense", "ghost_fire"]:
		if not fx_tbl.has(k):
			_fail("S7: AMBIENT_FX 缺键 %s" % k)
			return

	# ③ Config.MAP_THEMES 每条含 element / bg_tint / ambient 三接口字段（可换数据不改代码）
	for tid in Config.MAP_THEMES.keys():
		var t := Config.MAP_THEMES[tid] as Dictionary
		for fld in ["element", "bg_tint", "ambient"]:
			if not t.has(fld):
				_fail("S7: MAP_THEMES[%s] 缺接口字段 %s" % [tid, fld])
				return

	# ④ Config.REACTIONS 全部有 from/to，且方向与 GENERATES / OVERCOMES 一致（绝不解析 id）
	for rid in Config.REACTIONS.keys():
		var r := Config.REACTIONS[rid] as Dictionary
		if not r.has("from") or not r.has("to"):
			_fail("S7: REACTIONS[%s] 缺 from/to" % rid)
			return
		var f := String(r.get("from"))
		var tt := String(r.get("to"))
		var typ := String(r.get("type"))
		if typ == "generate":
			if String(Config.GENERATES.get(f, "")) != tt:
				_fail("S7: REACTIONS[%s] 生方向错（%s→%s，应为 %s）" % [rid, f, tt, Config.GENERATES.get(f, "")])
				return
		elif typ == "overcome":
			if String(Config.OVERCOMES.get(f, "")) != tt:
				_fail("S7: REACTIONS[%s] 克方向错（%s→%s，应为 %s）" % [rid, f, tt, Config.OVERCOMES.get(f, "")])
				return
	# 显式锚定 fire_water 反向坑：id 是 fire_water 但 from=water to=fire（靠 from/to 显式纠正）
	var fw := Config.REACTIONS.get("fire+water", {}) as Dictionary
	if String(fw.get("from", "")) != "water" or String(fw.get("to", "")) != "fire":
		_fail("S7: REACTIONS[fire+water] from/to 必须 water→fire（id 反例，靠 from/to 显式纠正）")
		return

	# ⑤ MenuElementLoop.spawn 可运行：默认 paused、派生链长 5、子 Label 不挡输入
	var loop := MenuElementLoop.spawn(self, Vector2(1280.0, 720.0), null)
	if loop == null or not (loop is MenuElementLoop):
		_fail("S7: MenuElementLoop.spawn 返回异常")
		return
	if not loop.paused:
		_fail("S7: MenuElementLoop 默认应 paused=true（定格不挡输入）")
		return
	# 派生链合法性（不依赖 _ready 时序，直接调 helper 校验逻辑）
	var gen_c := loop._derive_chain(Config.GENERATES)
	var ovr_c := loop._derive_chain(Config.OVERCOMES)
	if gen_c.size() != 5 or ovr_c.size() != 5:
		_fail("S7: MenuElementLoop 生/克链长度异常（%d/%d）" % [gen_c.size(), ovr_c.size()])
		return
	if String(gen_c[0]) != "wood" or String(ovr_c[0]) != "wood":
		_fail("S7: MenuElementLoop 生克链必须从木出发")
		return
	# 子 Label 必须 MOUSE_FILTER_IGNORE（不挡首页按钮）；若 _ready 尚未同步触发则手动补一次
	if loop.get_child_count() == 0:
		loop._ready()
	var label_ok := true
	for c in loop.get_children():
		if c is Label and c.mouse_filter != Control.MOUSE_FILTER_IGNORE:
			label_ok = false
	if not label_ok:
		_fail("S7: MenuElementLoop 子 Label 未设 MOUSE_FILTER_IGNORE，会挡输入")
		return
	loop.queue_free()

	print("SMOKE: S7 视觉层（Fx 入口 / AMBIENT_FX 注册表 / MAP_THEMES 接口 / REACTIONS 方向 / 菜单生克动画不挡输入）OK")


## ============================================================
## S8 · 平衡探针（五行体系 §14 观察点 → docs/武器DPS体检表.md）
## ============================================================
## §14 原话：记录「木角色 + 土武器 + 满土同化度」的**实测** DPS，若明显甩开其他构筑
##   再考虑加软上限 —— **现在不加护栏，但要能看见它**。本探针就是那个「看得见」。
##
## ⚠️ 必须走**真实 `player._roll_damage`**，不能在测试里另抄一份乘算公式：
##    另抄一份会让「文档里的数字」与「实际结算」悄悄分叉，而且分叉不报错。
##
## 口径（§2.3-A）：DPS = base ÷ cd × (1 + out_mult + assim) × (1 + crit_ch×(crit_mult−1))
##   本探针把 crit_ch 压成 0 → 得到**非暴击口径**；
##   含暴击口径 = 非暴击 × 1.05（Config.PLAYER 默认 crit_ch=0.05 / crit_mult=2.0）。
##
## ⚠️⚠️ 输出侧同化度取的是 `assim_<**武器**元素>`（2026-09-16 拍板 · 体检表 §4 决策 B）。
##   语义：同化度 = 你跟这个元素的亲和度 —— **用它打人更痛**（输出侧，本探针量的就是这个）、
##   **挨它打更抗**（受击侧 `_take_damage`）。两侧都读「对应属性」的那一列，都是**加算**。
##
##   2026-09-16 之前这里读的是 `assim_<角色元素>`，后果是「木角色堆满 assim_earth 再拿
##   土武器」输出一点不涨（实测 24.07→24.07），与 §14 处方矛盾。改键之后 25 个格子
##   的数值全部变化，两张矩阵必须重新转录。
##
##   第 ④ 步把它钉成断言并配反向对照 —— 将来若把同化度改回键角色元素，这里会立刻
##   报红，逼着同步修订 §14 与体检表，而不是让两个数字悄悄漂移。

## OVERCOMES 逆查：谁克 `ce`（即 out_mult(ce, ·) == beats_me 的那个元素）
static func _element_that_beats(ce: String) -> String:
	for e in Config.OVERCOMES.keys():
		if String(Config.OVERCOMES[e]) == ce:
			return String(e)
	return ""


## 还原 `_check_balance` 临时改写的现场（提前 return 的每条失败路径都要调）
static func _balance_restore(p: Node, bak: Dictionary, assim_bak: Dictionary) -> void:
	p.element = String(bak["element"])
	p.stats.dmg_mult = float(bak["dmg_mult"])
	p.stats.momentum_dmg_bonus = float(bak["momentum_dmg_bonus"])
	p.stats.low_hp_dmg_bonus = float(bak["low_hp_dmg_bonus"])
	p.stats.crit_ch = float(bak["crit_ch"])
	for k in assim_bak.keys():
		p.stats[k] = float(assim_bak[k])


func _check_balance() -> void:
	var p: Node = _main.get_node("Player")
	# ---- 现场快照 + 中和 ----
	# 断言纪律：期望值必须**只**由 Config 决定，不能取决于前面用例给这个玩家发过什么。
	# `dmg_mult` 若不还原成 1.0，一道早期的「伤害 +10%」升级就能让 ① 的基线等式假红，
	# 而且红得像是五行走错了 —— 实际病因却在几百行之外。
	var bak: Dictionary = {}
	bak["element"] = String(p.element)
	bak["dmg_mult"] = float(p.stats.get("dmg_mult", 1.0))
	bak["momentum_dmg_bonus"] = float(p.stats.get("momentum_dmg_bonus", 0.0))
	bak["low_hp_dmg_bonus"] = float(p.stats.get("low_hp_dmg_bonus", 0.0))
	bak["crit_ch"] = float(p.stats.get("crit_ch", 0.0))
	var assim_bak: Dictionary = {}
	# ⚠️ Config.ELEMENTS 是 **Array**（["earth","fire","metal","water","wood"]）不是 Dictionary，
	#    这里写成 .keys() 会 Parse Error: Cannot find member "keys" in base "Array"。
	for eid in Config.ELEMENTS:
		assim_bak["assim_" + String(eid)] = float(p.stats.get("assim_" + String(eid), 0.0))
	p.stats.dmg_mult = 1.0
	p.stats.momentum_dmg_bonus = 0.0
	p.stats.low_hp_dmg_bonus = 0.0
	p.stats.crit_ch = 0.0

	var wep_ids: Array = Config.LOADOUT_WEAPONS

	# ① 基线：白板角色（element == ""）持各武器 → DPS 恒等于 dmg/cd
	#    无元素不参与任何五行修正，这是后面所有倍率的锚点。
	var base_line: Dictionary = {}
	p.element = ""
	for wid in wep_ids:
		var wc: Dictionary = Config.WEAPONS[wid]
		var raw: float = float(wc["dmg"])
		var got: float = float(p._roll_damage(raw, wc).dmg)
		if not is_equal_approx(got, raw):
			_fail("S8: 白板角色持 %s 不该有输出侧修正（%.3f ≠ %.3f）" % [wid, got, raw])
			_balance_restore(p, bak, assim_bak)
			return
		base_line[wid] = got / float(wc["cd"])

	# ② 输出侧矩阵：5 元素角色 × 5 把武器，取「同化度 0」与「每把武器都吃满自己的亲和(2.0)」两档
	#
	# ⚠️ 满同化档必须**按武器元素逐个设置**（输出侧键武器元素），不能图省事设角色元素 ——
	#    设角色元素的话，这一行里 5 把武器会全部拿到同一个 +2.0，
	#    矩阵退化成「每行只差 out_mult」，而 out_mult 本来就是逐格查表的，看着完全正常，
	#    于是「键设错了」这件事**不会红、也看不出来**。这里逐个设才真的在测键。
	var chars: Array = ["metal", "wood", "water", "fire", "earth"]
	var m0: Dictionary = {}
	var mfull: Dictionary = {}
	for ce in chars:
		p.element = ce
		var row0: Dictionary = {}
		var row1: Dictionary = {}
		for eid in Config.ELEMENTS:
			p.stats["assim_" + String(eid)] = 0.0
		for wid in wep_ids:
			var wc0: Dictionary = Config.WEAPONS[wid]
			row0[wid] = float(p._roll_damage(float(wc0["dmg"]), wc0).dmg) / float(wc0["cd"])
		for wid in wep_ids:
			var wc1: Dictionary = Config.WEAPONS[wid]
			var we: String = String(wc1.get("element", ""))
			p.stats["assim_" + we] = 2.0
			row1[wid] = float(p._roll_damage(float(wc1["dmg"]), wc1).dmg) / float(wc1["cd"])
			p.stats["assim_" + we] = 0.0
		m0[ce] = row0
		mfull[ce] = row1

	# ③ 关系方向不变量（纯查表，与武器数值无关）：i_beat 必须 +0.25，beats_me 必须 −0.25
	#    这里盯着「第一人称参考系」—— 写成反向会让减伤变增伤且不报错。
	for ce in chars:
		var beat_el: String = String(Config.OVERCOMES.get(ce, ""))
		var upper: String = _element_that_beats(ce)
		var ob: float = Config.out_mult(ce, beat_el)
		var ou: float = Config.out_mult(ce, upper)
		if ob != 0.25 or ou != -0.25:
			_fail("S8: %s 输出侧关系错位（i_beat=%.2f beats_me=%.2f，应 +0.25/−0.25）"
				% [ce, ob, ou])
			_balance_restore(p, bak, assim_bak)
			return

	# ④ §14 观察点：木角色 + 土武器（thunder_gong）
	#    §14 处方已拍板为「输出侧键**武器**元素」→ 这里满 **土**（= 武器元素）同化度必须撬得动，
	#    满 **木**（= 角色元素）必须撬不动。两者都测，缺一则断言会退化成假绿。
	var tg: Dictionary = Config.WEAPONS["thunder_gong"]
	p.element = "wood"
	p.stats["assim_wood"] = 0.0
	p.stats["assim_earth"] = 0.0
	var no_assim: float = float(p._roll_damage(float(tg["dmg"]), tg).dmg) / float(tg["cd"])
	# 期望比值由被测数据推导（不硬编码 3.25/1.25）：rel 是木→土的关系修正，assim 满档 2.0 加在其上
	var rel_we: float = Config.out_mult("wood", "earth")
	var expect_full: float = no_assim * ((1.0 + rel_we + 2.0) / (1.0 + rel_we))
	p.stats["assim_earth"] = 2.0      # 字面执行 §14 的「满土同化度」= 满**武器**元素
	var full_earth: float = float(p._roll_damage(float(tg["dmg"]), tg).dmg) / float(tg["cd"])
	if not is_equal_approx(full_earth, expect_full):
		_fail("S8: 输出侧同化度应键武器元素（满 assim_earth 应 %.3f→%.3f，实为 %.3f）"
			% [no_assim, expect_full, full_earth])
		_balance_restore(p, bak, assim_bak)
		return
	# 反向对照：满「角色元素」同化度**不**撬动输出 —— 否则上面那条可能只是「两边都加了」的假绿。
	p.stats["assim_earth"] = 0.0
	p.stats["assim_wood"] = 2.0
	var full_wood: float = float(p._roll_damage(float(tg["dmg"]), tg).dmg) / float(tg["cd"])
	if not is_equal_approx(full_wood, no_assim):
		_fail("S8: 输出侧同化度不得键角色元素（满 assim_wood 应仍为 %.3f，实为 %.3f）"
			% [no_assim, full_wood])
		_balance_restore(p, bak, assim_bak)
		return
	p.stats["assim_wood"] = 0.0

	_balance_restore(p, bak, assim_bak)

	# ---- 数值落盘：供 docs/武器DPS体检表.md 转录（不进断言，只打印）----
	print("BALANCE base=" + str(base_line))
	print("BALANCE m0=" + str(m0))
	print("BALANCE mfull=" + str(mfull))
	print("BALANCE wood+earth assim0=%.4f full_earth=%.4f full_wood=%.4f"
		% [no_assim, full_earth, full_wood])
	print("SMOKE: S8 平衡探针（基线 DPS / 输出侧矩阵 / 关系方向 / 同化度键武器元素 + 角色元素反向对照）OK")


## ⚠️ S8 综合战力：**DPS 排序必须带上「攻击距离 / AOE / 生存」三个维度才有意义**。
##
## 近战 / 近距离武器（knife 95px、flamethrower 110px）必须冲进敌人的火力圈才打得到人；
## 而 `ai == "shooter"` 的远程敌人会把自己钉在 `keep_dist`（内置 ≈270~320px）上放风筝。
## 于是 **knife 的高单体 DPS 是「为贴脸风险付的价钱」，不是数值过强** ——
## 单看 DPS 排名会得出「满同化前五名全是金剑 → 金剑过强」的错误结论。
##
## reach 口径必须与源码一致，否则文档与结算会悄悄分叉：
##   远程 = `bspeed × bullet_life + 26.0`        （`player.gd:321`）
##   近战 = `range × (1 + melee_range_bonus)`    （`player.gd:380`，白板下就是 `range`）
##
## ⚠️ 安全线只取**内置**敌人（跳过带 `source` 的 mod 条目）：若让工坊内容参与定义这条线，
##    某 mod 塞一只 `keep_dist=20` 的射手就能让下面的反向断言假红，
##    而病因会被指向「近战武器设计错了」——典型误诊。
## 移动端 UI 度量（第 10 轮补）。改动前冒烟对 UiMetrics **零覆盖** ——
## 它同时被桌面与移动端读，一旦改坏，桌面排布会「静默变形」（不报错、只是位置变了）。
## 所以这里钉三件事：① 纯函数真的会收缩（不是恒等）② 收缩有下限（不出 0/负数）
## ③ 桌面端契约：card_grid / touch_at_least / 气泡四个上限**一律返回原值**。
func _check_mobile_ui() -> void:
	# ① 夹进视口：超出部分被裁到 vp - pad*2
	var vp := Vector2(200.0, 100.0)
	var c1: Vector2 = HintBubble.clamp_to_viewport(Vector2(9999.0, 9999.0), vp)
	if not c1.is_equal_approx(Vector2(192.0, 92.0)):
		_fail("clamp_to_viewport 未把尺寸夹进视口：%s（期望 192,92）" % c1)
		return
	# 反向对照：它必须**不是恒等函数**，否则上面那条在「函数没生效」时也会绿
	if c1.is_equal_approx(Vector2(9999.0, 9999.0)):
		_fail("clamp_to_viewport 是恒等函数（没生效）")
		return
	# ② 小尺寸不被放大（只在超限时收缩）
	var c2: Vector2 = HintBubble.clamp_to_viewport(Vector2(10.0, 20.0), vp)
	if not c2.is_equal_approx(Vector2(10.0, 20.0)):
		_fail("clamp_to_viewport 把未超限的尺寸改动了：%s" % c2)
		return
	# ③ 极小视口：下界兜到 1 而不是 0/负数（0 会让气泡不可见且落点夹取反向）
	var c3: Vector2 = HintBubble.clamp_to_viewport(Vector2(80.0, 80.0), Vector2(10.0, 10.0))
	if c3.x < 1.0 or c3.y < 1.0:
		_fail("clamp_to_viewport 在极小视口下返回了 0/负数：%s" % c3)
		return
	# ④ 桌面契约：headless 无触屏、非 mobile、视口高 720 → 一定不是 full_page
	if UiMetrics.prefers_full_page():
		_fail("桌面/headless 不该判为 full_page（排布分支会整体切错）")
		return
	if UiMetrics.size_class() != "expanded":
		_fail("桌面 720 高应为 expanded，实为 %s" % UiMetrics.size_class())
		return
	# card_grid 在非 full_page 时必须**原样返回 want**，否则桌面卡阵尺寸会变
	var g: Dictionary = UiMetrics.card_grid(3, Vector2(210.0, 224.0), 150.0, 150.0, 14.0, 140.0)
	if not Vector2(g.card_size).is_equal_approx(Vector2(210.0, 224.0)) or int(g.cols) != 3:
		_fail("card_grid 桌面端未原样返回设计尺寸：%s cols=%s" % [g.card_size, g.cols])
		return
	# touch_at_least：非触屏恒返回原值（这是「桌面不被改」的总闸门）
	if not is_equal_approx(UiMetrics.touch_at_least(30.0), 30.0):
		_fail("非触屏设备 touch_at_least 改动了原值")
		return
	# 气泡四个上限：桌面必须等于原常量（窄屏收缩绝不能漏到桌面）。
	# 它们是 static，所以这里**不实例化** —— 测试里 new 一个 Control 会往 ObjectDB 塞对象，
	# 把退出时的泄漏计数搅浑，真正的新增泄漏反而看不见。
	var mw: float = HintBubble._max_w()
	var mh: float = HintBubble._max_h()
	var dw: float = HintBubble._dock_w()
	var dh: float = HintBubble._dock_max_h()
	var caps_ok: bool = is_equal_approx(mw, HintBubble.MAX_W) and is_equal_approx(mh, HintBubble.MAX_H)
	caps_ok = caps_ok and is_equal_approx(dw, HintBubble.DOCK_W) and is_equal_approx(dh, HintBubble.DOCK_MAX_H)
	var caps_txt := "max_w=%.1f max_h=%.1f dock_w=%.1f dock_max_h=%.1f" % [mw, mh, dw, dh]
	if not caps_ok:
		_fail("气泡尺寸上限在桌面端被改动了：%s" % caps_txt)
		return
	# ⑤ 安全区兜底：四边都不小于 SAFE_MIN_DP（刘海 API 不可用时也不能是 0）
	var ins: Dictionary = UiMetrics.safe_insets()
	var min_side: float = UiMetrics.dp(UiMetrics.SAFE_MIN_DP) - 0.01
	for k in ["left", "right", "top", "bottom"]:
		if float(ins[k]) < min_side:
			_fail("安全区 %s 低于兜底值：%.2f < %.2f" % [k, float(ins[k]), min_side])
			return
	# available() 必须真的扣掉了边距（否则各界面的「自适应」都在按全屏算）
	var avail: Vector2 = UiMetrics.available()
	var vu: Vector2 = UiMetrics.viewport_units()
	if avail.x <= 0.0 or avail.y <= 0.0 or avail.x >= vu.x or avail.y >= vu.y:
		_fail("available() 未扣除边距：avail=%s viewport=%s" % [avail, vu])
		return
	# ⑥ grid_columns 纯函数：宽了才多列、窄了只 1 列（反向对照，防「恒返回 1」或「恒返回 n」）
	if UiMetrics.grid_columns(2000.0, 150.0, 3, 10.0) != 3:
		_fail("grid_columns 在宽区未放满 3 列")
		return
	if UiMetrics.grid_columns(200.0, 150.0, 3, 10.0) != 1:
		_fail("grid_columns 在窄区未退化成 1 列")
		return
	print("SMOKE: mobile ui metrics OK（%s / caps %s）" % [UiMetrics.size_class(), caps_txt])

func _check_reach_safety() -> void:
	var shooter_min := 1e9
	var shooter_max := 0.0
	var n_shooter := 0
	for eid in Registry.enemies:
		var ec: Dictionary = Registry.enemies[eid]
		if ec.has("source"):
			continue                       # mod 条目不参与内置平衡线的定义
		if String(ec.get("ai", "")) != "shooter":
			continue
		n_shooter += 1
		var kd: float = float(ec.get("keep_dist", 270.0))
		shooter_min = minf(shooter_min, kd)
		shooter_max = maxf(shooter_max, kd)
	if n_shooter == 0:
		_fail("S8: 内置池里没有 shooter AI —— keep_dist 安全线无从计算")
		return
	# AOE 面积是「客观强度」指标，比拍脑袋给倍率好复用：
	#   扇形 = ½·r²·θ（swing_arc 是弧度） / 溅射 = π·splash²
	var reach_tbl: Dictionary = {}
	var aoe_tbl: Dictionary = {}
	var eff_tbl: Dictionary = {}       # 有效交火距离 = 弹体射程 + splash（近战无 splash → 与 reach 相等）
	for wid1 in Config.LOADOUT_WEAPONS:
		var wc: Dictionary = Config.WEAPONS[wid1]
		var rch: float = 0.0
		var area: float = 0.0
		var sp: float = float(wc.get("splash", 0.0))
		if String(wc.get("attack_type", "projectile")) == "melee":
			rch = float(wc.get("range", 0.0))
			area = 0.5 * rch * rch * float(wc.get("swing_arc", 0.0))
		else:
			rch = float(wc.get("bspeed", 300.0)) * float(wc.get("bullet_life", 1.1)) + 26.0
			area = PI * sp * sp
		reach_tbl[wid1] = rch
		eff_tbl[wid1] = rch + sp
		aoe_tbl[wid1] = area
	print("BALANCE reach=" + str(reach_tbl))
	print("BALANCE reach_eff=" + str(eff_tbl))
	print("BALANCE aoe_area=" + str(aoe_tbl))
	print("BALANCE shooter_keep_dist=[%.0f,%.0f] n=%d" % [shooter_min, shooter_max, n_shooter])
	# ③ 有效交火距离口径：**有 splash 的必须严格大于弹体射程，没 splash 的必须严格相等**。
	#    溅射武器的弹体飞到射程尽头会自爆（`bullet.gd:91-93`），爆炸半径内是**全额伤害 + 全额上状态**
	#    （`explosion.gd:52-57`，无距离衰减）→ 真实能打到人的距离 = 弹体射程 + splash。
	#    ⚠️ 旧口径只报弹体飞行距离，把喷火枪的可用交火距离**读短了整整 75px**（110 → 实为 185），
	#    导致「近距档」评价被系统性夸大风险 —— 属于「不报错、只是算错」那一类。
	#    两侧都要测：只测正向的话，把 splash 加进不该加的地方（近战）也会判绿。
	for wid4 in Config.LOADOUT_WEAPONS:
		var wc4: Dictionary = Config.WEAPONS[wid4]
		var sp4: float = float(wc4.get("splash", 0.0))
		var base4: float = float(reach_tbl[wid4])
		var eff4: float = float(eff_tbl[wid4])
		if sp4 > 0.0 and eff4 <= base4:
			_fail("S8: %s 带 splash=%.0f 但有效交火距离 %.0f 未超过弹体射程 %.0f（溅射没接进交火距离）"
				% [String(wid4), sp4, eff4, base4])
			return
		if sp4 <= 0.0 and not is_equal_approx(eff4, base4):
			_fail("S8: %s 无 splash 却算出有效交火距离 %.0f ≠ 弹体射程 %.0f（口径分叉）"
				% [String(wid4), eff4, base4])
			return
	# ① 正向：必须存在能站在**全部**远程敌人火力圈之外的选项 —— 否则玩家全程被迫吃伤害
	var has_safe := false
	for wid2 in reach_tbl:
		if float(reach_tbl[wid2]) > shooter_max:
			has_safe = true
			break
	if not has_safe:
		_fail("S8: 没有任何武器射程超过内置远程敌人最大 keep_dist(%.0f) → 玩家将被迫全程吃火力"
			% shooter_max)
		return
	# ② 反向：近战武器必须**真的够不着** —— 「高风险」得是设计事实，不是配错了数值。
	#    没有这一侧的话，把 knife 的 range 改成 400 也不会有人发现。
	for wid3 in Config.LOADOUT_WEAPONS:
		var wc3: Dictionary = Config.WEAPONS[wid3]
		if String(wc3.get("attack_type", "projectile")) != "melee":
			continue
		var rr: float = float(reach_tbl[wid3])
		if rr >= shooter_min:
			_fail("S8: 近战武器 %s reach=%.0f 不该达到远程敌人最小 keep_dist=%.0f（贴脸风险就是它的定价）"
				% [wid3, rr, shooter_min])
			return
	# ---- #9 范围加成按面积：半径只能涨 sqrt(1+加成) ----
	var rs20 := Config.radius_scale(0.20)
	if not is_equal_approx(Config.radius_scale(0.0), 1.0):
		_fail("#9 无加成时半径倍率必须恒为 1.0（=%.4f）" % Config.radius_scale(0.0))
		return
	if not is_equal_approx(rs20, sqrt(1.20)) or rs20 >= 1.20:
		_fail("#9 半径换算错误（radius_scale(0.20)=%.4f，期望 %.4f，且必须 < 1.20）"
			% [rs20, sqrt(1.20)])
		return
	# 面积守恒：半径倍率的**平方**必须等于「1 + 加成」—— 这就是「按面积」的定义
	for b9 in [0.10, 0.20, 0.42, 1.0]:
		var area_gain: float = Config.radius_scale(float(b9)) * Config.radius_scale(float(b9))
		if not is_equal_approx(area_gain, 1.0 + float(b9)):
			_fail("#9 面积守恒被破坏（加成 %.2f → 实际面积 ×%.4f）" % [b9, area_gain])
			return
	# 集成：玩家侧实际算出来的 reach / splash 必须走同一换算（不能只有纯函数对）
	var p9: Node2D = _main.get_node("Player")
	var keep9: Dictionary = {}
	for k9 in ["melee_range_bonus", "aoe_radius_bonus"]:
		keep9[k9] = float(p9.stats[k9])
		p9.stats[k9] = 0.20
	var melee_probe: Dictionary = {}
	for wid9 in Registry.weapons:
		if String(Registry.weapons[wid9].get("attack_type", "projectile")) == "melee":
			melee_probe = Registry.weapons[wid9]
			break
	if melee_probe.is_empty():
		_restore_stat_keys(p9, keep9)
		_fail("#9 找不到近战武器用于集成验证")
		return
	var want_reach: float = float(melee_probe.get("range", 0.0)) * Config.radius_scale(0.20)
	if not is_equal_approx(p9.weapon_reach(melee_probe), want_reach):
		_restore_stat_keys(p9, keep9)
		_fail("#9 近战 reach 未走面积换算（实得 %.2f，期望 %.2f）"
			% [p9.weapon_reach(melee_probe), want_reach])
		return
	var splash_probe: Dictionary = {}
	for wid10 in Registry.weapons:
		var wc10: Dictionary = Registry.weapons[wid10]
		if float(wc10.get("splash", 0.0)) > 0.0:
			splash_probe = wc10
			break
	if splash_probe.is_empty():
		_restore_stat_keys(p9, keep9)
		_fail("#9 找不到带 splash 的武器用于集成验证")
		return
	var rt9: Dictionary = p9._weapon_runtime_cfg(splash_probe)
	var want_splash: float = float(splash_probe.get("splash", 0.0)) * Config.radius_scale(0.20)
	if not is_equal_approx(float(rt9.get("splash", 0.0)), want_splash):
		_restore_stat_keys(p9, keep9)
		_fail("#9 溅射半径未走面积换算（实得 %.2f，期望 %.2f）"
			% [float(rt9.get("splash", 0.0)), want_splash])
		return
	_restore_stat_keys(p9, keep9)
	print("SMOKE: #9 范围加成按面积（radius_scale 面积守恒 + 近战 reach / 溅射 splash 集成）OK")
	print("SMOKE: S8 综合战力（reach / AOE 面积 / %d 只内置远程怪 keep_dist %.0f~%.0f）OK"
		% [n_shooter, shooter_min, shooter_max])


## 原样还回一批 stats 键并重新净化 —— 「租的变量要还」的公共写法。
## 起因见 `_check_spread_channel` 与 `_check_balance_log` 里关于**残留加成**的长注释。
func _restore_stat_keys(p: Node2D, keep: Dictionary) -> void:
	for k in keep:
		p.stats[String(k)] = float(keep[k])
	p._sanitize_stats()


## 第 11 轮 · 用户需求 7：分段难度曲线 + 波段怪构成。
## 三条链路各测正向与反向：
##   ① 曲线：端点不漂移 + 单调不减 + 「先难后易 / 渐肉」真的体现在**斜率**上
##   ② 构成：远程段远程份额涨、精英段精英份额涨**且**杂兵份额跌（两头都断言，
##     否则「全都乘 2」这种错实现照样判绿）
##   ③ 名单防漂移：与 `Registry` 的 `ai=="shooter"` 双向核对 + 三张名单两两不相交
func _check_wave_bands() -> void:
	# ---- ① 曲线 ----
	var prev_hp := 0.0
	for w in range(1, Config.WAVES_TOTAL + 1):
		var hp := Config.wave_hp_scale(w)
		var dm := Config.wave_dmg_scale(w)
		if hp < prev_hp - 1e-6:
			_fail("难度曲线非单调：W%d HP 倍率 %.3f 低于 W%d 的 %.3f" % [w, hp, w - 1, prev_hp])
			return
		if hp <= 0.0 or dm <= 0.0:
			_fail("难度曲线出现非正倍率（W%d：HP %.3f / DMG %.3f）" % [w, hp, dm])
			return
		prev_hp = hp
	if not is_equal_approx(Config.wave_hp_scale(1), 1.0) \
			or not is_equal_approx(Config.wave_dmg_scale(1), 1.0):
		_fail("W1 难度倍率必须恒为 1.0（开局基准，改动它会连坐首杀窗口）")
		return
	# 端点不许失控漂移：W20 落在合理带内即可，不写死精确值（那是设计值不是实现细节）
	var hp20 := Config.wave_hp_scale(Config.WAVES_TOTAL)
	if hp20 < 6.0 or hp20 > 7.5:
		_fail("W20 HP 倍率 %.2f 超出合理带 [6.0, 7.5] —— 分段改动把端点带跑了" % hp20)
		return
	# 「先难后易」：区块 1（W1-4）的每波增量必须**严格大于**区块 2（W4-8）的。
	# 这是用户需求的直接翻译；只断言「W20 变大」的话，整条曲线抬高也能过。
	var slope1 := (Config.wave_hp_scale(4) - Config.wave_hp_scale(1)) / 3.0
	var slope2 := (Config.wave_hp_scale(8) - Config.wave_hp_scale(4)) / 4.0
	if slope1 <= slope2:
		_fail("「W1-4 难 / W4-8 易」没体现：区块1 斜率 %.3f 未大于区块2 的 %.3f"
			% [slope1, slope2])
		return
	# 「渐肉」：末段（W16-20）斜率必须 ≥ 区块 2（易）—— 否则后段成了第二个休息区
	var slope5 := (Config.wave_hp_scale(20) - Config.wave_hp_scale(16)) / 4.0
	if slope5 < slope2:
		_fail("「W16-20 渐肉」没体现：末段斜率 %.3f 低于区块2 的 %.3f" % [slope5, slope2])
		return
	# ---- ③ 名单防漂移（先测这个：后面②要用它的数据）----
	var ranged_truth: Array = []
	for eid in Registry.enemies:
		var ec: Dictionary = Registry.enemies[eid]
		if ec.has("source"):
			continue                      # mod 条目不参与内置构成的名单核对
		if String(ec.get("ai", "")) == "shooter":
			ranged_truth.append(String(eid))
	for rid in Config.BAND_RANGED_MOB_IDS:
		if not Registry.enemies.has(String(rid)):
			_fail("BAND_RANGED_MOB_IDS 含未注册敌人 %s" % String(rid))
			return
		if not ranged_truth.has(String(rid)):
			_fail("BAND_RANGED_MOB_IDS 里的 %s 在 Registry 里并非 shooter AI —— 名单写错了" % String(rid))
			return
	for tid in ranged_truth:
		if not (Config.BAND_RANGED_MOB_IDS as Array).has(String(tid)):
			_fail("Registry 里的 shooter 怪 %s 不在 BAND_RANGED_MOB_IDS 里 —— 名单漏了它，" % String(tid)
				+ "「远程多」这一段就悄悄漏一只")
			return
	for eid2 in Config.BAND_ELITE_MOB_IDS + Config.BAND_TRASH_MOB_IDS:
		if not Registry.enemies.has(String(eid2)):
			_fail("波段名单含未注册敌人 %s" % String(eid2))
			return
	# 三张名单两两不相交：同时命中两张会吃到两次倍率（远程精英被平方放大）
	var all_band: Array = []
	for grp in [Config.BAND_RANGED_MOB_IDS, Config.BAND_ELITE_MOB_IDS, Config.BAND_TRASH_MOB_IDS]:
		for mid_x in grp:
			if all_band.has(String(mid_x)):
				_fail("波段名单重复收录 %s —— 会吃到两次倍率" % String(mid_x))
				return
			all_band.append(String(mid_x))
	# ---- ② 构成：用**份额**（占比）而不是绝对权重，天然免疫「整体缩放」这种假实现 ----
	var share_w10 := _band_share(10, Config.BAND_RANGED_MOB_IDS)
	var share_w6 := _band_share(6, Config.BAND_RANGED_MOB_IDS)
	if share_w10 <= share_w6:
		_fail("区块 3（W9-12）「远程多」未生效：W10 远程份额 %.3f ≤ W6 的 %.3f"
			% [share_w10, share_w6])
		return
	var elite_w10 := _band_share(10, Config.BAND_ELITE_MOB_IDS)
	var elite_w14 := _band_share(14, Config.BAND_ELITE_MOB_IDS)
	var trash_w10 := _band_share(10, Config.BAND_TRASH_MOB_IDS)
	var trash_w14 := _band_share(14, Config.BAND_TRASH_MOB_IDS)
	if elite_w14 <= elite_w10:
		_fail("区块 4（W13-16）「小精英」未生效：W14 精英份额 %.3f ≤ W10 的 %.3f"
			% [elite_w14, elite_w10])
		return
	if trash_w14 >= trash_w10:
		_fail("「小精英」只抬了精英、没让出杂兵份额（W14 杂兵 %.3f ≥ W10 的 %.3f）——"
			% [trash_w14, trash_w10] + " 这不是构成变化，是整体缩放")
		return
	# 「渐肉」在**构成**侧的体现 = 末段仍是精英主导（相对中段），强度由 HP 曲线末段斜率承担
	# （上面 slope5 已断言）。⚠️ 这里**刻意不写「精英份额一路递增到区块 5」**：
	# 区块 5 的精英倍率(1.7)本就低于区块 4(2.0) ——「小精英」是区块 4 的峰值，
	# 区块 5 改为靠 HP 变厚 + 整池上移继续加压。把「递增」硬钉进断言会让
	# **完全正确的实现也红**（份额实算：W18 精英 ≈0.402 < W14 ≈0.440，那是设计不是 bug）。
	# 故这里只断言「末段精英主导 / 杂兵让位」这两个与区块 3 的对照 —— 方向与区块 4 一致。
	var elite_w18 := _band_share(18, Config.BAND_ELITE_MOB_IDS)
	var trash_w18 := _band_share(18, Config.BAND_TRASH_MOB_IDS)
	if elite_w18 <= elite_w10:
		_fail("区块 5（W17-20）「渐肉」的精英份额 %.3f 不高于中段（区块3）的 %.3f"
			% [elite_w18, elite_w10])
		return
	if trash_w18 >= trash_w10:
		_fail("区块 5 的杂兵份额 %.3f 未低于中段（区块3）的 %.3f —— 末段回到杂兵海了"
			% [trash_w18, trash_w10])
		return
	# 区块 1/2 刻意不做构成偏移（空表）→ 份额必须保持「未加工」的水平，
	# 即低于区块 3 的远程份额与区块 4 的精英份额。这是反向对照：
	# 若有人把倍率表整体前移，这三条会同时红。
	if _band_share(4, Config.BAND_RANGED_MOB_IDS) >= share_w10:
		_fail("区块 1（W1-4「难」）不该在构成上堆远程 —— 难度应由 HP/DMG 曲线承担")
		return
	# 权重必须恒 > 0（w<=0 的条目会让 weighted_pick 报错并返回 null）
	for w2 in range(1, Config.WAVES_TOTAL + 1):
		for entry_w in Config.wave_composition(w2):
			if float((entry_w as Dictionary).get("w", 0.0)) <= 0.0:
				_fail("波段加权把权重压到 ≤ 0（W%d / %s）" % [w2, String((entry_w as Dictionary).get("item", ""))])
				return
	print("SMOKE: 第11轮 分段难度曲线 + 波段怪构成（端点不漂移 / 先难后易 / 远程多·小精英·渐肉 / 名单防漂移）OK")


## 某波段名单在 W 波出怪池里的**权重份额**（占比）。
## 用份额而不是绝对权重：整体缩放（全都 ×2）不会改变份额 —— 那正是要拦的假实现。
func _band_share(w: int, ids: Array) -> float:
	var total := 0.0
	var hit := 0.0
	for e in Config.wave_composition(w):
		var d: Dictionary = e
		var wv := float(d.get("w", 0.0))
		total += wv
		if ids.has(String(d.get("item", ""))):
			hit += wv
	return 0.0 if total <= 0.0 else hit / total


## 第 11 轮：喷射散布角通道（喷嘴类道具）。
## 加「新字段」的老坑是**零消费点**（`boss_hp_scale` 那次），所以三侧一起断言：
##   ① 道具真的注册进来（不在 EFFECT_LIMITS 的键会让 registry 整条拒登，只 push_warning）
##   ② 通道真的被 `_weapon_runtime_cfg` 消费，且 0 值时**原样复用原字典**（反向对照）
##   ③ 表现层同源：火焰锥宽度随同一倍率缩放（否则就是「看到的 ≠ 打到的」）
##   + 相关度闸门两侧都测（有喷射武器才刷、没有就别刷）
func _check_spread_channel() -> void:
	var ids := ["i-highpressure", "i-multihole"]
	for iid in ids:
		if not Registry.items.has(iid):
			_fail("第11轮：喷嘴道具 %s 未注册（`proj_spread_mult` 不在 EFFECT_LIMITS 会整条被拒登）" % iid)
			return
		if not Registry.items[iid].get("effects", {}).has("proj_spread_mult"):
			_fail("第11轮：喷嘴道具 %s 没有 proj_spread_mult 效果" % iid)
			return
	# 反向对照：两件喷嘴方向必须相反 —— 否则「收窄 / 扩散」只有一头能用，
	# 而只测正向的话，把两件都写成 +60% 也会判绿。
	var hi := float(Registry.items["i-highpressure"].effects.proj_spread_mult)
	var mh := float(Registry.items["i-multihole"].effects.proj_spread_mult)
	if not (hi < 0.0 and mh > 0.0):
		_fail("第11轮：两件喷嘴方向必须相反（高压=%.2f / 多孔=%.2f）" % [hi, mh])
		return
	# ② 消费点前置：内置武器里必须**存在**带 spread 的，否则通道写了没人吃
	var spread_wid := ""
	for wid in Config.WEAPONS:
		if float(Config.WEAPONS[wid].get("spread", 0.0)) > 0.0:
			spread_wid = String(wid)
			break
	if spread_wid == "":
		_fail("第11轮：内置武器里没有带 spread 的 —— proj_spread_mult 零消费点")
		return
	var p: Node2D = _main.get_node("Player")
	var cfg: Dictionary = Registry.weapons[spread_wid]
	var base_spread := float(cfg.get("spread", 0.0))
	# ⚠️⚠️ 本用例排在几十条用例之后，玩家身上**已经有别人留下的武器加成**。
	#    实测（第 11 轮第一次跑就假红）：残留会让 `_weapon_runtime_cfg` 走 duplicate 分支，
	#    于是「全 0 时不该 duplicate」这条反向对照必红，**且红得像「实现错了」**。
	#    与 `_check_balance_log` 同款纪律：进用例先把武器加成键全摘掉，所有退出路径原样还回去。
	var keep := {}
	for k in ["bullet_speed_bonus", "bullet_range_bonus", "throw_speed_bonus",
			"throw_range_bonus", "melee_range_bonus", "aoe_radius_bonus", "proj_spread_mult"]:
		keep[String(k)] = float(p.stats.get(String(k), 0.0))
		p.stats[String(k)] = 0.0
	# 反向对照：武器加成**全部归零**后必须原样复用原字典（`_weapon_runtime_cfg` 的早退约定）。
	# ⚠️ 用 `is_same()` 而不是 `!=`：Dictionary 的 `!=` 语义随版本摇摆，
	#    `is_same()` 明确比的是「同一个实例」，正是这里要测的东西。
	if not is_same(p._weapon_runtime_cfg(cfg), cfg):
		_restore_stat_keys(p, keep)
		_fail("第11轮：全部武器加成归零时不该 duplicate 武器字典")
		return
	if not is_equal_approx(float(p._weapon_runtime_cfg(cfg).get("spread", 0.0)), base_spread):
		_restore_stat_keys(p, keep)
		_fail("第11轮：无加成时 spread 被改动（应恒为 %.4f）" % base_spread)
		return
	# 正向：收窄 / 扩散都必须真的改到 spread，且严格等于 base × (1+m)
	p.stats["proj_spread_mult"] = hi
	var got_hi := float(p._weapon_runtime_cfg(cfg).get("spread", 0.0))
	p.stats["proj_spread_mult"] = mh
	var got_mh := float(p._weapon_runtime_cfg(cfg).get("spread", 0.0))
	if not (got_hi < base_spread and got_mh > base_spread):
		_restore_stat_keys(p, keep)
		_fail("第11轮：喷嘴没改到 spread（base=%.4f 收窄=%.4f 扩散=%.4f）"
			% [base_spread, got_hi, got_mh])
		return
	if absf(got_hi - base_spread * (1.0 + hi)) > 1e-6 \
			or absf(got_mh - base_spread * (1.0 + mh)) > 1e-6:
		_restore_stat_keys(p, keep)
		_fail("第11轮：spread 缩放与 (1 + proj_spread_mult) 不一致")
		return
	# ③ 表现层同源：火焰锥末端宽度必须跟着同一倍率走
	p.stats["proj_spread_mult"] = 0.0
	p._ignite_flame_jet(cfg, 0.0)
	var w0 := float(p._ensure_flame_jet().width)
	p.stats["proj_spread_mult"] = mh
	p._ignite_flame_jet(cfg, 0.0)
	var w1 := float(p._ensure_flame_jet().width)
	_restore_stat_keys(p, keep)
	if w0 <= 0.0 or absf(w1 - w0 * (1.0 + mh)) > 1e-4:
		_fail("第11轮：火焰锥宽度没跟着 proj_spread_mult 缩放（%.2f → %.2f）" % [w0, w1])
		return
	# 相关度闸门两侧都测：用**非喷射弹幕武器**做反向对照（这样其它键都过得去，
	# 只有 proj_spread_mult 那一关该拦下它）
	if Config.entry_weapon_relevant(Registry.items["i-highpressure"], [{ "type": "frost_staff" }]):
		_fail("第11轮：没有喷射武器时仍判定喷嘴相关（会给一屋子废属性）")
		return
	if not Config.entry_weapon_relevant(Registry.items["i-highpressure"], [{ "type": spread_wid }]):
		_fail("第11轮：持有喷射武器时喷嘴却被判无关")
		return
	print("SMOKE: 第11轮 喷射散布角通道（喷嘴道具注册 / 1±proj_spread_mult 缩放 / 火焰锥同源 / 相关度闸门）OK")


## 第 11 轮 · 用户需求 6：临时增益显示层。
## 断言「数据源 → HUD 增益条 → 详情文案」三段都真的接上：
##   ① `player.active_buffs()` 在技能增益生效时给出条目（其余情形归零 → 反面对照）
##   ② HUD 的增益条子节点数 = 条目数（挂上了才叫「在武器上方显示」）
##   ③ `EntryText.buff_detail()` 正文非空 —— 空正文会让 `attach_hover` **静默不挂**，
##      悬浮没反应却不报错，正是最难发现的那一类
func _check_buff_display() -> void:
	var p: Node2D = _main.get_node("Player")
	var h: Control = _main.get_node("UI/HUD")
	# 反面对照：先把技能增益清空，`active_buffs()` 里不许再出现「剩余秒」那一条
	var keep_t := float(p._skill_buff_t)
	var keep_eff: Dictionary = p._skill_buff_effects.duplicate()
	p._skill_buff_t = 0.0
	p._skill_buff_effects = {}
	for b in p.active_buffs():
		if float((b as Dictionary).get("remain", -1.0)) >= 0.0:
			p._skill_buff_t = keep_t
			p._skill_buff_effects = keep_eff
			_fail("第11轮：技能增益已清空，active_buffs 仍报出带倒计时的条目")
			return
	# 正向：注入一条技能增益（直接写字段，不走 use_skill —— 那会真的进冷却）
	p._skill_buff_effects = { "dmg_mult": 0.25 }
	p._skill_buff_t = 4.0
	var buffs: Array = p.active_buffs()
	if buffs.is_empty():
		p._skill_buff_t = keep_t
		p._skill_buff_effects = keep_eff
		_fail("第11轮：技能增益生效时 active_buffs 为空")
		return
	var timed: Dictionary = {}
	for b in buffs:
		if float((b as Dictionary).get("remain", -1.0)) >= 0.0:
			timed = b
			break
	if timed.is_empty() or not is_equal_approx(float(timed.get("remain", 0.0)), 4.0):
		p._skill_buff_t = keep_t
		p._skill_buff_effects = keep_eff
		_fail("第11轮：技能增益没带出剩余秒（期望 4.0，得到 %s）" % str(timed))
		return
	# ② HUD 增益条：显式刷一次（`_process` 在非 PLAYING 阶段会跳过整段刷新）
	h._refresh_buff_row()
	if int(h._buff_row.get_child_count()) != buffs.size():
		p._skill_buff_t = keep_t
		p._skill_buff_effects = keep_eff
		_fail("第11轮：HUD 增益条芯片数 %d ≠ active_buffs 条目数 %d"
			% [int(h._buff_row.get_child_count()), buffs.size()])
		return
	if not h._buff_row.visible:
		p._skill_buff_t = keep_t
		p._skill_buff_effects = keep_eff
		_fail("第11轮：有增益时 HUD 增益条仍不可见")
		return
	# 芯片尺寸必须真的量出来 —— `_buff_row` 的父节点是 Control 不是 Container，
	# 没人替它设 size；不显式设的话宽高恒 0，芯片画不出来且不报错。
	if h._buff_row.size.x <= 0.0 or h._buff_row.size.y <= 0.0:
		p._skill_buff_t = keep_t
		p._skill_buff_effects = keep_eff
		_fail("第11轮：HUD 增益条尺寸为零（芯片画不出来）")
		return
	# ③ 详情文案：正文必须非空且说明实际加成（空正文 = 悬浮静默不挂）
	var det := EntryText.buff_detail(timed)
	var body := String(det.get("body", ""))
	if body.strip_edges() == "":
		p._skill_buff_t = keep_t
		p._skill_buff_effects = keep_eff
		_fail("第11轮：buff_detail 正文为空 → 悬浮会静默不挂")
		return
	if not body.contains("剩余") or not body.contains("25%"):
		p._skill_buff_t = keep_t
		p._skill_buff_effects = keep_eff
		_fail("第11轮：buff_detail 正文没写清剩余时间与实际加成：%s" % body.replace("\n", " / "))
		return
	# 收尾：原样还回去
	p._skill_buff_t = keep_t
	p._skill_buff_effects = keep_eff
	print("SMOKE: 第11轮 临时增益显示（技能/地脉/战意数据源 · HUD 武器上方增益条 · 详情文案）OK")


## 单把武器在「白板 + 单体 + 非暴击」下的**稳态 DoT DPS**。
##
## 口径镜像 `enemy.gd:331-339` 的 tick 公式，参数全部取自 `Config`，不另抄数字：
##   hits/s    = 1 / cd
##   stacks/s  = hits/s × status_chance
##   稳态层数  = min(stack_max, stacks/s × duration)   ← 只要还在打，duration 每发都被刷新
##   每跳伤害  = 单发伤害 × dot_scale × 稳态层数
##   DoT DPS   = 每跳伤害 / tick
##
## ⚠️ 单发伤害取 `WEAPONS[].dmg`（与 §1 基线表同基准）。输出侧关系 / 同化度 / 暴击
##    是**同一个倍率同时作用在直伤和 DoT 上**（`status_power` = 打完关系后的 dmg），
##    所以它们不改变武器之间的排序，这里不重复折算。
## ⚠️ 中毒走 `dot_max_hp_pct`（按最大生命），与武器伤害无关 → 本函数返回 0、由调用方标注。
func _dot_steady_dps(wc: Dictionary, scfg: Dictionary, chance_override: float = -1.0) -> float:
	var scale := float(scfg.get("dot_scale", 0.0))
	var tick := float(scfg.get("tick", 0.0))
	if scale <= 0.0 or tick <= 0.0:
		return 0.0
	var ch := float(wc.get("status_chance", 1.0)) if chance_override < 0.0 else chance_override
	var hits := 1.0 / maxf(0.01, float(wc.get("cd", 1.0)))
	var stacks: float = minf(float(scfg.get("stack_max", 1)), hits * ch * float(scfg.get("duration", 0.0)))
	return float(wc.get("dmg", 0.0)) * scale * stacks / tick


## 状态 DoT 的稳态贡献 —— **全表此前是纯直伤口径**，DoT 一分钱没算，
## 而「武器带 DoT」是玩家最能直接看到的一块（飘字一直在跳）。这里把它变成可复算的数字。
##
## ⚠️⚠️ **DoT 不吃受击侧**：`enemy.gd:345` 调的是 `take_damage(tick_dmg, false, true)`，
##    **不传 `element_atk`** → 走不进 `take_damage` 里「关系修正 × 元素抗性」那个乘区
##    （只吃 `_damage_taken_mult` 与法宝倍率）。也就是说
##    **对高元素抗性的怪，DoT 相对更值钱**；反之打「被克属性」时直伤更值钱。
##    本探针只算白板单体，**不折算这一层**，它是排序之外的独立维度。
func _check_dot_contribution() -> void:
	var dot_tbl: Dictionary = {}
	var sum_tbl: Dictionary = {}
	var n_dot := 0
	for wid in Config.LOADOUT_WEAPONS:
		var wc: Dictionary = Config.WEAPONS[wid]
		var scfg: Dictionary = Config.status_cfg(String(wc.get("status", "")))
		var d_dps: float = _dot_steady_dps(wc, scfg)
		if d_dps > 0.0:
			n_dot += 1
		dot_tbl[wid] = d_dps
		sum_tbl[wid] = float(wc.get("dmg", 0.0)) / maxf(0.01, float(wc.get("cd", 1.0))) + d_dps
	print("BALANCE dot=" + str(dot_tbl))
	print("BALANCE dps_total=" + str(sum_tbl))
	# ⚠️ `dot_max_hp_pct` 型（poison）**本探针算不了** —— 它按敌人最大生命掉血、随波次变，
	#    没有「白板单体」的固定值。这类状态**单列在 `BALANCE dot_hp_pct=`**，
	#    ⚠️ **绝不能**混进下面的「必须 > 0」—— 否则以后给内置武器配一个 poison，
	#    这条断言就会假红，而病因看着像「DoT 公式写错了」（典型误诊）。
	var hp_pct_tbl: Dictionary = {}
	for wid0 in Config.LOADOUT_WEAPONS:
		var wc0: Dictionary = Config.WEAPONS[wid0]
		var scfg0: Dictionary = Config.status_cfg(String(wc0.get("status", "")))
		if float(scfg0.get("dot_max_hp_pct", 0.0)) > 0.0 \
				and float(scfg0.get("dot_scale", 0.0)) <= 0.0:
			hp_pct_tbl[wid0] = float(scfg0.get("dot_max_hp_pct", 0.0))
	print("BALANCE dot_hp_pct=" + str(hp_pct_tbl))
	# ① 双向：`dot_scale` 型（burn / bleed）必须给出**正**贡献；其余（含纯控场 slow/stun/freeze）
	#    必须**恰好** 0。⚠️ 两侧都要有 —— 只测正向的话，「把所有状态都当 DoT 算」也会判绿。
	for wid2 in Config.LOADOUT_WEAPONS:
		var wc2: Dictionary = Config.WEAPONS[wid2]
		var sid2 := String(wc2.get("status", ""))
		var scfg2: Dictionary = Config.status_cfg(sid2)
		var has_dot := float(scfg2.get("dot_scale", 0.0)) > 0.0
		if has_dot and float(dot_tbl[wid2]) <= 0.0:
			_fail("S8 DoT: %s 带 dot_scale 型状态 %s 却算出 0 贡献（公式或参数写错）" % [String(wid2), sid2])
			return
		if not has_dot and not is_zero_approx(float(dot_tbl[wid2])):
			_fail("S8 DoT: %s 的状态 %s 不是 dot_scale 型 DoT，却算出 %.4f"
				% [String(wid2), sid2, float(dot_tbl[wid2])])
			return
	# ② 反向对照：`status_chance = 0` 必须一点都不产生（验证「命中率 → 层数」这段真的接进去了，
	#    而不是把 dot_scale 直接乘上单发伤害了事）
	for wid3 in Config.LOADOUT_WEAPONS:
		var wc3: Dictionary = Config.WEAPONS[wid3]
		var scfg3: Dictionary = Config.status_cfg(String(wc3.get("status", "")))
		if float(scfg3.get("dot_scale", 0.0)) <= 0.0:
			continue
		if _dot_steady_dps(wc3, scfg3, 0.0) > 0.0:
			_fail("S8 DoT: %s 在 status_chance=0 时仍算出 DoT 贡献（命中率没接进层数）" % String(wid3))
			return
	# ③ 被测对象必须存在（否则表空了这段也判绿）
	if n_dot < 2:
		_fail("S8 DoT: 内置武器里带 DoT 的只有 %d 把（应 ≥2）—— 探针失去被测对象" % n_dot)
		return
	print("SMOKE: S8 状态 DoT（%d 把带 DoT / 白板单体稳态口径，与 §1 基线表同基准）OK" % n_dot)


## §7.4 两条同化度获取途径（2026-09-17 补做，此前只做了道具 + 之悟升级）
##   ① 角色特性：元素角色在**本元素**上开局 `+CHAR_START_ASSIM`（白板角色 `element==""` 不吃）
##   ② 五行反应：每触发一次，参与的两个元素（`from` / `to`）各 `+REACTION_ASSIM_GAIN`，clamp 到上限
##
## ⚠️ ① 必须**新建** Player：主场景那个的 `_ready()` 早跑过了，它的 assim 混着
##    前面用例发的道具/升级/区域加成，**无法反推「开局值」**。
## ⚠️ 两条都配**反向对照**：只测正向的话，「全元素都加了」或「全都没加」都可能判绿。
func _check_assim_gain() -> void:
	var saved_cid: String = GameState.character_id
	# 局外天赋也会改 stats，先复位才能隔离出「开局值」
	MetaProgress.reset_for_tests()
	# ---- ① 元素角色开局同化度 ----
	GameState.character_id = "fire_adept"
	var p_fire: Node2D = preload("res://scenes/characters/player.tscn").instantiate()
	_main.add_child(p_fire)                       # 入树即触发 _ready()
	if String(p_fire.element) != "fire":
		_fail("fire_adept 的角色元素应为 fire，实为 %s" % String(p_fire.element))
		p_fire.queue_free()
		GameState.character_id = saved_cid
		MetaProgress.reset_for_tests()
		return
	var got_start: float = float(p_fire.stats.get("assim_fire", 0.0))
	if not is_equal_approx(got_start, Config.CHAR_START_ASSIM):
		_fail("元素角色未拿到开局同化度（assim_fire=%.3f，期望 %.3f）"
			% [got_start, Config.CHAR_START_ASSIM])
		p_fire.queue_free()
		GameState.character_id = saved_cid
		MetaProgress.reset_for_tests()
		return
	# 反向对照：只加**本元素**那一个，其余必须是 0
	for eid_a in Config.ELEMENTS:
		var ea := String(eid_a)
		if ea == "fire":
			continue
		if float(p_fire.stats.get("assim_" + ea, 0.0)) != 0.0:
			_fail("开局同化度只应加本元素（assim_%s=%.3f 应为 0）"
				% [ea, float(p_fire.stats.get("assim_" + ea, 0.0))])
			p_fire.queue_free()
			GameState.character_id = saved_cid
			MetaProgress.reset_for_tests()
			return
	p_fire.queue_free()
	# 白板角色（element == ""）不该吃这条
	GameState.character_id = "potato"
	var p_white: Node2D = preload("res://scenes/characters/player.tscn").instantiate()
	_main.add_child(p_white)
	for eid_b in Config.ELEMENTS:
		var eb := String(eid_b)
		if float(p_white.stats.get("assim_" + eb, 0.0)) != 0.0:
			_fail("白板角色不该有开局同化度（assim_%s=%.3f）"
				% [eb, float(p_white.stats.get("assim_" + eb, 0.0))])
			p_white.queue_free()
			GameState.character_id = saved_cid
			MetaProgress.reset_for_tests()
			return
	p_white.queue_free()
	GameState.character_id = saved_cid
	MetaProgress.reset_for_tests()
	# ---- ② 五行反应给参与元素 +3% ----
	var pl: Node = _main.get_node("Player")
	var assim_bak2: Dictionary = {}
	for eid_c in Config.ELEMENTS:
		assim_bak2["assim_" + String(eid_c)] = float(pl.stats.get("assim_" + String(eid_c), 0.0))
		pl.stats["assim_" + String(eid_c)] = 0.0
	# ⚠️ `Config.REACTIONS` 的**键是 "wood+fire"**，而 `EventBus.element_reaction` 带的是
	#    **id**（"wood_fire"）—— 两者不是一回事。按 id 找才对
	#    （`Registry.get_reaction` 同样按 id 解析，`enemy.gd:392` 发的也是 id）。
	var rid := "wood_fire"
	var rcfg: Dictionary = {}
	for rk in Config.REACTIONS:
		var rd: Dictionary = Config.REACTIONS[rk]
		if String(rd.get("id", "")) == rid:
			rcfg = rd
			break
	if rcfg.is_empty():
		_fail("Config.REACTIONS 里找不到 id=" + rid + " 的反应")
		return
	var from_el := String(rcfg.get("from", ""))
	var to_el := String(rcfg.get("to", ""))
	# ⚠️ 缺 from/to 会让加成**静默失效且不报错** —— 必须先拦出来
	if from_el == "" or to_el == "":
		_fail("反应 %s 缺 from/to —— 同化度加成会静默失效" % rid)
		return
	# ⚠️ 反应同化度按 reaction_id 冷却发放（Config.REACTION_ASSIM_COOLDOWN_MS），
	#    前序用例可能刚触发过同一反应 —— 先清冷却，否则下面的增益断言会假失败。
	_main.reset_reaction_assim_for_tests()
	EventBus.element_reaction.emit(rid, Vector2.ZERO, [])
	var got_from: float = float(pl.stats.get("assim_" + from_el, 0.0))
	var got_to: float = float(pl.stats.get("assim_" + to_el, 0.0))
	if not is_equal_approx(got_from, Config.REACTION_ASSIM_GAIN) \
			or not is_equal_approx(got_to, Config.REACTION_ASSIM_GAIN):
		_fail("反应未给参与元素加同化度（%s=%.3f / %s=%.3f，期望各 %.3f）"
			% [from_el, got_from, to_el, got_to, Config.REACTION_ASSIM_GAIN])
		return
	# 反向对照：未参与的元素必须是 0
	for eid_d in Config.ELEMENTS:
		var ed := String(eid_d)
		if ed == from_el or ed == to_el:
			continue
		if float(pl.stats.get("assim_" + ed, 0.0)) != 0.0:
			_fail("反应只应给参与的两个元素加同化度（assim_%s=%.3f 应为 0）"
				% [ed, float(pl.stats.get("assim_" + ed, 0.0))])
			return
	# 冷却闸：同一次冷却窗口内再触发，不得再加（否则增益会随同屏怪数膨胀）
	EventBus.element_reaction.emit(rid, Vector2.ZERO, [])
	if not is_equal_approx(float(pl.stats.get("assim_" + from_el, 0.0)), got_from):
		_fail("反应同化度冷却未生效（连续两次触发又加了 %.3f）"
			% (float(pl.stats.get("assim_" + from_el, 0.0)) - got_from))
		return
	# 上限：灌满再触发，不得溢出（否则存档校验 2.0 会反过来拒档）
	var lim: Vector2 = Registry.STAT_LIMITS["assim_" + from_el]
	var cap: float = float(lim.y)
	pl.stats["assim_" + from_el] = cap
	_main.reset_reaction_assim_for_tests()   # 再清冷却，真正走到 clamp 分支
	EventBus.element_reaction.emit(rid, Vector2.ZERO, [])
	if float(pl.stats.get("assim_" + from_el, 0.0)) > cap + 1e-6:
		_fail("反应同化度未 clamp 到上限（%.3f > %.3f）"
			% [float(pl.stats.get("assim_" + from_el, 0.0)), cap])
		return
	for bk in assim_bak2:
		pl.stats[bk] = float(assim_bak2[bk])
	print("SMOKE: §7.4 同化度获取（角色开局 +%.0f%% / 反应 +%.0f%% 且 clamp 到 %.1f）OK"
		% [Config.CHAR_START_ASSIM * 100.0, Config.REACTION_ASSIM_GAIN * 100.0, cap])


func _check_endless() -> void:
	Leaderboard.set_storage_root_for_tests("user://tests/lb")
	Leaderboard.entries = []   # 防上次异常中断的残留文件污染名次断言
	# 防御性复位自定义规则：本用例对波号有**硬期望**（BOSS 波 → +1 波），
	# 而 `start_wave` 会按 `RunRules.wave_total` 夹断波号 —— 只要上游有任何一处
	# 把 active/values 泄漏出来，这里就会以「无尽流程失败」的面目报红，
	# 真正的病因却在几百行之外。一行复位把这种误诊挡掉。
	RunRules.apply_from_save("garbage")
	# ---- 标准模式最后一波通关 → 胜利结算 → 继续无尽 ----
	GameState.endless = false
	GameState.score = 0
	var wm_v: Node = _main.get_node("WaveManager")
	wm_v.start_wave(Config.BOSS_WAVE)
	var vboss: Node2D = wm_v.boss
	if vboss == null:
		_fail("标准模式第 %d 波未生成 BOSS" % Config.BOSS_WAVE)
		return
	# ⚠️ 记下 BOSS id：下面的「血量随波次增长」断言必须拿**同一只 BOSS** 比。
	#    六只 BOSS 的基础血量差 560k~900k（`boss_summoner` vs `boss_titan`），
	#    若硬编码 `setup("boss", 30)` 而这一波的 BOSS 恰好是玄武岩王，
	#    「w30 < w20」就会以「实现错了」的面目报红 —— 实际是断言选错了比较对象。
	var vboss_id := String(vboss.type)
	var vboss_hp: float = vboss.max_hp
	if vboss_hp < 2400.0:
		_fail("BOSS 血量未强化（max_hp=%.0f）" % vboss_hp)
		return
	vboss.hp = 1.0   # 巨额抗性（dmg_cap_pct）下单发无法秒杀：压到 1 血再打致命一击
	vboss.take_damage(1.0e9, false)
	# 焚天凤凰会涅槃复活一次：一击后若仍未进结算（phase 仍 INTRO），补一刀
	if GameState.phase != GameState.Phase.VICTORY and is_instance_valid(vboss):
		vboss.hp = 1.0
		vboss.take_damage(1.0e9, false)
	await get_tree().process_frame
	if GameState.phase != GameState.Phase.VICTORY or not _main._victory_menu.visible:
		_fail("击破 BOSS 未进入通关结算（phase=%d）" % GameState.phase)
		return
	await get_tree().create_timer(0.8).timeout   # 胜利曲 0.6s 淡入淡出
	if Music.current_track() != "victory":
		_fail("通关未切换胜利 BGM（%s）" % Music.current_track())
		return
	_main._continue_endless()
	await get_tree().process_frame
	if not GameState.endless or wm_v.wave != Config.BOSS_WAVE + 1 or GameState.phase != GameState.Phase.INTRO:
		_fail("通关后继续无尽失败（endless=%s wave=%d 期望 %d phase=%d）"
			% [str(GameState.endless), wm_v.wave, Config.BOSS_WAVE + 1, GameState.phase])
		return
	# ---- 纯函数断言 ----
	# 标准模式：BOSS 只在最后一波（改动前写死 10，20 波制下必然误红）
	GameState.endless = false
	if not Config.is_boss_wave(Config.BOSS_WAVE) \
			or Config.is_boss_wave(Config.BOSS_WAVE - 1) \
			or Config.is_boss_wave(Config.BOSS_WAVE - 10):
		_fail("is_boss_wave 标准模式判定错误（第 %d 波必须是 BOSS，且 19 / 10 都不是）"
			% Config.BOSS_WAVE)
		return
	# 无尽模式：每 10 波一轮
	GameState.endless = true
	if not Config.is_boss_wave(30) or Config.is_boss_wave(29) or Config.is_boss_wave(31):
		_fail("is_boss_wave 无尽模式判定错误")
		return
	if Config.kill_score(Registry.enemies.grunt) <= 0 \
			or Config.boss_kill_score(Config.BOSS_WAVE) <= 0 or Config.wave_clear_score(5) <= 0:
		_fail("积分公式错误")
		return
	# 无尽 BOSS 血量必须随波次继续增长（**同一只 BOSS**：W30 > 标准局末波 W20 基准）
	var boss_deep: Node2D = preload("res://scenes/enemies/enemy.tscn").instantiate()
	boss_deep.setup(vboss_id, 30)
	var boss_deep_hp: float = boss_deep.max_hp
	boss_deep.free()
	if boss_deep_hp <= vboss_hp:
		_fail("无尽 BOSS 血量未随波次增长（w30=%.0f <= w%d=%.0f）"
			% [boss_deep_hp, Config.BOSS_WAVE, vboss_hp])
		return
	# ---- 排行榜：记录 / 排序 / 名次 ----
	if Leaderboard.record(100, 5, "测试A", 10, 60.0) != 1:
		_fail("排行榜首次记录应第 1 名")
		return
	Leaderboard.record(300, 8, "测试B", 30, 90.0)
	if int(Leaderboard.get_list()[0].score) != 300 or Leaderboard.get_list().size() != 2:
		_fail("排行榜排序错误")
		return
	if Leaderboard.record(0, 9, "无效", 1, 1.0) != 0:
		_fail("零分不应入榜")
		return
	# ---- 无尽流程：第 30 波 BOSS（无尽每 10 波一轮）----
	GameState.score = 0
	var wm: Node = _main.get_node("WaveManager")
	wm.start_wave(30)
	var boss: Node2D = wm.boss
	if boss == null:
		_fail("无尽第 30 波未生成 BOSS")
		return
	var p3: Node2D = _main.get_node("Player")
	# 普通击杀计分
	var grunt: Node2D = preload("res://scenes/enemies/enemy.tscn").instantiate()
	grunt.setup("grunt", 10)
	grunt.position = p3.global_position + Vector2(500, 0)
	_main.add_child(grunt)
	grunt.player = p3
	grunt.take_damage(1.0e9, false)
	if GameState.score <= 0:
		_fail("无尽模式击杀未计积分")
		return
	# BOSS 击破 → 商店衔接 + wave31 存档
	boss.hp = 1.0   # 巨额抗性下单发无法秒杀：压到 1 血再打
	boss.take_damage(1.0e9, false)
	# 焚天凤凰会涅槃复活一次：一击后若仍未进商店（phase 仍 INTRO 且 boss 仍存活），补一刀
	if GameState.phase != GameState.Phase.SHOP and is_instance_valid(boss):
		boss.hp = 1.0
		boss.take_damage(1.0e9, false)
	await get_tree().process_frame
	if GameState.phase != GameState.Phase.SHOP or wm.boss != null:
		_fail("无尽 BOSS 击破未衔接商店（phase=%d）" % GameState.phase)
		return
	if not SaveRun.exists(GameState.slot_id):
		_fail("无尽 wave31 存档失败")
		return
	# 存档往返：endless 标志与积分一致
	var score_saved: int = GameState.score
	if SaveRun.restore(p3) != 31:
		_fail("无尽存档波次往返失败（期望 31）")
		return
	if not GameState.endless or GameState.score != score_saved:
		_fail("无尽标志/积分未随存档恢复（endless=%s score=%d/%d）"
			% [str(GameState.endless), GameState.score, score_saved])
		return
	# ---- 240 敌群性能压测（120 物理帧）----
	# 排空波末回收积压的升级（补弹机制），保证压测期间敌群不被升级 UI 冻结
	GameState.set_phase(GameState.Phase.PLAYING)
	var lu: Control = _main.get_node("UI/LevelUp")
	while GameState.level_queue > 0 or lu.visible:
		if lu.visible:
			lu._choose(0)
		else:
			GameState.level_queue = 0
		await get_tree().process_frame
	p3.iframes = 1.0e9   # 免伤，防止压测期间死亡
	var saved_weapons: Array = p3.weapons.duplicate(true)
	p3.weapons = []      # 关闭自动攻击，聚焦敌群模拟开销
	var perf_enemies: Array = []
	var pp: Vector2 = p3.global_position
	for _i in 240:
		var e2: Node2D = preload("res://scenes/enemies/enemy.tscn").instantiate()
		e2.setup("grunt", 20)
		e2.position = pp + Vector2.from_angle(GameRng.next() * TAU) * GameRng.range_f(60.0, 620.0)
		_main.add_child(e2)
		e2.player = p3
		perf_enemies.append(e2)
	# 连测两轮取最小值：抑制偶发的调度尖峰。
	# 注意本用例测的是**墙钟时间**，机器整体负载（例如同时跑着游戏本体、或编译/打包进程）
	# 会把它整体抬高——那种情况应关掉后台负载再复测，而不是当成本项目的性能回归。
	# 本会话真实踩过：同一份代码在关掉负载时 1976ms、开着游戏时 3651ms。
	var elapsed := 1 << 30
	for _round in 2:
		var t0 := Time.get_ticks_msec()
		for _f in 120:
			await get_tree().physics_frame
		elapsed = mini(elapsed, Time.get_ticks_msec() - t0)
	print("SMOKE: perf 240 enemies x 120 ticks = %d ms (%.2f ms/tick, best of 2)"
		% [elapsed, elapsed / 120.0])
	for e3 in perf_enemies:
		e3.queue_free()
	await get_tree().physics_frame
	p3.weapons = saved_weapons
	p3.iframes = 0.45
	# 120 帧理想 2000ms；放宽到 3400ms（≈28ms/帧）防灾难性回归。
	# 若这里失败，先确认机器上没有别的重负载在跑，再判断是不是真回归
	if elapsed > 3400:
		_fail("240 敌群物理帧耗时异常（%d ms / 120 ticks）" % elapsed)
		return
	# ---- 死亡 → 排行榜记录 ----
	GameState.set_phase(GameState.Phase.PLAYING)
	var score_at_death: int = GameState.score
	EventBus.player_died.emit()
	await get_tree().process_frame
	await get_tree().create_timer(0.8).timeout   # 失败曲 0.6s 淡入淡出
	if Music.current_track() != "defeat":
		_fail("死亡未切换失败 BGM（%s）" % Music.current_track())
		return
	var lb := Leaderboard.get_list()
	if lb.is_empty() or int(lb[0].score) != score_at_death:
		_fail("无尽死亡未记录排行榜（top=%s）"
			% str((lb[0] as Dictionary).get("score", -1) if not lb.is_empty() else "空"))
		return
	if Leaderboard.record(9999, 2, "测试C", 1, 1.0) != 1 or Leaderboard.get_list().size() != 4:
		_fail("排行榜插入排序错误")
		return
	GameState.endless = false
	print("SMOKE: endless mode + leaderboard + perf OK")

## 逐波平衡日志（2026-09-17 第 8 轮需求 4）：结构 / 增量 / 波次隔离 / 射程口径。
##
## 断言口径：
##   · 期望值**从被测数据算**（Config.WEAPONS 的 evolve_branches、Registry 里的武器表），不写死 id；
##   · 每条 A→B 的断言都先造出「不满足」的反向情形（未开局不落盘 / 波次之间必须清零），
##     否则「池子空了」也能判绿；
##   · 用完把 stats 还原（租进来的变量必须还回去，否则污染后续用例）。
func _check_balance_log() -> void:
	if _failed:
		return
	var p: Node2D = _main.get_node("Player")
	BalanceLog.set_storage_root_for_tests(TEST_SAVE_ROOT)
	var log_path := BalanceLog.path()
	if FileAccess.file_exists(log_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(log_path))
	# ---- ① 反向对照：未开局（菜单 / 图鉴里跑到的战斗代码）一个字节都不该写 ----
	BalanceLog.close_run()
	BalanceLog.begin_wave(2)
	BalanceLog.add_damage_dealt(999.0, "knife")
	BalanceLog.add_damage_taken(999.0)
	if BalanceLog.commit(2, p, "shop"):
		_fail("BalanceLog: 未 begin_run 就落盘了")
		return
	if FileAccess.file_exists(log_path):
		_fail("BalanceLog: 未开局不应产生日志文件")
		return
	# ---- ② 开局 + 本波累计：总量 / 按来源拆分 / 出怪数 / 事件波 ----
	BalanceLog.begin_run()
	BalanceLog.begin_wave(2)
	BalanceLog.add_damage_dealt(120.0, "knife")
	BalanceLog.add_damage_dealt(80.0, "knife")
	BalanceLog.add_damage_dealt(50.0, "thunder_gong")
	BalanceLog.add_damage_dealt(30.0, "")        # 无来源 → 归 "other"
	BalanceLog.add_damage_taken(40.0)
	BalanceLog.add_heal(7.0)
	BalanceLog.note_hp(p.hp)
	BalanceLog.note_spawn(5)
	BalanceLog.note_event("meteor")
	if not BalanceLog.commit(2, p, "shop"):
		_fail("BalanceLog: 开局后应能落盘")
		return
	if not FileAccess.file_exists(log_path):
		_fail("BalanceLog: 落盘后文件不存在（%s）" % log_path)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.open(log_path, FileAccess.READ).get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail("BalanceLog: 日志不是合法 JSON")
		return
	var d: Dictionary = parsed
	var latest: Dictionary = d.get("latest", {})
	var wd: Dictionary = latest.get("wave_data", {})
	if int(latest.get("wave", 0)) != 2 or String(latest.get("outcome", "")) != "shop":
		_fail("BalanceLog: latest 的波次/outcome 不对（%s）" % str(latest))
		return
	if not is_equal_approx(float(wd.get("damage_dealt", 0.0)), 280.0):
		_fail("BalanceLog: 本波总伤害应为 120+80+50+30=280，实际 %s" % str(wd.get("damage_dealt")))
	var bysrc: Dictionary = wd.get("by_source", {})
	if not is_equal_approx(float(bysrc.get("knife", 0.0)), 200.0) \
			or not is_equal_approx(float(bysrc.get("thunder_gong", 0.0)), 50.0) \
			or not is_equal_approx(float(bysrc.get("other", 0.0)), 30.0):
		_fail("BalanceLog: 伤害来源拆分错误 %s" % str(bysrc))
	if int(wd.get("spawned", -1)) != 5 or String(wd.get("event", "")) != "meteor" \
			or not is_equal_approx(float(wd.get("damage_taken", 0.0)), 40.0) \
			or not is_equal_approx(float(wd.get("heal", 0.0)), 7.0):
		_fail("BalanceLog: 出怪数 / 事件波 / 受击 / 回复未记录 %s" % str(wd))
	# ---- ③ 玩家快照：全量属性 + 武器清单（含实战冷却，取 try_fire 的同一算法）----
	var snap: Dictionary = latest.get("player", {})
	var stats_snap: Dictionary = snap.get("stats", {})
	if not stats_snap.has("dmg_mult") or not stats_snap.has("as_mult"):
		_fail("BalanceLog: 玩家快照缺少全量 stats")
		return
	var wl: Array = snap.get("weapons", [])
	if wl.is_empty() or not (wl[0] as Dictionary).has("reach"):
		_fail("BalanceLog: 玩家快照缺少武器清单 / 射程")
		return
	for we in wl:
		var we_d: Dictionary = we
		if not is_equal_approx(float(we_d.get("cd_effective", -1.0)),
				float(we_d.get("cd", 0.0)) / maxf(0.01, float(p.stats.as_mult))):
			_fail("BalanceLog: 实战冷却未按 面板cd÷攻速 折算（%s）" % str(we_d))
			break
	# ---- ④ 射程口径：与开火同源，且**投掷物不吃弹速/射程类加成**（第 8 轮修复点）----
	#
	# ⚠️⚠️ 先把身份相关加成**全部摘掉再算期望**：本用例跑在几十条用例之后，玩家身上留着
	#    前面用例施加的加成（实测残留 melee_range_bonus 0.18 / aoe_radius_bonus 0.20）。
	#    直接拿裸公式当期望 → 期望 495 实测 514，红了还像是「实现错了」，其实是断言
	#    把别人的变量当成了自己的初值。用完必须原样还回去（租的变量要还）。
	var gcfg: Dictionary = Registry.weapons.get("thunder_gong", {})
	if gcfg.is_empty():
		_fail("BalanceLog: Registry 缺少 thunder_gong")
		return
	var keep_bullet: float = float(p.stats.get("bullet_range_bonus", 0.0))
	var keep_throw: float = float(p.stats.get("throw_range_bonus", 0.0))
	var keep_melee: float = float(p.stats.get("melee_range_bonus", 0.0))
	var keep_aoe: float = float(p.stats.get("aoe_radius_bonus", 0.0))
	p.stats.bullet_range_bonus = 0.0
	p.stats.throw_range_bonus = 0.0
	p.stats.melee_range_bonus = 0.0
	p.stats.aoe_radius_bonus = 0.0
	var r_expect: float = float(gcfg.bspeed) * float(gcfg.bullet_life) + 26.0 + float(gcfg.splash)
	var r_base: float = p.weapon_reach(gcfg)
	if not is_equal_approx(r_base, r_expect):
		_fail("BalanceLog: 投掷物射程应为 弹速×存活+26+splash=%.1f，实际 %.1f" % [r_expect, r_base])
	p.stats.bullet_range_bonus = 0.5
	if not is_equal_approx(p.weapon_reach(gcfg), r_expect):
		_fail("BalanceLog: 投掷物不该吃「弹道射程」类加成（第 8 轮修复点）")
	p.stats.bullet_range_bonus = 0.0
	p.stats.throw_range_bonus = 0.5
	if not is_equal_approx(p.weapon_reach(gcfg),
			float(gcfg.bspeed) * float(gcfg.bullet_life) * 1.5 + 26.0 + float(gcfg.splash)):
		_fail("BalanceLog: 投掷物应吃「投掷距离」类加成（存活时长 ×1.5）")
	p.stats.throw_range_bonus = 0.0
	# 爆炸半径加成改的是 splash（「爆多大」），与「飞多远」正交 → 两类武器都吃。
	# ⚠️ #9：`aoe_radius_bonus` 按**面积**定义 → 半径走 sqrt(1+0.5)，不是 ×1.5。
	p.stats.aoe_radius_bonus = 0.5
	var splash_boosted: float = float(gcfg.splash) * Config.radius_scale(0.5)
	if not is_equal_approx(p.weapon_reach(gcfg),
			r_expect - float(gcfg.splash) + splash_boosted):
		_fail("BalanceLog: 投掷物应吃「爆炸半径」类加成（加在 splash 上、按面积换算）")
	p.stats.aoe_radius_bonus = 0.0
	# 近战：射程 = range（不含枪口 26，也不含 splash）
	var mcfg: Dictionary = Registry.weapons.get("knife", {})
	var m_base: float = p.weapon_reach(mcfg)
	if not is_equal_approx(m_base, float(mcfg.range)):
		_fail("BalanceLog: 近战射程应等于 range（%.1f vs %.1f）" % [m_base, float(mcfg.range)])
	p.stats.melee_range_bonus = 0.5
	# ⚠️ #9：近战 reach 同样按**面积**定义 → ×sqrt(1.5)，不是 ×1.5
	if not is_equal_approx(p.weapon_reach(mcfg),
			float(mcfg.range) * Config.radius_scale(0.5)):
		_fail("BalanceLog: 近战射程未吃「近战范围」加成（按面积换算）")
	p.stats.melee_range_bonus = 0.0
	# 原样还回去
	p.stats.bullet_range_bonus = keep_bullet
	p.stats.throw_range_bonus = keep_throw
	p.stats.melee_range_bonus = keep_melee
	p.stats.aoe_radius_bonus = keep_aoe
	# ---- ⑤ 进化体识别：期望集**从被测数据算**，并配反向对照 ----
	var evolved_ids: Array = []
	for base_id in Config.WEAPONS:
		for br in Config.WEAPONS[base_id].get("evolve_branches", []):
			evolved_ids.append(String(br))
	if evolved_ids.is_empty():
		_fail("BalanceLog: Config.WEAPONS 里一条 evolve_branches 都没有，本断言已失去意义")
		return
	for eid in evolved_ids:
		if not p._is_evolved_form(eid):
			_fail("BalanceLog: 进化体 %s 未被识别" % eid)
			break
	for wid in Config.WEAPONS:
		if String(wid) in evolved_ids:
			continue
		if p._is_evolved_form(String(wid)):
			_fail("BalanceLog: 基础武器 %s 被误判为进化体" % wid)
			break
	# ---- ⑥ 波次隔离：第二笔 commit 必须追加历史，且本波计数归零 ----
	BalanceLog.begin_wave(3)
	if not BalanceLog.commit(3, p, "shop"):
		_fail("BalanceLog: 第二波落盘失败")
		return
	var parsed2: Variant = JSON.parse_string(FileAccess.open(log_path, FileAccess.READ).get_as_text())
	if typeof(parsed2) != TYPE_DICTIONARY:
		_fail("BalanceLog: 第二波后日志不是合法 JSON")
		return
	var d2: Dictionary = parsed2
	var waves: Array = d2.get("waves", [])
	if waves.size() != 2:
		_fail("BalanceLog: 逐波历史应为 2 条（追加而非覆盖），实际 %d" % waves.size())
		return
	if int((waves[0] as Dictionary).get("wave", 0)) != 2 \
			or int((waves[1] as Dictionary).get("wave", 0)) != 3:
		_fail("BalanceLog: 逐波历史顺序/波号错误 %s" % str(waves))
	var wd2: Dictionary = (d2.get("latest", {}) as Dictionary).get("wave_data", {})
	if float(wd2.get("damage_dealt", -1.0)) != 0.0 or int(wd2.get("spawned", -1)) != 0:
		_fail("BalanceLog: 波次之间未清零累计（第 2 波的数字滚进了第 3 波）%s" % str(wd2))
	# ---- ⑦ 正式根形态：`_root` 必须恒以 "/" 结尾 ----
	# ⚠️⚠️ 这一条是**真机 P0 的回归闸门**（2026-09-18 第 11 轮）。正式包里 `_root == "user://"`，
	#    而 `_write` 曾经对它做 `trim_suffix("/")` → `"user:/"`（**单斜杠**）→ `globalize_path`
	#    认不出这个 scheme、**原样返回** → `make_dir_recursive_absolute("user:/")` 去建一个名为
	#    `user:` 的目录 → 必失败 → `_write` 直接 return → `balance_log.json` **从未落盘过**。
	#    当时冒烟全绿，正是因为测试根被设成了**无尾斜杠**，`trim_suffix` 恰好是空操作。
	#    ⇒ 修法：`_root` 归一化成恒以 "/" 结尾（测试根与正式根**同形**），`_write` 直接用 `abs_dir()`。
	if not BalanceLog.storage_root().ends_with("/"):
		_fail("BalanceLog: _root 未归一化成以 / 结尾（%s）—— 正是真机不落盘的那个坑"
			% BalanceLog.storage_root())
	# 反向对照：先证明「单斜杠形态」确实解析不了，否则上面那条断言只是走过场
	if ProjectSettings.globalize_path("user:/") != "user:/":
		_fail("BalanceLog: globalize_path 竟然能解析 \"user:/\"，本断言的依据已失效")
	if ProjectSettings.globalize_path("user://").begins_with("user:"):
		_fail("BalanceLog: globalize_path(\"user://\") 未解析成绝对路径")
	# 正向：写盘目录必须真的存在（`_write` 每次都会先建它）
	if not DirAccess.dir_exists_absolute(BalanceLog.abs_dir()):
		_fail("BalanceLog: abs_dir() 指向的目录不存在：%s" % BalanceLog.abs_dir())
	# ⚠️ 刻意**不**还原存储根：本用例之后还有别的用例会跑到 BOSS 波 / 收波
	#    （`_on_boss_killed` → victory 落盘），根一旦还原，那些落盘就会写进开发者**真实的**
	#    user://balance_log.json。与 SaveRun 一样全程留在测试目录，进程结束自然消失。
	BalanceLog.close_run()
	if _failed:
		return   # 上面任何一条红了就别再打「OK」——否则日志里 FAIL 与 OK 同时出现，读起来自相矛盾
	print("SMOKE: balance_log OK (waves=%d)" % waves.size())

func _cleanup_test_storage(reset_root: bool) -> void:
	var previous_slot := GameState.slot_id
	# 唯一档：必须在 reset_storage_root_after_tests 之前清 —— 根一旦还原，
	# clear() 指向的就是真实 user://save_run.json（会删掉开发者自己的档）
	GameState.slot_id = 1
	SaveRun.clear()
	GameState.slot_id = previous_slot if previous_slot >= 1 else 1
	# 整个测试存档根目录连文件一起清：唯一档、旧三槽 `save_slot_N.json`（合并用例会造）、
	# .tmp/.bak 中间文件都算。只删目录的话非空时静默失败，残留会跨运行污染迁移断言
	var root_abs := ProjectSettings.globalize_path(TEST_SAVE_ROOT)
	if DirAccess.dir_exists_absolute(root_abs):
		for fn in DirAccess.get_files_at(root_abs):
			DirAccess.remove_absolute(root_abs.path_join(String(fn)))
	DirAccess.remove_absolute(root_abs)
	# 法宝存档用例的独立存储根（验证点 8 换根跑，残留目录会污染下次运行的落盘断言）
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE_ROOT + "_artifact"))
	# 排行榜测试隔离目录清理（_fail 路径也会走到这里，防跨运行残留污染）
	var lb_file := "user://tests/lb/leaderboard.json"
	if FileAccess.file_exists(lb_file):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(lb_file))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://tests/lb"))
	Leaderboard.reset_storage_root_after_tests()
	# 天赋档：全程指向隔离路径，本机 user://meta_progress.json 不受影响
	if FileAccess.file_exists(TEST_META_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_META_PATH))
	MetaProgress.reset_storage_path_after_tests()
	# 图鉴测试隔离档：CodexData 全程指向测试路径，删除即可（不动本机 user://codex.json）
	if FileAccess.file_exists(TEST_CODEX_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_CODEX_PATH))
	CodexData.reset_for_tests()   # 清除脏标记，避免退出时重建测试档
	# 平台成就离线队列：测试全程指向隔离路径，删除测试档并还原真实路径
	if FileAccess.file_exists(TEST_STEAM_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_STEAM_PATH))
	PlatformAchievements.reset_for_tests()
	PlatformAchievements.reset_storage_path_after_tests()
	if reset_root:
		SaveRun.reset_storage_root_after_tests()

## 平台桥测试观测：calls 中是否记录了转发到指定 Steamworks API 的调用
func _forwarded_call(calls: Array, api: String) -> bool:
	for c in calls:
		if c is Array and c.size() >= 2 \
				and String(c[0]) == "setAchievement" and String(c[1]) == api:
			return true
	return false

func _store_stats_call(calls: Array) -> bool:
	for c in calls:
		if c is Array and not c.is_empty() and String(c[0]) == "storeStats":
			return true
	return false

## 递归拼接节点树中的 Label 文本（图鉴详情断言用）
func _node_text(node: Node) -> String:
	var out := ""
	if node is Label:
		out += String(node.text) + "\n"
	for c in node.get_children():
		out += _node_text(c)
	return out

## 抑制江湖奇遇触发：奇遇以 30% 概率把「商店 → 下一波」推迟到三选一之后，
## 会让波次流向断言变成抽奖（70% 通过）。这里受控地把本局次数顶满来关闭触发，
## 奇遇自身的行为在 _check_event_cards() 中用受控方式单独验证。
func _suppress_event_cards() -> void:
	_event_suppress_count = GameState.event_card_count
	_event_suppress_cap = GameState.event_card_cap
	GameState.event_card_count = GameState.event_card_cap

func _restore_event_cards() -> void:
	GameState.event_card_count = _event_suppress_count
	GameState.event_card_cap = _event_suppress_cap

## 选中第一个可负担的奇遇选项（代价类选项资源不足时是禁用态，直接 _choose(0) 会空转）
func _pick_enabled_event_choice() -> bool:
	for i in _main.event_card_ui.choice_count():
		if _main.event_card_ui.is_choice_enabled(i):
			_main.event_card_ui._choose(i)
			return true
	return false

func _fail(reason: String) -> void:
	if _failed:
		return   # 已失败：只保留首个原因，退出码不被后续 quit(0) 覆盖
	_failed = true
	print("SMOKE: FAIL - " + reason)
	_cleanup_test_storage(true)
	get_tree().quit(1)
