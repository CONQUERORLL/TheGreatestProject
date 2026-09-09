class_name CharacterAvatar
extends Control
## 角色专属头像：程序化绘制每个角色的像素风人物形象（无贴图资源）。
## 内置 7 角色：土豆勇者/狂战士/游侠/赌徒/收获者/血族/铁卫；
## 未知角色（mod 自定义）回退为角色主题色的通用土豆头。
## 用法：var av := CharacterAvatar.new(); av.setup("berserker", 72.0)

var char_id := "potato"
var avatar_size := 72.0

func setup(id: String, size: float = 72.0) -> void:
	char_id = id
	avatar_size = size
	custom_minimum_size = Vector2(size, size)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _draw() -> void:
	# 以 72px 基准坐标绘制，先设缩放再落笔
	var s := avatar_size / 72.0
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(s, s))
	var c := Vector2(36.0, 38.0)  # 头部中心
	var r := 19.0
	var ch: Dictionary = Registry.get_character(char_id)
	var theme_col: Color = Color(String(ch.get("color", "#e8b84b")))
	# 底座阴影（所有角色统一的落地面）
	draw_circle(Vector2(c.x, c.y + r + 6.0), r * 0.85, Color(0.0, 0.0, 0.0, 0.18))
	match char_id:
		"berserker": _draw_berserker(c, r)
		"ranger": _draw_ranger(c, r)
		"gambler": _draw_gambler(c, r)
		"farmer": _draw_farmer(c, r)
		"vampire": _draw_vampire(c, r)
		"guardian": _draw_guardian(c, r)
		_: _draw_potato(c, r, theme_col)

# ---------------- 通用部件 ----------------

func _head(col: Color, c: Vector2, r: float, outline_col := Color(0.0, 0.0, 0.0, 0.45)) -> void:
	draw_circle(c, r, col)
	draw_arc(c, r, 0.0, TAU, 36, outline_col, 2.0, true)

func _eyes(c: Vector2, r: float, eye_col := Color("2b2110"), dx := 7.5, dy := -2.0, er := 2.6) -> void:
	draw_circle(c + Vector2(-dx, dy), er, eye_col)
	draw_circle(c + Vector2(dx, dy), er, eye_col)

func _smile(c: Vector2, r: float, col := Color("6b4d1f")) -> void:
	draw_arc(c + Vector2(0.0, 4.0), r * 0.42, 0.35, PI - 0.35, 12, col, 2.0, true)

# ---------------- 各角色形象 ----------------

## 土豆勇者：金棕土豆 + 顶部嫩芽（经典原型造型）
func _draw_potato(c: Vector2, r: float, col: Color) -> void:
	_head(col, c, r, Color("8a6420"))
	_eyes(c, r)
	_smile(c, r)
	# 顶部嫩芽：茎 + 两片叶
	var stem := c + Vector2(0.0, -r)
	draw_line(stem, stem + Vector2(0.0, -7.0), Color("4a7c2a"), 3.0)
	draw_colored_polygon(PackedVector2Array([
		stem + Vector2(0.0, -6.0), stem + Vector2(-8.0, -11.0), stem + Vector2(-2.0, -3.0)]),
		Color("6aa93e"))
	draw_colored_polygon(PackedVector2Array([
		stem + Vector2(0.0, -6.0), stem + Vector2(8.0, -11.0), stem + Vector2(2.0, -3.0)]),
		Color("6aa93e"))

## 狂战士：赤红 + 怒眉 + 双角 + 战斧
func _draw_berserker(c: Vector2, r: float) -> void:
	_head(Color("d9534f"), c, r, Color("7c1f1c"))
	# 怒眉 + 眼
	draw_line(c + Vector2(-11.0, -8.0), c + Vector2(-3.0, -5.0), Color("5c1210"), 3.0)
	draw_line(c + Vector2(11.0, -8.0), c + Vector2(3.0, -5.0), Color("5c1210"), 3.0)
	draw_circle(c + Vector2(-7.0, -1.5), 2.4, Color("2b0d0c"))
	draw_circle(c + Vector2(7.0, -1.5), 2.4, Color("2b0d0c"))
	# 咆哮嘴（张开）
	draw_colored_polygon(PackedVector2Array([
		c + Vector2(-6.0, 5.0), c + Vector2(6.0, 5.0), c + Vector2(4.0, 11.0),
		c + Vector2(-4.0, 11.0)]), Color("5c1210"))
	# 左眼角伤疤
	draw_line(c + Vector2(-14.0, -6.0), c + Vector2(-10.0, 2.0), Color("8a3a36"), 2.0)
	# 双角（头顶两侧斜插）
	draw_colored_polygon(PackedVector2Array([
		c + Vector2(-12.0, -14.0), c + Vector2(-22.0, -26.0), c + Vector2(-8.0, -18.0)]),
		Color("e8dcc8"))
	draw_colored_polygon(PackedVector2Array([
		c + Vector2(12.0, -14.0), c + Vector2(22.0, -26.0), c + Vector2(8.0, -18.0)]),
		Color("e8dcc8"))
	# 战斧（右侧）：木柄 + 弧形斧刃
	var hh := c + Vector2(r + 6.0, -r + 4.0)
	draw_line(hh, hh + Vector2(3.0, 30.0), Color("6b4a2a"), 4.0)
	draw_colored_polygon(PackedVector2Array([
		hh, hh + Vector2(14.0, 4.0), hh + Vector2(11.0, 14.0), hh + Vector2(2.0, 9.0)]),
		Color("aab4c4"))

