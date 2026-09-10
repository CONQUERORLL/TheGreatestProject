# 「东方奇谭」玩法包 · Phase 4-5 实施计划

> **导出说明**：本文摘自总计划《「东方奇谭」玩法包 · 实施计划》（共 5 个 Phase，598 行），
> 只保留 Phase 4 与 Phase 5，并把总计划中散落在「风险与应对」「测试计划」「文件清单」
> 「验收标准」「分阶段发布计划」各章节里与这两个 Phase 直接相关的条目聚合到对应位置。
> Phase 4/5 正文为原文照录，未改动任务定义。

## 前置状态

Phase 1-3 已完成、已提交、已推送：

| 提交 | Phase | 规模 |
|---|---|---|
| `e2f9159` | Phase 1 五行相生相克反应系统 | 23 files, +1466 −20 |
| `b8f2dd4` | Phase 2 东方奇谭主题内容包 | 4 files, +1046 −19 |
| `255aa57` | Phase 3 法宝系统 | 20 files, +2243 −36 |

分支 `pc`，与 `origin/pc` 同步，冒烟测试通过。Phase 4/5 在此基础上继续。

## 已确认的设计决策（与本文相关）

总计划共 5 条关键决策，其中约束 Phase 4/5 的是后两条：

4. **奇遇触发**：商店后随机 30%，每局最多 3-5 次
5. **地图主题化**：换背景 + 装饰性障碍物（3 主题，不可破坏）

## 工作量定位

| 系统 | 工作量 | 周数 |
|---|---|---|
| 江湖奇遇（10 个事件卡） | M | 1.5 周 |
| 地图主题化（3 主题 + 障碍物） | M | 1.5 周 |

---

## Phase 4：江湖奇遇事件卡（Week 8-9）

### 目标
实现江湖奇遇事件卡系统，10 个事件（三选一决策），商店后随机 30% 触发。

### 任务清单

#### 4.1 数据结构（`scripts/core/config.gd`）
- 新增 `const EVENT_CARDS: Array` 数据表（10 个事件）
- 每个事件字段：`id`, `title`, `desc`, `choices` (数组), `rarity`, `theme`
- 每个 choice 字段：`text`, `effect` (字典)

#### 4.2 事件卡 UI（`scenes/ui/event_card.tscn` + `scripts/ui/event_card.gd`）
- 新增场景（复用 level_up_ui 布局）
- 全屏遮罩 + 标题 + 描述 + 3 选项按钮
- 键盘 1/2/3 + 手柄焦点 + 鼠标点击
- 选择后发出信号，关闭 UI

#### 4.3 事件触发逻辑（`scripts/main.gd`）
- 修改 `_on_wave_ended()`，在 `shop_ui.close()` 后加事件触发分支
- 新增 `_try_trigger_event_card()` 方法：
  - 检查触发概率（30%）
  - 检查每局上限（3-5 次）
  - 随机选择事件（考虑 theme 和前置条件）
  - 打开 EventCardUI
- 新增 `_on_event_choice(card_id, choice_id, effect)` 方法：
  - 执行效果（cost_materials/grant_item/spawn_elite/...）
  - 发出 EventBus 信号
  - 显示横幅提示

#### 4.4 事件效果执行（`scripts/main.gd`）
- 新增 `_execute_event_effect(effect: Dictionary)` 方法：
  - `cost_materials`: 扣除材料
  - `grant_item`: 给予随机道具（调用 Registry）
  - `grant_relic`: 给予随机法宝
  - `spawn_elite`: 生成精英怪
  - `unlock_reaction`: 解锁五行反应（永久）
  - `heal_pct`: 回复生命百分比
  - 等

#### 4.5 事件总线（`scripts/core/event_bus.gd`）
- 新增信号：`signal event_card_triggered(card_id: String, choice_id: String)`

#### 4.6 图鉴集成（`scripts/core/codex_data.gd`）
- 新增 `events` 分类（图鉴第 10 页）
- 新增事件图鉴数据（10 项）

#### 4.7 GameState 扩展（`scripts/core/game_state.gd`）
- 新增 `event_card_count: int` 字段（每局触发次数）
- 修改 `reset_run()` 重置计数器

#### 4.8 冒烟测试（`tests/smoke_test.gd`）
- 新增事件卡测试用例：
  - 事件触发概率（30%）
  - 每局上限（3-5 次）
  - 每个选项效果正确执行
  - 图鉴解锁

### 验证点
- [x] 10 个事件全部可触发
- [x] 触发概率 30% + 每局上限 3-5 次
- [x] 每个选项效果正确执行
- [x] 图鉴解锁 + toast
- [x] 冒烟测试通过

