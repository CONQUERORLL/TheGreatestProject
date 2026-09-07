extends Node
## 波次管理（移植自原型 startWave / updateWaves）
## 普通波：intro 横幅 → 按 interval 刷怪（受 cap 限制）→ waveTimer 到 →
##   敌人 flee 消散 + 清空敌方子弹（掉落物保留原位，不清不收）→ 清场后进入商店
## BOSS 波（第 10 波）：开场即刷 BOSS（不死不休），持续刷少量干扰怪

const EnemyScene := preload("res://scenes/enemies/enemy.tscn")

var wave := 0
var wave_timer := 0.0
var spawn_t := 0.0
var intro_t := 0.0
var ending_started := false
var boss: Node2D   # 当前 BOSS 引用（HUD 显示血量用；击杀后清空）
var player: Node2D

func _ready() -> void:
	EventBus.boss_killed.connect(_on_boss_killed)

func _on_boss_killed() -> void:
	boss = null

func start_wave(n: int) -> void:
	wave = clampi(n, 1, Config.WAVES_TOTAL)
	ending_started = false
	spawn_t = 0.6
	wave_timer = Config.wave_duration(wave)
	_clear_projectiles()
	# 玩家回到世界中心（原型 startWave 同款）
	player.global_position = Vector2(Config.WORLD.w, Config.WORLD.h) / 2.0
	player.velocity = Vector2.ZERO
	var is_boss_wave := wave == Config.BOSS_WAVE
	intro_t = 2.6 if is_boss_wave else 2.2
	GameState.set_phase(GameState.Phase.INTRO)
	if is_boss_wave:
		var bid := Registry.boss_id()
		spawn(bid)
		EventBus.banner_requested.emit("第 %d 波 · BOSS" % wave,
			Registry.enemies[bid].name + " 出现了！活下去并击败它！", 2.6)
	else:
		EventBus.banner_requested.emit("第 %d 波 / 共 %d 波" % [wave, Config.WAVES_TOTAL],
			"武器会自动攻击，专心走位", 2.2)
	EventBus.wave_started.emit(wave)

func _physics_process(delta: float) -> void:
	if GameState.phase == GameState.Phase.INTRO:
		intro_t -= delta
		if intro_t <= 0.0:
			GameState.set_phase(GameState.Phase.PLAYING)
		return
	if GameState.phase != GameState.Phase.PLAYING:
		return
	GameState.run_time += delta
	var is_boss_wave := wave == Config.BOSS_WAVE
	var diff: Dictionary = Registry.get_difficulty(GameState.difficulty_id)
	if not is_boss_wave:
		wave_timer -= delta
		spawn_t -= delta
		var cap := int(float(Config.wave_cap(wave)) * float(diff.spawn_mult))
		if wave_timer > 0.0 and spawn_t <= 0.0 and _alive_count(false) < cap:
			spawn_t = Config.wave_interval(wave) / float(diff.spawn_mult)
			spawn(String(GameRng.weighted_pick(Registry.wave_composition(wave))))
		if wave_timer <= 0.0 and not ending_started:
			ending_started = true
			# 时间到只执行一次：敌人退场，双方弹丸清空，掉落物跨波保留。
			for e in get_tree().get_nodes_in_group("enemies"):
				if e.flee <= 0.0:
					e.start_flee()
			_clear_projectiles()
	else:
		# BOSS 波：少量干扰小怪持续刷新，BOSS 不死不休
		spawn_t -= delta
		if spawn_t <= 0.0 and _alive_count(true) < 14:
			spawn_t = 2.4
			spawn("runner" if GameRng.chance(0.6) else "grunt")
	# 普通波：清场后进入商店（main 监听 wave_ended 打开；下一波由商店"下一波"触发）
	if not is_boss_wave and wave_timer <= 0.0 and _alive_count(false) == 0:
		EventBus.wave_ended.emit(wave)

## 刷怪：玩家视野外一圈、世界边界内（原型 12 次尝试，距玩家 >420）
func spawn(type: String) -> void:
	if not Registry.enemies.has(type):
		push_warning("WaveManager: 未知敌人 ID，跳过生成：" + type)
		return
	var e := EnemyScene.instantiate()
	e.setup(type, wave)
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