## 游侠：青绿兜帽 + 箭羽眼 + 长弓
func _draw_ranger(c: Vector2, r: float) -> void:
	_head(Color("3bbfae"), c, r, Color("186b60"))
	# 兜帽：上半覆盖的深色弧冠 + 帽尖
	draw_colored_polygon(PackedVector2Array([
		c + Vector2(-r - 2.0, 2.0), c + Vector2(0.0, -r - 14.0), c + Vector2(r + 2.0, 2.0),
		c + Vector2(0.0, -6.0)]), Color("1d8577"))
	# 兜帽阴影下的眼（冷静细长）
	draw_line(c + Vector2(-10.0, -2.0), c + Vector2(-4.0, -2.0), Color("0d3f39"), 3.0)
	draw_line(c + Vector2(10.0, -2.0), c + Vector2(4.0, -2.0), Color("0d3f39"), 3.0)
	_smile(c, r, Color("0d4a44"))
	# 肩后箭袋（两支箭羽）
	draw_rect(Rect2(c + Vector2(r - 2.0, -4.0), Vector2(6.0, 18.0)), Color("6b4a2a"))
	draw_line(c + Vector2(r + 1.0, -4.0), c + Vector2(r + 1.0, -12.0), Color("e8e2d0"), 2.0)
	draw_line(c + Vector2(r + 4.0, -4.0), c + Vector2(r + 4.0, -13.0), Color("e8e2d0"), 2.0)
	# 长弓（左侧）：弓臂 + 弦
	var bow_c := c + Vector2(-r - 8.0, 0.0)
	draw_arc(bow_c, 15.0, -1.1, 1.1, 16, Color("8a6420"), 3.5, true)
	draw_line(bow_c + Vector2.from_angle(-1.1) * 15.0,
		bow_c + Vector2.from_angle(1.1) * 15.0, Color("d8d3c4"), 1.5)

## 赌徒：橙色 + 歪礼帽 + 眨眼 + 骰子
func _draw_gambler(c: Vector2, r: float) -> void:
	_head(Color("e8902a"), c, r, Color("8a5210"))
	# 歪礼帽（旋转的帽冠 + 帽檐）
	draw_set_transform(c + Vector2(0.0, -r + 2.0), -0.28, Vector2.ONE)
	draw_rect(Rect2(-13.0, -14.0, 26.0, 4.0), Color("22262f"))    # 帽檐
	draw_rect(Rect2(-8.0, -22.0, 16.0, 9.0), Color("2c323e"))     # 帽冠
	draw_rect(Rect2(-8.0, -16.0, 16.0, 3.0), Color("e8b84b"))     # 帽带
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# 左眼睁 + 右眼眨（挑逗表情）
	draw_circle(c + Vector2(-7.0, -2.0), 2.6, Color("2b2110"))
	draw_line(c + Vector2(4.0, -2.0), c + Vector2(10.0, -3.0), Color("2b2110"), 3.0)
	_smile(c, r, Color("7a4a12"))
	# 漂浮骰子（右上角）
	var d := c + Vector2(r + 4.0, -r + 2.0)
	draw_rect(Rect2(d - Vector2(7.0, 7.0), Vector2(14.0, 14.0)), Color("f2f0ea"))
	draw_rect(Rect2(d - Vector2(7.0, 7.0), Vector2(14.0, 14.0)), Color(0.0, 0.0, 0.0, 0.4), false, 2.0)
	draw_circle(d + Vector2(-3.5, -3.5), 1.6, Color("22262f"))
	draw_circle(d + Vector2(0.0, 0.0), 1.6, Color("22262f"))
	draw_circle(d + Vector2(3.5, 3.5), 1.6, Color("22262f"))

