---
name: "godot-game-ui"
description: "Godot 4 游戏内 UI 搭建规范（代码构建节点 + Registry 数据源 + 手柄焦点 + 震动）。Invoke when 在本工作区新建/修改游戏界面（菜单、HUD、商店、弹卡、向导）或需要手柄可导航的 UI。"
---

# Godot 游戏 UI 搭建规范（TheGreatestProject 工作区）

本技能沉淀自 HUD / 商店 / 升级三选一 / 主菜单分步向导 / 创意工坊 的实战经验。
在本工作区（Godot 4.7，项目根 `game/`）做任何界面开发时遵循。

## 1. 场景与脚本分工

- `.tscn` 只放：一个根 Control（`anchors_preset = 15` 全屏）+ 脚本挂载。**节点全部在 GDScript 里 new 出来**，不手写 .tscn 节点树。
  - 参考：`scenes/ui/main_menu.tscn` / `workshop.tscn` 只有 3 行；逻辑全在 `scripts/ui/*.gd`。
- 脚本结构：`_ready()` 里 `_build_xxx()` 分层构建（背景 ColorRect → Center/Margin → VBox → 行容器 → 卡片）。

## 2. 数据一律走 Registry，禁止硬编码选项

- 选项列表（角色/武器/道具/升级/敌人/难度）遍历 `Registry.characters.values()` 等注册表，**mod 内容自动出现**。
- 取数：`Registry.weapons[id]`、`Registry.item_list()`、`Registry.upgrade_list()`、`Registry.shop_weapon_pool()`、`Registry.get_difficulty(id)`。
- 新属性效果走数据驱动：道具/升级用 `effects` 字典（键 = player.stats 键，特例 `heal_flat` / `heal_pct`），player.apply_item/apply_upgrade 统一遍历，**不要为新内容写 match 分支**。
- 编辑器创建内容：`Registry.save_content(kind, entry)`（kind 为复数键 characters/weapons/items/upgrades/enemies/difficulties）——注册校验 + upsert 持久化到 `user://mods/workshop_user/manifest.json`，重启自动加载。动态表单参考 `workshop.gd` 的 `FIELD_DEFS`（text/f/i/choice）+ `EFFECT_FIELDS` 属性 SpinBox 组。
- 敌人 AI 用 `cfg.ai`（chaser/runner/shooter/boss）分派，`enemy.ai_type()` 读取；`is_boss()` 含 ai=="boss"。波次/BOSS mod 覆盖：`Registry.boss_id()`、`Registry.wave_composition(w)`（manifest 顶层 "boss" / "spawn_table"）。
- register_xxx 必须用 `_apply_defaults` 补可选字段（bspeed/price/xp/mat/color 等），否则 mod 漏字段会读到 null 运行时报错。
- **道具/升级归属**：`player.items_owned`（id→数量）由 `apply_item` 自动记账；出售走 `player.sell_item(id)` → 返还 50% 购入价并**反向扣 effects**（heal_flat/heal_pct 一次性效果不可逆，跳过），加钱由商店 `_sell` 负责。商店三源商品：42% 武器 + 29% 升级属性（`apply_upgrade` 生效）+ 其余道具。

## 3. 单选/卡片模式（ButtonGroup）

```gdscript
var group := ButtonGroup.new()
var b := Button.new()
b.toggle_mode = true
b.button_group = group
b.button_pressed = pressed
b.set_meta("id", id)          # 用 meta 携带数据 id
b.custom_minimum_size = Vector2(220.0, 180.0)
b.toggled.connect(_on_toggled)
# 取值：
var picked: String = group.get_pressed_button().get_meta("id")
```
- 卡片文本多行：`"图标\n名称\n\n描述"`，`b.alignment = HORIZONTAL_ALIGNMENT_LEFT`。

## 4. 手柄/键盘焦点（必须可导航）

- 面板打开/步骤切换后 **必须** `grab_focus()`：默认给已选项或第一张卡。
- 跨行/跨容器移动：焦点邻居显式接线
  ```gdscript
  btn.focus_neighbor_bottom = btn.get_path_to(other_btn)
  other_btn.focus_neighbor_top = other_btn.get_path_to(btn)
  ```
  （参考 `shop_ui.gd` 的 `_wire_focus()`：商品行 ↓ → 动作按钮，动作区 ↑ → 第一张可购卡。）
- 面板/界面关闭时焦点必须释放（隐藏 Control 后 `gui_get_focus_owner()` 应为 null，冒烟测试会断言）。
- 容器里的非交互节点（Label/ColorRect/Panel）一律 `mouse_filter = Control.MOUSE_FILTER_IGNORE`，否则挡点击和焦点。
- 分步向导：卡片选中即自动 `_next()`；最后一步不要自动提交，改为聚焦"开始游戏"按钮防误触。
- 返回：`_unhandled_input` 里监听 `"ui_cancel"`（Esc/手柄B）回上一步，`get_viewport().set_input_as_handled()`。

## 5. 反馈

