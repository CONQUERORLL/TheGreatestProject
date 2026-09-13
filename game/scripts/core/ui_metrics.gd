extends Node
## UiMetrics —— UI 度量 autoload：界面「该多大 / 该几列 / 安全区在哪」的唯一真值来源
##
## 【要解决的问题】
## 本项目 UI 全部代码构建，早期排布是「两套写死的尺寸 + 一个写死的放大倍率」：
## 桌面 1000×620 面板 / 手机 150×170 卡片，再靠 Settings.MOBILE_UI_SCALE = 1.5
## 把整体等比放大。那等于「把桌面 UI 缩小后塞进手机」，问题有三：
##   1. 倍率写死 1.5 —— 只对「约 5 寸 1080p」这一种机器正确；4.7 寸小屏偏挤、
##      7 寸大屏偏空、平板完全错位，且永远不会随设备变化
##   2. 安全区（刘海 / 打孔 / 手势条）在主菜单和摇杆里各算一遍，两处必须手动保持一致
##   3. 没有「尺寸档位」概念 —— 排布层无法判断「这块屏够不够放三列」，只能二选一
##
## 【现在的做法】
##   1. 倍率由**物理尺寸**推算：先用 DPI 把屏幕像素换算成英寸，让 1 英寸 = 160 个 UI 单位
##      （160 dp/inch 是移动端事实标准）。于是画布高度 ≈ 160 × 屏幕物理高度：
##      手机约 400~500 单位、平板 800+，物理大小跨设备一致
##   2. dp()：写界面时按 dp 描述尺寸，运行时换算成 UI 单位；触控目标统一走 touch_min()
##   3. safe_insets()：安全区唯一真值来源（四边，UI 单位）
##   4. size_class()：compact / medium / expanded 三档 —— 界面据此**换排布**（列数、面板尺寸），
##      而不是换尺寸（缩放已由倍率负责）
##
## 【两个轴要分开用】
##   · 排布（列数 / 面板是铺满还是居中）看 size_class()
##   · 人体工学（触控目标多大、要不要 hover 提示）看 is_touch
##   平板就是典型反例：排布够宽（expanded），但它是纯触屏（is_touch）——
##   两者混用会把平板推进「桌面小按钮」的坑里
##
## 【桌面端行为不变】
## 倍率只在 Android/iOS 生效（桌面 scale 恒为 1.0），size_class() 在桌面返回 expanded，
## 各界面沿用原有的桌面分支分支，排布与数值与改动前一致。

## 每英寸 UI 单位数（160 = Android dp 基准，全项目唯一基准值）
const UNITS_PER_INCH := 160.0
## 桌面兜底 DPI（DisplayServer 取不到时按 96 算，Windows 默认值）
const FALLBACK_DPI := 96.0
## 倍率上下限：低于 1.0 会让 1280×720 基准画布被「缩小」，UI 反而更小，无意义
const SCALE_MIN := 1.0
const SCALE_MAX := 2.0
## 安全区最薄兜底（dp）：刘海屏取不到数据时也要留出呼吸空间
const SAFE_MIN_DP := 8.0
## 最小触控目标（dp）：Material 标准 48dp，低于它手指点不准
const TOUCH_MIN_DP := 48.0

## 尺寸档位阈值（可用 UI 单位高度）
const CLASS_COMPACT_MAX := 520.0
const CLASS_MEDIUM_MAX := 680.0

## 布局/度量发生变化（旋转、窗口 resize、跨屏拖窗）——界面收到后重排
signal metrics_changed

var is_mobile := false       ## 运行在 Android/iOS（导出模板自带 mobile 标签）
var is_touch := false        ## 有触摸屏（含带触屏的笔记本；只影响人体工学，不影响倍率）
var scale := 1.0             ## content_scale_factor（仅移动端不为 1.0）
var units_per_inch := 0.0    ## 当前 1 英寸折合多少 UI 单位
var physical_h_in := 0.0     ## 屏幕物理高度（英寸），取不到时为 0

