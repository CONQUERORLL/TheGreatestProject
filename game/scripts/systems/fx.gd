class_name Fx
extends RefCounted
## §16.3 特效统一入口：所有五行 / 反应特效只经此处，调用点只传 element / reaction_id，
## 取色一律来自 Config（ELEMENT_COLOR / rarity_color），避免「同一种火伤，三处三个色」。
##
## ⚠️ 视觉层零判定：本文件只读 Config，绝不参与任何碰撞 / 遮挡 / 索敌 / 伤害计算。
## ⚠️ 预算组约定（沿用 §16.5 / bamboo_leaf.gd 口径）：
##    hit_burst / reaction_burst 进 "fx" 组，吃 FX_BURST_MAX_LIVE / FX_SKILL_MAX_LIVE 护栏；
##    element_aura 进 "ambient_fx" 组，常驻型，不吃打击感特效预算。

## 命中迸发：取该元素配色，落入 fx 组（Burst 自带 FX_BURST_MAX_LIVE 护栏）
static func hit_burst(element: String, pos: Vector2, scale := 1.0, parent: Node = null) -> void:
	if not Config.ELEMENTS.has(element):
		return
	var col := Color(String(Config.ELEMENT_COLOR.get(element, "#ffffff")))
	var root := parent if parent != null else _world_root()
	if root == null:
		return
	Burst.spawn(root, pos, col, int(14.0 * scale), 220.0 * scale)

## 元素光环：在 node 上挂一圈常驻元素色描边（进 ambient_fx 组，不吃打击感预算）
static func element_aura(element: String, node: Node2D, dur := 2.0) -> void:
	if not Config.ELEMENTS.has(element) or node == null:
		return
	var col := Color(String(Config.ELEMENT_COLOR.get(element, "#ffffff")))
	var aura := FxAura.new()
	aura.setup(col, dur)
	node.add_child(aura)

## 反应爆发：取反应 rarity 配色，落入 fx 组（SkillFX 自带 FX_SKILL_MAX_LIVE 护栏）
static func reaction_burst(reaction_id: String, pos: Vector2, parent: Node = null) -> void:
	var rid := String(reaction_id)
	var rarity := "common"
	if Registry.reactions.has(rid):
		rarity = String(Registry.reactions[rid].get("rarity", "common"))
	var col := Config.rarity_color(rarity)
	var root := parent if parent != null else _world_root()
	if root == null:
		return
	_spawn_skill_shock(root, pos, col, 200.0, 1.0)

## 技能冲击波 spawn（隔离 skill_fx.gd 的 load 调用，与 player.gd 一致：该脚本未用 class_name）
static func _spawn_skill_shock(root: Node, pos: Vector2, col: Color, rad: float, power: float) -> void:
	var script := load("res://scripts/fx/skill_fx.gd") as GDScript
	var s = script.new()
	s.position = pos
	s.z_index = 30
	s.color = col
	s.radius = maxf(1.0, rad)
	s.intensity = clampf(power, 0.0, 1.0)
	root.add_child(s)

## 解析当前游戏场景根（Gameplay FX 落在 main 上，与敌人/玩家 get_parent() 同坐标系）
static func _world_root() -> Node:
	var ml = Engine.get_main_loop()
	if ml is SceneTree:
		return (ml as SceneTree).current_scene
	return null

## 内部：元素光环（常驻型，进 ambient_fx 组，不吃打击感预算）
class FxAura extends Node2D:
	var _col := Color.WHITE
	var _dur := 2.0
	var _t := 0.0

	func setup(col: Color, dur: float) -> void:
		_col = col
		_dur = dur
		_t = 0.0
		add_to_group("ambient_fx")
		z_index = 4

	func _process(delta: float) -> void:
		_t += delta
		if _t >= _dur:
			queue_free()
			return
		queue_redraw()

	func _draw() -> void:
		var a := 1.0 - (_t / _dur)
		var r := 30.0 + 6.0 * sin(_t * 6.0)
		draw_arc(Vector2.ZERO, r, 0.0, TAU, 32, _col, 3.0, true)
		draw_arc(Vector2.ZERO, r + 6.0, 0.0, TAU, 32,
			Color(_col.r, _col.g, _col.b, a * 0.4), 1.5, true)
