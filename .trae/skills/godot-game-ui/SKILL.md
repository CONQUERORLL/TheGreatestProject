---
name: "godot-game-ui"
description: "Godot 4 游戏内 UI 搭建规范（代码构建节点 + Registry 数据源 + 手柄焦点 + 震动）。Invoke when 在本工作区新建/修改游戏界面（菜单、HUD、商店、弹卡、向导）或需要手柄可导航的 UI。运行测试、实机启动、提交推送、GDScript 语言陷阱见 godot-dev-workflow。"
---

# Godot 游戏 UI 搭建规范（TheGreatestProject 工作区）

本技能沉淀自 HUD / 商店 / 升级三选一 / 主菜单分步向导 / 创意工坊 的实战经验。
在本工作区（Godot 4.7，项目根 `game/`）做任何界面开发时遵循。

> 运行冒烟测试、拉起实机、提交推送、沙箱工具限制、GDScript 语言陷阱
> → 见 `godot-dev-workflow`。

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

## 5. 视觉与反馈

- 按钮/卡片选中：`Haptics.rumble(0.15, 0.0, 0.05)`；确认：`0.3, 0.0, 0.1`。Haptics 内部有 40ms 节流，不用自己防连点。
- 标题强调色 `Color("e8b84b")`（土豆黄），次要文字 `Color("9aa3b2")`，背景 `Color("101218")`。
- **稀有度着色**：色表统一取 `Config.rarity_color(r)`（common 白 / rare 蓝 / epic 紫 / legendary 红）；难度色阶 `Config.DIFFICULTY_COLORS`（normal 绿 / hard 橙 / nightmare 红）。卡片样式 = accent 色 9% 微底 + 2px 描边圆角，hover/focus 金边 + 20% 底（参考 `main_menu.gd` `_make_card` / `shop_ui.gd` `_rarity_style`）。
- **侧面板页**（暂停/商店共用形态）：全屏遮罩 + MarginContainer + HBox[左属性面板 | 中内容 | 右道具面板]；属性行 = 名称灰 + 数值金（`_stat_row` 模式）；道具面板 ScrollContainer 内行式布局。暂停页打开时重建内容（数值实时变）。
- **角色特性展示**：主菜单角色卡把特性置顶（`⚡【名称】描述`），HUD 特性行显示关键加成数字（`⚡ 弹道精通（弹速 +60%）`）而不只是特性名；动态特性（战意/光环半径）实时取值。

## 6. 输入设备

- **手柄 UI 确认**：`project.godot` 显式绑定 `ui_accept`（Enter/Space/手柄按钮 0=A）与 `ui_cancel`（Esc/按钮 1=B），**不要依赖引擎默认**。InputMap 重绑定系统参考 `scripts/core/settings.gd`（事件序列化为 `{t:key/jbtn/jmot}` 描述符存 ConfigFile，同类设备事件替换、手柄绑定快照保留）。
- **移动端触控**：虚拟摇杆参考 `scripts/ui/touch_controls.gd` ——
  `DisplayServer.is_touchscreen_available()` 检测 + `phase_changed` 控制显隐；
  `_input` 处理 ScreenTouch/ScreenDrag（多点触控用 index 独占手指）；
  输出写 `GameState.touch_move` 模拟量，player 优先读取；
  Control 全程 `MOUSE_FILTER_IGNORE`，暂停钮 `FOCUS_NONE` 不抢手柄焦点。
