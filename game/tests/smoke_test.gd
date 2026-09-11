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
	if not PlatformAchievements.steam_config_valid() \
			or PlatformAchievements.steam_definitions().size() != 12:
		_fail("Steamworks 12 项成就配置未完整对齐")
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
				< CodexData.achievement_reward("endless_20") \
			or not CodexData.achievement_reward("boss_hunter") \
				< CodexData.achievement_reward("boss_10"):
		_fail("成就奖励未保持阶梯递进")
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
	# BGM 分波次：1-4 基础 / 5-7 中盘 / 8+ 终盘 / BOSS 波专属
	if Music.track_for_wave(1) != "battle" or Music.track_for_wave(5) != "battle_mid" \
			or Music.track_for_wave(8) != "battle_late" or Music.track_for_wave(10) != "boss":
		_fail("BGM 分波次映射错误")
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
	get_tree().create_timer(8.0).timeout.connect(_check_weapons)   # 首杀窗口放宽，避免 RNG 抖动误报

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
	# 波末掉落自动回收：进商店后场上不应再有掉落物
	if not get_tree().get_nodes_in_group("loot").is_empty():
		_fail("波末掉落未自动回收（剩余 %d）"
			% get_tree().get_nodes_in_group("loot").size())
		return
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
	# 波末自动回收可能积压升级：直接进入 PLAYING 触发补弹并清空（模拟玩家选卡），
	# 避免 INTRO 自然结束后升级 UI 弹出冻结 BOSS 测试窗口
	GameState.set_phase(GameState.Phase.PLAYING)
	var lu_drain: Control = _main.get_node("UI/LevelUp")
	while lu_drain.visible or GameState.level_queue > 0:
		if lu_drain.visible:
			lu_drain._choose(0)
		else:
			GameState.level_queue = 0
		await get_tree().process_frame
	var loot_left := get_tree().get_nodes_in_group("loot").size()
	print("SMOKE: loot_left=%d (auto-collected at wave end)" % loot_left)
	if loot_left != 0:
		_fail("波末回收后仍残留掉落（%d）" % loot_left)
		return
	# 数值调整断言：波时 45+5/波、初始移速 742（495+50%）
	if Config.wave_duration(1) != 45.0 or Config.wave_duration(2) != 50.0 \
			or not is_equal_approx(Config.PLAYER.base_speed, 742.0):
		_fail("数值调整未生效（波时/移速）")
		return
	# Registry 注册表 + 示例 mod 加载断言
	if Registry.weapons.size() < 8 or not Registry.weapons.has("laser"):
		_fail("Registry 未加载示例 mod 武器 laser")
		return
	if Registry.items.size() < 19 or Registry.difficulties.size() < 3 \
			or Registry.characters.size() < 7:
		_fail("Registry 内置内容缺失（items=%d difficulties=%d characters=%d）"
			% [Registry.items.size(), Registry.difficulties.size(), Registry.characters.size()])
		return
	# 新品阶/新内容回归：金色+红色道具与升级、新武器、新角色、新怪物、难度精英
	if not Config.RARITIES.has("mythic") or not Config.RARITIES.has("legendary"):
		_fail("稀有度枚举缺少 mythic/legendary")
		return
	if Config.rarity_weight("legendary", 1) != 0.0 \
			or Config.rarity_weight("legendary", 9) <= 0.0:
		_fail("稀有度权重曲线错误（legendary 应 LV1=0、LV9 起解锁）")
		return
	if not Registry.items.has("i-crown") or not Registry.upgrades.has("berserk") \
			or not Registry.weapons.has("sniper") or not Registry.weapons.has("blade"):
		_fail("高品阶道具/升级/新武器未注册")
		return
	for cid in ["berserker", "ranger", "gambler", "farmer", "vampire", "guardian"]:
		if not Registry.characters.has(cid):
			_fail("新角色缺失：%s" % cid)
			return
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
	# ---- 单次跨两级：第一次选择后必须立即重抽三张，第二次选择后恢复战斗 ----
	var need_two := Config.xp_need(GameState.level) + Config.xp_need(GameState.level + 1)
	GameState.gain_xp(need_two + 1)
	await get_tree().process_frame
	if GameState.phase != GameState.Phase.LEVEL_UP or GameState.level_queue != 2 or ui.card_count() != 3:
		_fail("单次跨两级未生成首组卡（phase=%d queue=%d cards=%d）" %
			[GameState.phase, GameState.level_queue, ui.card_count()])
		return
	ui._choose(0)
	await get_tree().process_frame
	if GameState.phase != GameState.Phase.LEVEL_UP or GameState.level_queue != 1 or ui.card_count() != 3:
		_fail("连升第二组未重新抽卡（phase=%d queue=%d cards=%d）" %
			[GameState.phase, GameState.level_queue, ui.card_count()])
		return
	var focus2: Control = ui.get_viewport().gui_get_focus_owner()
	if focus2 == null or focus2.get_parent() != ui.get_node("Center/Box/Cards"):
		_fail("连升第二组卡未获得焦点")
		return
	ui._choose(0)
	if GameState.phase != GameState.Phase.PLAYING or GameState.level_queue != 0:
		_fail("连升完成后未恢复 PLAYING")
		return
	# ---- 商店流程验证：压缩第 2 波 → 清场 → 自动进商店 → 购买/刷新/回血/下一波 ----
	var wm: Node = _main.get_node("WaveManager")
	wm.wave_timer = 0.5
	get_tree().create_timer(3.0).timeout.connect(_check_shop)

