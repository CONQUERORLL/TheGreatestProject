extends Node
## 波次管理（移植自原型 startWave / updateWaves）
## 普通波：intro 横幅 → 按 interval 刷怪（受 cap 限制；高难度按 elite_chance 混入精英）
##   → waveTimer 到 → 敌人 flee 消散 + 清空敌方子弹 → 清场后进入商店
##   （场上掉落由 main 在波末自动回收结算，不再跨波滞留）
## BOSS 波：标准=第 10 波；无尽炼狱=每 10 波。开场即刷 BOSS（不死不休），
##   持续刷混合干扰怪；无尽下 BOSS 击破 → 退场进商店 → 继续下一波

const EnemyScene := preload("res://scenes/enemies/enemy.tscn")

var wave := 0
var wave_timer := 0.0
var spawn_t := 0.0
var intro_t := 0.0
var ending_started := false
var boss: Node2D   # 当前 BOSS 引用（HUD 显示血量用；击杀后清空）
var boss_dead := false   # 无尽 BOSS 波：BOSS 击破后停止补怪
var player: Node2D
var _alive_cache := 0    # 存活敌数缓存（0.12s 刷新，大规模敌群省全量遍历）
var _alive_t := 0.0
var event_kind := ""     # 当前事件波类型："" 常规 / treasure / hunt / meteor
var _meteor_t := 0.0     # 流星雨：下次砸落倒计时
var _hunt_elites_total := 0   # 精英狩猎：本场精英总数（奖励基数）

func _ready() -> void:
	EventBus.boss_killed.connect(_on_boss_killed)

func _on_boss_killed() -> void:
	boss = null
	if not GameState.endless:
		return
	# 无尽：BOSS 击破 → 积分入账 → 干扰怪退场 → 进商店 → 挑战更深的波次
	boss_dead = true
	GameState.add_score(Config.boss_kill_score(wave))
	for e in get_tree().get_nodes_in_group("enemies"):
		if e.flee <= 0.0:
			e.start_flee()
	_clear_projectiles()
	EventBus.wave_ended.emit(wave)

func start_wave(n: int) -> void:
	var wave_max := Config.ENDLESS_MAX_WAVE if GameState.endless \
		else RunRules.wave_total(Config.WAVES_TOTAL)
	wave = clampi(n, 1, wave_max)
	ending_started = false
	boss_dead = false
	event_kind = ""
	_meteor_t = 0.0
	_hunt_elites_total = 0
	spawn_t = 0.6
	wave_timer = Config.wave_duration(wave) * RunRules.wave_duration_mult()
	_clear_projectiles()
	# 地图主题（Phase 5）：由波次推导，波 1-3 竹林 / 4-6 古庙 / 7-10 幽冥，
	# 无尽按主题表循环。障碍物与氛围粒子由 main 在 wave_started 里按此重建
	var prev_theme := GameState.map_theme
	GameState.map_theme = Config.map_theme_for_wave(wave)
	# 玩家回到世界中心（原型 startWave 同款）
	player.global_position = Vector2(Config.WORLD.w, Config.WORLD.h) / 2.0
	player.velocity = Vector2.ZERO
	var is_boss_wave := Config.is_boss_wave(wave)
	intro_t = 2.6 if is_boss_wave else 2.2
	GameState.set_phase(GameState.Phase.INTRO)
	# 换景提示：只在主题真的变了的那一波播报，避免每波刷屏
	var theme_note := ""
	if GameState.map_theme != prev_theme:
		theme_note = " · " + Config.map_theme_name(GameState.map_theme)
	if is_boss_wave:
		var bid := _pick_boss_id()
		spawn(bid)
		var bname: String = Registry.enemies[bid].name
		var title: String = Config.BOSS_TITLES.get(bid, "")
		EventBus.banner_requested.emit("第 %d 波 · BOSS%s" % [wave, theme_note],
			"%s 出现了！%s" % [bname, "（%s）" % title if title != "" else ""], 2.6)
	elif Config.is_event_wave(wave):
		_roll_event_wave()
	else:
		EventBus.banner_requested.emit("第 %d 波%s%s" % [wave,
				" / 共 %d 波" % RunRules.wave_total(Config.WAVES_TOTAL) if not GameState.endless else " · 无尽炼狱",
				theme_note],
			"武器会自动攻击，专心走位", 2.2)
	# 江湖奇遇的风险代价（如「挥手驱赶」「跃龙门」）：上一波约定「下一波多 N 个精英」，
	# 在这里兑现并清零。刻意放在横幅之后、wave_started 之前——精英立刻入场，
	# 但 intro 阶段（2.2s）玩家尚有反应时间
	if GameState.next_wave_elite > 0:
		var extra: int = GameState.next_wave_elite
		GameState.next_wave_elite = 0
		for _i in extra:
			spawn(String(GameRng.weighted_pick(Config.ELITE_POOL)), true)
	EventBus.wave_started.emit(wave)

