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
## ---- 窄屏（移动端 / 紧凑档）收缩（移动端适配补齐）----
## 上面几个常量是**桌面绝对尺寸**，不含视口概念：手机横屏可用区只有约 700×380 单位，
## DOCK_MAX_H=340 会吃掉八成屏高、DOCK_W=360 会占掉近半屏宽 —— 一张临时详情把战场全盖住。
## 所以窄屏按 `UiMetrics.available()` 的比例收缩；桌面走原常量，排布逐像素不变。
## ⚠️ 比「太大」更要紧的是**溢出**：`show_at` 的落点夹取是 `clampf(p, 4, vp - size - 4)`，
##    size 一旦超过视口，上界就跌到 4 以下（被 maxf 兜成 4）→ 气泡被钉在左上角，
##    右/下侧文字**直接看不见**，且不报任何错。
const NARROW_W_RATIO := 0.92       # 跟随气泡最大宽 / 可用区宽
const NARROW_H_RATIO := 0.62       # 跟随气泡最大高 / 可用区高
const NARROW_DOCK_W_RATIO := 0.80  # 固定视图宽 / 可用区宽
const NARROW_DOCK_H_RATIO := 0.78  # 固定视图高 / 可用区高
## 窄屏收缩后的绝对下限：再小就读不成句，宁可让外层换行
const NARROW_MIN_W := 168.0
const NARROW_MIN_H := 140.0
## ---- 点击详情的「固定视图」（第 9 轮 · 用户要求）----
## 用户原话：「属性和道具查看的时候就是固定视图 + 滚动条」。
## 跟随鼠标的气泡读长描述时很别扭：同一个属性在商店不同格点开、位置都不同，
## 视线每次都要重新找位置。所以**点击详情**改成钉在右侧固定位、内部滚动；
## **悬浮仍然跟随鼠标**（那是一眼扫过的短提示，贴着指针才对）。
const DOCK_W := 360.0       # 固定视图宽度（位置稳定比「刚好包住文字」重要）
const DOCK_MAX_H := 340.0   # 固定视图高度上限，超出则内部滚动
const DOCK_MARGIN := 12.0   # 距屏幕右缘的边距（与安全区取较大者）

## 把「想要的尺寸」夹进视口（**纯函数** —— 冒烟 `_check_mobile_ui()` 直接断言它）。
## 气泡自算的宽高一旦超过视口，落点夹取就会失效并把气泡钉在左上角（见上面常量区的说明）。
static func clamp_to_viewport(want: Vector2, vp: Vector2, pad := 4.0) -> Vector2:
	return Vector2(
		clampf(want.x, 1.0, maxf(1.0, vp.x - pad * 2.0)),
		clampf(want.y, 1.0, maxf(1.0, vp.y - pad * 2.0)))

## 四个尺寸上限：桌面恒为原常量，窄屏按可用区比例收缩。
## 统一 gate 在 `UiMetrics.prefers_full_page()` 上 —— 桌面不能走 `dp()`：
## 桌面 units_per_inch≈96，`dp(340)` 会算成 204，气泡反而缩水。
##
## ⚠️ 这四个必须是 `static`：它们只读 UiMetrics（autoload）与常量，**没有任何实例状态**。
##    写成实例方法会逼着测试 `HintBubble.new()` 才能断言 —— 而冒烟退出时本来就有
##    `N ObjectDB instances were leaked` 的引擎侧噪音，测试再塞对象进去就把那个数字搅浑了，
##    真正新引入的泄漏会被淹没（本次正是先踩了这个坑）。纯函数就该是 static 的。
static func _max_w() -> float:
	if not UiMetrics.prefers_full_page():
		return MAX_W
	return clampf(UiMetrics.available().x * NARROW_W_RATIO, NARROW_MIN_W, MAX_W)

static func _max_h() -> float:
	if not UiMetrics.prefers_full_page():
		return MAX_H
	return clampf(UiMetrics.available().y * NARROW_H_RATIO, NARROW_MIN_H, MAX_H)

static func _dock_w() -> float:
	if not UiMetrics.prefers_full_page():
		return DOCK_W
	return clampf(UiMetrics.available().x * NARROW_DOCK_W_RATIO, NARROW_MIN_W, DOCK_W)

