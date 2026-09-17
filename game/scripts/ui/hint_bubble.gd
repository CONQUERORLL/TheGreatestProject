extends PanelContainer
class_name HintBubble
## HintBubble —— 「悬浮看说明 / 点击看详情」的通用气泡（第 8 轮新增）
##
## 【用户需求】
##   · 商店与暂停里「悬浮属性名称看到属性具体描述」
##   · 「点击道具名称看到道具加成和描述」
##
## 【为什么自己画，不用 `tooltip_text`】
##   Godot 内建 tooltip 有两个硬限制，正好卡住这两个需求：
##     1. 只有 `mouse_filter = STOP` 的控件才收得到 hover；本项目侧栏属性行**整行都是 IGNORE**
##        （为的是不挡住下面的按钮），改成 STOP 会顺手改变点击穿透行为。
##     2. 内建 tooltip 全是纯文本，且**触摸屏没有 hover** —— 手机上等于完全没有说明。
##   所以这里自建：悬浮即弹、点击即钉住，鼠标与触屏都能用。
##
## 【用法（每个调用点一行）】
##   `HintBubble.attach_hover(label, "攻速", EntryText.stat_help("攻速"), host)`
##   `HintBubble.attach_click(name_label, func() -> Dictionary: return EntryText.entry_detail(d, "道具"), host)`
##
## 【宿主与实例】
##   一个 `host` 只建一个气泡，靠 `get_meta` 存放（不引入 autoload / 全局单例）。
##   `host` 可以是 Control，也可以是 CanvasLayer（`main.gd` 传的就是 `$UI`）。
##   ⚠️ 气泡是**后加的最后一个子节点**，所以永远画在宿主已有内容之上。
##
## 【两处性能注意】
##   · `mouse_entered` / `mouse_exited` 只在跨控件时触发，不是每帧 —— 悬浮本身零帧开销。
##   · 气泡 `mouse_filter = IGNORE`：它压在别的控件上时**不吃点击**，否则会挡住下面的按钮。

const META_KEY := "_hint_bubble"
## 气泡最大宽度：超过就自动换行。340 是「读得下两行加成说明、又不盖住半个商店」的折中。
const MAX_W := 340.0
## 尺寸上限（超出则内部滚动）—— 屏幕小的时候防止气泡长到出屏
const MAX_H := 260.0
## ---- 点击详情的「固定视图」（第 9 轮 · 用户要求）----
## 用户原话：「属性和道具查看的时候就是固定视图 + 滚动条」。
## 跟随鼠标的气泡读长描述时很别扭：同一个属性在商店不同格点开、位置都不同，
## 视线每次都要重新找位置。所以**点击详情**改成钉在右侧固定位、内部滚动；
## **悬浮仍然跟随鼠标**（那是一眼扫过的短提示，贴着指针才对）。
const DOCK_W := 360.0       # 固定视图宽度（位置稳定比「刚好包住文字」重要）
const DOCK_MAX_H := 340.0   # 固定视图高度上限，超出则内部滚动
const DOCK_MARGIN := 12.0   # 距屏幕右缘的边距（与安全区取较大者）

var _title: Label = null
var _body: Label = null
var _scroll: ScrollContainer = null
var _last_title := ""
var _docked := false   # 本气泡当前是不是「固定视图」（点击详情）——悬浮提示不受影响

## 取（必要时创建）host 上的气泡
##
## ⚠️⚠️ 必须**先 `has_meta` 再 `get_meta`**，不能写成 `get_meta(KEY, null)`：
##    Godot 的 `Object::get_meta(name, default)` 内部判的是 `if (p_default != Variant())` ——
##    **`null` 恰好等于 `Variant()`**，于是「给 null 当缺省」会走进 ERR_FAIL 分支，
##    每建一次气泡就在日志里刷一条 `The object does not have any 'meta' values with the key …`
##    （实测：暂停面板每帧重建 → 冒烟日志里成串报错，看着像气泡系统坏了）。
static func for_host(host: Node) -> HintBubble:
	if host.has_meta(META_KEY):
		var existing: Variant = host.get_meta(META_KEY)
		if existing != null and is_instance_valid(existing):
			return existing as HintBubble
	_cleanup_host_meta(host)
	var bb := HintBubble.new()
	bb.name = "HintBubble"
	bb.visible = false
	bb.z_index = 200          # UI 层内最高，压在商店卡/暂停面板之上
	bb.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 不吃点击，绝不挡住底下的按钮
	host.add_child(bb)
	host.set_meta(META_KEY, bb)
	return bb

static func _cleanup_host_meta(host: Node) -> void:
	if host.has_meta(META_KEY):
		host.remove_meta(META_KEY)

## 关掉某宿主上的气泡（商店重开 / 暂停重建时调用，避免残留一张卡）
## 同样先 `has_meta`（见 `for_host` 的注释：`get_meta(KEY, null)` 会误触 ERR_FAIL）
static func hide_for(host: Node) -> void:
	if not host.has_meta(META_KEY):
		return
	var existing: Variant = host.get_meta(META_KEY)
	if existing != null and is_instance_valid(existing):
		(existing as HintBubble).visible = false

