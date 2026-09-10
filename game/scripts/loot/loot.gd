class_name Loot
extends Node2D
## 掉落物（移植自原型 pickups / updatePickups / settlePickup / drawPickup）
## kind: "xp" 经验晶体 / "mat" 材料 / "heart" 红心（+val HP）/ "artifact" 法宝（读 artifact_id）
## 行为：弹出减速（摩擦 exp(-6dt)）→ 进入拾取范围被磁吸 → 接触结算

var kind := "xp"
var val := 1
var artifact_id := ""   # 仅 kind == "artifact" 时使用（val 是 int，承载不了字符串 id）
var vel := Vector2.ZERO
var player  # characters/player.gd 引用，由生成方注入
var _t := 0.0
var _phase := 0.0
var _collected := false
var _bob := 0.0        # 当前浮动偏移（位置承担，避免每帧重绘）
var _scale_settled := false

func setup(kind_name: String, value: int, pos: Vector2, velocity: Vector2) -> void:
	kind = kind_name
	val = value
	position = pos
	vel = velocity

## 法宝掉落专用入口：与 setup 分开而非改其签名，避免影响 xp/mat/heart 三处现有调用
func setup_artifact(id: String, pos: Vector2, velocity: Vector2) -> void:
	kind = "artifact"
	artifact_id = id
	val = 1
	position = pos
	vel = velocity

func _ready() -> void:
	add_to_group("loot")
	z_index = -1   # 原型中掉落物绘制在敌人/玩家之下
	scale = Vector2(0.2, 0.2)   # 弹出缩放动画
	_phase = position.x   # 原型浮动相位取自 x 坐标

func _physics_process(delta: float) -> void:
	_t += delta
	# 弹出缩放动画：到位后停笔（大规模掉落场的主要重绘来源）
	if not _scale_settled:
		scale = scale.lerp(Vector2.ONE, minf(1.0, delta * 14.0))
		if scale.distance_squared_to(Vector2.ONE) < 0.0004:
			scale = Vector2.ONE
			_scale_settled = true
		queue_redraw()
	if not GameState.is_running() or player == null or not is_instance_valid(player):
		return
	vel *= exp(-6.0 * delta)
	var d: float = player.global_position.distance_to(global_position)
	var pr: float = player.stats.pickup_range
	if d < pr:   # 磁吸：f = 1800 * (1 - d/R + 0.2)，越近吸力越强（原 900 翻倍）
		var f: float = 1800.0 * (1.0 - d / pr + 0.2)
		vel += (player.global_position - global_position).normalized() * f * delta
	global_position += vel * delta
	# 浮动动画走节点位置（无需重绘）：静止掉落物零绘制开销
	var bob := sin(_t * 3.33 + _phase) * 2.0
	global_position.y += bob - _bob
	_bob = bob
	if d < float(Config.PLAYER.radius) + 12.0:
		settle()

## 结算拾取（原型 settlePickup）；波末全场回收也走这里
func settle() -> void:
	if _collected:
		return
	_collected = true
	remove_from_group("loot")   # 立即出组，避免同帧统计/二次回收
	match kind:
		"xp":
			GameState.gain_xp(val)
		"mat":
			GameState.add_materials(val)
		"heart":
			if player and is_instance_valid(player):
				player.hp = minf(player.stats.max_hp, player.hp + float(val))
				FloatingText.spawn(get_parent(), player.global_position + Vector2(0.0, -24.0),
					"+" + str(val), Color("7ec850"))
		"artifact":
			# 统一走 player.apply_artifact：重复持有转材料补偿、图鉴解锁、
			# artifact_acquired 信号（HUD/toast）全在里面，这里不重复造轮子。
			# 波末全场回收也走 settle()，没捡到的法宝仍会入账（保底不丢）
			if player and is_instance_valid(player):
				player.apply_artifact(artifact_id)
	queue_free()

func _draw() -> void:
	match kind:
		"xp":
			# 绿色菱形晶体（旋转 45° 的 8×8 方块）
			draw_set_transform(Vector2.ZERO, PI / 4.0, Vector2.ONE)
			draw_rect(Rect2(-4.0, -4.0, 8.0, 8.0), Color("7ec850"))
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		"mat":
			# 琥珀圆 + 高光
			draw_circle(Vector2.ZERO, 5.0, Color("e8b84b"))
			draw_circle(Vector2(-1.5, -1.5), 1.6, Color("fff3d0"))
		"heart":
			# 红心：两圆 + 三角近似贝塞尔心形
			draw_circle(Vector2(-2.8, -2.2), 3.4, Color("ef6b5e"))
			draw_circle(Vector2(2.8, -2.2), 3.4, Color("ef6b5e"))
			draw_colored_polygon(PackedVector2Array([
				Vector2(-5.6, -0.5), Vector2(5.6, -0.5), Vector2(0.0, 6.0)]), Color("ef6b5e"))
		"artifact":
			# 法宝：稀有度色菱形 + 半透光环，体积大于 xp 晶体以区分
			# 不做脉动动画：_draw 仅在弹出缩放期重绘，脉动要每帧 queue_redraw
			var col := Config.rarity_color(
				String(Registry.get_artifact(artifact_id).get("rarity", "common")))
			draw_circle(Vector2.ZERO, 10.0, Color(col.r, col.g, col.b, 0.22))
			draw_set_transform(Vector2.ZERO, PI / 4.0, Vector2.ONE)
			draw_rect(Rect2(-6.0, -6.0, 12.0, 12.0), col)
			draw_rect(Rect2(-2.6, -2.6, 5.2, 5.2), col.lightened(0.55))
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