func _check_shop() -> void:
	var shop: Control = _main.get_node("UI/Shop")
	var player: Node2D = _main.get_node("Player")
	print("SMOKE: shop phase=%d goods=%d mats=%d" %
		[GameState.phase, shop.goods_count(), GameState.materials])
	if GameState.phase != GameState.Phase.SHOP or shop.goods_count() != 4:
		_fail("商店未打开或商品数不对（phase=%d goods=%d）"
			% [GameState.phase, shop.goods_count()])
		return
	if shop.get_viewport().gui_get_focus_owner() == null:
		_fail("商店焦点丢失（手柄导航不可用）")
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
	if shop.get_reroll_cost() <= cost0 or shop.goods_count() != 4:
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
	var wcfg: Dictionary = Registry.weapons["flamethrower"]
	var w_roll: Dictionary = p2._roll_damage(10.0, wcfg)
	if String(w_roll.status) != "burn" or float(w_roll.status_chance) < 0.85:
		_fail("武器状态载荷未打包（status=%s chance=%.2f）"
			% [String(w_roll.status), float(w_roll.status_chance)])
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
	await _check_map_themes()   # 内含 physics_frame 等待（索敌视线需要索引重建）
	await _check_character_traits()
	await _check_weapon_fx()
	_check_affinity()
	_check_sigils()
	_check_affinity_floor()
	_check_object_pool()
	_check_boss_death_skills()
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
	# ---- 三槽存档验证：自动档入槽1 → 槽间隔离 → 篡改恢复一致 → 清档 + 损档容错 ----
	for i: int in [2, 3]:   # 清其他槽残留，不动槽 1 的自动存档
		GameState.slot_id = i
		SaveRun.clear()
	GameState.slot_id = 1
	if not SaveRun.exists(1):
		_fail("商店阶段未自动生成存档（槽 1）")
		return
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
	# 空槽隔离：槽 2 无档，restore 必须返回 0 且不动现场
	GameState.slot_id = 2
	GameState.materials = 555
	if SaveRun.restore(p2) != 0:
		_fail("空槽 2 不应恢复出进度")
		return
	if GameState.materials != 555:
		_fail("空槽 restore 不应改动现场")
		return
	# 篡改现场后从槽 1 恢复
	GameState.materials = 7
	GameState.level = 1
	GameState.xp = 5
	p2.hp = 1.0
	p2.weapons = []
	p2.items_owned = {}
	GameState.slot_id = 1
	var nw: int = SaveRun.restore(p2)
	print("SMOKE: save slot1 wave=%d mats=%d lv=%d xp=%d hp=%.0f weapons=%d items=%d" %
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
		_fail("槽 1 清档失败")
		return
	# 槽 2 独立读写
	GameState.slot_id = 2
	if not SaveRun.save(8, p2):
		_fail("槽 2 合法存档写入失败")
		return
	if not SaveRun.exists(2):
		_fail("槽 2 保存失败")
		return
	if SaveRun.exists(1):
		_fail("槽间隔离失败：槽 1 不应有档")
		return
	SaveRun.clear()
	# 损档容错：垃圾内容应判定无效
	GameState.slot_id = 3
	var fj := FileAccess.open(SaveRun.slot_path(3), FileAccess.WRITE)
	fj.store_string("corrupted{{{")
	fj.close()
	if SaveRun.restore(p2) != 0:
		_fail("损坏存档未被判定为无效")
		return
	SaveRun.clear()
	var malformed := FileAccess.open(SaveRun.slot_path(3), FileAccess.WRITE)
	malformed.store_string(JSON.stringify({"version": 2, "rng_a": 1,
		"run": {"wave": 3, "materials": 0, "kills": 0, "run_time": 0,
			"level": 1, "xp": 0, "level_queue": 0},
		"player": {"hp": 10, "stats": {}, "weapons": [], "items_owned": {}}}))
	malformed.close()
	if SaveRun.restore(p2) != 0:
		_fail("结构完整但深层字段非法的存档未被拒绝")
		return
	SaveRun.clear()
	GameState.slot_id = 1
	if SaveRun.save(Config.WAVES_TOTAL + 1, p2) or SaveRun.slot_path(0) != "":
		_fail("非法波次/槽位未被拒绝")
		return
	# ---- 武器进化：多分支（手枪 → 冲锋枪/散弹枪/双管神射，优先未持有分支）----
	var p4: Node2D = _main.get_node("Player")
	var saved_weapons4: Array = p4.weapons.duplicate(true)
	p4.weapons = []
	for _i2 in 4:
		p4.weapons.append({ "type": "pistol", "cd": 0.1 })
	p4.weapons.append({ "type": "rocket", "cd": 0.1 })   # 混入其他武器验证只合成同名
	var evolved: Array = p4.evolve_weapons()
	print("SMOKE: evolve results=%s weapons=%d" % [str(evolved), p4.weapons.size()])
	# 4 把手枪（need=3）→ 优先未持有分支 = 冲锋枪
	if evolved.size() != 1 or not String(evolved[0]).contains("冲锋枪"):
		_fail("武器进化结果错误（%s）" % str(evolved))
		return
	var pistol_cnt := 0
	var smg_cnt := 0
	for w in p4.weapons:
		if w.type == "pistol":
			pistol_cnt += 1
		if w.type == "smg":
			smg_cnt += 1
	if pistol_cnt != 1 or smg_cnt != 1 or p4.weapons.size() != 3:
		_fail("进化后武器列表错误（pistol=%d smg=%d total=%d）" % [pistol_cnt, smg_cnt, p4.weapons.size()])
		return
	# 多分支选择：3 把手枪 + 已持有冲锋枪 → 跳到下一个未持有分支 = 霰弹枪
	p4.weapons = []
	for _i3 in 3:
		p4.weapons.append({ "type": "pistol", "cd": 0.1 })
	p4.weapons.append({ "type": "smg", "cd": 0.1 })   # 已持有冲锋枪
	var evolved2: Array = p4.evolve_weapons()
	if evolved2.size() != 1 or not String(evolved2[0]).contains("霰弹枪"):
		_fail("多分支进化未跳到未持有分支（%s）" % str(evolved2))
		return
	# 进化预览：2 把手枪显示 2/3
	p4.weapons = [{ "type": "pistol", "cd": 0.1 }, { "type": "pistol", "cd": 0.1 }]
	var prog: Array = p4.evolve_progress()
	if prog.size() != 1 or int(prog[0].have) != 2 or int(prog[0].need) != 3:
		_fail("进化进度预览错误（%s）" % str(prog))
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
	if MetaProgress.weapon_slots() != 6:
		_fail("未购军火专家时武器槽应为 6")
		return
	# 精华不足拒绝：余额清零后尝试购买
	MetaProgress.essence = 0
	if MetaProgress.buy_talent("arsenal"):
		_fail("精华不足不应购入军火专家")
		return
	MetaProgress.essence = 1000
	if not MetaProgress.buy_talent("arsenal") or MetaProgress.weapon_slots() != 7:
		_fail("军火专家购买后武器槽应为 7")
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
	# 精确整数校验与 v1 无 checkpoint 旧单槽迁移。
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
	SaveRun.clear()
	legacy_data["run"]["wave"] = 4.5
	var fractional := FileAccess.open(SaveRun.slot_path(1), FileAccess.WRITE)
	fractional.store_string(JSON.stringify(legacy_data))
	fractional.close()
	if SaveRun.restore(p2) != 0:
		_fail("小数波次绕过了精确整数校验")
		return
	SaveRun.clear()
	legacy_data["version"] = 1
	legacy_data.erase("checkpoint")
	legacy_data["run"]["wave"] = 4
	var legacy_path := TEST_SAVE_ROOT.path_join("save_run.json")
	var legacy_file := FileAccess.open(legacy_path, FileAccess.WRITE)
	legacy_file.store_string(JSON.stringify(legacy_data))
	legacy_file.close()
	SaveRun.migrate_legacy_if_needed(true)
	if not SaveRun.exists(1) or FileAccess.file_exists(legacy_path) \
			or SaveRun.restore(p2) != 4 or SaveRun.restored_checkpoint != SaveRun.CHECKPOINT_SHOP:
		_fail("v1 旧单槽迁移或兼容检查点失败")
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
	menu._codex._on_search_changed("手枪")
	if menu._codex._list_btns.size() != 1 \
			or String(menu._codex._list_btns[0].get_meta("id")) != "pistol":
		_fail("图鉴搜索未按名称过滤（%d 条）" % menu._codex._list_btns.size())
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
	for sid in Config.STATUS:
		CodexData.unlock("status", String(sid))
	CodexData.unlock("weapon", "pistol")
	CodexData.unlock("item", "i-ember")
	CodexData.unlock("enemy", "grunt")
	CodexData.unlock("enemy", "boss")
	menu._codex._select_tab("status")
	var burn_src: Dictionary = Registry.status_sources("burn")
	var burn_wids: Array = []
	for w in burn_src.get("weapons", []):
		burn_wids.append(String(w.get("id", "")))
	if not burn_wids.has("flamethrower") or not burn_wids.has("rocket"):
		_fail("图鉴燃烧武器来源缺失（%s）" % str(burn_wids))
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
	if not fz_wids.has("frost_staff") or fz_wids.has("flamethrower"):
		_fail("图鉴冰冻来源筛选错误（%s）" % str(fz_wids))
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
	menu._codex._select_entry("pistol")
	var wtext := _node_text(menu._codex._detail)
	if wtext.find("基础伤害") < 0 or wtext.find("进化") < 0:
		_fail("图鉴武器详情缺字段（%s）" % wtext.substr(0, 60))
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
	menu._open_slots("new")
	menu._do_new(1)
	await get_tree().process_frame
	if not menu._wizard.visible or menu._slots_panel.visible or not SaveRun.exists(1):
		_fail("新局选槽未进入向导，或提前清除了旧档")
		return
	# 角色选择卡：每张卡内含程序化专属头像（CharacterAvatar）
	var avatar_cnt := 0
	for card in menu._options.get_children():
		for box_child in card.get_child(0).get_children():
			if box_child is CharacterAvatar:
				avatar_cnt += 1
	if avatar_cnt < 7:
		_fail("角色卡专属头像缺失（%d/7）" % avatar_cnt)
		return
	var accept := InputEventAction.new()
	accept.action = "ui_accept"
	accept.pressed = true
	menu._unhandled_input(accept)
	if menu._step != 1:
		_fail("手柄确认已选中的默认向导卡未进入下一步")
		return
	menu.queue_free()
	print("SMOKE: save isolation + contracts + menu wizard OK")
	await _check_endless()
	if _failed:
		return   # 协程内已 _fail（quit(1) 已排队），不再覆盖退出码
	_cleanup_test_storage(true)
	print("SMOKE: PASS")
	get_tree().quit(0)

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
	# 双燃烧武器（火焰喷射器 + 火箭筒）：命中率取最大，来源计数 2
	p2.weapons = [{ "type": "flamethrower", "cd": 0.3 }, { "type": "rocket", "cd": 1.3 }]
	var flame_ch := clampf(float(Registry.weapons["flamethrower"].get("status_chance", 1.0)), 0.0, 1.0)
	hud._status_key = ""
	hud._refresh_status_legend()
	var src: Dictionary = p2.status_sources()
	if not src.has("burn") or int(src["burn"]["count"]) != 2:
		_fail("status_sources 未合并同状态武器（count=%d）"
			% int(src.get("burn", {}).get("count", 0)))
		return
	if not is_equal_approx(float(src["burn"]["chance"]), flame_ch):
		_fail("同状态武器应取最大命中率（%.2f ≠ %.2f）" % [float(src["burn"]["chance"]), flame_ch])
		return
	if not hud._status_panel.visible or hud._status_box.get_child_count() < 2:
		_fail("有状态来源时 HUD 图例未显示（children=%d）" % hud._status_box.get_child_count())
		return
	# 再叠余烬：概率按 1-(1-a)(1-b) 独立合并，来源计数 3
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
	p2.weapons = [{ "type": "venom_dagger", "cd": 0.4 }]
	p2.stats.status_spread = 1.0
	hud._status_key = ""
	hud._refresh_status_legend()
	if hud._bonus_label == null or String(hud._bonus_label.text).find("传染") < 0:
		_fail("中毒传染加成未显示")
		return
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
	e_r._tick_statuses(3.1)
	if not e_r.reaction_debuffs.is_empty() \
			or not is_equal_approx(e_r._damage_taken_mult(), 1.0):
		_fail("反应 debuff 未按时到期")
		return
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
## Phase 2 主题包内容验证（5 角色 + 8 武器 + 10 敌人 + 3 BOSS）
## 7 个验证点：Registry 完整性 / BOSS_POOL / 每日挑战 / 波次组合 / 精英池 / 五行覆盖 / stats 范围
## ============================================================
func _check_phase2_content() -> void:
	if _failed:
		return
	# ---- 验证点 1：Registry 完整性（12 角色 / 22 武器 / 23 敌人） ----
	var new_chars := ["pyromancer", "druid", "swordmaster", "tidecaller", "geomancer"]
	for cid in new_chars:
		if not Registry.characters.has(cid):
			_fail("Phase 2 角色未注册：%s" % cid)
			return
		var ch: Dictionary = Registry.characters[cid]
		# 角色不再绑定初始武器（开局武器完全由玩家在向导中选择），
		# 改为校验每个角色都带合法的专属特性
		var tr: Dictionary = ch.get("trait", {})
		if tr.is_empty() or String(tr.get("kind", "")) not in Registry.TRAIT_KINDS:
			_fail("角色 %s 缺少合法的专属特性" % cid)
			return
		if typeof(ch.get("stats", {})) != TYPE_DICTIONARY:
			_fail("角色 %s 的 stats 不是字典" % cid)
			return
	if Registry.characters.size() < 12:
		_fail("角色总数不足 12（%d）" % Registry.characters.size())
		return
	var new_weapons := ["thunder_gong", "tar_whip", "ember_fan", "vine_lash",
		"gold_bell", "frost_nova", "flame_jian", "chaos_hammer"]
	for wid in new_weapons:
		if not Registry.weapons.has(wid):
			_fail("Phase 2 武器未注册：%s" % wid)
			return
		var w: Dictionary = Registry.weapons[wid]
		if float(w.get("shop_weight", 0.0)) <= 0.0:
			_fail("武器 %s 的 shop_weight 必须 > 0" % wid)
			return
		if int(w.get("price", 0)) <= 0:
			_fail("武器 %s 的 price 必须 > 0" % wid)
			return
	if Registry.weapons.size() < 22:
		_fail("武器总数不足 22（%d）" % Registry.weapons.size())
		return
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
	# ---- 验证点 6：五行武器覆盖（每个五行 ≥ 2 把武器） ----
	var elem_coverage := {"fire": 0, "wood": 0, "metal": 0, "water": 0, "earth": 0}
	for wid2 in Registry.weapons:
		var st := String(Registry.weapons[wid2].get("status", ""))
		if st == "" or not Config.STATUS.has(st):
			continue
		var el := Config.get_element(st)
		if elem_coverage.has(el):
			elem_coverage[el] += 1
	for el2 in ["fire", "wood", "metal", "water", "earth"]:
		if int(elem_coverage[el2]) < 2:
			_fail("五行 %s 武器覆盖不足（%d < 2）" % [el2, int(elem_coverage[el2])])
			return
	# ---- 验证点 7（额外）：5 新角色 stats 都在 STAT_LIMITS 范围内 ----
	for cid2 in new_chars:
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
	var e_kill: Node2D = _spawn_reaction_target("grunt", far_corner + Vector2(-180.0, 0.0), p2)
	made.append(e_kill)
	e_kill.hp = 1.0
	e_kill.apply_status("bleed", 1, 0.0, 40.0, 1.0)
	e_kill.take_damage(50.0, false, false)   # 走真实 die()，验证 enemy_died 确实发出
	if int(p2.artifact_stacks.get("art_notch_blade", 0)) != 1 \
			or not is_equal_approx(float(p2.stats.crit_ch), crit_base + 0.04):
		_fail("断刃锋击杀流血敌人未叠暴击（层数 %d，暴击 %.3f，期望 1 / %.3f）"
			% [int(p2.artifact_stacks.get("art_notch_blade", 0)),
				float(p2.stats.crit_ch), crit_base + 0.04])
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
	var chars: int = Registry.characters.size()
	var weapons: int = Registry.weapons.size()
	var items: int = Registry.items.size()
	var enemies: int = Registry.enemies.size()
	var bosses := 0
	for eid in Registry.enemies:
		var ecfg: Dictionary = Registry.enemies[eid]
		if bool(ecfg.get("is_boss", false)) or String(ecfg.get("ai", "")) == "boss":
			bosses += 1
	var plain_enemies := enemies - bosses
	if chars < 15:
		_fail("角色数量未达 Phase 3 目标（%d < 15）" % chars)
		return
	if weapons < 20:
		_fail("武器数量未达 Phase 3 目标（%d < 20）" % weapons)
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
	# ---- 新增内容 id 齐全 ----
	for cid in ["gunner", "artillery", "monk", "ascetic", "alchemist", "warlord"]:
		if not Registry.characters.has(cid):
			_fail("新增角色缺失：%s" % cid)
			return
	for wid in ["railgun", "blight_bow", "frost_hammer", "gold_scepter"]:
		if not Registry.weapons.has(wid):
			_fail("新增武器缺失：%s" % wid)
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
	# ---- 自洽 3：武器必须有价格与商店权重，否则 Registry 注册时即崩 ----
	for wid2 in Config.WEAPONS:
		if not Config.WEAPON_PRICES.has(wid2) or not Config.WEAPON_SHOP_WEIGHTS.has(wid2):
			_fail("武器 %s 缺少价格或商店权重" % String(wid2))
			return
	# ---- 自洽 4：每日挑战角色池必须覆盖全部已注册角色（防新增角色漏加，漏了完全静默）----
	if Config.DAILY_CHARACTERS.size() != Registry.characters.size():
		_fail("每日挑战角色池未覆盖全部角色（%d vs %d）"
			% [Config.DAILY_CHARACTERS.size(), Registry.characters.size()])
		return
	for cid4 in Registry.characters:
		if not Config.DAILY_CHARACTERS.has(String(cid4)):
			_fail("每日挑战角色池缺少 %s" % String(cid4))
			return
	print("SMOKE: phase 3 content OK")

## 江湖奇遇事件卡（Phase 4）：数据完整性 / 抽取池 / UI 可负担性 / 效果执行 / 图鉴 / 触发门控
## 注意：不在这里真正走 shop_ui.next_wave() → start_wave()，否则会把当前波次重置，
## 后续「触控驱动移动」「暂停面板」等用例会因阶段退回 INTRO 而误报。
## 波次推迟的契约由 _suppress_event_cards + _pending_wave_after_event 归零共同验证。
func _check_event_cards() -> void:
	if Config.EVENT_CARDS.size() != 10:
		_fail("奇遇事件卡数量不对（%d，应为 10）" % Config.EVENT_CARDS.size())
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

## 地图主题化（Phase 5）：主题数据 / 波次映射 / 障碍物生成分布 / 推出与遮挡判定 /
## 索敌视线 / BOSS 波削减 / 氛围粒子。最后把现场还原成当前波次的主题。
func _check_map_themes() -> void:
	var wm: Node = _main.get_node("WaveManager")
	var p_mt: Node2D = _main.get_node("Player")
	# ---- 主题数据与波次映射 ----
	if Config.MAP_THEMES.size() != 3 or Config.MAP_THEME_ORDER.size() != 3:
		_fail("地图主题数量不对（%d）" % Config.MAP_THEMES.size())
		return
	for tid in Config.MAP_THEMES:
		var t: Dictionary = Config.MAP_THEMES[tid]
		for key in ["name", "bg", "grid", "accent", "obstacle", "particle", "waves"]:
			if not t.has(key):
				_fail("地图主题 %s 缺字段 %s" % [String(tid), key])
				return
		if not Obstacle.SHAPES.has(String(t.get("obstacle", ""))):
			_fail("地图主题 %s 引用了未知障碍物外观（%s）"
				% [String(tid), String(t.get("obstacle", ""))])
			return
	var expect := { 1: "bamboo", 3: "bamboo", 4: "temple", 6: "temple", 7: "nether", 10: "nether" }
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
	# 背景/网格/强调色三主题必须两两不同，否则「换景」没有意义
	var bgs: Array = []
	for tid2 in Config.MAP_THEMES:
		bgs.append(String(Config.MAP_THEMES[tid2].get("bg", "")))
	if bgs.size() != 3 or bgs[0] == bgs[1] or bgs[1] == bgs[2] or bgs[0] == bgs[2]:
		_fail("三主题背景色未区分（%s）" % str(bgs))
		return
	# BOSS 波判定与削减上限的关系
	if not Config.is_boss_wave(Config.BOSS_WAVE):
		_fail("第 %d 波未被判定为 BOSS 波" % Config.BOSS_WAVE)
		return
	if Config.OBSTACLE_BOSS_MAX > Config.OBSTACLE_MIN:
		_fail("BOSS 波障碍物上限不低于普通波下限（%d vs %d）"
			% [Config.OBSTACLE_BOSS_MAX, Config.OBSTACLE_MIN])
		return
	# 当前主题应当与当前波次一致（start_wave 写入 GameState）
	if GameState.map_theme != Config.map_theme_for_wave(wm.wave):
		_fail("当前主题与波次不符（wave=%d theme=%s）" % [wm.wave, GameState.map_theme])
		return
	print("SMOKE: map themes mapping OK (%s @ wave %d)" % [GameState.map_theme, wm.wave])
	# ---- 障碍物生成：数量 / 避开出生点 / 场内 / 块间通道 ----
	var origin := Vector2(Config.WORLD.w, Config.WORLD.h) * 0.5
	var made: int = _main.spawn_obstacles("nether", Config.OBSTACLE_MAX)
	if made < Config.OBSTACLE_MIN:
		_fail("障碍物生成数量不足（%d，请求 %d）" % [made, Config.OBSTACLE_MAX])
		return
	var entries: Array = Obstacles.entries()
	if entries.size() != made or Obstacles.count() != made:
		_fail("障碍物数据与索引不一致（%d / %d / %d）"
			% [entries.size(), Obstacles.count(), made])
		return
	var r := Obstacle.radius("stele")
	var min_gap := r * 2.0 + 56.0
	for e in entries:
		var p: Vector2 = e.pos
		if p.distance_to(origin) < Config.OBSTACLE_SAFE_RADIUS + r - 0.01:
			_fail("障碍物侵入玩家出生点安全圈（%.1f）" % p.distance_to(origin))
			return
		if p.x < r or p.y < r or p.x > Config.WORLD.w - r or p.y > Config.WORLD.h - r:
			_fail("障碍物越出世界边界（%s）" % str(p))
			return
	for i in entries.size():
		var a: Vector2 = entries[i].pos
		for j in range(i + 1, entries.size()):
			var b: Vector2 = entries[j].pos
			if a.distance_to(b) < min_gap - 0.01:
				_fail("障碍物间距不足，可能出现死路（%.1f < %.1f）" % [a.distance_to(b), min_gap])
				return
	print("SMOKE: obstacles spawned=%d gap>=%.0f safe>=%.0f"
		% [made, min_gap, Config.OBSTACLE_SAFE_RADIUS])
	# ---- 碰撞与视线：改用「世界中心一块已知障碍物」的受控场景 ----
	# 生成集是随机的，坐标可能贴边导致测试线段越界；碰撞/视线是纯几何，
	# 用受控单块障碍物验证既确定又可读，生成集的分布特征已在上面单独断言
	var c0 := Vector2(Config.WORLD.w, Config.WORLD.h) * 0.5
	var cr := Obstacle.radius("stele")
	Obstacles.rebuild([{ "pos": c0, "kind": "stele", "r": cr }])
	if Obstacles.count() != 1:
		_fail("受控障碍物重建失败（%d）" % Obstacles.count())
		return
	var pushed := Obstacles.resolve_circle(c0, 16.0)
	if pushed.distance_to(c0) < cr + 16.0 - 0.01:
		_fail("与障碍物圆心重合的实体未被推出（%.1f）" % pushed.distance_to(c0))
		return
	var far_pos := c0 + Vector2(cr + 16.0 + 80.0, 0.0)
	if Obstacles.resolve_circle(far_pos, 16.0) != far_pos:
		_fail("远离障碍物的实体被误推出")
		return
	if not Obstacles.overlaps_circle(c0, 1.0):
		_fail("障碍物自身位置未被判定为重叠")
		return
	if Obstacles.overlaps_circle(far_pos, 16.0):
		_fail("障碍物外侧 80px 的实体被误判为重叠")
		return
	var from := c0 + Vector2(-(cr + 120.0), 0.0)
	var to := c0 + Vector2(cr + 120.0, 0.0)
	var t_hit := Obstacles.first_block_t(from, to, 4.0)
	if not is_finite(t_hit) or t_hit <= 0.0 or t_hit >= 1.0:
		_fail("穿过障碍物的线段未被挡住（t=%.3f）" % t_hit)
		return
	var offset := Vector2(0.0, cr + 200.0)
	var t_clear := Obstacles.first_block_t(from + offset, to + offset, 4.0)
	if is_finite(t_clear):
		_fail("未经过障碍物的线段被误判为遮挡（t=%.3f）" % t_clear)
		return
	if Obstacles.has_los(from, to, 4.0):
		_fail("has_los 与实际遮挡结果不一致（应被挡住）")
		return
	if not Obstacles.has_los(from + offset, to + offset, 4.0):
		_fail("has_los 与实际遮挡结果不一致（应通畅）")
		return
	print("SMOKE: obstacle collision OK (block_t=%.3f)" % t_hit)
	# ---- 索敌视线：被障碍物挡住的近处敌人必须让位给无遮挡的远处敌人 ----
	var far := c0 + Vector2(-(cr + 400.0), 0.0)
	var e_blocked: Node2D = _spawn_reaction_target("grunt", c0 + Vector2(cr + 20.0, 0.0), p_mt)
	var e_visible: Node2D = _spawn_reaction_target("grunt",
		far + Vector2(0.0, -(cr * 2.0 + 500.0)), p_mt)
	await get_tree().physics_frame
	var blocked_visible := Obstacles.has_los(far, e_blocked.global_position, 4.0)
	var clear_visible := Obstacles.has_los(far, e_visible.global_position, 4.0)
	var picked: Node2D = Combat.nearest_enemy_visible(far, 4.0)
	e_blocked.queue_free()
	e_visible.queue_free()
	if blocked_visible:
		_fail("被障碍物遮挡的敌人未被判定为无视线")
		return
	if not clear_visible:
		_fail("无遮挡的敌人被误判为无视线")
		return
	if picked == e_blocked:
		_fail("索敌未避开被障碍物遮挡的目标")
		return
	print("SMOKE: obstacle line-of-sight targeting OK")
	# ---- 弹丸遮挡回归：没有障碍物时弹丸绝不能凭空消失 ----
	# 踩过的坑：first_block_t 用 INF 表示「没被挡住」，而 INF > 0.0 为真、
	# INF <= enemy_t（同样为 INF）也为真，于是漏判把「没挡住」当成「挡住」，
	# 每颗子弹在第一帧就被销毁——无敌人时 enemy_t 同为 INF，这个坑更隐蔽。
	# 这里放一颗零速弹丸：没有障碍物可挡、也不会命中敌人或飞出世界，它必须活下来
	var saved_phase: int = GameState.phase
	var saved_queue: int = GameState.level_queue
	GameState.level_queue = 0
	GameState.set_phase(GameState.Phase.PLAYING)
	Obstacles.clear()
	var free_bullet: Node2D = preload("res://scenes/weapons/bullet.tscn").instantiate()
	_main.add_child(free_bullet)
	free_bullet.setup(c0 + Vector2(0.0, -300.0), PI,
		{ "bspeed": 0.0, "bullet_life": 5.0 }, { "dmg": 1.0, "crit": false })
	for _i in 6:
		await get_tree().physics_frame
	var survived := is_instance_valid(free_bullet) and not free_bullet.is_queued_for_deletion()
	if is_instance_valid(free_bullet):
		free_bullet.queue_free()
	GameState.set_phase(saved_phase)
	GameState.level_queue = saved_queue
	if not survived:
		_fail("无障碍物时弹丸被误判为被遮挡（第一帧即销毁）")
		return
	print("SMOKE: obstacle-free bullet survives OK")
	# ---- BOSS 波障碍物削减（临时把波次推到 BOSS 波，验完立即还原）----
	var saved_wave: int = wm.wave
	var saved_endless: bool = GameState.endless
	GameState.endless = false
	wm.wave = Config.BOSS_WAVE
	_main._apply_map_theme("nether")
	var boss_count: int = Obstacles.count()
	wm.wave = saved_wave
	GameState.endless = saved_endless
	if boss_count > Config.OBSTACLE_BOSS_MAX:
		_fail("BOSS 波障碍物未削减（%d > %d）" % [boss_count, Config.OBSTACLE_BOSS_MAX])
		return
	print("SMOKE: boss wave obstacles=%d (cap %d)" % [boss_count, Config.OBSTACLE_BOSS_MAX])
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
	# ---- 还原：重建当前波次的主题障碍物 ----
	_main._apply_map_theme(GameState.map_theme)
	if Obstacles.count() < 1:
		_fail("还原当前主题后障碍物为空")
		return
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
	# 四类机制都必须有角色在用 —— 少了任何一类就说明新机制没接线
	for k2 in Registry.TRAIT_KINDS:
		if int(kinds.get(k2, 0)) <= 0:
			_fail("没有任何角色使用 %s 类特性" % String(k2))
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
	var orphans: Array = []
	for wid2 in Registry.WEAPON_FX:
		if not Config.WEAPONS.has(String(wid2)):
			orphans.append(String(wid2))
	if not orphans.is_empty():
		_fail("外观族映射指向不存在的武器：%s" % ", ".join(orphans))
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
	sl.setup(Vector2.ZERO, 0.0, 100.0, 1.9, String(Registry.weapons["blade"].get("fx", "")))
	if String(sl.fx) != "slash":
		_fail("太刀的刀光未取到 slash 外观族（%s）" % String(sl.fx))
		sl.queue_free()
		return
	sl.queue_free()
	await get_tree().process_frame
	print("SMOKE: weapon fx wiring OK")

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
	if not ("melee" in Config.affinity_tags("potato", [{ "type": "blade" }], {})):
		_fail("近战武器未推导出 melee 亲和")
		return
	if not ("poison" in Config.affinity_tags("potato", [{ "type": "venom_dagger" }], {})):
		_fail("带毒武器未推导出 poison 亲和")
		return
	if not ("burn" in Config.affinity_tags("pyromancer", [], {})):
		_fail("焚天祭司的光环未推导出 burn 亲和")
		return
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
	if used.size() < 8:
		_fail("印记覆盖面过低：只有 %d 种被角色使用" % used.size())
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
	var expects := { "pyromancer": "fire", "swordmaster": "blade", "guardian": "guard",
		"warlord": "blade", "tidecaller": "water" }
	for cid2 in expects:
		var got := Config.sigil_for(String(cid2))
		if got != String(expects[cid2]):
			_fail("角色 %s 的印记应为 %s（实得 %s）" % [String(cid2), String(expects[cid2]), got])
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

## 亲和保底：单靠加权只是「更常出现」，保底把关联性变成承诺。
## 这里直接对保底函数做确定性验证 —— 不依赖随机抽到什么，断言永远可复现
func _check_affinity_floor() -> void:
	# ---- 1. 升级三选一：三张全不契合时必须换出至少一张契合项 ----
	var lu: Node = _main.get_node("UI/LevelUp")
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
	phx.take_damage(max_hp * 10.0, false)
	var ok_first: bool = killed[0] == 0 and phx.hp > 0.0 \
		and is_equal_approx(phx.hp, max_hp * 0.5)
	phx.take_damage(phx.hp * 10.0, false)
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
	if not Unlocks.is_unlocked("character", "potato"):
		_fail("基础角色 potato 应默认解锁")
		return
	if not Unlocks.is_unlocked("weapon", "pistol"):
		_fail("基础武器 pistol 应默认解锁")
		return
	# 阈值推导：快照统计 → 清零 → 精确断言 → 还原（不受前置用例的统计污染）
	var saved := {}
	for k in Config.UNLOCK_STAT_KEYS:
		saved[k] = CodexData.stat(k)
		CodexData.stats[k] = 0
	Unlocks.reset_for_tests()
	if Unlocks.is_unlocked("character", "warlord"):
		_restore_unlock_stats(saved)
		_fail("warlord 应在 victories=0 时锁定")
		return
	if Unlocks.is_unlocked("weapon", "gold_scepter"):
		_restore_unlock_stats(saved)
		_fail("gold_scepter 应在 victories=0 时锁定")
		return
	CodexData.stats["victories"] = 1
	if not Unlocks.is_unlocked("character", "warlord"):
		_restore_unlock_stats(saved)
		_fail("warlord 应在 victories>=1 时解锁")
		return
	if not Unlocks.is_unlocked("weapon", "gold_scepter"):
		_restore_unlock_stats(saved)
		_fail("gold_scepter 应在 victories>=1 时解锁")
		return
	# check_new 一次性：本轮应恰有 2 个新解锁（warlord + gold_scepter），再次调用为 0
	var n := Unlocks.check_new()
	if n != 2:
		_restore_unlock_stats(saved)
		_fail("check_new 应恰有 2 个新解锁（实际 %d）" % n)
		return
	if Unlocks.check_new() != 0:
		_restore_unlock_stats(saved)
		_fail("check_new 第二次应返回 0（庆祝应一次性）")
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
	if MetaProgress.sect_for("pyromancer") != "fire":
		_fail("sect_for(pyromancer) 应返回 fire")
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
	# pyromancer 吃到 fire 门派天赋
	GameState.character_id = "pyromancer"
	var p_pyro: Node2D = preload("res://scenes/characters/player.tscn").instantiate()
	_main.add_child(p_pyro)
	var base_dmg: float = p_pyro.stats.status_dmg_mult
	MetaProgress.apply_on_run_start(p_pyro)
	if not is_equal_approx(float(p_pyro.stats.status_dmg_mult), base_dmg + 0.15):
		_fail("门派天赋未对 pyromancer 生效（%.3f ≠ %.3f）"
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
## BOSS 击破 → 商店衔接 → wave11 存档/恢复、240 敌群性能压测、死亡入榜
func _check_endless() -> void:
	Leaderboard.set_storage_root_for_tests("user://tests/lb")
	Leaderboard.entries = []   # 防上次异常中断的残留文件污染名次断言
	# ---- 标准模式第 10 波通关 → 胜利结算 → 继续无尽 ----
	GameState.endless = false
	GameState.score = 0
	var wm_v: Node = _main.get_node("WaveManager")
	wm_v.start_wave(10)
	var vboss: Node2D = wm_v.boss
	if vboss == null:
		_fail("标准模式第 10 波未生成 BOSS")
		return
	var vboss_hp: float = vboss.max_hp
	if vboss_hp < 2400.0:
		_fail("BOSS 血量未强化（max_hp=%.0f）" % vboss_hp)
		return
	vboss.take_damage(1.0e9, false)
	# 焚天凤凰会涅槃复活一次：一击后若仍未进结算（phase 仍 INTRO），补一刀
	if GameState.phase != GameState.Phase.VICTORY and is_instance_valid(vboss):
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
	if not GameState.endless or wm_v.wave != 11 or GameState.phase != GameState.Phase.INTRO:
		_fail("通关后继续无尽失败（endless=%s wave=%d phase=%d）"
			% [str(GameState.endless), wm_v.wave, GameState.phase])
		return
	# ---- 纯函数断言 ----
	GameState.endless = false
	if not Config.is_boss_wave(10) or Config.is_boss_wave(11) or Config.is_boss_wave(20):
		_fail("is_boss_wave 标准模式判定错误")
		return
	GameState.endless = true
	if not Config.is_boss_wave(20) or Config.is_boss_wave(19):
		_fail("is_boss_wave 无尽模式判定错误")
		return
	if Config.kill_score(Registry.enemies.grunt) <= 0 \
			or Config.boss_kill_score(10) <= 0 or Config.wave_clear_score(5) <= 0:
		_fail("积分公式错误")
		return
	# 无尽 BOSS 血量随波次增长（第 20 波 > 第 10 波基准）
	var boss20: Node2D = preload("res://scenes/enemies/enemy.tscn").instantiate()
	boss20.setup("boss", 20)
	var boss20_hp: float = boss20.max_hp
	boss20.free()
	if boss20_hp <= vboss_hp:
		_fail("无尽 BOSS 血量未随波次增长（w20=%.0f <= w10=%.0f）" % [boss20_hp, vboss_hp])
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
	# ---- 无尽流程：第 10 波 BOSS ----
	GameState.score = 0
	var wm: Node = _main.get_node("WaveManager")
	wm.start_wave(10)
	var boss: Node2D = wm.boss
	if boss == null:
		_fail("无尽第 10 波未生成 BOSS")
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
	# BOSS 击破 → 商店衔接 + wave11 存档
	boss.take_damage(1.0e9, false)
	# 焚天凤凰会涅槃复活一次：一击后若仍未进商店（phase 仍 INTRO 且 boss 仍存活），补一刀
	if GameState.phase != GameState.Phase.SHOP and is_instance_valid(boss):
		boss.take_damage(1.0e9, false)
	await get_tree().process_frame
	if GameState.phase != GameState.Phase.SHOP or wm.boss != null:
		_fail("无尽 BOSS 击破未衔接商店（phase=%d）" % GameState.phase)
		return
	if not SaveRun.exists(GameState.slot_id):
		_fail("无尽 wave11 存档失败")
		return
	# 存档往返：endless 标志与积分一致
	var score_saved: int = GameState.score
	if SaveRun.restore(p3) != 11:
		_fail("无尽存档波次往返失败")
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

func _cleanup_test_storage(reset_root: bool) -> void:
	var previous_slot := GameState.slot_id
	for slot in range(1, SaveRun.SLOT_COUNT + 1):
		GameState.slot_id = slot
		SaveRun.clear()
	GameState.slot_id = clampi(previous_slot, 1, SaveRun.SLOT_COUNT)
	var legacy_path := TEST_SAVE_ROOT.path_join("save_run.json")
	if FileAccess.file_exists(legacy_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(legacy_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE_ROOT))
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