## 收获者：草绿 + 宽檐草帽 + 红润脸颊 + 麦穗
func _draw_farmer(c: Vector2, r: float) -> void:
	_head(Color("9ccf6a"), c, r, Color("4e7a2e"))
	_eyes(c, r, Color("233a12"))
	_smile(c, r, Color("3d5c22"))
	# 红润脸颊
	draw_circle(c + Vector2(-12.0, 4.0), 3.2, Color(0.92, 0.45, 0.40, 0.45))
	draw_circle(c + Vector2(12.0, 4.0), 3.2, Color(0.92, 0.45, 0.40, 0.45))
	# 宽檐草帽：帽冠 + 大帽檐 + 帽带
	var hat := c + Vector2(0.0, -r + 3.0)
	draw_rect(Rect2(hat + Vector2(-19.0, -2.0), Vector2(38.0, 5.0)), Color("d9b45e"))
	draw_rect(Rect2(hat + Vector2(-10.0, -10.0), Vector2(20.0, 9.0)), Color("c9a24a"))
	draw_rect(Rect2(hat + Vector2(-10.0, -4.0), Vector2(20.0, 3.0)), Color("8a6420"))
	# 麦穗（右侧）
	var w := c + Vector2(r + 7.0, -r + 10.0)
	draw_line(w, w + Vector2(2.0, 20.0), Color("7c8a2e"), 2.5)
	for i in 4:
		var gy := w.y + 3.0 + float(i) * 4.5
		draw_line(Vector2(w.x, gy), Vector2(w.x - 5.0, gy - 3.0), Color("e0c95e"), 2.0)
		draw_line(Vector2(w.x, gy), Vector2(w.x + 5.0, gy - 3.0), Color("e0c95e"), 2.0)

## 血族：苍白紫 + 背头 + 尖牙 + 高领披风
func _draw_vampire(c: Vector2, r: float) -> void:
	_head(Color("c9a8e0"), c, r, Color("5e3d78"))
	_eyes(c, r, Color("3d1a52"), 7.5, -2.0, 2.6)
	# 背头（深色前倾发型）
	draw_colored_polygon(PackedVector2Array([
		c + Vector2(-r + 1.0, -4.0), c + Vector2(-r + 4.0, -r - 2.0), c + Vector2(2.0, -r - 6.0),
		c + Vector2(r - 1.0, -r + 2.0), c + Vector2(r - 4.0, -6.0), c + Vector2(0.0, -10.0)]),
		Color("3d1a52"))
	# 微笑 + 两颗尖牙
	draw_arc(c + Vector2(0.0, 4.0), r * 0.42, 0.35, PI - 0.35, 12, Color("3d1a52"), 2.0, true)
	draw_colored_polygon(PackedVector2Array([
		c + Vector2(-5.0, 8.0), c + Vector2(-3.0, 8.0), c + Vector2(-4.0, 13.0)]), Color("f5f2f8"))
	draw_colored_polygon(PackedVector2Array([
		c + Vector2(3.0, 8.0), c + Vector2(5.0, 8.0), c + Vector2(4.0, 13.0)]), Color("f5f2f8"))
	# 高领披风（底部两侧尖角）
	draw_colored_polygon(PackedVector2Array([
		c + Vector2(-r - 4.0, r + 8.0), c + Vector2(-r - 2.0, -2.0), c + Vector2(-r + 6.0, r + 2.0)]),
		Color("2c1238"))
	draw_colored_polygon(PackedVector2Array([
		c + Vector2(r + 4.0, r + 8.0), c + Vector2(r + 2.0, -2.0), c + Vector2(r - 6.0, r + 2.0)]),
		Color("2c1238"))

## 铁卫：钢蓝方盔 + T 型观察缝 + 护盾
func _draw_guardian(c: Vector2, r: float) -> void:
	# 头部：略方的钢盔
	draw_colored_polygon(PackedVector2Array([
		c + Vector2(-r, -r + 4.0), c + Vector2(-r, r - 2.0), c + Vector2(-r + 4.0, r),
		c + Vector2(r - 4.0, r), c + Vector2(r, r - 2.0), c + Vector2(r, -r + 4.0),
		c + Vector2(r - 6.0, -r), c + Vector2(-r + 6.0, -r)]), Color("5a6dbf"))
	draw_colored_polygon(PackedVector2Array([
		c + Vector2(-r + 1.0, -r + 4.0), c + Vector2(-r + 1.0, r - 2.0), c + Vector2(-r + 4.0, r - 1.0),
		c + Vector2(r - 4.0, r - 1.0), c + Vector2(r - 1.0, r - 2.0), c + Vector2(r - 1.0, -r + 4.0),
		c + Vector2(r - 6.0, -r + 1.0), c + Vector2(-r + 6.0, -r + 1.0)]),
		Color(0.0, 0.0, 0.0, 0.30))
	# T 型观察缝（发光青色）
	draw_rect(Rect2(c + Vector2(-9.0, -6.0), Vector2(18.0, 4.0)), Color("8ef0e2"))
	draw_rect(Rect2(c + Vector2(-2.0, -2.0), Vector2(4.0, 9.0)), Color("8ef0e2"))
	# 盔顶冠脊
	draw_rect(Rect2(c + Vector2(-2.0, -r - 3.0), Vector2(4.0, 6.0)), Color("3d4c8a"))
	# 护盾（前方）：盾体 + 纹章 + 描边
	var sh := c + Vector2(0.0, r + 6.0)
	var sb := Rect2(sh + Vector2(-15.0, -7.0), Vector2(30.0, 20.0))
	draw_rect(sb, Color("3d4c8a"))
	draw_rect(sb, Color("8ef0e2"), false, 2.0)
	draw_circle(Vector2(sb.position.x + sb.size.x / 2.0, sb.position.y + sb.size.y / 2.0), 4.5, Color("8ef0e2"))
