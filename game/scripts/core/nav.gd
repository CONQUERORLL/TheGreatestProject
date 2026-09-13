extends Node
## Nav —— 返回键路由 autoload：把 Android 返回键、Windows 鼠标侧键、Esc / 手柄 B 汇成一条路
##
## 【要解决的问题】
## Godot 4 里 Android 返回键**不是** ui_cancel 动作，而是 NOTIFICATION_WM_GO_BACK_REQUEST
## 通知（见官方 Handling quit requests）。而 project.godot 里 quit_on_go_back=false
## （注释写的是「交给游戏内逻辑处理」），可实际上全项目没有任何地方处理这个通知 ——
## 各界面只在 _unhandled_input 里接 ui_cancel（Esc / 手柄 B）。
## 结果就是：**Android 上按返回键什么都不会发生**，玩家被困在当前界面。
## （settings.gd 里「Android 返回会作为 ui_cancel 交给游戏」的注释是错的，已一并修正。）
##
## 【现在的做法】
##   · 每个场景/界面把自己的「返回」动作 bind 进来（返回 true = 已消费）
##   · 返回键从栈顶往下找第一个愿意处理的；都没处理就发 root_back_requested，
##     由主菜单决定「双击回桌面 / 退出」
##   · 移动端上 Nav 同时接管 ui_cancel 与 GO_BACK 两条来路 —— 不同 Godot 版本/ROM
##     把返回键投递成哪种形式都覆盖得住；两条路撞车时用时间窗去重，只算一次
##
## 【为什么不是每个界面自己接通知】
## 通知会广播给场景树里的**每一个**节点。各自处理既会重复消费，也无法表达优先级
## （「图鉴打开时返回键该关图鉴而不是关菜单」）。集中成栈后优先级天然由注册顺序决定。

## 谁都没消费这次的返回请求（主菜单据此走「双击回桌面」）
signal root_back_requested

## 去重窗口（毫秒）：同一物理按键可能同时以通知 + ui_cancel 两种形式到达，
## 窗口内只认第一次。取值远小于主菜单 2000ms 的双击判定，不会误吞真正的连按。
const DEDUPE_MS := 180

var _entries: Array = []      # [{ "node": Node, "handler": Callable }]，末尾为栈顶
var _last_ms := -99999

## 注册一个返回处理器。node 被释放时自动摘除 —— 场景切换不会留下指向死节点的回调。
func bind(node: Node, handler: Callable) -> void:
	if node == null or not handler.is_valid():
		return
	unbind(node)
	_entries.append({"node": node, "handler": handler})
	if not node.tree_exiting.is_connected(_on_node_exiting):
		node.tree_exiting.connect(_on_node_exiting.bind(node))

## 摘除某个节点的处理器（节点自己退出时也会调）
func unbind(node: Node) -> void:
	for i in range(_entries.size() - 1, -1, -1):
		if _entries[i].node == node:
			_entries.remove_at(i)

## 移动端由 Nav 全权接管返回输入：界面自身的 ui_cancel 分支必须让位，
## 否则两边都会处理，一次返回被算成两次。
func owns_back() -> bool:
	return UiMetrics.is_mobile

## 交由栈顶优先消费；返回是否有人处理
func back() -> bool:
	for i in range(_entries.size() - 1, -1, -1):
		var e: Dictionary = _entries[i]
		var n: Node = e.node
		var h: Callable = e.handler
		if not is_instance_valid(n) or not h.is_valid():
			_entries.remove_at(i)
			continue
		if bool(h.call()):
			return true
	return false

## 统一的返回入口：先给界面栈，无人认领则抛给根（主菜单）
func dispatch() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_ms < DEDUPE_MS:
		return
	_last_ms = now
	if not back():
		root_back_requested.emit()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		dispatch()

func _unhandled_input(event: InputEvent) -> void:
	# 移动端：Godot 若把返回键映射成 ui_cancel，也会走到这里（去重窗口保证只算一次）
	if owns_back() and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		dispatch()

func _on_node_exiting(node: Node) -> void:
	unbind(node)
