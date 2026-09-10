---
title: Phase 3 法宝系统设计（15 件法宝 + 多渠道掉落 + 触发式特效）
date: 2026-09-09
status: approved (2026-09-09, 用户已拍板 4 个核心决策)
depends_on: Phase 1 五行反应系统 + Phase 2 主题包内容（均已完成，连续 3 次 SMOKE: PASS）
scope: 新建法宝子系统（数据 + 触发执行器 + 掉落 + 存档 + UI）
---

# Phase 3 法宝系统设计

## 一、决策记录（用户已确认）

| 决策 | 选项 | 说明 |
|------|------|------|
| 法宝定位 | **触发式特效** | 带触发条件与参数，区别于现有 29 件纯属性道具 |
| 获取渠道 | **多渠道：精英 + BOSS + 商店** | 保证标准模式 10 波内也能体验，不做成死代码 |
| 内容骨架 | **5 五行 × 3 件 = 15 件** | 每行 common/epic/legendary 各 1，与 Phase 1/2 五行主线一脉相承 |
| 叠加容量 | **每种限 1 件、无总上限** | 重复获得转 60 材料补偿，避免触发式效果叠加破坏平衡 |

### 探索期发现的真实设计冲突（已解决）

原计划写「BOSS 必掉一件法宝」，但代码实测：

- **标准模式** `BOSS_WAVE = 10 = WAVES_TOTAL`，`main._on_boss_killed()` 当帧 `set_phase(VICTORY)` + `run_ended.emit(true)`，**局终**
- **每日挑战** 同样 BOSS 击破即通关结算，**局终**
- **无尽模式** 每 10 波一 BOSS，击杀后 `wave_ended` → 商店 → 下一波，**游戏继续**

结论：只靠 BOSS 掉落，法宝在 3 种模式里仅无尽模式有效，15 件内容大部分玩家看不到。
解决：**精英怪概率掉落 + BOSS 必掉 + 商店栏位** 三渠道并行。

---

## 二、架构

### 2.1 为什么独立于 items 管线

现有 `Registry.register_item()` 只校验 `effects` 的扁平数值（`_valid_effects` 对 `EFFECT_LIMITS`），
无法承载「触发条件 + 参数」结构；且道具可叠加计数、法宝每种限 1 件，语义冲突。

→ 新建 `Config.ARTIFACTS` + `Registry.artifacts` + `register_artifact()`，
与武器/道具/升级/敌人平级，创意工坊同样数据驱动。

### 2.2 触发执行器 ArtifactSystem

新增 `scripts/systems/artifact_system.gd`，挂 `main.tscn` 下与 `WaveManager` 同级。

**不用 autoload 的理由**：执行器需要访问 player、`enemies` 组、世界坐标来生成 AOE 与掉落物，
autoload 拿不到场景引用；做成场景节点也天然随局重置（`main.tscn` 每次重开都新建实例）。

订阅 EventBus 信号，遍历 `player.artifacts_owned` 执行匹配触发器的法宝。

### 2.3 触发器白名单（6 种）

| trigger | 触发时机 | 参数 | 数据来源 |
|---|---|---|---|
| `on_reaction` | 五行反应触发 | `element` 或 `key` | `EventBus.element_reaction` |
| `on_kill` | 击杀敌人 | `status`（可选，要求目标死前带该状态） | `EventBus.enemy_died`（新增） |
| `on_status_apply` | 玩家施加状态 | `status` | `EventBus.status_applied` |
| `on_deal_hit` | 玩家命中敌人 | `hp_below`（目标血量比例阈值） | `player._roll_damage` 回调 |
| `on_take_hit` | 玩家受伤 | — | `EventBus.player_damaged` |
| `on_wave_end` | 波次结束 | — | `EventBus.wave_ended` |

**`enemy_died(enemy)` 新信号的必要性**：`on_kill` 类法宝（凤凰翎/断刃锋/后土符）需要读目标
死前身上的状态，而现有 `enemy_killed(enemy_type: String)` 只带类型字符串。
新增信号而非改现有签名，避免破坏 4 个既有订阅者（main / sfx / codex_data / wave_manager）。

---

## 三、15 件法宝数值表

五行 → 状态映射沿用 `Config.STATUS_ELEMENT`：
fire=burn / wood=poison / metal=bleed / water=freeze,slow / earth=stun

### 火 · 爆发

| id | 图标 | 名称 | 品阶 | 触发 | 参数 | 效果 |
|---|---|---|---|---|---|---|
| `art_cinder_seal` | 🔥 | 焚天印 | common | on_reaction | element=fire | 火系反应触发时，对反应目标追加 40% 攻击力额外伤害 |
| `art_phoenix_plume` | 🪶 | 凤凰翎 | epic | on_kill | status=burn | 击杀燃烧中的敌人时，12% 概率点燃周围 120 半径敌人 1 层 |
| `art_molten_crucible` | 🌋 | 熔金炉 | legendary | on_reaction | key=fire+metal | 「火克金」破甲 50%→80%，持续 3s→5s |