## BOSS 轮换：从 BOSS_POOL 按当前波次确定性选取（同种子同波次同 BOSS，
## 每日挑战全服一致；mod 的 boss_override 仍最高优先）
func _pick_boss_id() -> String:
	var override := Registry.boss_id()
	if override != "boss" or not Registry.enemies.has("boss_spiral"):
		return override
	# 每日挑战：今日 BOSS 由日期哈希固定（全服一致）
	if GameState.daily:
		var daily_boss := String(Config.daily_setup(GameState.daily_date).get("boss_id", "boss"))
		return daily_boss if Registry.enemies.has(daily_boss) else "boss"
	# 波 10/20/30… 在池内轮换（种子 + 轮次决定）
	var round_idx := wave / 10
	var pool: Array = Config.BOSS_POOL.duplicate()
	var pick: String = pool[(GameRng._a + round_idx * 7919) % pool.size()]
	return pick if Registry.enemies.has(pick) else "boss"

## 事件波抽取：宝箱守卫 / 精英狩猎 / 流星雨 三选一
func _roll_event_wave() -> void:
	event_kind = String(GameRng.weighted_pick([
		{ "item": "treasure", "w": 0.34 }, { "item": "hunt", "w": 0.33 },
		{ "item": "meteor", "w": 0.33 }]))
	match event_kind:
		"treasure":
			EventBus.banner_requested.emit("第 %d 波 · 🎁 宝箱守卫" % wave,
				"击杀全部宝箱守卫，战利品归你！", 2.6)
		"hunt":
			EventBus.banner_requested.emit("第 %d 波 · ⚔ 精英狩猎" % wave,
				"尽早击杀精英！波末按存活精英数扣减奖励", 2.6)
		"meteor":
			EventBus.banner_requested.emit("第 %d 波 · ☄ 流星雨" % wave,
				"天降流星！看清预警圈再走位", 2.6)