### 工作量
- 数据结构：2 天
- 事件卡 UI：3 天
- 触发逻辑：2 天
- 效果执行：2 天
- 图鉴/GameState：1 天
- 测试：1 天
- **总计：11 天（1.5 周）**

### 相关风险（摘自总计划「风险与应对」）

| 风险 | 影响 | 应对 |
|---|---|---|
| 事件卡文本量大 | 本地化困难 | 先做中文，英文后补 |

### 相关测试（摘自总计划「测试计划」）
- 单元测试：事件卡 10 个事件选项效果
- 集成测试：存档序列化（事件卡计数）、图鉴解锁（事件）

### 发布亮点（摘自总计划「分阶段发布计划」）
> "叙事调味：10 个事件卡，三选一决策"

每个 Phase 完成后可作为版本更新公告，不必等全部完成。

---

## Phase 5：地图主题化 + 平衡性（Week 10-12）

### 目标
实现 3 个地图主题（竹林/古庙/幽冥）+ 装饰性障碍物，以及整体平衡性调优。

### 任务清单

#### 5.1 障碍物场景（`scenes/obstacle.tscn` + `scripts/obstacle.gd`）
- 新增场景（StaticBody2D + CollisionShape2D + Sprite2D）
- 阻挡子弹（CollisionLayer 设置）
- 阻挡移动（玩家/敌人 CollisionMask）
- 不可破坏（无 HP）
- 3 种 Sprite（竹子/庙柱/石碑）

#### 5.2 地图主题数据（`scripts/core/config.gd`）
- 新增 `const MAP_THEMES: Dictionary`：
  ```
  {
    "bamboo": {"bg_color": "#2d5a27", "obstacle": "bamboo", "particle": "bamboo_leaf"},
    "temple": {"bg_color": "#8b2500", "obstacle": "pillar", "particle": "incense"},
    "nether": {"bg_color": "#1a1f3a", "obstacle": "stele", "particle": "ghost_fire"},
  }
  ```

#### 5.3 障碍物生成（`scripts/main.gd`）
- 新增 `spawn_obstacles(theme: String, count: int)` 方法：
  - 随机生成 30-50 个障碍物
  - 避开玩家出生点（半径 200 内无障碍物）
  - BOSS 波减少障碍物（上限 15 个）
- 修改 `_on_wave_started()` 调用障碍物生成
- 修改 `_draw()` 背景色根据主题切换

#### 5.4 主题切换（`scripts/systems/wave_manager.gd`）
- 根据波次切换主题（波 1-3 竹林 / 4-6 古庙 / 7-10 幽冥）
- 修改 `start_wave()` 设置当前主题

#### 5.5 粒子效果（`scripts/fx/`）
- 新增竹叶粒子（bamboo_leaf.gd）
- 新增香火粒子（incense.gd）
- 新增鬼火粒子（ghost_fire.gd）

#### 5.6 平衡性调优
- 五行反应伤害上限（不超过同波次普通伤害的 3 倍）
- 法宝掉落权重（BOSS 必掉 epic+）
- 事件卡触发概率（30%）+ 每局上限（3-5 次）
- 障碍物数量（30-50 个，BOSS 波 15 个）
- 新角色/武器/敌人数值平衡（封闭测试反馈）

#### 5.7 冒烟测试（`tests/smoke_test.gd`）
- 新增地图主题测试用例：
  - 障碍物生成（数量/分布/避开出生点）
  - 障碍物碰撞（阻挡子弹/移动）
  - 主题切换（背景/障碍物/粒子）
  - BOSS 波障碍物减少

#### 5.8 封闭测试准备
- 准备测试包（Windows 导出）
- 收集玩家反馈（平衡性/Bug/体验）
- 迭代调整数值

### 验证点
- [x] 3 个地图主题正确切换
- [x] 障碍物生成/碰撞正确
- [x] BOSS 波障碍物减少
- [x] 平衡性调优完成（相克爆发上限 REACTION_BURST_CAP_MULT=12，其余复核）
- [x] 冒烟测试通过
- [ ] 封闭测试无重大 Bug

### 工作量
- 障碍物场景：2 天
- 地图主题数据：1 天
- 障碍物生成：2 天
- 粒子效果：2 天
- 平衡性调优：3 天
- 测试：2 天
- 封闭测试准备：2 天
- **总计：14 天（2 周）**

### 相关风险（摘自总计划「风险与应对」）

| 风险 | 影响 | 应对 |
|---|---|---|
| 障碍物影响性能 | 帧率下降 | 对象池 + 限制数量（30-50 个） |
| 五行反应破坏平衡 | 某些组合无敌 | 反应伤害上限 + BOSS 抗性 + 封闭测试 |
| 法宝机制太复杂 | 新手困惑 | 法宝描述清晰 + 暂停页详情 |

