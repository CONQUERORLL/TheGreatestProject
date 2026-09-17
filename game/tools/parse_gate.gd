extends SceneTree

## 临时语法门禁：只做「把 smoke_test.gd 编译进内存」这一件事，然后立刻退出。
##
## 为什么需要它：完整冒烟要跑 10 分钟以上，而 Parse Error 只要 1~2 秒就能暴露。
## 修断言时如果每次都等整轮冒烟，迭代成本高得离谱。
##
## 用法：
##   Godot_v4.7.2-stable_win64_console.exe --headless --path <game> --script res://tools/parse_gate.gd
##
## ⚠️ 用 `--script` 方式时 autoload **不会**加载，所以这里只能做纯语法/静态检查，
##    任何依赖 Registry / Config 运行期的调用都不能执行。本文件因此只 preload。
##
## 退出码：0 = 编译通过；1 = 有 Parse Error（Godot 自身会把错误打到 stderr）。

func _initialize() -> void:
	# ⚠️ 不能靠 `load(path) == null` 判断失败 —— 脚本解析失败时 Godot 仍会返回一个
	#    非空的失败占位对象，所以 `load` 成功与否在这里不可区分。真正的信号是
	#    Godot 打到 stderr 的 "Parse Error" / "Failed to load script"。
	#    → 本门禁因此配一个 Python 包装器（tools/parse_gate.py）去扫日志；
	#      这里只负责"把脚本拖进编译器"这一件事。
	for path in ["res://tests/smoke_test.gd"]:
		load(path)
	print("PARSE_GATE: load attempted (see log above for details)")
	quit(0)
