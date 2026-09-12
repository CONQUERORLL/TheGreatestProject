class_name Obstacles
extends RefCounted
## 地图障碍物（Phase 5）：一波内静止的不可破坏阻挡物。
##
## 架构说明（重要）：本项目没有使用 Godot 物理引擎——
##   · player 用 CharacterBody2D 但直接写 global_position，从不调用 move_and_slide
##   · enemy 是普通 Node2D，靠手写分离（Combat 空间索引）
##   · 子弹是 Node2D，用 Combat 线段扫掠命中
## 所以障碍物不能用 StaticBody2D（放进场里既挡不住移动也挡不住子弹）。
## 这里改用等价实现：纯数据 + 静态网格索引 + 解析几何判定。
##   · main 每波调用 rebuild() 写入本波障碍物（一波内不变，索引只建一次）
##   · 移动端调用 resolve_circle() 把实体推出障碍物
##   · 弹丸端调用 first_block_t() 做线段遮挡查询
##
## 网格单元与 Combat 同为 128px；每个障碍物按自身包围盒写入所有覆盖到的单元，
## 因此「查询圆/线段覆盖的单元」即可保证不漏（圆-圆相交 ⟺ 两包围盒在 x/y 上都重叠）。

const CELL_SIZE := 128.0
const MAX_QUERY_CELLS := 4096
const RESOLVE_PASSES := 3   # 推出迭代趟数：处理夹在两块障碍物之间的情况

static var _list: Array = []       # [{ "pos": Vector2, "r": float, "kind": String }]
static var _grid: Dictionary = {}  # Vector2i -> Array[int]（_list 下标）
static var _max_r := 0.0

# ---------------- 生命期 ----------------

static func clear() -> void:
	_list = []
	_grid = {}
	_max_r = 0.0

## 用一批 { pos, r?, kind } 重建本波障碍物（r 缺省取外观半径）
## 返回「被拒条目数」：非法条目（非字典 / r<=0 / 非有限坐标）会被静默跳过，
## 若不把这个数量暴露出来，调用方会以为「要了 N 块就有 N 块」，
## 而实际可能更少 —— smoke_test 依赖 count() 断言，那种偏差会变成假通过。
static func rebuild(entries: Array) -> int:
	clear()
	var rejected := 0
	for e in entries:
		if typeof(e) != TYPE_DICTIONARY:
			rejected += 1
			continue
		var kind := String(e.get("kind", "bamboo"))
		var r := float(e.get("r", Obstacle.radius(kind)))
		if r <= 0.0 or not is_finite(r):
			rejected += 1
			continue
		var pos: Vector2 = e.get("pos", Vector2.ZERO)
		if not is_finite(pos.x) or not is_finite(pos.y):
			rejected += 1
			continue
		var idx := _list.size()
		_list.append({ "pos": pos, "r": r, "kind": kind })
		_max_r = maxf(_max_r, r)
		var min_cell := _cell_for(pos - Vector2(r, r))
		var max_cell := _cell_for(pos + Vector2(r, r))
		for x in range(min_cell.x, max_cell.x + 1):
			for y in range(min_cell.y, max_cell.y + 1):
				var key := Vector2i(x, y)
				if not _grid.has(key):
					_grid[key] = []
				_grid[key].append(idx)
	if rejected > 0:
		push_warning("[Obstacles] rebuild 拒绝了 %d 条非法障碍物条目（共 %d 条）"
			% [rejected, entries.size()])
	return rejected

static func count() -> int:
	return _list.size()

static func is_empty() -> bool:
	return _list.is_empty()

## 只读快照（测试/调试用；改动不会回流到内部索引）
static func entries() -> Array:
	return _list.duplicate(true)

static func max_radius() -> float:
	return _max_r

# ---------------- 查询 ----------------

static func _cell_for(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / CELL_SIZE), floori(pos.y / CELL_SIZE))