- 按钮/卡片选中：`Haptics.rumble(0.15, 0.0, 0.05)`；确认：`0.3, 0.0, 0.1`。Haptics 内部有 40ms 节流，不用自己防连点。
- 标题强调色 `Color("e8b84b")`（土豆黄），次要文字 `Color("9aa3b2")`，背景 `Color("101218")`。
- **稀有度着色**：色表统一取 `Config.rarity_color(r)`（common 白 / rare 蓝 / epic 紫 / legendary 红）；难度色阶 `Config.DIFFICULTY_COLORS`（normal 绿 / hard 橙 / nightmare 红）。卡片样式 = accent 色 9% 微底 + 2px 描边圆角，hover/focus 金边 + 20% 底（参考 `main_menu.gd` `_make_card` / `shop_ui.gd` `_rarity_style`）。
- **侧面板页**（暂停/商店共用形态）：全屏遮罩 + MarginContainer + HBox[左属性面板 | 中内容 | 右道具面板]；属性行 = 名称灰 + 数值金（`_stat_row` 模式）；道具面板 ScrollContainer 内行式布局。暂停页打开时重建内容（数值实时变）。

## 6. headless 验证（改动必做）

- 运行：`& "D:\code\godot\Godot_v4.7.2-stable_win64_console.exe" --headless --path game res://tests/smoke_test.tscn`，退出码 0 为通过。
- **新增 `class_name` 脚本后必须先 `--import` 重建类缓存**，否则 headless 里报 "Identifier not found"：
  `& <godot> --headless --path game --import`（日志里会出现 `update_scripts_classes | <新类名>`）。
  验证：`.godot/global_script_class_cache.cfg` 里能搜到新类名。
- `--check-only --script res://xx.gd` **不能当语法检查用**：该模式不加载 autoload，
  凡引用 `Config` / `GameState` / `Registry` / `Haptics` 的脚本必然报 "Identifier not found: Config"，
  全是假阳性。唯一可靠的检查就是把 `.tscn` 场景跑起来（smoke_test 或临时检查场景）。
- **临时检查场景用完即删**（放 `tests/_xxx_check.tscn` + `.gd`）。
- 坑：`-s script.gd` 模式 **不加载 autoload**；必须用 `.tscn` 场景跑（同 smoke_test.tscn 模式）。
- UI 构建错误只在面板打开时触发：检查脚本要显式调用打开/切换方法并遍历各步骤断言子节点数。
- **超时保护**：脚本一旦 Parse Error，`smoke_test.tscn` 加载失败后主场景会一直跑下去不退出，
  直跑命令会永久挂住。务必用 `timeout 240 <godot> ...` 或 `run_smoke.ps1`（内含 280s 沙箱超时）。
  判定只看 stdout 的 `SMOKE:` 行，不要依赖退出码。
- **user:// 落点**：`run_smoke.ps1` / `run_game.ps1` 会套沙箱放行 `%APPDATA%\Godot`；
  若在未设 APPDATA 的环境里直跑 `--headless --path .`，Godot 会退化成项目内
  `game/Godot/app_userdata/BrotatoLite/`（已 gitignore）。直跑反而能让落盘类断言通过。
- **断言别跨帧比对节点组总数**：`Burst` 存活 0.2~0.5s 会整批到期，跨一个 `process_frame`
  采样「fx 组数量」时，新特效会被同帧到期的旧特效抵消而出现假失败。
  要改成直接找目标类型的节点（`for n in get_tree().get_nodes_in_group("fx"): if n is Explosion`）。
- **测试里不要硬编码会被随机产出的内容 id**：例如断言 `apply_artifact("art_cinder_seal")`，
  而前置的精英掉落/波末回收会随机送法宝，一旦正好送出这一件用例必挂（普品 5 件 → 约 1/5）。
  正确做法是从注册表里动态挑一件「当前确定未持有」的。
- **常驻氛围粒子不要进 `"fx"` 组**：`"fx"` 是打击感特效的预算与统计口径
  （`Burst.MAX_LIVE` 护栏 + 冒烟测试的 fx 计数），常驻粒子混进去会同时污染两者。
  另开一组（如 `"ambient_fx"`）。
- **窗口化启动（给用户实机试玩）**：`game/tools/run_game.ps1` 是正规入口，但若当前终端
  调不动 PowerShell / cmd（本项目所在沙箱会把二者从 Bash 里直接拦住），
  可用 Bash 直调 GUI 版 exe（**不要**用 `_console.exe`，否则多一个黑框）：
  ```bash
  cd game && APPDATA='C:\Users\<用户>\AppData\Roaming' \
    "/c/<godot 目录>/Godot_v4.7.2-stable_win64.exe" \
    --path 'C:\<仓库绝对路径>\game'
  ```
  两个必须注意的点：
  1. **`--path` 一定要写 Windows 风格绝对路径**。MSYS 不会转换 `--path /c/...`，
     Godot 会直接报 `Invalid project path specified` 并 abort（程序路径 `/c/...` 反而会被转换，别被这点迷惑）。
  2. **必须显式设置 `APPDATA`**。不设的话 Godot 把 `user://` 落到项目内
     `game/Godot/app_userdata/`，玩家的真实存档（`%APPDATA%\Godot\app_userdata\BrotatoLite`）
     就看不见了，会以为进度丢了。
  用后台任务方式拉起（`run_in_background`），拉起后校验：
  进程在 + `user://logs/godot.log` 时间戳刷新 + 日志里有 `OpenGL API ... Using Device` 行
  （有 GPU 行才说明真的开了窗口；headless 不会有这一行）。

