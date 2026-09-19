extends Node
## 自动对局机器人（A/B 平衡对照用 · 2026-09-19）
##
## 用途：用同一批 seed 跑「新曲线 / 旧曲线」两版，逐波对比生存压力到底差多少。
## 它是一个**中等水平的真人替身**：会走位躲怪、靠近拾取掉落、买商店、选升级，
## 但不会瞬移 / 不会无敌 / 不会用调试后门。
##
## 运行（先杀干净其它 Godot 进程）：
##   godot --headless --fixed-fps 60 --path game res://tools/autoplay.tscn \
##         -- --seed=28 --tag=A --out=%TEMP%\autoplay_A_28.json
##
## ⚠️ 刻意**不改** `Engine.time_scale`（固定 60fps 的 delta 才是真值）；
##    改 time_scale 会放大 delta → 接触判定 / 伤害结算全部失真，对照就失去意义。
##
## ⚠️ 存档 / 平衡日志全部走 `set_storage_root_for_tests()` 隔离，
##    MetaProgress / CodexData / Unlocks / PlatformAchievements / RunTrace 也一并隔离，
##    绝不写玩家真实档（见 tests/smoke_test.gd 的同款套路）。
##
## 数据来源：逐波 `taken` / `hp_min` / `kills` / `level` / `armor` / `dodge`
## 全部取自游戏自身的 `BalanceLog`（每波落盘的真值），机器人只做汇总转发，
## 不自己重算伤害 —— 保证「日志里的数 == 游戏认定的数」。

## 升级卡各属性权重（越看重越优先）。
## 只影响「选哪张卡」，不影响战斗数值，因此不会污染 A/B 对照。
const STAT_WEIGHT := {
	"dmg_mult": 3.0, "as_mult": 3.0, "max_hp": 2.5, "armor": 2.2, "dodge": 2.0,
	"speed_mult": 1.8, "regen": 1.6, "crit_ch": 1.4, "crit_mult": 1.2, "lifesteal": 1.5,
	"status_chance": 0.8, "status_dmg_mult": 0.8, "momentum_dmg_bonus": 1.0,
	"pickup_range": 0.4, "harvesting": 0.3,
}

var main = null                 # res://scenes/main.tscn 实例
var player = null               # main.player（Variant：动态点属性，避免静态类型报错）

var run_seed := 0
var tag := "A"
var out_path := ""
var max_sim_seconds := 4000.0   # 模拟时长上限（游戏内秒）——通关不了时的兜底
var wall_limit_ms := 900000     # 墙钟上限（毫秒）——卡死兜底

var _waves: Array = []
var _seen_waves := 0
var _finished := false
var _end_reason := ""
var _shop_key := -1
var _skill_cd := 0.0
var _poll_t := 0.0
var _start_ms := 0
## 诊断开关（默认关；只为定位「同 seed 不可重复」的根因，不影响正常跑测）
var _diag_nomove := false      # 站桩不走位
var _diag_noskill := false     # 不放技能
var _diag_noai := false        # 不消费任何 UI（升级/商店），只观察纯战斗
var _diag_trace := false       # 打印每次关键决策的 (帧号, run_time, 选择)

func _ready() -> void:
	_start_ms = Time.get_ticks_msec()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			run_seed = int(arg.trim_prefix("--seed=")) & 0xFFFFFFFF
		elif arg.begins_with("--tag="):
			tag = arg.trim_prefix("--tag=")
		elif arg.begins_with("--out="):
			out_path = arg.trim_prefix("--out=").replace("\\", "/")
		elif arg.begins_with("--maxtime="):
			max_sim_seconds = float(arg.trim_prefix("--maxtime="))
		elif arg == "--nomove":
			_diag_nomove = true
		elif arg == "--noskill":
			_diag_noskill = true
		elif arg == "--noai":
			_diag_noai = true
		elif arg == "--trace":
			_diag_trace = true
	if out_path == "":
		out_path = "user://autoplay_%s_%d.json" % [tag, run_seed]

	_setup_isolation()
	_configure_run()

	main = preload("res://scenes/main.tscn").instantiate()
	add_child(main)
	player = main.player
	EventBus.run_ended.connect(_on_run_ended)
	print("[autoplay] start tag=%s seed=%d out=%s" % [tag, run_seed, out_path])