var _safe := {"left": 0.0, "right": 0.0, "top": 0.0, "bottom": 0.0}
var _applying := false       ## 防止改 content_scale_factor 引发的回调重入

func _ready() -> void:
	_refresh_platform()
	apply()
	# 旋转 / 分屏 / 跨屏拖窗都会改窗口尺寸，度量必须跟着重算
	get_tree().root.size_changed.connect(_on_root_resized)

func _refresh_platform() -> void:
	is_mobile = OS.has_feature("mobile")
	is_touch = DisplayServer.is_touchscreen_available()

# ---------------- 倍率 ----------------

## 由物理尺寸反推倍率：目标是让 1 英寸 = UNITS_PER_INCH 个 UI 单位。
## 推导（以「屏幕比 16:9 更宽」的常见手机横屏为例）：
##   canvas_items + aspect=expand 下，基准 1280×720 的画布高度恒为 720 / content_scale_factor
##   画布高度(单位) = UNITS_PER_INCH × 物理高度(英寸)
##   ⇒ content_scale_factor = 720 / (UNITS_PER_INCH × 物理高度)
## 例：5 寸 1080p 手机横屏物理高约 2.6 英寸 ⇒ 倍率 1.73（旧写死值 1.5 偏小约 15%）
func _compute_scale() -> float:
	if not is_mobile:
		return 1.0   # 桌面不做全局缩放，排布与数值保持原样
	var phy_h := _physical_height_in()
	physical_h_in = phy_h
	if phy_h <= 0.0:
		# 取不到 DPI 的机器（少数定制 ROM）：退回改动前的经验值，保证不倒退
		return 1.5
	return clampf(720.0 / (UNITS_PER_INCH * phy_h), SCALE_MIN, SCALE_MAX)

## 屏幕物理高度（英寸）。DPI 明显不合理时返回 0，交由调用方走兜底。
func _physical_height_in() -> float:
	var dpi := DisplayServer.screen_get_dpi()
	if dpi <= 0.0:
		dpi = FALLBACK_DPI
	var scr := DisplayServer.screen_get_size()
	if scr.y <= 0:
		return 0.0
	var h := float(scr.y) / dpi
	# 手机横屏物理高大致落在 1.5~6 英寸；越界说明 DPI 是假值（部分平台硬报 96），
	# 此时宁可用经验值，也不要按假 DPI 算出一个把小屏 UI 压扁的倍率
	if h < 1.5 or h > 6.5:
		return 0.0
	return h

## 应用倍率（Settings.autoload 阶段调用一次；旋转/尺寸变化时自动重算）
func apply() -> void:
	_applying = true
	scale = _compute_scale()
	var root := get_tree().root
	if not is_equal_approx(root.content_scale_factor, scale):
		root.content_scale_factor = scale
	_refresh_units_per_inch()
	_refresh_safe()
	_applying = false
	metrics_changed.emit()

func _refresh_units_per_inch() -> void:
	# 由「实际可见视口 ÷ 窗口物理高度」反推，而不是复用上面的公式 ——
	# 倍率被 clamp 过的设备（平板/超小屏）只有这样才能拿到真实密度
	var win := DisplayServer.window_get_size()
	var vp := viewport_units()
	if win.y <= 0 or vp.y <= 0.0:
		units_per_inch = UNITS_PER_INCH
		return
	var dpi := DisplayServer.screen_get_dpi()
	if dpi <= 0.0:
		dpi = FALLBACK_DPI
	var win_h_in := float(win.y) / dpi
	if win_h_in <= 0.0:
		units_per_inch = UNITS_PER_INCH
		return
	units_per_inch = vp.y / win_h_in

# ---------------- 尺寸换算 ----------------