## 7. GDScript 通用禁忌（本项目踩过）

- 跨脚本不用 `class_name` 静态类型引用（headless 类缓存未注册会 Parse Error）：用 `preload(...)` + `var x := Scene.instantiate()`，跨脚本引用保持无类型 `var player`。
- 无类型引用的派生表达式必须显式标注：`var v: float = dict.key`。
- 无类型变量（如 `var player`）的**返回值**也不能用 `:=` 推断（`var got := player.sell_item(id)` 报 "Cannot infer the type"），要写 `var got: int = player.sell_item(id)`。
- **赋值不能出现在表达式内**：`f(x = VBox.new())` Parse Error "Assignment is not allowed inside an expression"，先建变量再传参。
- JSON 数组遍历不要写 `for entry: Dictionary in arr`（非对象条目直接崩），先 `typeof(entry) == TYPE_DICTIONARY` 判断。
- **`for kv in dict` 遍历出的是键名（String）不是键值对**：补默认值写 `for k in defaults: if not data.has(k): data[k] = defaults[k]`，写 `kv.key`/`kv.value` 会运行时才报错。
- 赋值号后不能直接换行起表达式（`x =\n "..."` Parse Error "Expected an expression after ="），多行字符串拼接用行尾 `\` 续行或首行同行起。
- mod/数据校验失败用 `push_warning(...)` 跳过该条目，不能中断其他内容加载。
- **`INF` 哨兵必须配 `is_finite()`**：GDScript 里 `INF > 0.0` 为 **true**，
  且 `INF <= INF` 也为 **true**。用 INF 表示「无命中 / 无遮挡」时，只写
  `if t > 0.0 and t <= other` 会把「没挡住」判成「挡住」——本项目踩过一次：
  子弹的障碍物遮挡判定漏了 `is_finite(block_t)`，无敌人时 enemy_t 同为 INF，
  条件恒真，导致每颗子弹在第一帧就被销毁、全场 0 击杀。
  正确写法：`if is_finite(t) and t > 0.0 and t <= other:`。
  同理 `minf/maxf/absf` 与 `is_equal_approx(INF, INF)` 也不要当普通数值用。
- **格式化字符串里出现字面 `%` 必须写 `%%`**，否则运行期报
  "unsupported format character in operator %"（更糟的情况是 Parse Error，整个脚本加载失败）。
  中文全角括号紧跟百分号是最常见的踩法：`"概率 30%（%.2f）" % x` → 必须写 `"30%%（%.2f）"`。
- **class_name 循环依赖**：两个全局类互相引用（A 调 B、B 调 A）在 GDScript 里是隐患。
  本项目 `Combat` 需要 `Obstacles` 的视线判定，而 `Obstacles` 需要线段-圆解析解，
  解法是让 `Obstacles` 本地实现那 15 行几何、只保留单向依赖 `Combat → Obstacles`。
- **手写判定的系统不要用物理体**：本项目 player/enemy/bullet 全部手写移动与命中
  （直接写 `global_position`、`Combat` 线段扫掠），放 `StaticBody2D` 进去既不挡移动也不挡子弹。
  地形/障碍物要按「纯数据 + 空间网格 + 解析几何」实现（见 `scripts/systems/obstacles.gd`）。
- **索敌要考虑遮挡**：障碍物会拦弹丸，若索敌仍死盯最近目标，玩家会对着柱子倾泻输出。
  本项目在 `Combat.nearest_enemy_visible()` 里优先选视线通畅的目标，
  全部被挡住时才退回最近目标（不允许「有敌人却不开火」）。
- **手柄 UI 确认**：project.godot 显式绑定 `ui_accept`（Enter/Space/手柄按钮 0=A）与 `ui_cancel`（Esc/按钮 1=B），不要依赖引擎默认；InputMap 重绑定系统参考 `scripts/core/settings.gd`（事件序列化为 {t:key/jbtn/jmot} 描述符存 ConfigFile，同类设备事件替换、手柄绑定快照保留）。
- **移动端触控**：虚拟摇杆参考 `scripts/ui/touch_controls.gd`——`DisplayServer.is_touchscreen_available()` 检测 + `phase_changed` 控制显隐；`_input` 处理 ScreenTouch/ScreenDrag（多点触控用 index 独占手指）；输出写 `GameState.touch_move` 模拟量，player 优先读取；Control 全程 `MOUSE_FILTER_IGNORE`，暂停钮 `FOCUS_NONE` 不抢手柄焦点；`.godot` 缓存丢失后先跑 `--import` 重建 class_name 缓存再 headless 测试。