## 隔离所有会落盘的局外数据，保证测试局不碰玩家真实存档 / 天赋 / 日志
func _setup_isolation() -> void:
	var root := "user://autoplay/%s_%d" % [tag, run_seed]
	SaveRun.set_storage_root_for_tests(root)
	BalanceLog.set_storage_root_for_tests(root)
	RunTrace.set_dir_for_tests(root + "/run_trace/")
	MetaProgress.set_storage_path_for_tests(root + "/meta_progress.json")
	MetaProgress.reset_for_tests()          # 清掉局外天赋，A/B 两边同为白板开局
	CodexData.set_storage_path_for_tests(root + "/codex_data.json")
	PlatformAchievements.set_storage_path_for_tests(root + "/steam_pending.json")
	Unlocks.set_storage_path_for_tests(root + "/unlocks.json")
	# 上一轮同 seed 跑过的平衡日志必须清掉，否则会把旧波次当成新数据读进来
	var stale := BalanceLog.path()
	if FileAccess.file_exists(stale):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(stale))

## 钉死「标准局 / normal 难度 / 白板角色」——A/B 唯一变量只有伤害曲线
func _configure_run() -> void:
	GameState.difficulty_id = "normal"
	GameState.character_id = "potato"
	GameState.endless = false
	GameState.daily = false
	GameState.continue_pending = false
	GameState.loadout_weapon = ""     # 回落到 Config.FALLBACK_WEAPON
	GameState.loadout_item = ""
	GameState.slot_id = 1
	GameRng.seed_from(run_seed)       # main._ready 里也会再解析一次 --seed，幂等

func _process(_delta: float) -> void:
	# ⚠️⚠️ 这里刻意**不做事**：所有驱动都放 `_physics_process`（固定 60Hz）。
	#    `_process` 是**渲染帧**回调，`--fixed-fps 60` 只固定物理帧，`_process` 的实际
	#    调用次数仍随真实运行速度漂移（headless 下尤其明显）。曾把 UI 消费/采样放在
	#    这里，导致**同一个 seed 连跑三次得到三个不同结果**（W1 就分叉）——
	#    A/B 对照因此失效。UI 消费时机直接决定波次推进节奏，必须钉在物理帧上。
	pass

func _physics_process(delta: float) -> void:
	if _finished:
		return
	if main == null or not is_instance_valid(main):
		return
	# 采样按物理帧累计（0.2 游戏秒），不再依赖墙钟
	_poll_t -= delta
	if _poll_t <= 0.0:
		_poll_t = 0.2
		_harvest_waves()
	if not _diag_noai:
		_handle_ui()
	if not _diag_nomove:
		_drive_movement()
	else:
		GameState.touch_move = Vector2.ZERO
	_skill_cd -= delta
	if _skill_cd <= 0.0 and not _diag_noskill:
		_skill_cd = 1.5
		if GameState.phase == GameState.Phase.PLAYING and player != null \
				and is_instance_valid(player):
			player.cast_skill()
	# 兜底：通关不了 / 卡在某个界面时，靠模拟时长与墙钟双双兜住
	if GameState.run_time > max_sim_seconds:
		_finish("timeout")
	elif Time.get_ticks_msec() - _start_ms > wall_limit_ms:
		_finish("watchdog")

# ------------------------------------------------------------
# 移动：躲最近怪 + 靠墙回中 + 有掉落时去捡（一个中等水平真人的走位）
# ------------------------------------------------------------