## dp → UI 单位。写界面时按手指/物理尺寸描述（48dp 的按钮、14dp 的文字），
## 运行时自动换算，跨设备物理大小一致。
func dp(v: float) -> float:
	if units_per_inch <= 0.0:
		return v
	return v * units_per_inch / UNITS_PER_INCH

## 最小触控目标边长（UI 单位）。仅触摸设备有意义，鼠标设备返回 dp 原值。
func touch_min() -> float:
	return dp(TOUCH_MIN_DP)

## 触控场景下取两者较大者（保证按钮不低于最小可点尺寸，又不缩水既有设计）
func touch_at_least(v: float) -> float:
	if not is_touch:
		return v
	return maxf(v, touch_min())

# ---------------- 视口与安全区 ----------------

## 可见视口尺寸（UI 单位）。已包含 stretch 与 content_scale_factor 的影响。
func viewport_units() -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return Vector2.ZERO
	return vp.get_visible_rect().size

## 安全区四边内缩（UI 单位）。刘海 / 打孔 / 手势条 / 圆角统一从这里取，
## 各界面不要再自己读 DisplayServer.get_display_safe_area()。
func safe_insets() -> Dictionary:
	if _safe.is_empty():
		_refresh_safe()
	return _safe

## 重算安全区：屏幕像素 → UI 单位的换算比例取「视口 / 屏幕」，
## 移动端窗口即屏幕，故该比例 = 1 / (基准缩放 × content_scale_factor)
func _refresh_safe() -> void:
	var min_side := dp(SAFE_MIN_DP)
	var scr := DisplayServer.screen_get_size()
	var vp := viewport_units()
	if scr.x <= 0 or scr.y <= 0 or vp.x <= 0.0 or vp.y <= 0.0:
		_safe = {"left": min_side, "right": min_side, "top": min_side, "bottom": min_side}
		return
	var safe := DisplayServer.get_display_safe_area()
	# 安全区为全屏时说明平台没实现该 API（桌面常见），退化为统一最小边距
	if safe.size.x <= 0 or safe.size.y <= 0 or safe.size == scr:
		_safe = {"left": min_side, "right": min_side, "top": min_side, "bottom": min_side}
		return
	var kx := vp.x / float(scr.x)
	var ky := vp.y / float(scr.y)
	_safe = {
		"left": maxf(float(safe.position.x) * kx, min_side),
		"right": maxf(float(scr.x - (safe.position.x + safe.size.x)) * kx, min_side),
		"top": maxf(float(safe.position.y) * ky, min_side),
		"bottom": maxf(float(scr.y - (safe.position.y + safe.size.y)) * ky, min_side),
	}

## 对称外边距（取左右/上下较大边）：全屏页面统一用它做内缩。
## extra 是叠在安全区之外的额外呼吸距离（dp）。
func margin(extra: float = 8.0) -> Vector2:
	var s := safe_insets()
	return Vector2(
		maxf(float(s.left), float(s.right)) + dp(extra),
		maxf(float(s.top), float(s.bottom)) + dp(extra))

# ---------------- 尺寸档位 ----------------

## 可用 UI 单位高度 → 档位。排布层用它决定「几列 / 面板铺满还是居中」。
func size_class() -> String:
	var h := viewport_units().y
	if h <= 0.0:
		return "expanded"
	if h < CLASS_COMPACT_MAX:
		return "compact"
	if h < CLASS_MEDIUM_MAX:
		return "medium"
	return "expanded"

func is_compact() -> bool:
	return size_class() == "compact"

## 是否该用「铺满屏幕 + 内部滚动」的页面式排布（小屏 / 移动端）
func prefers_full_page() -> bool:
	return is_mobile or is_compact()

## 去掉安全区与边距后，真正可用来摆内容的尺寸
func available(extra_margin: float = 8.0) -> Vector2:
	var vp := viewport_units()
	var m := margin(extra_margin)
	return Vector2(maxf(vp.x - m.x * 2.0, 1.0), maxf(vp.y - m.y * 2.0, 1.0))

