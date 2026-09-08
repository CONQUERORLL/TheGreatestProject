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

const TEST_SAVE_ROOT := "user://tests/smoke_run"

func _ready() -> void:
	SaveRun.set_storage_root_for_tests(TEST_SAVE_ROOT)
	_cleanup_test_storage(false)
	_main = preload("res://scenes/main.tscn").instantiate()
	add_child(_main)
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
	get_tree().create_timer(3.0).timeout.connect(_check_wave)

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
	player.hp = 100.0  # 保证测试期间玩家存活
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
	# 追踪：apply_item 计数
	p2.apply_item("i-hp")
	if int(p2.items_owned.get("i-hp", 0)) != 1:
		_fail("apply_item 未计入 items_owned")
		return
	p2.apply_item("i-hp")
	if int(p2.items_owned.get("i-hp", 0)) != 2:
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
	if int(p2.items_owned.get("i-hp", 0)) != 1 or p2.stats.max_hp >= max2:
		_fail("出售未扣数量或未移除效果")
		return
	p2.sell_item("i-hp")
	if p2.items_owned.has("i-hp"):
		_fail("售空后道具未移除")
		return
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
	# 连续碰撞工具：线段跨过圆心必须命中，偏离则不能误判。
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
	menu._open_slots("new")
	menu._do_new(1)
	await get_tree().process_frame
	if not menu._wizard.visible or menu._slots_panel.visible or not SaveRun.exists(1):
		_fail("新局选槽未进入向导，或提前清除了旧档")
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
	_cleanup_test_storage(true)
	print("SMOKE: PASS")
	get_tree().quit(0)

## 无尽炼狱模式回归：BOSS 波判定/积分公式/排行榜、
## BOSS 击破 → 商店衔接 → wave11 存档/恢复、240 敌群性能压测、死亡入榜
func _check_endless() -> void:
	Leaderboard.set_storage_root_for_tests("user://tests/lb")
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
	var lb := Leaderboard.get_list()
	if lb.is_empty() or int(lb[0].score) != score_at_death:
		_fail("无尽死亡未记录排行榜（top=%s）"
			% str((lb[0] as Dictionary).get("score", -1) if not lb.is_empty() else "空"))
		return
	if Leaderboard.record(9999, 2, "测试C", 1, 1.0) != 1 or Leaderboard.get_list().size() != 4:
		_fail("排行榜插入排序错误")
		return
	GameState.endless = false
	Leaderboard.reset_storage_root_after_tests()
	var lb_path := "user://tests/lb/leaderboard.json"
	if FileAccess.file_exists(lb_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(lb_path))
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
	if reset_root:
		SaveRun.reset_storage_root_after_tests()

func _fail(reason: String) -> void:
	print("SMOKE: FAIL - " + reason)
	_cleanup_test_storage(true)
	get_tree().quit(1)