## 收集可能命中 (center, radius) 的障碍物下标（去重）
static func _candidates(center: Vector2, radius: float) -> Array:
	var out: Array = []
	if _grid.is_empty():
		return out
	if not is_finite(radius):
		return out
	var min_cell := _cell_for(center - Vector2(radius, radius))
	var max_cell := _cell_for(center + Vector2(radius, radius))
	var cell_count := float(max_cell.x - min_cell.x + 1) * float(max_cell.y - min_cell.y + 1)
	if cell_count > MAX_QUERY_CELLS:
		for i in _list.size():
			out.append(i)
		return out
	var seen := {}
	for x in range(min_cell.x, max_cell.x + 1):
		for y in range(min_cell.y, max_cell.y + 1):
			for idx in _grid.get(Vector2i(x, y), []):
				if seen.has(idx):
					continue
				seen[idx] = true
				out.append(idx)
	return out

## 圆 (center, radius) 是否与任一障碍物相交
static func overlaps_circle(center: Vector2, radius: float) -> bool:
	for idx in _candidates(center, radius + _max_r):
		var o: Dictionary = _list[idx]
		if center.distance_squared_to(o.pos) < pow(float(o.r) + radius, 2.0):
			return true
	return false

## 把半径 radius 的实体推出全部重叠障碍物，返回修正后的位置。
## 多趟迭代处理「夹在两块障碍物之间」；密度固定为每波 30~50 块，
## 趟数与候选数都是常数级，不随敌人数量放大。
static func resolve_circle(pos: Vector2, radius: float) -> Vector2:
	if _list.is_empty():
		return pos
	var p := pos
	for _pass in RESOLVE_PASSES:
		var moved := false
		for idx in _candidates(p, radius + _max_r):
			var o: Dictionary = _list[idx]
			var oc: Vector2 = o.pos
			var min_d: float = float(o.r) + radius
			var d := p - oc
			var dist := d.length()
			if dist >= min_d:
				continue
			if dist <= 0.0001:
				p = oc + Vector2(min_d, 0.0)   # 圆心完全重合：定方向推出，避免除零
			else:
				p = oc + d / dist * min_d
			moved = true
		if not moved:
			break
	return p

## 线段 (from → to) 首次被障碍物挡住的位置参数 t（0..1）；未挡住返回 INF。
static func first_block_t(from: Vector2, to: Vector2, radius: float) -> float:
	if _list.is_empty():
		return INF
	var mid := (from + to) * 0.5
	var query_r := from.distance_to(to) * 0.5 + radius + _max_r
	var best := INF
	for idx in _candidates(mid, query_r):
		var o: Dictionary = _list[idx]
		var t := _segment_circle_entry_t(from, to, o.pos, float(o.r) + radius)
		if t < best:
			best = t
	return best

## 两点的连线是否被障碍物挡住（视线判定）
static func has_los(from: Vector2, to: Vector2, radius: float = 4.0) -> bool:
	return not is_finite(first_block_t(from, to, radius))

## 线段首次进入圆的参数 t（0..1）；不相交返回 INF。
##
## ⚠ 等价性契约：这是 Combat.segment_circle_entry_t 的刻意副本 ——
## Combat 需要调用本文件的 has_los，两边互相引用会形成 class_name 循环依赖，
## 因此只能各留一份实现。两者必须永远返回相同结果。
## 改这里就改那边；smoke_test 的「线段求交等价性」断言会守住这条约束。
static func _segment_circle_entry_t(from: Vector2, to: Vector2, center: Vector2, radius: float) -> float:
	var delta := to - from
	var rel := from - center
	var radius_sq := radius * radius
	if rel.length_squared() <= radius_sq:
		return 0.0
	var a := delta.length_squared()
	if a <= 0.000001:
		return INF
	var b := 2.0 * rel.dot(delta)
	var c := rel.length_squared() - radius_sq
	var discriminant := b * b - 4.0 * a * c
	if discriminant < 0.0:
		return INF
	var entry_t := (-b - sqrt(discriminant)) / (2.0 * a)
	return entry_t if entry_t >= 0.0 and entry_t <= 1.0 else INF

# ---------------- 绘制 ----------------

## 在 canvas（main 的 _draw）里一次性画完全部障碍物。
## 集中绘制而不是每个障碍物一个节点：30~50 次 draw 调用合并在一遍过，
## 静态内容由 CanvasItem 缓存，不产生逐帧开销。
static func draw_all(canvas: CanvasItem) -> void:
	for o in _list:
		Obstacle.draw_one(canvas, o.pos, String(o.kind))
