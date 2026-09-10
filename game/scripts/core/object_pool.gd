class_name ObjectPool
## 通用节点对象池：高频实例化的节点走这里复用，避免频繁 instantiate + queue_free
## 的分配开销（移动端低端机 / 极端弹幕场景下，这是 GC 峰值卡顿的主要来源）。
##
## 用法：
##   var node = ObjectPool.acquire("bullet", BulletScene, parent)  # 取一个（复用或新建），已 add_child
##   ObjectPool.release("bullet", node)                            # 归还（立即移出场景树）
##
## 设计约定：
## - 方法名刻意避开 Object 原生方法（`get` 会覆盖 Object.get 而报错），用 acquire / release。
## - key 是字符串，不由场景路径推导 —— 脚本里 preload("自己的.tscn") 会形成资源循环引用。
## - 归还 = remove_child（而非 queue_free），所以 get_nodes_in_group 这类
##   「只统计在树中节点」的接口不会把池里的节点算进去。
## - 状态重置由各节点的 setup() 负责：池只负责进出树，不臆测节点怎么复位。
##   因此接入池化的节点，其 setup 必须完整重置所有运行时字段（含 group 成员关系）。
## - 每池有上限（POOL_CAP），超出直接销毁，防止内存无限膨胀。

const POOL_CAP := 256

static var _pools: Dictionary = {}   # key -> Array[Node]

## 返回 Variant（不标类型）：调用方用 `var x = ...` 接收，才能动态调用各节点自定义的
## setup 而不触发「Node 无此方法」的静态报错
static func acquire(key: String, scene: PackedScene, parent: Node):
	var stack: Array = _pools.get(key, [])
	var node: Node = null
	if stack.is_empty():
		node = scene.instantiate()
	else:
		node = stack.pop_back() as Node
	if node != null:
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		parent.add_child(node)
	return node

static func release(key: String, node: Node) -> void:
	if not is_instance_valid(node):
		return
	if node.get_parent() != null:
		node.get_parent().remove_child(node)
	var stack: Array = _pools.get(key, [])
	if stack.size() < POOL_CAP:
		stack.append(node)
		_pools[key] = stack
	else:
		node.queue_free()

## 清空所有池（测试隔离用）
static func clear() -> void:
	for key in _pools:
		for n in _pools[key]:
			if is_instance_valid(n):
				n.queue_free()
	_pools.clear()

## 池中当前空闲节点总数（测试观测 / 诊断用）
static func idle_count() -> int:
	var c := 0
	for key in _pools:
		c += _pools[key].size()
	return c
