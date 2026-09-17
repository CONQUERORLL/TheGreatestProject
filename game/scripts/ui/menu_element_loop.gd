class_name MenuElementLoop
extends Node2D
## §15 菜单五行生克循环动画（纯视觉，零判定，不挡输入）。
##
## 背景层：main_menu 的纯色 ColorRect 在本节点下层，本节点在其上画五行环。
## 生克链由 Config.GENERATES / Config.OVERCOMES 派生（方向真值，绝不解析 REACTIONS 的 id ——
## 因为 fire_water 的 id 方向与 name 相反，见 §15.6）。顶点序固定 [木,火,土,金,水] 顺时针、木在正上。
##
## ⚠️ 与全仓库一致：视觉层零判定。本脚本只读 Config 取色 / 取链，不参与任何碰撞 / 遮挡 / 索敌 / 伤害。
## ⚠️ 必须不挡输入：本节点是 Node2D（天然不消费鼠标事件）；其下的 5 个中文单字 Label 已显式
##    设为 MOUSE_FILTER_IGNORE，避免 Control 默认 STOP 拦截首页按钮点击。

const STEP_GEN := 0.9       # 生步：0.6 生成 + 0.3 停留
const STEP_OVR := 0.7       # 克步：0.45 吞噬 + 0.25 停留
const STEP_HOLD := 0.8      # 循环间隙（全环回稳，避免生克接缝生硬）
const MAX_PARTICLES := 120
const NODE_R := 42.0        # 顶点节点基础半径
const BASE_PRES := 0.35     # 空闲 / 被吞噬到底时的存在度（保证单字可读）
const FULL_PRES := 1.0      # 生成完成时的存在度

var radius := 210.0         # 五边形外接半径（由外部 set_radius 给，跟随 UiMetrics）
var speed_mult := 1.0       # 全局速度倍率（§14-Q5「降速」实现位）
var paused := true          # 手动总开关：true = 永不推进（静态定格，不销毁）
var home: Control = null    # 首页引用；提供后，非首页（向导 / 弹窗）自动定格

# ---- 派生链（_ready 时从 Config 取，方向正确）----
var _gen_chain: Array = []   # 生序列（环）：[wood, fire, earth, metal, water]
var _ovr_chain: Array = []   # 克序列（环）：[wood, earth, water, fire, metal]

# 顶点布局序（相生序顺时针，木在正上）；下标即 _pos / _pres / _labels 的下标
const _ORDER := ["wood", "fire", "earth", "metal", "water"]
# 生边 = 五边形外圈相邻边（布局序相邻，跨 72°）
const _GEN_EDGES := [[0, 1], [1, 2], [2, 3], [3, 4], [4, 0]]
# 克边 = 内接五角星（隔一个顶点，跨 144°）：（木,土）（土,水）（水,火）（火,金）（金,木）
const _OVR_EDGES := [[0, 2], [2, 4], [4, 1], [1, 3], [3, 0]]

var _pos: Array = []
var _pres: Array = [BASE_PRES, BASE_PRES, BASE_PRES, BASE_PRES, BASE_PRES]
var _labels: Array = []
var _particles: Array = []
var _size := Vector2(1280.0, 720.0)

# 时间轴状态机
var _phase := "hold"         # "gen" | "ovr" | "hold"
var _step := 0
var _local := 0.0

static func spawn(parent: Node, size: Vector2, home_ref: Variant = null) -> MenuElementLoop:
	var n := MenuElementLoop.new()
	n._size = size
	n.home = home_ref as Control
	parent.add_child(n)
	return n

func set_radius(r: float) -> void:
	radius = maxf(40.0, r)
	_build_layout()

func set_speed(mult: float) -> void:
	speed_mult = maxf(0.1, mult)

func _ready() -> void:
	_gen_chain = _derive_chain(Config.GENERATES)
	_ovr_chain = _derive_chain(Config.OVERCOMES)
	_build_layout()
	_build_labels()
	_reset_state()

func _reset_state() -> void:
	_phase = "hold"
	_step = 0
	_local = 0.0
	_pres = [BASE_PRES, BASE_PRES, BASE_PRES, BASE_PRES, BASE_PRES]

## 把 {a:b,...} 关系表转成有序顶点环：从木出发沿关系走一圈回到木。
## 不解析 REACTIONS 的 id（避免 fire_water 方向反的坑），方向直接取 GENERATES / OVERCOMES。
func _derive_chain(rel: Dictionary) -> Array:
	var start := "wood"
	var chain: Array = [start]
	var cur := String(start)
	for _i in _ORDER.size():
		var nxt := String(rel.get(cur, ""))
		if nxt == "" or nxt == start:
			break
		chain.append(nxt)
		cur = nxt
	return chain

func _build_layout() -> void:
	var cx := _size.x / 2.0
	var cy := _size.y / 2.0
	_pos = []
	for i in _ORDER.size():
		var ang := -PI / 2.0 + float(i) * (TAU / 5.0)   # 木在正上，顺时针
		_pos.append(Vector2(cx + radius * cos(ang), cy + radius * sin(ang)))

func _build_labels() -> void:
	for el in _ORDER:
		var lbl := Label.new()
		lbl.text = String(Config.ELEMENT_NAME.get(el, "?"))
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override("font_size", 34)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 关键：不挡输入
		lbl.z_index = 1
		lbl.modulate.a = BASE_PRES
		add_child(lbl)
		_labels.append(lbl)

