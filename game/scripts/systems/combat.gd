class_name Combat
extends RefCounted
## 每物理帧构建一次敌人空间索引，供索敌、弹丸、近战、爆炸和分离复用。

const CELL_SIZE := 128.0
const MAX_ENTITY_RADIUS := 256.0
const MAX_QUERY_CELLS := 4096
const MAX_GRID_QUERY_RADIUS := 4000.0

static var _cache_frame := -1
static var _grid: Dictionary = {}
static var _enemies: Array = []
static var _enemy_cells: Dictionary = {}

static func _ensure_index() -> void:
	var frame := Engine.get_physics_frames()
	if frame == _cache_frame:
		return
	_cache_frame = frame
	_grid = {}
	_enemies = []
	_enemy_cells = {}
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for node in tree.get_nodes_in_group("enemies"):
		if node == null or not is_instance_valid(node) or node.is_queued_for_deletion() or node.flee > 0.0:
			continue
		var enemy := node as Node2D
		if enemy == null:
			continue
		_enemies.append(enemy)
		var cell := _cell_for(enemy.global_position)
		_enemy_cells[enemy.get_instance_id()] = cell
		if not _grid.has(cell):
			_grid[cell] = []
		_grid[cell].append(enemy)

static func _cell_for(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / CELL_SIZE), floori(pos.y / CELL_SIZE))

## 敌人移动或分离后更新当前帧桶，避免后续查询使用旧位置。
static func update_enemy_position(enemy: Node2D) -> void:
	_ensure_index()
	if enemy == null or not is_instance_valid(enemy):
		return
	var id := enemy.get_instance_id()
	var old_cell: Variant = _enemy_cells.get(id)
	if enemy.is_queued_for_deletion() or enemy.flee > 0.0:
		if old_cell != null and _grid.has(old_cell):
			_grid[old_cell].erase(enemy)
		_enemy_cells.erase(id)
		return
	var new_cell := _cell_for(enemy.global_position)
	if old_cell == new_cell:
		return
	if old_cell != null and _grid.has(old_cell):
		_grid[old_cell].erase(enemy)
		if _grid[old_cell].is_empty():
			_grid.erase(old_cell)
	if not _grid.has(new_cell):
		_grid[new_cell] = []
	_grid[new_cell].append(enemy)
	_enemy_cells[id] = new_cell

static func enemies_near(center: Vector2, radius: float) -> Array:
	_ensure_index()
	var result: Array = []
	if not is_finite(radius) or radius < 0.0:
		return result
	if radius > MAX_GRID_QUERY_RADIUS:
		for enemy in _enemies:
			if is_instance_valid(enemy) and not enemy.is_queued_for_deletion():
				result.append(enemy)
		return result
	var min_cell := _cell_for(center - Vector2(radius, radius))
	var max_cell := _cell_for(center + Vector2(radius, radius))
	var cell_count := float(max_cell.x - min_cell.x + 1) * float(max_cell.y - min_cell.y + 1)
	if cell_count > MAX_QUERY_CELLS:
		for enemy in _enemies:
			if is_instance_valid(enemy) and not enemy.is_queued_for_deletion():
				result.append(enemy)
		return result
	for x in range(min_cell.x, max_cell.x + 1):
		for y in range(min_cell.y, max_cell.y + 1):
			for enemy in _grid.get(Vector2i(x, y), []):
				if is_instance_valid(enemy) and not enemy.is_queued_for_deletion():
					result.append(enemy)
	return result

static func nearest_enemy(from: Vector2) -> Node2D:
	_ensure_index()
	var best: Node2D = null
	var best_d_sq := INF
	for enemy in _enemies:
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
			continue
		var d_sq := from.distance_squared_to(enemy.global_position)
		if d_sq < best_d_sq:
			best_d_sq = d_sq
			best = enemy
	return best

## 最近的、且视线未被地图障碍物挡住的敌人（Phase 5）。
## 全部被挡住时退回最近的敌人，保证任何情况下都不会「有敌人在场却不开火」。
## 障碍物为空时 Obstacles.has_los 立即返回 true，等于退化成 nearest_enemy，零额外开销。
static func nearest_enemy_visible(from: Vector2, projectile_radius: float = 4.0) -> Node2D:
	_ensure_index()
	var best_vis: Node2D = null
	var best_vis_d := INF
	var best_any: Node2D = null
	var best_any_d := INF
	for enemy in _enemies:
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion() or enemy.flee > 0.0:
			continue
		var d_sq := from.distance_squared_to(enemy.global_position)
		if d_sq < best_any_d:
			best_any_d = d_sq
			best_any = enemy
		# 只有比当前最优可视目标更近时才做遮挡查询，正常情况每帧只查少数几次
		if d_sq < best_vis_d \
				and Obstacles.has_los(from, enemy.global_position, projectile_radius):
			best_vis_d = d_sq
			best_vis = enemy
	return best_vis if best_vis != null else best_any

static func first_enemy_hit_on_segment(from: Vector2, to: Vector2, projectile_radius: float) -> Dictionary:
	var midpoint := (from + to) * 0.5
	var query_radius := from.distance_to(to) * 0.5 + projectile_radius + MAX_ENTITY_RADIUS
	var best: Node2D = null
	var best_t := INF
	for enemy in enemies_near(midpoint, query_radius):
		if enemy.is_queued_for_deletion() or enemy.flee > 0.0:
			continue
		var hit_radius := projectile_radius + float(enemy.radius)
		var entry_t := segment_circle_entry_t(from, to, enemy.global_position, hit_radius)
		if entry_t < best_t:
			best_t = entry_t
			best = enemy
	if best == null:
		return {}
	return {"enemy": best, "t": best_t, "position": from.lerp(to, best_t)}

static func first_enemy_on_segment(from: Vector2, to: Vector2, projectile_radius: float) -> Node2D:
	var hit := first_enemy_hit_on_segment(from, to, projectile_radius)
	return hit.get("enemy") as Node2D

## 返回线段首次进入圆的参数 t（0..1）；不相交返回 INF。
##
## ⚠ 等价性契约：Obstacles._segment_circle_entry_t 是本函数的刻意副本
##   （Obstacles.has_los ← 本文件的 nearest_enemy_visible，反向调用会形成
##   class_name 循环依赖，故只能各留一份）。两者必须永远返回相同结果。
##   改这里就改那边；smoke_test 的「线段求交等价性」断言会守住这条约束。
static func segment_circle_entry_t(from: Vector2, to: Vector2, center: Vector2, radius: float) -> float:
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

static func segment_hits_circle(from: Vector2, to: Vector2, center: Vector2, radius: float) -> bool:
	return is_finite(segment_circle_entry_t(from, to, center, radius))
