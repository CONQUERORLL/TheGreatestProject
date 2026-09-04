extends Node
## 冒烟测试：武器闭环 + 掉落拾取 + 波次推进（掉落跨波保留）+ 商店 + BOSS 弹幕
##   + 升级三选一 + HUD + 手柄焦点 + Registry/mod 加载 + 数值断言 + 粒子/飘字/爆炸特效（fx 组）
## 运行：godot --headless --path . res://tests/smoke_test.tscn（退出码 0=通过）

var _main: Node
var _last_ended := 0
var _mats_at_end := -1      # 第 1 波收波结算后的材料数
var _loot_left_at_end := -1 # 第 1 波收波结算后的场上剩余掉落

func _ready() -> void:
	_main = preload("res://scenes/main.tscn").instantiate()
	add_child(_main)
	EventBus.wave_ended.connect(_on_wave_ended)
	get_tree().create_timer(8.0).timeout.connect(_check_weapons)   # 首杀窗口放宽，避免 RNG 抖动误报

func _on_wave_ended(w: int) -> void:
	_last_ended = w
	if w == 1:
		_mats_at_end = GameState.materials
		_loot_left_at_end = get_tree().get_nodes_in_group("loot").size()

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
	print("SMOKE: wave=%d last_ended=%d mats_at_end=%d loot_left=%d lv=%d xp=%d" %
		[wm.wave, _last_ended, _mats_at_end, _loot_left_at_end, GameState.level, GameState.xp])
	if _last_ended < 1:
		_fail("波次未推进（last_ended=%d）" % _last_ended)
		return
	if _mats_at_end <= 0 and _loot_left_at_end <= 0:
		_fail("击杀既未拾取也无掉落留存")
		return
	if GameState.level <= 1 and GameState.xp <= 0:
		_fail("经验未入账")
		return
	# 波末不再回收掉落：只清敌人/敌弹，掉落物保留原位跨波
	if GameState.phase != GameState.Phase.SHOP:
		_fail("波末未进入商店（phase=%d）" % GameState.phase)
		return
	shop.next_wave()
	if wm.wave != 2 or GameState.phase != GameState.Phase.INTRO:
		_fail("商店下一波未生效（wave=%d phase=%d）" % [wm.wave, GameState.phase])
		return
	var loot_kept := get_tree().get_nodes_in_group("loot").size()
	print("SMOKE: loot_kept=%d (at_end=%d)" % [loot_kept, _loot_left_at_end])
	if loot_kept < _loot_left_at_end:
		_fail("跨波掉落物被清除（%d -> %d）" % [_loot_left_at_end, loot_kept])
		return
	# 数值调整断言：波时 45+5/波、初始移速 742（495+50%）
	if Config.wave_duration(1) != 45.0 or Config.wave_duration(2) != 50.0 \
			or not is_equal_approx(Config.PLAYER.base_speed, 742.0):
		_fail("数值调整未生效（波时/移速）")
		return
	# Registry 注册表 + 示例 mod 加载断言
	if Registry.weapons.size() < 6 or not Registry.weapons.has("laser"):
		_fail("Registry 未加载示例 mod 武器 laser")
		return
	if Registry.items.size() < 12 or Registry.difficulties.size() < 3 \
			or Registry.characters.size() < 1:
		_fail("Registry 内置内容缺失（items=%d difficulties=%d characters=%d）"
			% [Registry.items.size(), Registry.difficulties.size(), Registry.characters.size()])
		return
	# BOSS 弹幕验证（在下一波进行中生成，避开收波清弹窗口）
	var boss: Node2D = preload("res://scenes/enemies/enemy.tscn").instantiate()
	boss.setup("boss", 10)
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
	# ---- 二次升级验证（修复后：连升/二次升级焦点和输入必须可用） ----
	GameState.gain_xp(Config.xp_need(GameState.level) + 1)   # 再升 1 级
	await get_tree().process_frame   # 等一帧让 deferred grab_focus 执行
	print("SMOKE: lv2_phase=%d queue=%d cards=%d focus=%s" %
		[GameState.phase, GameState.level_queue, ui.card_count(),
		str(ui.get_viewport().gui_get_focus_owner())])
	if GameState.phase != GameState.Phase.LEVEL_UP or ui.card_count() != 3:
		_fail("二次升级 UI 未打开（phase=%d cards=%d）" % [GameState.phase, ui.card_count()])
		return
	var focus2: Control = ui.get_viewport().gui_get_focus_owner()
	if focus2 == null or focus2.get_parent() != ui.get_node("Center/Box/Cards"):
		_fail("二次升级卡未获得焦点（grab_focus deferred 失效）")
		return
	var stats2: Dictionary = player.stats.duplicate()
	var hp2: float = player.hp
	ui._choose(0)
	print("SMOKE: after_lv2_choose phase=%d queue=%d" % [GameState.phase, GameState.level_queue])
	if GameState.phase != GameState.Phase.PLAYING:
		_fail("二次升级选择后未恢复 PLAYING")
		return
	if player.stats == stats2 and is_equal_approx(player.hp, hp2):
		_fail("二次升级未产生属性变化")
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
	print("SMOKE: items track/sell + pause panel OK")
	print("SMOKE: PASS")
	get_tree().quit(0)

func _fail(reason: String) -> void:
	print("SMOKE: FAIL - " + reason)
	get_tree().quit(1)
