extends Node
## 可复现随机数（mulberry32 算法，与 Web 原型位运算一致）
## 用法：GameRng.next() / range_f(a,b) / range_i(a,b) / pick(arr) / chance(p) / weighted_pick(list)
## 复现：启动参数加 `-- --seed=123`（与 Web 原型 ?seed=123 等价）

var _a: int = 0

func _ready() -> void:
	seed_from(int(Time.get_unix_time_from_system()) & 0xFFFFFFFF)

func seed_from(seed_value: int) -> void:
	_a = seed_value & 0xFFFFFFFF

func _mul32(x: int, y: int) -> int:
	# 32 位乘法（等价 JS Math.imul），避免 64 位有符号溢出
	var x0 := x & 0xFFFF
	var x1 := (x >> 16) & 0xFFFF
	var y0 := y & 0xFFFF
	var y1 := (y >> 16) & 0xFFFF
	return ((((x1 * y0 + x0 * y1) & 0xFFFF) << 16) + x0 * y0) & 0xFFFFFFFF

## 核心：返回 [0,1) 随机数
func next() -> float:
	_a = (_a + 0x6D2B79F5) & 0xFFFFFFFF
	var t := _mul32((_a ^ (_a >> 15)) & 0xFFFFFFFF, (1 | _a) & 0xFFFFFFFF)
	t = (((t + _mul32((t ^ (t >> 7)) & 0xFFFFFFFF, (61 | t) & 0xFFFFFFFF)) & 0xFFFFFFFF) ^ t) & 0xFFFFFFFF
	var r := (t ^ (t >> 14)) & 0xFFFFFFFF
	return float(r) / 4294967296.0

## [a, b) 区间浮点
func range_f(a: float, b: float) -> float:
	return a + next() * (b - a)

## [a, b] 区间整数
func range_i(a: int, b: int) -> int:
	return a + int(next() * float(b - a + 1))

func pick(arr: Array) -> Variant:
	if arr.is_empty():
		push_error("GameRng.pick: 空数组")
		return null
	return arr[int(next() * float(arr.size()))]

func chance(p: float) -> bool:
	return next() < p

## list 元素形如 { "item": 任意, "w": 权重 }
func weighted_pick(list: Array) -> Variant:
	var valid: Array = []
	var total := 0.0
	for e in list:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var weight: Variant = e.get("w")
		if (typeof(weight) == TYPE_INT or typeof(weight) == TYPE_FLOAT) \
				and is_finite(float(weight)) and float(weight) > 0.0:
			valid.append(e)
			total += float(weight)
	if valid.is_empty() or total <= 0.0:
		push_error("GameRng.weighted_pick: 无有效正权重条目")
		return null
	var r := next() * total
	for e in valid:
		r -= float(e.w)
		if r <= 0.0:
			return e.item
	return valid[valid.size() - 1].item