static func _dock_max_h() -> float:
	if not UiMetrics.prefers_full_page():
		return DOCK_MAX_H
	return clampf(UiMetrics.available().y * NARROW_DOCK_H_RATIO, NARROW_MIN_H, DOCK_MAX_H)

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
	# 初始值；每次 show_* 都会按当前视口重算（旋转 / 布局变化后 _max_w 会变）
	_body.custom_minimum_size = Vector2(MAX_W, 0.0)
	_body.add_theme_font_size_override("font_size", 12)
	_body.add_theme_color_override("font_color", Color("d8dde6"))
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll.add_child(_body)

## 量出气泡尺寸（`show_at` / `show_docked` 共用）。
##
## ⚠️⚠️ 这是第 11 轮修掉的那个真 bug：旧写法在「没超上限」的分支里把
##    `_scroll.custom_minimum_size` **复位成 ZERO**，而 `ScrollContainer` 在
##    `vertical_scroll_mode = AUTO` 时**最小高度恒为 0**（它不把子节点高度算进自己）
##    → 气泡的正文区高度恒 0 → **只剩标题**。
##    用户原话：「点击查看详情时，只有名称，没有道具效果描述」「属性悬浮也只有名称」。
##    headless 探针实测：`body.combined_min=(340,37)` / `scroll.min=(348,0)` /
##    `panel.combined_min=(376,44)` —— 44 就是「标题 + 间距 + 内边距」，正文一点没分到。
## 修法：**先量出正文高度并显式写进 `_scroll.custom_minimum_size`**，超上限才回收；
##    回收量用「实测总高 − 实测正文高」推出来的真 chrome（标题+间距+内边距），**不硬编码 42**。
func _layout_body(wrap_w: float, cap_h: float) -> Vector2:
	reset_size()
	# 换行宽度必须先定：`custom_minimum_size.x` 既是 Label 的换行宽，也决定气泡最小宽度。
	# 窄屏不收这一项，下面的 clamp 就永远夹不动（恒 ≥ MAX_W + 内边距）。
	_body.custom_minimum_size = Vector2(wrap_w, 0.0)
	# ① 先按「完整显示正文」设高，量出真实总高
	_scroll.custom_minimum_size = Vector2(0.0, maxf(1.0, _body.get_combined_minimum_size().y))
	var full := get_combined_minimum_size()
	# ② 超上限才把正文区压回去（其余部分原样保留，不做「复位成 0」那种自毁）
	if full.y > cap_h:
		var chrome := maxf(0.0, full.y - _scroll.custom_minimum_size.y)
		_scroll.custom_minimum_size = Vector2(0.0, maxf(24.0, cap_h - chrome))
		return Vector2(full.x, cap_h)
	return full

func show_at(title_text: String, body_text: String) -> void:
	_ensure()
	_title.text = title_text
	_body.text = body_text
	_last_title = title_text
	visible = true
	# 尺寸「先按内容算，再夹进视口」—— 全部交给 `_layout_body`（见那里的长注释）
	var want := _layout_body(_max_w(), _max_h())
	var vp := get_viewport().get_visible_rect().size
	size = clamp_to_viewport(want, vp)
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
	var dock_w := _dock_w()
	var want := _layout_body(_max_w(), _dock_max_h())
	var vp := get_viewport().get_visible_rect().size
	# 固定视图「位置稳定比刚好包住文字重要」→ 宽度取固定值，但必须 ≥ 换行宽且不超上限。
	# 桌面（dock_w=360 / max_w=340）结果恒为 360，与改动前逐像素一致。
	want.x = maxf(dock_w, minf(want.x, _max_w()))
	size = clamp_to_viewport(want, vp)
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

## 点任意处收起。
##
## ⚠️⚠️ 必须用 `_input` 而**不是** `_unhandled_input`（第 11 轮修）：`_unhandled_input`
##    只在「**没有任何 GUI 消费这次点击**」时才触发，而暂停面板 / 商店里到处都是
##    `MOUSE_FILTER_STOP` 的按钮与面板 —— 点哪都被它们吃掉 → 钉住的气泡**根本关不掉**。
##    （用户原话：「没法关闭」。）
##    `_input` 跑在 GUI 之前，所以语义是「先收起，再让这次点击照常落到下面的控件上」，
##    点到道具/按钮时的行为与关闭前完全一致。
func _input(e: InputEvent) -> void:
	if not visible:
		return
	var pressed := (e is InputEventMouseButton and (e as InputEventMouseButton).pressed) \
		or (e is InputEventScreenTouch and (e as InputEventScreenTouch).pressed)
	if pressed:
		hide_now()