func _drive_movement() -> void:
	if GameState.phase != GameState.Phase.PLAYING or player == null \
			or not is_instance_valid(player):
		GameState.touch_move = Vector2.ZERO
		return
	var pos: Vector2 = player.global_position
	var world := Vector2(Config.WORLD.w, Config.WORLD.h)

	# 威胁斥力：离得越近推得越狠
	var flee := Vector2.ZERO
	var nearest_enemy := 999999.0
	for e in get_tree().get_nodes_in_group("enemies"):
		var n := e as Node2D
		if n == null or float(n.get("flee")) > 0.0:
			continue
		var d: Vector2 = pos - n.global_position
		var dist := d.length()
		if dist < nearest_enemy:
			nearest_enemy = dist
		if dist < 240.0 and dist > 0.01:
			var w := (240.0 - dist) / 240.0
			flee += (d / dist) * w * w

	# 墙边斥力（避免被怪推到角里贴墙挨打）
	var m := 120.0
	if pos.x < m:
		flee.x += (m - pos.x) / m
	elif pos.x > world.x - m:
		flee.x -= (m - (world.x - pos.x)) / m
	if pos.y < m:
		flee.y += (m - pos.y) / m
	elif pos.y > world.y - m:
		flee.y -= (m - (world.y - pos.y)) / m

	# 掉落物吸引（红心优先级最高）
	var loot_dir := Vector2.ZERO
	var loot_score := 999999.0
	for l in get_tree().get_nodes_in_group("loot"):
		var ln := l as Node2D
		if ln == null:
			continue
		var dd := pos.distance_to(ln.global_position)
		if dd > 520.0:
			continue
		var score := dd
		if String(ln.get("kind")) == "heart":
			score -= 400.0
		if score < loot_score:
			loot_score = score
			loot_dir = ln.global_position - pos

	var dir := Vector2.ZERO
	if nearest_enemy > 170.0 and loot_dir.length() > 8.0:
		dir = loot_dir.normalized()
	elif flee.length() > 0.02:
		dir = flee.normalized()
	elif loot_dir.length() > 8.0:
		dir = loot_dir.normalized()
	else:
		# 无威胁时绕场中心环游（保持移动，别站着被围）
		var center := world * 0.5
		var radial := pos - center
		if radial.length() < 1.0:
			radial = Vector2.RIGHT
		var rdir := radial.normalized()
		var desired := 0.32 * minf(world.x, world.y)
		var corr := clampf((radial.length() - desired) / desired, -1.0, 1.0)
		dir = (Vector2(-rdir.y, rdir.x) - rdir * corr).normalized()
	GameState.touch_move = dir.limit_length(1.0)

# ------------------------------------------------------------
# 打断弹窗消费：升级 / 进化 / 法宝盒子 / 奇遇 / 商店
# ------------------------------------------------------------

func _handle_ui() -> void:
	var level_up = main.level_up_ui
	if level_up != null and level_up.visible:
		_pick_level_up(level_up)
		return
	var evo = main.evolve_choose_ui
	if evo != null and evo.visible:
		_pick_evolve(evo)
		return
	var box = main.boss_box_ui
	if box != null and box.visible:
		var cs: Array = box.choices()
		if not cs.is_empty():
			box._choose(String(cs[0]))
		return
	var ev = main.event_card_ui
	if ev != null and ev.visible:
		var n: int = int(ev.choice_count())
		for i in n:
			if bool(ev.is_choice_enabled(i)):
				ev._choose(i)
				break
		return
	var shop = main.shop_ui
	if shop != null and shop.visible and GameState.phase == GameState.Phase.SHOP:
		_do_shop(shop)

## 升级三选一：按 STAT_WEIGHT 打分选最高的那张（打平选最靠前的）
func _pick_level_up(ui) -> void:
	var choices: Array = ui._choices
	if choices.is_empty():
		return
	var best := 0
	var best_score := -1.0
	for i in choices.size():
		var c = choices[i]
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var s := 0.0
		for key in ["effects", "stats"]:
			var d = c.get(key, {})
			if typeof(d) != TYPE_DICTIONARY:
				continue
			for k in d:
				s += float(STAT_WEIGHT.get(String(k), 0.5)) * absf(float(d[k]))
		if s > best_score:
			best_score = s
			best = i
	if _diag_trace:
		print("[trace] LEVELUP f=%d rt=%.4f lv=%d picked=%d/%d id=%s"
			% [Engine.get_physics_frames(), GameState.run_time, GameState.level,
				best, choices.size(), String((choices[best] as Dictionary).get("id", "?"))])
	ui._choose(best)

## 武器进化方向：取第一个注册表里存在的分支
func _pick_evolve(ui) -> void:
	var choice = ui._choice
	var branches: Array = []
	if typeof(choice) == TYPE_DICTIONARY:
		var b = choice.get("branches", [])
		if typeof(b) == TYPE_ARRAY:
			branches = b
	for b2 in branches:
		if Registry.weapons.has(String(b2)):
			ui._choose(String(b2))
			return
	if not branches.is_empty():
		ui._choose(String(branches[0]))