# ---------------------------------------------------------------
func _process(delta: float) -> void:
	if paused or (home != null and not home.visible):
		queue_redraw()
		return
	var dt := delta * speed_mult
	_advance(dt)
	_update_particles(dt)
	_update_labels()
	queue_redraw()

func _advance(dt: float) -> void:
	_local += dt
	match _phase:
		"hold":
			if _local >= STEP_HOLD:
				_phase = "gen"
				_step = 0
				_local = 0.0
				for i in _pres.size():
					_pres[i] = BASE_PRES   # 进入生成前先归底，避免凭空出现
		"gen":
			var i := mini(_step, 4)
			var sidx := _ORDER.find(_gen_chain[i])
			var tidx := _ORDER.find(_gen_chain[(i + 1) % 5])
			var grow := clampf(_local / 0.6, 0.0, 1.0)
			grow = 1.0 - pow(1.0 - grow, 2.0)   # ease_out：先快后慢，像涌出来
			_pres[tidx] = lerp(BASE_PRES, FULL_PRES, grow)
			_spawn_flow(sidx, tidx, String(Config.ELEMENT_COLOR.get(_ORDER[tidx], "#ffffff")))
			if _local >= STEP_GEN:
				_pres[tidx] = FULL_PRES
				_step += 1
				_local = 0.0
				if _step >= 5:
					_phase = "ovr"
					_step = 0
					_local = 0.0
		"ovr":
			var i := mini(_step, 4)
			var sidx := _ORDER.find(_ovr_chain[i])          # 被吞噬者
			var tidx := _ORDER.find(_ovr_chain[(i + 1) % 5]) # 吞噬者
			var devour := clampf(_local / 0.45, 0.0, 1.0)
			# 台阶式下降（5 段）：像被一口口吃掉，而非淡出
			var seg: float = ceil(devour * 5.0) / 5.0
			_pres[sidx] = lerp(FULL_PRES, BASE_PRES, seg)
			if devour > 0.0 and fmod(devour * 5.0, 1.0) < 0.35:
				_spawn_burst(sidx, String(Config.ELEMENT_COLOR.get(_ORDER[sidx], "#ffffff")))
			if _local >= STEP_OVR:
				_pres[sidx] = BASE_PRES
				_step += 1
				_local = 0.0
				if _step >= 5:
					_phase = "hold"
					_step = 0
					_local = 0.0

# ---- 粒子（封顶 MAX_PARTICLES，菜单建议 ≤120）----
func _spawn_flow(sidx: int, tidx: int, col: String) -> void:
	if _particles.size() >= MAX_PARTICLES:
		return
	var a: Vector2 = _pos[sidx]
	var b: Vector2 = _pos[tidx]
	var dir: Vector2 = (b - a).normalized()
	_particles.append({"pos": a + dir * NODE_R, "vel": dir * randf_range(60.0, 120.0),
		"life": 0.5, "max_life": 0.5, "col": Color(col)})

func _spawn_burst(sidx: int, col: String) -> void:
	if _particles.size() >= MAX_PARTICLES:
		return
	var p: Vector2 = _pos[sidx]
	for _k in 3:
		var ang := randf() * TAU
		_particles.append({"pos": p, "vel": Vector2.from_angle(ang) * randf_range(40.0, 90.0),
			"life": 0.35, "max_life": 0.35, "col": Color(col)})

func _update_particles(dt: float) -> void:
	var keep := []
	for p in _particles:
		p.life -= dt
		if p.life <= 0.0:
			continue
		p.pos += p.vel * dt
		p.vel *= exp(-4.0 * dt)
		keep.append(p)
	_particles = keep

func _update_labels() -> void:
	for i in _labels.size():
		var pres := float(_pres[i])
		var p: Vector2 = _pos[i]
		var s := maxf(0.25, pres)
		_labels[i].scale = Vector2(s, s)
		_labels[i].modulate.a = clampf(pres, 0.25, 1.0)
		_labels[i].position = p - Vector2(17.0, 17.0) * s

# ---- 绘制 ----
func _draw() -> void:
	_draw_edges()
	for i in _pos.size():
		var el := String(_ORDER[i])
		var p: Vector2 = _pos[i]
		var col := Color(String(Config.ELEMENT_COLOR.get(el, "#ffffff")))
		var pres := float(_pres[i])
		var r := NODE_R * pres
		draw_circle(p, r + 10.0 * pres, Color(col.r, col.g, col.b, 0.16 * pres))
		draw_circle(p, r, Color(col.r, col.g, col.b, 0.85))
	_draw_particles()

func _draw_edges() -> void:
	for e in _GEN_EDGES:
		draw_line(_pos[e[0]], _pos[e[1]], Color(0.6, 0.72, 0.85, 0.10), 2.0)
	var ai := -1
	if _phase == "gen" or _phase == "ovr":
		ai = _step
	for idx in _OVR_EDGES.size():
		var e: Array = _OVR_EDGES[idx]
		var active := (idx == ai)
		var a := 0.10
		var w := 2.0
		if active:
			a = 0.30 + 0.2 * sin(_local * 14.0)
			w = 3.0
		draw_line(_pos[e[0]], _pos[e[1]], Color(0.96, 0.55, 0.4, a), w)

func _draw_particles() -> void:
	for p in _particles:
		var a := clampf(p.life / p.max_life, 0.0, 1.0)
		draw_circle(p.pos, 3.0 * a + 1.0, Color(p.col.r, p.col.g, p.col.b, a))
