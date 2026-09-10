extends Node2D
## 火焰喷射锥 —— 真正的「喷射」表现层。
##
## 上一版把火焰画在弹丸身上（长雾带 + 首尾重叠），但弹丸本身在飞：
## 无论把火舌画多长，读起来仍是「一颗颗会飞的火团」，所以观感依旧不像喷射。
##
## 真实喷火器喷出的是一股**连着枪口**的锥形火焰，火焰留在空间里向上飘散，
## 而不是被扔出去。因此这一层不跟弹丸走 —— 它是玩家的子节点，恒在枪口，
## 按当前朝向画一条越远越宽越淡、并整体上飘的火焰锥。
##
## 伤害仍由（视觉近乎不可见的）弹丸负责，见 player.gd 的 _spawn_bullet / _ignite_flame_jet：
## 表现与判定彻底解耦，火焰喷到哪里就是弹丸飞到哪里。

const FADE_SPEED := 7.5    # 强度渐变速度：开火瞬间起焰，停火后自然熄灭
const TURN_SPEED := 17.0   # 朝向跟随速度（略慢于玩家转身，转身时有甩动感）
const HOLD_TIME := 0.26    # 单次开火保持喷射的时长（火焰喷射器 cd 0.10，可覆盖 2~3 发）

var dir := 0.0             # 当前喷射方向（平滑跟随 target_dir）
var target_dir := 0.0
var reach := 120.0         # 喷射长度（由武器实际射程推算）
var width := 26.0          # 末端宽度（锥体扩散程度）
var _hold := 0.0           # 剩余保持时间
var _fade := 0.0           # 0~1 当前强度
var _t := 0.0              # 时间累积（火焰跳动相位）

## 每次开火调用：刷新保持时间，更新目标方向与喷射长度
func ignite(direction: float, length: float, end_width: float = 26.0) -> void:
	target_dir = direction
	reach = length
	width = end_width
	_hold = HOLD_TIME

func _process(delta: float) -> void:
	_t += delta
	_hold = maxf(0.0, _hold - delta)
	var want := 1.0 if _hold > 0.0 else 0.0
	if not is_equal_approx(_fade, want):
		_fade = move_toward(_fade, want, delta * FADE_SPEED)
	dir = lerp_angle(dir, target_dir, clampf(delta * TURN_SPEED, 0.0, 1.0))
	if _fade <= 0.001:
		if visible:
			visible = false   # 熄灭后停画，不再逐帧重绘
		return
	if not visible:
		visible = true
	queue_redraw()

func _draw() -> void:
	var d := Vector2.from_angle(dir)
	var perp := Vector2(-d.y, d.x)
	var muzzle := d * 18.0   # 枪口位置（与 player 画的枪管长度对应）
	# 三层锥：外焰暗红 → 中焰橙 → 内焰亮黄，越远越宽、越淡
	_cone(muzzle, d, perp, reach, width, Color(0.84, 0.18, 0.04, 0.15), 0)
	_cone(muzzle, d, perp, reach * 0.86, width * 0.60, Color(1.00, 0.48, 0.10, 0.24), 1)
	_cone(muzzle, d, perp, reach * 0.58, width * 0.32, Color(1.00, 0.84, 0.42, 0.32), 2)
	# 枪口核心：交代火焰从哪儿喷出来
	draw_circle(muzzle * 0.72, 5.5 * _fade, Color(1.0, 0.95, 0.74, 0.55 * _fade))
	# 飞散火星：沿锥体外扩并整体上飘
	for i in 6:
		var u := fmod(float(i) * 0.17 + _t * 1.05, 1.0)
		var sway := sin(float(i) * 2.6 + _t * 6.5) * width * 0.55 * u
		var p := muzzle + d * (reach * u) + perp * sway + Vector2(0.0, -reach * u * 0.16)
		draw_circle(p, 1.7, Color(1.0, 0.86, 0.5, (1.0 - u) * 0.75 * _fade))

## 沿轴撒圆构成锥体：半径随距离线性增长（扩散）、透明度递减，并叠加时间抖动
func _cone(from: Vector2, d: Vector2, perp: Vector2, length: float, end_w: float,
		col: Color, phase: int) -> void:
	var steps := 14
	for i in steps + 1:
		var u := float(i) / float(steps)
		var wob := sin(_t * 8.5 + float(i) * 1.6 + float(phase) * 2.1) * end_w * 0.30 * u
		# 火焰向上飘：世界 -Y 方向，越远偏移越大（火苗总是往上走）
		var p := from + d * (length * u) + perp * wob + Vector2(0.0, -length * u * 0.12)
		var rr := (2.0 + end_w * u) \
			* (0.70 + 0.30 * sin(_t * 14.0 + float(i) * 0.9 + float(phase)))
		draw_circle(p, rr, Color(col.r, col.g, col.b, col.a * _fade * (1.0 - u * 0.72)))