func _physics_process(delta: float) -> void:
	if GameState.phase == GameState.Phase.INTRO:
		intro_t -= delta
		if intro_t <= 0.0:
			GameState.set_phase(GameState.Phase.PLAYING)
		return
	if GameState.phase != GameState.Phase.PLAYING:
		return
	GameState.run_time += delta
	var is_boss_wave := Config.is_boss_wave(wave)
	var diff: Dictionary = Registry.get_difficulty(GameState.difficulty_id)
	if not is_boss_wave:
		wave_timer -= delta
		spawn_t -= delta
		# 流星雨：常规刷怪 + 周期性天降流星（优先砸玩家附近）
		if event_kind == "meteor":
			_meteor_t -= delta
			if _meteor_t <= 0.0:
				_meteor_t = Config.METEOR_FALL_CD
				_spawn_meteor()
		# 存活敌数 0.12s 缓存刷新：大规模敌群下免每帧全量遍历
		_alive_t -= delta
		if _alive_t <= 0.0:
			_alive_t = 0.12
			_alive_cache = _alive_count(false)
		var alive := _alive_cache
		# 同屏上限 = 波次曲线 × 难度倍率，且不超过性能护栏
		var cap := mini(int(float(Config.wave_cap(wave)) * float(diff.spawn_mult)),
			Config.ENEMY_HARD_CAP)
		if wave_timer > 0.0 and spawn_t <= 0.0 and alive < cap:
			spawn_t = Config.wave_interval(wave) / float(diff.spawn_mult)
			var pick_id := _pick_spawn_id(diff)
			# 必须紧跟 _pick_spawn_id 读取：_picked_elite 是单次调用的伴随标志位
			spawn(pick_id, _picked_elite)
			_alive_cache += 1
			alive += 1
		if wave_timer <= 0.0 and not ending_started:
			ending_started = true
			# 时间到只执行一次：敌人退场，双方弹丸清空，掉落物由波末自动回收。
			for e in get_tree().get_nodes_in_group("enemies"):
				if e.flee <= 0.0:
					e.start_flee()
			_clear_projectiles()
			alive = 0   # 退场敌人不再计入存活
			_alive_cache = 0
		# 普通波：清场后进入商店（main 监听 wave_ended 打开；下一波由商店"下一波"触发）
		if wave_timer <= 0.0 and alive == 0:
			_settle_event_wave()
			EventBus.wave_ended.emit(wave)
	else:
		# BOSS 波：混合干扰怪持续刷新（BOSS 击破后停止），BOSS 不死不休
		spawn_t -= delta
		if not boss_dead and spawn_t <= 0.0 and _alive_count(true) < 16:
			spawn_t = 2.4
			spawn(String(GameRng.weighted_pick([
				{ "item": "runner", "w": 0.35 }, { "item": "grunt", "w": 0.30 },
				{ "item": "shadow", "w": 0.20 }, { "item": "bomber", "w": 0.15 }])))

## 上一次 _pick_spawn_id 的结果是否为精英（伴随标志位）
## _pick_spawn_id 刻意保持返回 String：冒烟测试按字符串断言 chest_guard，
## 改返回结构体会破坏既有契约。法宝掉落只认这个标志而不认敌人类型，
## 因为 Config.wave_composition 里 guard/wizard/shadow/bomber 在 W7+ 常规波就会出现
var _picked_elite := false

## 选怪：事件波用专属组合；常规按波次权重组合；
## 高难度（hard/噩梦）有 elite_chance 概率在第 4 波起替换为精英怪
## 返回敌人 id，是否为精英写入 _picked_elite
func _pick_spawn_id(diff: Dictionary) -> String:
	_picked_elite = false
	match event_kind:
		"treasure":
			# 宝箱守卫波：只刷宝箱守卫（少量慢速高价值目标）
			return "chest_guard"
		"hunt":
			# 精英狩猎波：精英 40% + 常规怪 60%
			if GameRng.chance(0.4):
				var elite := String(GameRng.weighted_pick(Config.ELITE_POOL))
				_hunt_elites_total += 1
				_picked_elite = true
				return elite
			return String(GameRng.weighted_pick(Registry.wave_composition(wave)))
	var pick_id := String(GameRng.weighted_pick(Registry.wave_composition(wave)))
	var elite_ch := float(diff.get("elite_chance", 0.0))
	if elite_ch > 0.0 and wave >= 4 and GameRng.chance(elite_ch):
		pick_id = String(GameRng.weighted_pick(Config.ELITE_POOL))
		_picked_elite = true
	return pick_id

## 流星砸落点：70% 砸玩家附近（半径 120-320 随机），30% 全场随机
func _spawn_meteor() -> void:
	var pos := Vector2.ZERO
	if GameRng.chance(0.7):
		var ang := GameRng.next() * TAU
		var dist := GameRng.range_f(120.0, 320.0)
		pos = player.global_position + Vector2.from_angle(ang) * dist
	else:
		pos = Vector2(GameRng.range_f(60.0, Config.WORLD.w - 60.0),
			GameRng.range_f(60.0, Config.WORLD.h - 60.0))
	var dmg := Config.METEOR_DAMAGE * Config.wave_dmg_scale(wave) \
			* float(Registry.get_difficulty(GameState.difficulty_id).dmg_mult)
	Meteor.spawn(get_parent(), pos, player, dmg, Config.METEOR_RADIUS, Config.METEOR_WARN_TIME)

