class_name Combat
extends RefCounted
## 战斗工具（无状态静态函数；不依赖 autoload，便于任何上下文调用）

## 最近敌人（对应原型 nearestEnemy；后续加入逃跑敌人时在此过滤）
static func nearest_enemy(from: Vector2) -> Node2D:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var best: Node2D = null
	var best_d := INF
	for node in tree.get_nodes_in_group("enemies"):
		if node == null or node.flee > 0.0:
			continue
		var e := node as Node2D
		if e == null:
			continue
		var d := from.distance_to(e.global_position)
		if d < best_d:
			best_d = d
			best = e
	return best