### 木 · 持续 / 回复

| id | 图标 | 名称 | 品阶 | 触发 | 参数 | 效果 |
|---|---|---|---|---|---|---|
| `art_vine_knot` | 🌿 | 缠藤结 | common | on_status_apply | status=poison | 施加中毒时 15% 概率额外 +1 层 |
| `art_spore_heart` | 🍄 | 孢心 | epic | on_reaction | key=water+wood | 「水生木」扩散半径 100→180 |
| `art_world_tree` | 🌳 | 建木枝 | legendary | on_wave_end | — | 每波结束回复 18% 最大生命 |

### 金 · 暴击 / 处决

| id | 图标 | 名称 | 品阶 | 触发 | 参数 | 效果 |
|---|---|---|---|---|---|---|
| `art_notch_blade` | ⚔ | 断刃锋 | common | on_kill | status=bleed | 击杀流血敌人 +4% 暴击（本波内，上限 8 层 = 32%） |
| `art_executioner` | 🪓 | 刑天斧 | epic | on_deal_hit | hp_below=0.25 | 对血量 <25% 的敌人伤害 +45% |
| `art_soul_bell` | 🔔 | 落魂钟 | legendary | on_reaction | key=metal+wood | 「金克木」败血症期间目标受伤额外 +35% |

### 水 · 控制 / 生存

| id | 图标 | 名称 | 品阶 | 触发 | 参数 | 效果 |
|---|---|---|---|---|---|---|
| `art_frost_mirror` | ❄ | 寒镜 | common | on_reaction | element=water | 水系反应触发时 12% 概率冰冻周围 140 半径敌人 0.8s |
| `art_tide_pearl` | 🫧 | 潮汐珠 | epic | on_take_hit | — | 受击时 18% 概率释放寒冰新星（半径 150，减速 40%/2s） |
| `art_leviathan_eye` | 👁 | 蛟皇目 | legendary | on_reaction | key=earth+water | 「土克水」处决阈值 20%→32%，处决成功回复 8 生命 |

### 土 · 防御 / 资源

| id | 图标 | 名称 | 品阶 | 触发 | 参数 | 效果 |
|---|---|---|---|---|---|---|
| `art_stone_skin` | 🪨 | 岩肤符 | common | on_take_hit | — | 生命 >70% 时护甲 +4；<30% 时受伤 -22% |
| `art_earth_tally` | 🏵 | 后土符 | epic | on_kill | — | 每次击杀 8% 概率额外掉落 1 份材料 |
| `art_titan_core` | ⛰ | 玄武核 | legendary | on_reaction | element=earth | 土系反应触发 +1 层「磐石」（+1.5 护甲，永久，上限 12 层） |

**数据结构**（每件法宝）：
```
{ "id", "name", "ico", "desc", "element", "rarity",
  "trigger", "params": {...}, "effect": {...},
  "price", "shop_weight" }
```

---

## 四、获取规则

| 渠道 | 规则 |
|---|---|
| **精英怪** | 实例 `elite == true` 的敌人被击杀时 **12%** 概率掉法宝 |
| **BOSS** | **必掉 1 件**，legendary 权重 ×3 |
| **商店** | 每次开商店 **25%** 概率把其中一格换成法宝栏位，价格 = base × 波次缩放 |

- 抽取池 = **玩家尚未持有**的法宝，按 `Config.rarity_weight(rarity, wave) × shop_weight` 加权
  （复用现有稀有度公式，再乘法宝自身的商店权重）
- base price：common 110 / epic 210 / legendary 300
- `register_artifact` 价格上限 **400**（与道具 300 区分，法宝定位更高阶）
- **重复获得补偿**：已持有的法宝再次掉落 → 转化为 **60 材料** + 飘字提示，绝不空掉落

### 4.0 实现偏差（已定稿）：精英判定用实例标志位，不按敌人类型

原设计写「`ELITE_POOL` 6 种被击杀时掉落」。实现时改为**实例 `elite` 标志位**：

- `Config.wave_composition` 里 guard/wizard/shadow/bomber 在 **W7+ 常规波**就会成批出现，
  按类型判定会误伤大量常规怪，实际掉率远超 12%
- `enemy.gd` 新增 `var elite := false`，由 `wave_manager.spawn(type, is_elite)` 注入
- `wave_manager` 用伴随标志位 `_picked_elite`（不改 `_pick_spawn_id` 的返回签名，
  冒烟测试有字符串断言依赖它）
- 好处：判定与「这一只到底是不是精英刷新出来的」严格一致，且 mod 新增敌人无需登记类型表

