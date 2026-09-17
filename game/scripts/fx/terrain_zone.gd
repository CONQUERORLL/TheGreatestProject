extends Node2D
class_name TerrainZone
## 场景属性地形区域（第 9 轮 · 用户需求 4：每 4 关新增一个场景属性地形区域）
##
## 【规则】
##   · 每 4 波（= 一个区块，`Config.block_of`）换一片地形，元素 = **本区区域元素**
##     （`Config.wave_area_element`）→ 「这块地是什么属性」与横幅/出怪加权自洽。
##   · 圆心位置是 `(玩家元素, 波次)` 的**纯函数**（`Config.terrain_zone_for_wave`），
##     不用随机数 → 读档重进同一波、每日挑战全服，看到的都是同一片区域。
##   · **玩家**站进区内 → 对该元素的同化度临时 +
##   · **怪物**站进区内且元素与本区相同 → 抗性临时 +
##   · 离区即撤销（进出可逆）。
##
## 【为什么与 `AREA_BONUS` 并存，而不是合并】
##   现有的「区域加成」（`main._grant_area_bonus`）是**区块级、进区首波一次性 +0.10 永久**
##   —— 它是养成轴（选择在哪个区深耕）。本类要的是**区块内一片有边界的临时区域**，
##   进出可逆、只有站在里面才生效。两者语义不同：一个是"这四波你在这个区"，一个是
##   "这四波里你要不要站到那片地里"。硬合并会同时破坏「一次性发放的幂等」与
##   「站进去才有用」两条规则，所以刻意分两套常量、两套代码。
##
## 【上限】
##   玩家侧：同化度叠加后仍受 `Config.apply_hit_mult` 的逐关系 cap（同属 0.90）与
##           `_sanitize_stats` 的 assim 上限 2.0 约束；本类另外把自身增量夹到
##           `Config.TERRAIN_ZONE_CAP`。
##   怪物侧：直接进 `Config.mob_resist` 的加法项 → 天然被 `_resist_cap()`（普通 0.75、
##           同属 BOSS 0.90）吃掉，这正是「加成不超过上限」。
##
## 【图层】
##   `z_index = 0` 且由 main 插成**第一个子节点** → 画在背景网格之上、敌人之下。
##   （铁律 3：新视觉元素必须显式声明 z_index；这里刻意不进 `fx` 组也不吃特效预算 ——
##     它是常驻地面，不是一次性特效。）

## 扫描节流：0.35s 一次。与 BOSS 光环（`enemy._refresh_boss_aura`）同一口径 ——
## 距离判定不需要每帧，频繁写 `refresh_element_resist()` 反而会白算抗性。
const SCAN_INTERVAL := 0.35

var element := ""
var radius := 260.0
var bonus := 0.15
var player  # characters/player.gd 引用，由 main 注入（项目里玩家不在任何组，只能注入）

var _t := 0.0
var _player_in := false
## 已显式 `clear()` 过（供 `_exit_tree` 判重）：避免"显式撤销 + 节点销毁"撤销两次。
var _cleared := false

## 按 `Config.terrain_zone_for_wave()` 的返回值配置自己（空字典 = 本波没有地形）
func configure(z: Dictionary) -> bool:
	if z.is_empty():
		return false
	element = String(z.get("element", ""))
	if element == "":
		return false
	radius = float(z.get("radius", 260.0))
	bonus = clampf(float(z.get("bonus", 0.15)), 0.0, float(z.get("cap", 0.30)))
	global_position = z.get("center", Vector2.ZERO)
	_t = 0.0
	queue_redraw()
	return true

func _physics_process(delta: float) -> void:
	# 只在战斗/入场阶段判定：商店、暂停、结算时玩家不会移动，扫了也是白扫
	if GameState.phase != GameState.Phase.PLAYING and GameState.phase != GameState.Phase.INTRO:
		return
	_t -= delta
	if _t > 0.0:
		return
	_t = SCAN_INTERVAL
	if player != null and is_instance_valid(player):
		var p_in: bool = player.global_position.distance_to(global_position) <= radius
		# 一直在区内也要每轮写一次：波次切换会改元素/数值，写入口自己带"无变化直接返回"
		player.set_zone_assim(element if p_in else "", bonus if p_in else 0.0)
		_player_in = p_in
	for node in get_tree().get_nodes_in_group("enemies"):
		# 用 has_method 兼作「它是不是 Enemy」的判据（同 `_refresh_boss_aura` 的理由：
		# `get_nodes_in_group` 返回 Array[Node]，直接点 .element 静态类型会编译报错）
		if not node.has_method("set_zone_bonus"):
			continue
		var n2 := node as Node2D
		if n2 == null:
			continue
		var want := 0.0
		if String(node.get("element")) == element \
				and n2.global_position.distance_to(global_position) <= radius:
			want = bonus
		# 写前比较（照抄 BOSS 光环）：避免每次扫描都重算一遍抗性
		if not is_equal_approx(float(node.get("zone_bonus")), want):
			node.call("set_zone_bonus", want)

## 同步撤销本区给玩家/怪物加的全部临时加成。由 `main._clear_terrain_zone` 在销毁前调用。
##
## ⚠️ 刻意与 `_exit_tree` 分开、而不是只写 `_exit_tree`：
##    `queue_free()` 的 `_exit_tree` 要等到**本帧末**才跑，而新建的那片地可能在本帧内
##    就已经把加成写了一遍 —— 旧区迟到的撤销会把新区的加成一并抹掉，
##    表现为「站进区里完全没有加成」，且不会报任何错。
func clear() -> void:
	_cleared = true
	_player_in = false
	if player != null and is_instance_valid(player):
		player.set_zone_assim("", 0.0)
	# 怪也一起撤：怪不像玩家那样有"重新扫描"的机会（本区节点已经没了），
	# 留着 zone_bonus 会变成一份凭空的抗性加成，直到它自己离场。
	for node in get_tree().get_nodes_in_group("enemies"):
		if not node.has_method("set_zone_bonus"):
			continue
		if not is_equal_approx(float(node.get("zone_bonus")), 0.0):
			node.call("set_zone_bonus", 0.0)

## 离开本波时把临时加成撤干净 —— 否则下一波（可能已经没有地形）会凭空多出一档
## 同化度/抗性，且**不会报错**。已经显式 `clear()` 过就不再重复撤销。
func _exit_tree() -> void:
	if not _cleared:
		clear()

func _draw() -> void:
	var col := Color(String(Config.ELEMENT_COLOR.get(element, "#ffffff")))
	# 地面填充：极低透明度（它是地面装饰，不能盖住怪与弹丸）
	draw_circle(Vector2.ZERO, radius, Color(col.r, col.g, col.b, 0.10))
	# 边界环：虚线感用内圈补足（draw_arc 不支持虚线，双层环比单环更像"领域"）
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 64, Color(col.r, col.g, col.b, 0.55), 3.0, true)
	draw_arc(Vector2.ZERO, radius - 10.0, 0.0, TAU, 64, Color(col.r, col.g, col.b, 0.18), 1.5, true)
	# 中心元素标记：写元素首字（玩家一眼知道"这片地是什么属性"）
	var f := ThemeDB.fallback_font
	if f != null:
		var txt := String(Config.ELEMENT_NAME.get(element, element))
		var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 26).x
		draw_string(f, Vector2(-w * 0.5, 9.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 26,
			Color(col.r, col.g, col.b, 0.35))