## ---- 悬浮显示：移入弹、移出收 ----
## `body` 为空串时**不挂**（说明表里没这条，就别弹一个空气泡）
static func attach_hover(target: Control, title: String, body: String, host: Node) -> void:
	if body.strip_edges() == "":
		return
	target.mouse_filter = Control.MOUSE_FILTER_STOP
	target.tooltip_text = ""      # 关掉系统 tooltip，避免和气泡同时弹两个
	var bb := for_host(host)
	target.mouse_entered.connect(func() -> void: bb.show_at(title, body))
	target.mouse_exited.connect(func() -> void: bb.hide_now())

## ---- 点击显示：按下弹出并**钉住**，点到别处才收 ----
## `provider` 在**点击那一刻**才求值，所以气泡里的数值永远是最新的（悬浮挂上去时还没买呢）
static func attach_click(target: Control, provider: Callable, host: Node) -> void:
	target.mouse_filter = Control.MOUSE_FILTER_STOP
	target.tooltip_text = ""
	var bb := for_host(host)
	target.gui_input.connect(func(e: InputEvent) -> void:
		var pressed := (e is InputEventMouseButton and (e as InputEventMouseButton).pressed
				and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT) \
			or (e is InputEventScreenTouch and (e as InputEventScreenTouch).pressed)
		if not pressed:
			return
		var res: Dictionary = provider.call()
		bb.show_docked(String(res.get("title", "")), String(res.get("body", "")))
		target.accept_event()      # 消费掉，别再传给底下的按钮
	)

## ---- 气泡自身 ----
func _ensure() -> void:
	if _title != null:
		return
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("12151c")
	sb.border_color = Color("e8b84b")
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	add_theme_stylebox_override("panel", sb)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 14)
	_title.add_theme_color_override("font_color", Color("e8b84b"))
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_title)
	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(0.0, 0.0)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_scroll)
	_body = Label.new()
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.custom_minimum_size = Vector2(MAX_W, 0.0)
	_body.add_theme_font_size_override("font_size", 12)
	_body.add_theme_color_override("font_color", Color("d8dde6"))
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll.add_child(_body)

func show_at(title_text: String, body_text: String) -> void:
	_ensure()
	_title.text = title_text
	_body.text = body_text
	_last_title = title_text
	visible = true
	# 尺寸必须「先按内容算，再夹进视口」：直接信任内容高度会在长说明时把气泡顶出屏幕，
	# 玩家看不到上半截，还以为是渲染 bug。
	reset_size()
	var want := get_combined_minimum_size()
	if want.y > MAX_H:
		want.y = MAX_H
		_scroll.custom_minimum_size = Vector2(0.0, MAX_H - 42.0)
	else:
		# ⚠️ 必须显式复位：`_scroll` 是**复用**节点，上一次长文把最小高度顶上去之后
		#    不复位，下一条短提示也会撑出同样一大片空白（现象是"气泡突然变得很高"，
		#    不是报错，纯视觉）。
		_scroll.custom_minimum_size = Vector2.ZERO
	size = want
	var vp := get_viewport().get_visible_rect().size
	var p := get_viewport().get_mouse_position() + Vector2(18.0, 18.0)
	p.x = clampf(p.x, 4.0, maxf(4.0, vp.x - size.x - 4.0))
	p.y = clampf(p.y, 4.0, maxf(4.0, vp.y - size.y - 4.0))
	_docked = false
	position = p

## ---- 点击详情：固定视图 + 滚动条 ----
## 与 `show_at` 的差别只有两处：① 宽度固定成 DOCK_W（不随文字长短抖）
## ② 位置固定成「右侧、垂直居中」（不跟鼠标）。滚动条两者共用（见 `_ensure`）。
func show_docked(title_text: String, body_text: String) -> void:
	_ensure()
	_title.text = title_text
	_body.text = body_text
	_last_title = title_text
	_docked = true
	visible = true
	reset_size()
	var vp := get_viewport().get_visible_rect().size
	var want := get_combined_minimum_size()
	want.x = maxf(DOCK_W, minf(want.x, MAX_W))
	if want.y > DOCK_MAX_H:
		want.y = DOCK_MAX_H
		_scroll.custom_minimum_size = Vector2(0.0, DOCK_MAX_H - 42.0)
	else:
		# 同 `show_at`：固定视图与跟随视图共用同一个滚动节点，短内容必须把最小高度收回
		_scroll.custom_minimum_size = Vector2.ZERO
	size = want
	var m := UiMetrics.margin()
	var edge := maxf(m.x, DOCK_MARGIN)
	# 右侧固定位：避开商店左侧属性栏，也不压中间的商品卡（会挡住右侧「已购道具」，
	# 但那是可关闭的临时详情，且点别处即收 —— 比「位置到处跳」好得多）
	var x := maxf(edge, vp.x - size.x - edge)
	var y := clampf((vp.y - size.y) * 0.5, m.y, maxf(m.y, vp.y - size.y - m.y))
	position = Vector2(x, y)

func hide_now() -> void:
	visible = false
	_last_title = ""
	_docked = false

## 点空白处收起：`gui_input` 已被目标 `accept_event()` 消费，所以钉住的气泡
## 只在点到别的地方时才会走到这里 —— 正是想要的行为。
func _unhandled_input(e: InputEvent) -> void:
	if not visible:
		return
	var pressed := (e is InputEventMouseButton and (e as InputEventMouseButton).pressed) \
		or (e is InputEventScreenTouch and (e as InputEventScreenTouch).pressed)
	if pressed:
		hide_now()