## 商店：买得起就买（满槽武器跳过，避免弹换装面板），缺血就回血，然后进下一波
func _do_shop(shop) -> void:
	var key := int(shop._wave)
	if key == _shop_key:
		return
	_shop_key = key
	var goods: Array = shop.goods
	if _diag_trace:
		print("[trace] SHOP f=%d rt=%.4f wave=%d mats=%d goods=%d hp=%.1f"
			% [Engine.get_physics_frames(), GameState.run_time, key,
				GameState.materials, goods.size(), float(player.hp)])
	for i in goods.size():
		var g = goods[i]
		if typeof(g) != TYPE_DICTIONARY or bool(g.get("sold", false)):
			continue
		var price := int(shop._price_of(g))
		if GameState.materials < price:
			continue
		if String(g.get("kind", "")) == "weapon" and bool(player.weapon_capacity_full()):
			continue   # 满槽点武器会弹「换掉哪把」，机器人不走这条支线
		shop.buy(i)
	if float(player.hp) < float(player.stats.max_hp) * 0.6:
		shop.heal()
	shop.next_wave()

# ------------------------------------------------------------
# 逐波数据汇总 + 落盘
# ------------------------------------------------------------

## BalanceLog 每波落盘时都会重写整份历史；这里增量读取新增条目
func _harvest_waves() -> void:
	var p := BalanceLog.path()
	if not FileAccess.file_exists(p):
		return
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var waves = parsed.get("waves", [])
	if typeof(waves) != TYPE_ARRAY:
		return
	if waves.size() <= _seen_waves:
		return
	for i in range(_seen_waves, waves.size()):
		_waves.append(_map_wave(waves[i]))
	_seen_waves = waves.size()

func _map_wave(e) -> Dictionary:
	if typeof(e) != TYPE_DICTIONARY:
		return {}
	var w := int(e.get("wave", 0))
	var st = e.get("stats", {})
	if typeof(st) != TYPE_DICTIONARY:
		st = {}
	return {
		"wave": w,
		"outcome": String(e.get("outcome", "")),
		"taken": float(e.get("damage_taken", 0.0)),
		"hp_min": float(e.get("hp_min", 0.0)),
		"hp_max": float(e.get("hp_max", 0.0)),
		"hp_end": float(e.get("hp", 0.0)),
		"kills": int(e.get("kills", 0)),
		"level": int(e.get("level", 0)),
		"armor": float(st.get("armor", 0.0)),
		"dodge": float(st.get("dodge", 0.0)),
		"boss": bool(w >= 20 or w % 4 == 0),
		"duration": float(e.get("duration", 0.0)),
	}

func _on_run_ended(victory: bool) -> void:
	_finish("victory" if victory else "death")

func _finish(reason: String) -> void:
	if _finished:
		return
	_finished = true
	_end_reason = reason
	_harvest_waves()
	var max_hp := 0.0
	var final_hp := 0.0
	if not _waves.is_empty():
		var last: Dictionary = _waves[_waves.size() - 1]
		max_hp = float(last.get("hp_max", 0.0))
		final_hp = float(last.get("hp_end", 0.0))
	var result := {
		"tag": tag,
		"seed": run_seed,
		"difficulty": "normal",
		"outcome": reason,
		"death_wave": _death_wave(reason),
		"waves_played": _waves.size(),
		"max_hp": max_hp,
		"final_hp": final_hp,
		"final_level": GameState.level,
		"final_kills": GameState.kills,
		"run_time": GameState.run_time,
		"waves": _waves,
	}
	var abs_out := ProjectSettings.globalize_path(out_path)
	var f := FileAccess.open(abs_out, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(result, "\t"))
		f.flush()
		f.close()
	print("[autoplay] result outcome=%s waves=%d max_hp=%.1f final_hp=%.1f level=%d kills=%d"
		% [reason, _waves.size(), max_hp, final_hp, GameState.level, GameState.kills])
	for w in _waves:
		print("[autoplay-wave] w=%d taken=%.1f hp_min=%.1f kills=%d lv=%d armor=%.1f dodge=%.2f boss=%s"
			% [int(w.wave), float(w.taken), float(w.hp_min), int(w.kills), int(w.level),
				float(w.armor), float(w.dodge), str(bool(w.boss))])
	get_tree().quit(0)

func _death_wave(reason: String) -> int:
	if reason != "death":
		return -1
	if _waves.is_empty():
		return int(main.wave_manager.wave) if main != null and is_instance_valid(main) else -1
	var last: Dictionary = _waves[_waves.size() - 1]
	return int(last.get("wave", -1))