## 把一个控件摆成「铺满安全区」—— 小屏页面式排布的统一入口。
##
## 注意：**不能只调 set_anchors_preset**。如果这个控件的父节点是 Container
## （CenterContainer / VBoxContainer …），容器会用 fit_child_in_rect 按最小尺寸把它摆好，
## 锚点被直接覆盖 —— 面板不会铺满，只会按内容最小尺寸居中，内容一多就两头溢出屏幕。
## 所以调用方必须把它挂到普通 Control 父节点下（或直接挂在全屏 Control 上）。
func fill_safe_area(node: Control, extra: float = 8.0) -> void:
	var m := margin(extra)
	node.set_anchors_preset(Control.PRESET_FULL_RECT)
	node.offset_left = m.x
	node.offset_right = -m.x
	node.offset_top = m.y
	node.offset_bottom = -m.y

## 把「想要多大」的面板收进可用区域 —— 固定尺寸面板在小屏上溢出的统一解法。
## 返回值 ≤ 可用尺寸，界面内部若仍需滚动由界面自己挂 ScrollContainer。
func fit_panel(want: Vector2, extra_margin: float = 8.0) -> Vector2:
	var avail := available(extra_margin)
	return Vector2(minf(want.x, avail.x), minf(want.y, avail.y))

## 自适应列数：在 avail_w 宽度里尽量多放列，但不让单格窄于 min_cell_w，
## 且不要把 n 个元素摊到超出 n 列。小屏因此自动退化成「少列多行 + 滚动」。
func grid_columns(avail_w: float, min_cell_w: float, n: int, gap: float = 10.0) -> int:
	if n <= 0 or min_cell_w <= 0.0:
		return 1
	var cols := int(floor((avail_w + gap) / (min_cell_w + gap)))
	return clampi(cols, 1, n)

## 卡片阵列自适应：返回 { "card_size": Vector2, "cols": int }。
## （键名刻意避开 "size" —— Dictionary 自带 size() 方法，点访问有歧义。）
##
## 升级三选一 / 进化方向 / 奇遇卡都是「N 张等大卡片横排」，桌面写死 200×220。
## 窄屏横排装不下时，CenterContainer 只会把溢出的部分**从两端裁掉** ——
## 卡面文字看不全，玩家还以为是渲染 bug。这里改成：列数按可用宽度自动减少
## （4 张进化分支在窄屏落成 2×2），高度再按行数摊薄，保证整块卡阵连同上方标题
## 一起装进安全区。
##
##   n        卡片数量
##   want     桌面设计尺寸（一行摆得下就用它 —— 桌面排布逐像素不变）
##   min_w    允许压缩到的最小宽度（再窄字就读不出来，宁可换行）
##   min_h    允许压缩到的最小高度
##   gap      卡间距
##   reserve_h 卡阵上方标题/说明占掉的高度（已在 available() 之内扣除）
func card_grid(n: int, want: Vector2, min_w: float, min_h: float, gap: float,
		reserve_h: float) -> Dictionary:
	var count := maxi(n, 1)
	if n <= 0 or not prefers_full_page():
		return { "card_size": want, "cols": count }
	var avail := available()
	var cols := grid_columns(avail.x, min_w, n, gap)
	var rows := int(ceil(float(n) / float(cols)))
	var w := clampf((avail.x - gap * float(cols - 1)) / float(cols), min_w, want.x)
	var h := clampf((avail.y - reserve_h - gap * float(rows - 1)) / float(rows), min_h, want.y)
	return { "card_size": Vector2(w, h), "cols": cols }

# ---------------- 变化通知 ----------------

func _on_root_resized() -> void:
	if _applying:
		return
	# 窗口尺寸变化可能改变倍率（旋转后物理高度不变，但窗口比例变了），延迟一帧重算，
	# 避免在 Godot 自身的 resize 通知栈里再改 content_scale_factor 造成抖动
	call_deferred("apply")
