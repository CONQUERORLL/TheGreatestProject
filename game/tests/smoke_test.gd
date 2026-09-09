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

const TEST_SAVE_ROOT := "user://tests/smoke_run"
const TEST_CODEX_PATH := "user://tests/codex_data.json"
const TEST_META_PATH := "user://tests/meta_progress.json"
const TEST_STEAM_PATH := "user://tests/steam_pending.json"

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
	PlatformAchievements._flush_pending()
	if PlatformAchievements.pending_count() != 0 \
			or not _forwarded_call(PlatformAchievements.test_calls(), "ACH_FIRST_BLOOD"):
		_fail("平台成就未在后端可用时补发（calls=%s）" % str(PlatformAchievements.test_calls()))
		return
	PlatformAchievements.set_backend_for_tests("")   # 还原真实检测（headless 无 SDK）
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
	shop.next_wave()
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
	if Config.rarity_weight("legendary", 1) <= 0.0 \
			or Config.rarity_weight("legendary", 9) <= Config.rarity_weight("legendary", 1):
		_fail("稀有度权重曲线错误（legendary 应随进度提升）")
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
	var fx3 := get_tree().get_nodes_in_group("fx").size()
	print("SMOKE: fx explosion ->%d" % fx3)
	if fx3 <= fx2:
		_fail("爆炸未生成光环/粒子特效（fx %d->%d）" % [fx2, fx3])
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
	shop.next_wave()
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
	# 冰冻：移速归零 + 受到伤害 +25%
	e_stat.apply_status("freeze", 1, 0.0, 0.0, 1.0)
	if e_stat._status_speed_mult() > 0.001:
		_fail("冰冻未定身（speed_mult=%.2f）" % e_stat._status_speed_mult())
		return
	if not is_equal_approx(e_stat._damage_taken_mult(), 1.25):
		_fail("冰冻易伤倍率错误（%.2f）" % e_stat._damage_taken_mult())
		return
	# 到期清除：一次推进 4 秒后燃烧/冰冻都应消失
	e_stat._tick_statuses(4.0)
	if e_stat.has_status("burn") or e_stat.has_status("freeze"):
		_fail("状态到期未清除（burn=%s freeze=%s）"
			% [str(e_stat.has_status("burn")), str(e_stat.has_status("freeze"))])
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
	if not Sfx._streams.has("status_burn") or not Sfx._streams.has("status_stun"):
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
	# ---- 武器进化：4 把手枪波末合成双管神射 ----
	var p4: Node2D = _main.get_node("Player")
	var saved_weapons4: Array = p4.weapons.duplicate(true)
	p4.weapons = []
	for _i2 in 4:
		p4.weapons.append({ "type": "pistol", "cd": 0.1 })
	p4.weapons.append({ "type": "rocket", "cd": 0.1 })   # 混入其他武器验证只合成同名
	var evolved: Array = p4.evolve_weapons()
	print("SMOKE: evolve results=%s weapons=%d" % [str(evolved), p4.weapons.size()])
	if evolved.size() != 1 or not String(evolved[0]).contains("双管神射"):
		_fail("武器进化结果错误（%s）" % str(evolved))
		return
	var pistol_cnt := 0
	var ex_cnt := 0
	for w in p4.weapons:
		if w.type == "pistol":
			pistol_cnt += 1
		if w.type == "pistol_ex":
			ex_cnt += 1
	if pistol_cnt != 0 or ex_cnt != 1 or p4.weapons.size() != 2:
		_fail("进化后武器列表错误（pistol=%d ex=%d total=%d）" % [pistol_cnt, ex_cnt, p4.weapons.size()])
		return
	# 进化预览：2 把手枪显示 2/4
	p4.weapons = [{ "type": "pistol", "cd": 0.1 }, { "type": "pistol", "cd": 0.1 }]
	var prog: Array = p4.evolve_progress()
	if prog.size() != 1 or int(prog[0].have) != 2 or int(prog[0].need) != 4:
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
	var items_t0: int = p4.items_owned.size()
	wm3.ending_started = true
	wm3.wave_timer = 0.0
	wm3._settle_event_wave()
	await get_tree().process_frame
	if p4.items_owned.size() <= items_t0:
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
	# 强化加成行：伤害/时长 > 0 时图例末尾追加说明
	p2.stats.status_dmg_mult = 0.25
	p2.stats.status_dur_mult = 0.10
	hud._status_key = ""
	hud._refresh_status_legend()
	var last: Node = hud._status_box.get_child(hud._status_box.get_child_count() - 1)
	if not (last is Label) or String(last.text).find("伤害") < 0 or String(last.text).find("时长") < 0:
		_fail("状态强化加成行未显示")
		return
	if String(last.text).find("传染") >= 0:
		_fail("无中毒来源时不应显示传染加成")
		return
	# 瘟疫之心（中毒传染）：存在中毒来源时才追加显示
	p2.weapons = [{ "type": "venom_dagger", "cd": 0.4 }]
	p2.stats.status_spread = 1.0
	hud._status_key = ""
	hud._refresh_status_legend()
	var last2: Node = hud._status_box.get_child(hud._status_box.get_child_count() - 1)
	if not (last2 is Label) or String(last2.text).find("传染") < 0:
		_fail("中毒传染加成未显示")
		return
	# 还原构筑，避免影响后续存档/结算断言
	p2.weapons = w_backup
	p2.items_owned = items_backup
	p2.stats = stats_backup
	hud._status_key = ""
	hud._refresh_status_legend()
	print("SMOKE: status legend OK")

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
	var t0 := Time.get_ticks_msec()
	for _f in 120:
		await get_tree().physics_frame
	var elapsed := Time.get_ticks_msec() - t0
	print("SMOKE: perf 240 enemies x 120 ticks = %d ms (%.2f ms/tick)" % [elapsed, elapsed / 120.0])
	for e3 in perf_enemies:
		e3.queue_free()
	await get_tree().physics_frame
	p3.weapons = saved_weapons
	p3.iframes = 0.45
	# 120 帧理想 2000ms；放宽到 3400ms（≈28ms/帧）防灾难性回归
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

## 递归拼接节点树中的 Label 文本（图鉴详情断言用）
func _node_text(node: Node) -> String:
	var out := ""
	if node is Label:
		out += String(node.text) + "\n"
	for c in node.get_children():
		out += _node_text(c)
	return out

func _fail(reason: String) -> void:
	if _failed:
		return   # 已失败：只保留首个原因，退出码不被后续 quit(0) 覆盖
	_failed = true
	print("SMOKE: FAIL - " + reason)
	_cleanup_test_storage(true)
	get_tree().quit(1)