> 后两条针对 Phase 1/3 的已交付内容，由 5.6 平衡性调优统一回收处理。

### 相关测试（摘自总计划「测试计划」）
- 单元测试：地图 3 主题切换 + 障碍物生成
- 集成测试：存档序列化（主题）
- **封闭测试（Phase 5 后）**：10-20 个玩家试玩，收集反馈（平衡性/Bug/体验），迭代调整

### 发布亮点（摘自总计划「分阶段发布计划」）
> "视觉升级：3 主题地图 + 障碍物 + 平衡性调优"

---

## 文件清单（Phase 4-5 部分）

摘自总计划「文件清单」，按任务条目归属拆分；括号内为对应任务号。

### 新增文件

| 文件 | 归属 |
|---|---|
| `scenes/ui/event_card.tscn` | 4.2 |
| `scripts/ui/event_card.gd` | 4.2 |
| `scenes/obstacle.tscn` | 5.1 |
| `scripts/obstacle.gd` | 5.1 |
| `scripts/fx/bamboo_leaf.gd` | 5.5 |
| `scripts/fx/incense.gd` | 5.5 |
| `scripts/fx/ghost_fire.gd` | 5.5 |

### 修改文件

| 文件 | 改动内容 | 归属 |
|---|---|---|
| `scripts/core/config.gd` | `EVENT_CARDS` / `MAP_THEMES` | 4.1 / 5.2 |
| `scripts/core/event_bus.gd` | `event_card_triggered` 信号 | 4.5 |
| `scripts/core/game_state.gd` | `event_card_count` + `reset_run()` 重置 | 4.7 |
| `scripts/core/codex_data.gd` | `events` 分类（图鉴第 10 页） | 4.6 |
| `scripts/main.gd` | 事件卡触发/效果执行、障碍物生成、背景色切换 | 4.3 / 4.4 / 5.3 |
| `scripts/systems/wave_manager.gd` | 主题切换（`start_wave()` 设置当前主题） | 5.4 |
| `tests/smoke_test.gd` | 事件卡用例、地图主题用例 | 4.8 / 5.7 |

> 总计划原清单为 Phase 1-5 混合，未逐项标注归属；上表按任务条目推断。
> 与 Phase 4/5 无关的条目（mod 主题包 6 个 json、`registry.gd` 法宝校验、`save_run.gd`、
> `meta_progress.gd`、`player.gd`、`enemy.gd`、`hud.gd`、`shop_ui.gd`、`main_menu.gd`）未列入。
>
> 两处原计划内部不一致，实施时以任务条目为准：
> - 原清单写 `game_state.gd（theme_id/event_card_count）`，其中 `theme_id` 是 Phase 2 的 mod
>   主题字段（配合 `main_menu.gd` 的主题选择），不属本文范围；Phase 5.4 的地图主题由
>   `wave_manager.start_wave()` 设置，原计划未说明是否要落到 `game_state`。
> - 原清单把「障碍物生成」记在 `wave_manager.gd` 名下，但任务 5.3 明确写在 `main.gd`
>   （`spawn_obstacles()` + `_on_wave_started()` 调用）。以 5.3 为准。

---

## 验收标准（Phase 4-5 部分）

摘自总计划「验收标准」，共 8 条中属于这两个 Phase 的 5 条：

- [x] 江湖奇遇：10 个事件全部可触发，30% 概率 + 每局上限
- [x] 地图主题化：3 主题切换 + 障碍物生成/碰撞
- [x] 所有冒烟测试通过
- [ ] 封闭测试无重大 Bug
- [ ] 平衡性调优完成（玩家反馈良好）

---

## 执行约定（导出时补充，非原计划内容）

原计划「下一步行动」写的是「创建分支 `feature/oriental-fantasy`」，该步已过时——
Phase 1-3 实际在 `pc` 分支完成并推送。按仓库已验证的节奏，Phase 4/5 沿用：

- **冒烟测试**：每个 Phase 完成后跑
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File game\tools\run_smoke.ps1 -Times 3`，
  要求连续 3 次 `SMOKE: PASS`。判定看 stdout 的 `SMOKE:` 行，不看退出码
  （Godot Windows 版是 GUI 子系统 exe，经 `Start-Process` 拉起拿不到 `$LASTEXITCODE`）。
- **实机验证**：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File game\tools\run_game.ps1`
  带窗口启动，可用 `-Scene res://scenes/main.tscn` 跳过主菜单直接进战斗。
- **提交粒度**：每个 Phase 一个提交，与前三个提交保持一致的 message 风格
  （`feat: <系统名>` + 要点列表）。