### 4.1 掉落表现（两条路径分开）

| 来源 | 表现 | 理由 |
|---|---|---|
| 精英怪 | 新增 `Loot` kind `"artifact"`，走磁吸拾取 | 有充足时间捡，割草爽感 |
| BOSS | **直接入账 + 横幅公告**，不生成实体掉落物 | 标准/每日模式 BOSS 死亡当帧就 `set_phase(VICTORY)`，实体掉落来不及被磁吸拾取，会直接白掉 |

BOSS 直接入账有既有 precedent：宝箱波 `wave_manager._settle_event_wave()` 就是
`player.apply_item()` + `banner_requested` + `Sfx.play("buy")`。

### 4.2 Loot 携带 id 的实现

`Loot.setup(kind, value: int, pos, velocity)` 的 `val` 是 int，无法承载法宝字符串 id。
→ 新增 `artifact_id: String` 字段，仅 kind=="artifact" 时使用，`settle()` 分支调
`player.apply_artifact(artifact_id)`。

---

## 五、集成点（10 处）

| # | 文件 | 改动 |
|---|------|------|
| 1 | `scripts/core/config.gd` | `ARTIFACTS` 常量（15 件）+ `ARTIFACT_TRIGGERS` 白名单 + 4 个概率/补偿常量 |
| 2 | `scripts/core/registry.gd` | `artifacts` 字典 + `register_artifact()` + `artifact_list()` + `get_artifact()` + **`artifact_pool(owned, wave, boss=false)`** + PARAM/EFFECT/PATCH/STACK_RESET 白名单校验 + 引导注册 + `_apply_manifest` / `save_content` 支持 |
| 3 | `scripts/core/event_bus.gd` | 新增 `enemy_died(enemy)` 与 `artifact_acquired(id)` 信号 |
| 4 | `scripts/systems/artifact_system.gd` + `scenes/main.tscn` | 新建触发执行器脚本 + 挂节点 |
| 5 | `scripts/characters/player.gd` | `artifacts_owned: Dictionary` + `apply_artifact()` + `sell_artifact()` |
| 6 | `scripts/enemies/enemy.gd` | `elite` 标志位；`die()` 发 `enemy_died`；`_drop_loot()` 精英分支加概率掉落；反应执行前调 `patch_reaction_effect`；`take_damage` 乘 `execute_damage_mult`；`execute_heal` 结算 |
| 7 | `scripts/loot/loot.gd` | 新增 `"artifact"` kind + `artifact_id` 字段 + `setup_artifact()` + 绘制 |
| 8 | `scripts/core/codex_data.gd` | `CATEGORIES` 加 `"artifact"`，`UNLOCK_REWARDS["artifact"] = 6` |
| 9 | `scripts/core/save_run.gd` | 持久化 `artifacts_owned` + `_read` 恢复 + 存档校验（非法 id 丢弃） |
| 10 | UI | `shop_ui.gd` 法宝栏位与出售、`main.gd` 暂停面板法宝列表、`workshop.gd` 创意工坊 schema |

**实现偏差（已定稿）：`artifact_pool` 归 Registry，不归 Config**

抽取池要遍历 `Registry.artifacts`（含 mod 注册的法宝）并复用 `rarity_weight`，
放在 Config 里会形成 Config → Registry 的反向依赖。→ 落在 `registry.gd`，
签名 `artifact_pool(owned: Dictionary, wave: int, boss: bool = false) -> Array`。

**BOSS 必掉不在 `enemy.gd` 的 BOSS 分支里做**，而在 `artifact_system._on_boss_killed()`：
BOSS 死亡当帧就 `set_phase(VICTORY)`，`enemy.gd` 里拿不到「直接入账 + 横幅」所需的 UI 上下文，
交给订阅 `boss_killed` 的系统节点更干净。

**改了的文件**：`wave_manager.gd`（`spawn(type, is_elite)` + `_picked_elite` 注入精英标志位）

**不动的文件**：`combat.gd` / `hud.gd`（法宝不占常驻 HUD，只在商店、图鉴与暂停面板展示）

---

## 六、边界与错误处理

### 6.1 Registry 校验拒绝清单

`register_artifact()` 拒绝以下条目（沿用现有 `_reject` 打 warning + 返回 false 的模式）：

- `trigger` 不在白名单 6 种内
- `element` 不在 `Config.ELEMENTS` 内
- `key` 不在 `Config.REACTIONS` 内
- `status` 不在 `Config.STATUS` 内
- 概率类参数不在 [0, 1]
- 半径类参数不在 [1, 600]
- 时长类参数不在 [0, 30]
- 倍率类参数不在 [0, 10]
- `price` > 400 或非非负整数
- `rarity` 不在 `Config.RARITIES`
- id/name 为空字符串
- 内置法宝 id 被 mod 覆盖（沿用现有保护策略）

