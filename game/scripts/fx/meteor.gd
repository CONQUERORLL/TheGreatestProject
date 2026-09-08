class_name Meteor
extends Node2D
## 流星雨事件的天降流星：先显示预警圈（红色收缩环），预警结束后砸落：
## AOE 伤害玩家（敌我不伤敌），砸落点爆裂特效后自毁。纯视觉预警不拦截输入。

var warn_t := 0.9
var radius := 78.0
var dmg := 22.0
var player
var _warn_total := 0.9
var _landed := false

static func spawn(parent: Node, pos: Vector2, target_player, damage: float, r: float, warn: float) -> void:
	var m := Meteor.new()
	m.position = pos
	m.player = target_player
	m.dmg = damage
	m.radius = r
	m.warn_t = warn
	m._warn_total = warn
	m.z_index = 15
	parent.add_child(m)

func _ready() -> void:
	add_to_group("fx")

func _physics_process(delta: float) -> void:
	if _landed:
		return
	if not GameState.is_running():
		return
	warn_t -= delta
	if warn_t <= 0.0:
		_land()
	else:
		queue_redraw()

func _land() -> void:
	_landed = true
	# 砸落：AOE 判定玩家
	if player != null and is_instance_valid(player):
		if global_position.distance_to(player.global_position) < radius + float(Config.PLAYER.radius):
			player.take_damage(dmg)
	# 爆裂特效（橙红双层）+ 震屏
	Burst.spawn(get_parent(), global_position, Color("ff8a3d"), 14, 220.0)
	Burst.spawn(get_parent(), global_position, Color("ffd24a"), 8, 120.0)
	EventBus.screen_shake.emit(4.0)
	Sfx.play("shoot_rocket")
	queue_free()

func _draw() -> void:
	if _landed:
		return
	var t := clampf(warn_t / _warn_total, 0.0, 1.0)
	# 预警圈：外圈警戒环（闪烁）+ 内圈随时间收缩的落点指示
	var blink := 0.35 + 0.3 * sin(Time.get_ticks_msec() * 0.02)
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 40, Color(1.0, 0.45, 0.25, blink), 3.0, true)
	var inner := radius * t
	draw_arc(Vector2.ZERO, inner, 0.0, TAU, 40, Color(1.0, 0.62, 0.3, 0.55), 2.0, true)
	if inner > 6.0:
		draw_circle(Vector2.ZERO, inner, Color(1.0, 0.4, 0.2, 0.10))
	# 落点中心标记
	draw_circle(Vector2.ZERO, 3.0, Color(1.0, 0.7, 0.4, 0.9))
