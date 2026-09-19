extends Node2D
class_name TerrainZone
## 场景属性地形区域（第 9 轮引入 · 第 16 轮按用户需求 6 重做为「全体增益区」）
##
## 【规则】
##   · 每 4 波（= 一个区块，`Config.block_of`）**新增**一片地形，元素 = 本区区域元素
##     （`Config.wave_area_element`）→ 「这块地是什么属性」与横幅/出怪加权自洽。
##   · 旧区**不销毁**：`main._terrain_zones` 累积持有，场景轮转后之前的地形仍在
##     （第 16 轮 · 用户原话「场景轮转后，之前的区域不消失」）。
##   · 圆心位置是 `(玩家元素, 区块号)` 的**纯函数**（`Config.terrain_zone_for_wave`），
##     不用随机数 → 读档重进同一波、每日挑战全服，看到的都是同一片区域。
##   · 圆内**任何单位**（玩家 / 普通怪 / BOSS）都获得本区 `Config.ZONE_BUFFS` 的那套增益，
##     **与五行无关** —— 第 16 轮取消了旧版「怪物须与本区同元素才吃抗性」的筛选。
##   · 离区即撤销（进出可逆）；本波结束由 `main._suspend_terrain_buffs()` 统一撤销。
##
## 【多区重叠】区域会累积，玩家/怪可能同时站在两片地里 —— 所以两侧的写入口都是
##   **按 `zone_id` 记槽位**（`player.set_zone_buff` / `enemy.set_zone_buff`），由宿主把
##   所有生效区求和后再落地。若每个区各自往属性上加一笔，重叠时会重复累加、
##   离区时又会把别的区的量撤掉（顺序相关、且不报错）。
##
## 【图层】
##   `z_index = 0` 且由 main 插成**第一个子节点** → 画在背景网格之上、敌人之下。
##   （铁律 3：新视觉元素必须显式声明 z_index；这里刻意不进 `fx` 组也不吃特效预算 ——
##     它是常驻地面，不是一次性特效。）

## 扫描节流：0.35s 一次。与 BOSS 光环（`enemy._refresh_boss_aura`）同一口径 ——
## 距离判定不需要每帧，反复写属性/抗性反而会白算。
const SCAN_INTERVAL := 0.35

var element := ""
var radius := 260.0
var buff: Dictionary = {}   # 本区增益 = Config.ZONE_BUFFS[element]（玩家侧 + 敌人侧两套）
## 本区唯一 id（由 main 按区块号写入，如 "blk3"）：两侧槽位表的键。
## ⚠️ 不能用元素当 id —— 无尽局区块会循环，同一元素的地形会在不同位置各有一片。
var zone_id := ""
var player  # characters/player.gd 引用，由 main 注入（项目里玩家不在任何组，只能注入）

var _t := 0.0
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
	buff = (z.get("buff", {}) as Dictionary).duplicate(true)
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
	# ⚠️ 必须把 `ZONE_BUFFS[元素]` 拆成 `player` / `enemy` 两份**再**往下传。
	#    直接传整条会把 `name` / `desc`（字符串）和 `player` / `enemy`（子字典）一起
	#    塞进 `player._zone_buffs` / `enemy._zone_ids`，两侧的求和循环于是会对字符串和
	#    字典调 `float()` → 运行期 `Nonexistent 'float' constructor` 刷屏，**增益一条也落不了地**
	#    （`player.active_buffs()` 又把这份脏字典喂给悬浮详情卡的 `EntryText.effect_lines`，
	#     同一根因再报一次）。冒烟当时没抓到：它直接调 `set_zone_buff` 传手搓字典，
	#    绕过了本函数 —— 真实路径的覆盖已补进 `smoke_test._check_round9_boss_terrain` 的 7c 段。
	var pbuff: Dictionary = buff.get("player", {})
	var ebuff: Dictionary = buff.get("enemy", {})
	if player != null and is_instance_valid(player):
		var p_in: bool = player.global_position.distance_to(global_position) <= radius
		# 一直在区内也要每轮写一次：写入口自己带"无变化直接返回"，这里不必先判重
		player.set_zone_buff(zone_id, pbuff if p_in else {}, element)
	for node in get_tree().get_nodes_in_group("enemies"):
		# 用 has_method 兼作「它是不是 Enemy」的判据（同 `_refresh_boss_aura` 的理由：
		# `get_nodes_in_group` 返回 Array[Node]，直接点 .element 静态类型会编译报错）
		if not node.has_method("set_zone_buff"):
			continue
		var n2 := node as Node2D
		if n2 == null:
			continue
		var inside: bool = n2.global_position.distance_to(global_position) <= radius
		node.call("set_zone_buff", zone_id, ebuff if inside else {})

## 同步撤销本区给玩家/怪物加的全部临时增益。由 `main._suspend_terrain_buffs` 在
## 「本波结束 / 即将写档」的路径上调用（区域节点本身保留，下一波扫描会重新写入）。
##
## ⚠️ 刻意与 `_exit_tree` 分开、而不是只写 `_exit_tree`：
##    存档写在波末，而 `queue_free()` 的 `_exit_tree` 要等到**本帧末**才跑 ——
##    在写档那一刻临时增益还挂在身上，会被 `SaveRun.save()` 当成永久属性镀进档，且不报错。
func clear() -> void:
	_cleared = true
	if player != null and is_instance_valid(player):
		player.set_zone_buff(zone_id, {})
	for node in get_tree().get_nodes_in_group("enemies"):
		if node.has_method("set_zone_buff"):
			node.call("set_zone_buff", zone_id, {})

## 节点被销毁时兜底撤销（正常情况下 main 已经先显式 `clear()` 过，这里判重跳过）。
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
	# 中心文字：元素名 + 增益名 + 增益内容 —— 玩家一眼知道"站进去会发生什么"。
	# 第 16 轮起它不再只是"这片地什么属性"，而是"双方都能吃到的增益"，
	# 所以必须把**增益**写出来，否则玩家只能靠猜。
	var f := ThemeDB.fallback_font
	if f == null:
		return
	var title := String(Config.ELEMENT_NAME.get(element, element))
	var bname := String(buff.get("name", ""))
	if bname != "":
		title += " · " + bname
	var w := f.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, 26).x
	draw_string(f, Vector2(-w * 0.5, 9.0), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 26,
		Color(col.r, col.g, col.b, 0.42))
	var desc := String(buff.get("desc", ""))
	if desc != "":
		var w2 := f.get_string_size(desc, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
		draw_string(f, Vector2(-w2 * 0.5, 32.0), desc, HORIZONTAL_ALIGNMENT_LEFT, -1, 18,
			Color(col.r, col.g, col.b, 0.32))