### 6.2 运行时守卫

- 存档里的法宝 id 若已被 mod 移除 → 静默丢弃，不崩档（与 `items_owned` 现有行为一致）
- `ArtifactSystem` 在 player 失效 / 局终后不再触发（`GameState.is_running()` + `is_instance_valid(player)` 双守卫）
- 层数类效果重置时机：
  - 断刃锋「锋锐」层 → `wave_started` 重置（本波内有效）
  - 玄武核「磐石」层 → 永久，仅局终重置
- 所有触发都有 `GameRng.chance()` 概率判定，概率 0 直接短路，不做无谓遍历

### 6.3 性能

- `ArtifactSystem` 每次信号回调先检查 `player.artifacts_owned.is_empty()` → 空则立即 return
- 按 trigger 类型预建索引（`_by_trigger: Dictionary`，持有法宝变化时重建），避免每次遍历全部 15 件
- AOE 类效果复用 `Combat.enemies_near()` 空间索引，不做全场遍历

---

## 七、测试计划

新增 `_check_phase3_artifacts()`，验证点：

1. **数据完整性** — 15 件法宝全部注册；5 五行各 3 件；品阶分布 common/epic/legendary 各 5
2. **参数合法性** — 所有 trigger 在白名单内；所有 element/key/status 引用真实存在
3. **Registry 拒登** — 构造 8+ 条非法条目（未知 trigger / 非法 element / 不存在的 key / 概率越界 / 半径越界 / price 超限），断言全部被拒且 `artifacts.size()` 仍为 15
4. **合法注册 + 还原** — 注册临时法宝成功，清理后仍为 15
5. **获取规则** — 精英掉落概率生效（多次击杀统计）；BOSS 必掉；重复获得转 60 材料
6. **apply_artifact 幂等** — 同 id 调两次，`artifacts_owned` 仍只 1 件，第二次触发材料补偿
7. **图鉴** — `CodexData.unlock("artifact", id)` 生效，`CATEGORIES` 含 artifact，奖励在 [4,7]
8. **存档往返** — 持有法宝 → 存盘 → 读盘 → 仍持有；存档含非法 id → 被丢弃不崩
9. **触发器实跑** — 构造燃烧 + 流血目标触发「火克金」，断言熔金炉把破甲提升到 80%、时长 5s
10. **触发器实跑 2** — 断刃锋击杀流血敌人后暴击率 +4%，`wave_started` 后层数归零

验收标准：连续 3 次 `SMOKE: PASS`，stderr 无非预期 SCRIPT ERROR。
（原写「退出码 0」已删：Godot Windows 版是 GUI 子系统 exe，经 `Start-Process` 拉起时
`$LASTEXITCODE` 拿不到值，**stdout 的 `SMOKE: PASS` 才是可靠判据**。）

---

## 八、与原计划（Phase 3）的范围差异

原计划用 `RELICS` 术语并假设「法宝槽上限 3」。本文的**决策 4（每种限 1 件、无总上限）**
直接作废了槽位概念，以下三项因此不再实现：

| 原计划项 | 处置 | 理由 |
|---|---|---|
| 3.3 法宝槽上限 3（天赋扩展到 5） | **作废** | 无总上限，每种限 1 件，槽位无意义；上限改由「重复获得转 60 材料」自然调节 |
| 3.8 HUD 法宝槽（3 格常驻） | **作废** | 法宝是触发式特效而非常驻技能，不占 HUD；改在商店/图鉴/暂停面板展示 |
| 3.11 MetaProgress「法宝大师」天赋（槽+1） | **作废** | 依赖槽位上限，随 3.3 一同失效 |
| 3.5 `wave_manager.spawn_relic_drop` + `RelicDrop` 新场景 | **改为复用 `Loot`** | 新增 `kind == "artifact"` 分支，不另建场景（见 4.1 / 4.2） |
| 3.7 触发逻辑放 `main.gd` | **改为独立 `artifact_system.gd`** | main.gd 已过大；触发器集中到单一执行器，信号订阅而非散布 |

---

## 九、未决问题（挂账后续）

| 问题 | 挂账到 | 备注 |
|------|-------|------|
| 法宝合成 / 升阶（3 件同行 → 1 件神器） | 后续 Phase | 需新增合成 UI 与配方表 |
| 角色与法宝的羁绊加成 | 后续 Phase | 5 门派 × 5 行 = 25 组羁绊，数值工作量大 |
| 法宝主动技（按键释放） | 已否决 | 用户在决策 1 中选了触发式，主动技另立系统 |
| 创意工坊表单不支持 patch 类法宝的嵌套 effect | 后续 Phase | 熔金炉/孢心/落魂钟/蛟皇目 4 件需手写 `mods/*/manifest.json`；数据管线本身已支持，仅编辑器不做嵌套录入 |