## 事件波结算（进商店前调用，wave_ended 之前）
func _settle_event_wave() -> void:
	match event_kind:
		"treasure":
			# 宝箱波清场必掉 1 件高品阶道具（紫/金/红加权，波次越高金红越多）
			var pool: Array = []
			for it in Registry.item_list():
				var r := String(it.get("rarity", "common"))
				if r in ["epic", "mythic", "legendary"] \
						and Config.entry_weapon_relevant(it, player.weapons):
					pool.append({ "item": it, "w": Config.rarity_weight(r, wave) * 6.0 })
			if not pool.is_empty():
				var loot: Dictionary = GameRng.weighted_pick(pool)
				player.apply_item(String(loot.id))
				EventBus.banner_requested.emit("🎁 战利品！",
					"获得 %s %s" % [loot.ico, loot.name], 2.6)
				Sfx.play("buy")
		"hunt":
			# 精英狩猎：按击杀比例奖励材料（波次 × 20 × 击杀率，至少 10）
			var alive_elites := 0
			for e in get_tree().get_nodes_in_group("enemies"):
				if e.flee <= 0.0 and String(e.type) in ["guard", "wizard", "shadow", "bomber"]:
					alive_elites += 1
			if _hunt_elites_total > 0:
				var killed := maxi(0, _hunt_elites_total - alive_elites)
				var reward := maxi(10, int(round(float(wave) * 20.0
					* float(killed) / float(_hunt_elites_total))))
				GameState.add_materials(reward)
				EventBus.banner_requested.emit("⚔ 狩猎结算",
					"击杀 %d/%d 精英 · 奖励 %d ◆" % [killed, _hunt_elites_total, reward], 2.4)
		"meteor":
			# 流星雨撑过即奖励（波次 × 12 材料）
			var reward_m := wave * 12
			GameState.add_materials(reward_m)
			EventBus.banner_requested.emit("☄ 撑过流星雨",
				"奖励 %d ◆" % reward_m, 2.2)

## 刷怪：玩家视野外一圈、世界边界内（原型 12 次尝试，距玩家 >420）
## is_elite：标记为精英实例（影响法宝掉落）；默认 false，
## BOSS 波干扰怪与调试快捷键（main.gd KEY_6/KEY_7）沿用单参调用
func spawn(type: String, is_elite: bool = false) -> void:
	if not Registry.enemies.has(type):
		push_warning("WaveManager: 未知敌人 ID，跳过生成：" + type)
		return
	var e := EnemyScene.instantiate()
	e.setup(type, wave)
	e.elite = is_elite
	var view := get_viewport().get_visible_rect().size
	var base_r := maxf(view.x, view.y) * 0.62
	var pos := Vector2.ZERO
	for _t in 12:
		var rr := base_r + GameRng.range_f(40.0, 160.0)
		pos = player.global_position + Vector2.from_angle(GameRng.next() * TAU) * rr
		pos = pos.clamp(Vector2(40.0, 40.0),
			Vector2(Config.WORLD.w, Config.WORLD.h) - Vector2(40.0, 40.0))
		if pos.distance_squared_to(player.global_position) > 420.0 * 420.0:
			break
	e.position = pos
	get_parent().add_child(e)
	e.player = player
	if e.is_boss():
		boss = e

func _clear_projectiles() -> void:
	for group in ["enemy_bullets", "player_bullets"]:
		for projectile in get_tree().get_nodes_in_group(group):
			projectile.queue_free()

## 存活敌人计数；exclude_boss=true 时不含 BOSS（BOSS 波干扰怪上限用）
func _alive_count(exclude_boss: bool) -> int:
	var count := 0
	for e in get_tree().get_nodes_in_group("enemies"):
		if e.flee > 0.0:
			continue
		if exclude_boss and e.is_boss():
			continue
		count += 1
	return count
