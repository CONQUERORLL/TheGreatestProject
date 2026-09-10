---
title: Phase 2 主题包内容设计（5 角色 + 8 武器 + 10 敌人 + 3 BOSS）
date: 2026-09-09
status: approved (2026-09-09, 用户已拍板 3 个平衡性风险)
depends_on: Phase 1 五行反应系统（已完成，连续 3 次 SMOKE: PASS）
scope: 纯数据注入（保守版）——不改 enemy.gd / player.gd / weapon schema
---

# Phase 2 主题包内容设计

## 概览

### 定位
江湖五行录主题内容包，作为 Phase 1 五行反应系统的**内容承载层**：
- **5 个新角色** = 5 个五行门派修士，每个专精一个五行状态
- **8 个新武器** = 补齐五行状态覆盖（尤其 slow / stun 空白），每个五行至少 2 把武器
- **10 个新敌人** = 每个五行 2 只，附带对应五行抗性
- **3 个新 BOSS** = 五行主宰（火/水/土），扩展 BOSS_POOL 到 6 个

### 决策记录（用户已确认）
| 决策 | 选项 | 说明 |
|------|------|------|
| Phase 2 边界 | **A. 保守：纯数据注入** | 不动 enemy.gd / player.gd / weapon schema，26 项内容全部只用现有字段 |
| 复合状态武器 | **A. 改为单状态高叠层** | 8 把武器全部单状态，靠 status_stacks 与 status_chance 差异化 |
| 角色主题 | **五行门派修士** | 5 个角色 = 5 个五行专精，与 Phase 1 五行反应深度绑定 |

### 不做的事（挂账到后续 Phase）
- ❌ 复合状态武器（`status2` 字段） → 挂账 Phase 3 法宝系统一起考虑
- ❌ BOSS 死亡技能 / AOE 眩晕波 / 减伤护甲 → 挂账 Phase 5 平衡性调优
- ❌ 敌人给玩家上异常（反向五行） → 挂账 Phase 5
- ❌ 门派专属天赋树 → 挂账后续
- ❌ 地图主题化 → 已在 Phase 5 计划里

---

## 一、5 个新角色（五行门派修士）

### 数据位置
`game/scripts/core/registry.gd` `_register_builtin()` 内的 `characters` 字典追加 5 项。

### 内容清单

| ID | 名称 | 五行 | 图标 | 颜色 | 起手武器 | 定位 |
|----|------|------|------|------|---------|------|
| `pyromancer` | 焚天祭司 | 火 | 🔥 | `#ff7a3c` | `flamethrower` | 火系爆发，状态伤害/持续加成，血薄 |
| `druid` | 青囊药王 | 木 | 🌿 | `#7ec850` | `venom_dagger` | 毒扩散流，命中率+持续时间+扩散 |
| `swordmaster` | 太白剑客 | 金 | ⚔ | `#dfe6f0` | `blade` | 高暴击流血，攻速/伤害均衡 |
| `tidecaller` | 沧海鲛人 | 水 | 💧 | `#8fd8ff` | `frost_staff` | 冰控场，命中率+持续+移速 |
| `geomancer` | 厚土方士 | 土 | ⛰ | `#ffd24a` | `knife` | 眩晕坦克，高血高甲低移速 |

### 数值详解

#### 1. `pyromancer` 焚天祭司（火）
```gdscript
"pyromancer": {
    "id": "pyromancer", "name": "焚天祭司", "ico": "🔥",
    "desc": "火系爆发：状态伤害 +35%，异常持续 +25%，命中率 +10%；代价是血薄甲脆。初始武器：火焰喷射器",
    "color": "#ff7a3c", "start_weapon": "flamethrower",
    "stats": {
        "status_dmg_mult": 0.35, "status_dur_mult": 0.25, "status_chance": 0.10,
        "max_hp": 85.0, "armor": -1.0, "dmg_mult": 0.95,
    },
},
```
**平衡锚点**：`i-pyro` 熔火核心 = status_dmg_mult 0.35 + status_dur_mult 0.25，价 195。焚天祭司 = 白送一件 mythic 道具，但血量 -15、护甲 -1、伤害 -5%。

#### 2. `druid` 青囊药王（木）
```gdscript
"druid": {
    "id": "druid", "name": "青囊药王", "ico": "🌿",
    "desc": "毒扩散流：异常命中 +20%，持续 +35%，中毒扩散 +60%；材料获取微幅加成。初始武器：毒牙匕首",
    "color": "#7ec850", "start_weapon": "venom_dagger",
    "stats": {
        "status_chance": 0.20, "status_dur_mult": 0.35, "status_spread": 0.60,
        "max_hp": 90.0, "dmg_mult": 0.92, "harvesting": 0.15,
    },
},
```
**平衡锚点**：`i-plague` 瘟疫之心 = status_dmg_mult 0.60 + status_spread 1.0，价 175。药王给的扩散 0.6 是它的六折，配合高命中率+持续时间形成"木系专属玩法"。

#### 3. `swordmaster` 太白剑客（金）
```gdscript
"swordmaster": {
    "id": "swordmaster", "name": "太白剑客", "ico": "⚔",
    "desc": "剑道宗师：暴击 +12%、暴伤 +230%、攻速 +5%、伤害 +10%、异常命中 +8%。初始武器：太刀",
    "color": "#dfe6f0", "start_weapon": "blade",
    "stats": {
        "crit_ch": 0.12, "crit_mult": 2.3, "as_mult": 1.05, "dmg_mult": 1.10,
        "status_chance": 0.08, "max_hp": 88.0,
    },
},
```
**平衡锚点**：介于 `ranger`（暴击流远程）和 `berserker`（伤害流近战）之间，但走"暴击 + 流血"复合路线，触发土生金（流血+眩晕暴击必中）时爆发极高。

#### 4. `tidecaller` 沧海鲛人（水）
```gdscript
"tidecaller": {
    "id": "tidecaller", "name": "沧海鲛人", "ico": "💧",
    "desc": "冰控场：异常命中 +15%，异常持续 +30%，移速 +8%，护甲 +1。血薄。初始武器：霜冻法杖",
    "color": "#8fd8ff", "start_weapon": "frost_staff",
    "stats": {
        "status_chance": 0.15, "status_dur_mult": 0.30, "speed_mult": 1.08,
        "armor": 1.0, "max_hp": 82.0,
    },
},
```
**平衡锚点**：血量最低（82）但控场能力最强，配合土克水反应（消耗冰冻/眩晕，血量<20% 直接处决）可以秒 BOSS。

#### 5. `geomancer` 厚土方士（土）
```gdscript
"geomancer": {
    "id": "geomancer", "name": "厚土方士", "ico": "⛰",
    "desc": "眩晕坦克：生命 140、护甲 4、回复 0.4/s、异常命中 +10%；代价是移速 -10%、伤害 -5%。初始武器：砍刀",
    "color": "#ffd24a", "start_weapon": "knife",
    "stats": {
        "max_hp": 140.0, "armor": 4.0, "regen": 0.4, "status_chance": 0.10,
        "dmg_mult": 0.95, "speed_mult": 0.90,
    },
},
```
**平衡锚点**：血量比 `guardian`（165）低但异常命中高，走"眩晕+土系反应"路线，触发火生土/土生金/土克水都能吃到收益。

### 每日挑战角色池扩展
`Config.daily_setup()` 里的 `chars` 数组从 7 扩到 12：
```gdscript
var chars := ["potato", "berserker", "ranger", "gambler", "farmer", "vampire", "guardian",
    "pyromancer", "druid", "swordmaster", "tidecaller", "geomancer"]
```

### 角色校验对照
- ✅ 所有 stats 键都在 `Registry.STAT_LIMITS` 里
- ✅ 所有 stats 数值都在 limit 区间内（max_hp ∈ [1, 10000], armor ∈ [-7.9, 1000], status_chance ∈ [0, 1] 等）
- ✅ color 都是合法 HTML 色值
- ✅ start_weapon 都指向已注册武器（flamethrower/venom_dagger/blade/frost_staff/knife 均已存在）

---

## 二、8 个新武器（补齐五行状态）

### 现有武器状态覆盖
| 五行 | 状态 | 现有武器数 |
|------|------|-----------|
| 火 | burn | 2（flamethrower, rocket） |
| 木 | poison | 1（venom_dagger） |
| 金 | bleed | 3（knife, sniper, blade） |
| 水 | freeze | 1（frost_staff） |
| 水 | slow | **0** ⚠️ |
| 土 | stun | **0** ⚠️ |

### 新增武器状态覆盖目标
| 五行 | 状态 | 新增数 | 覆盖后 |
|------|------|--------|-------|
| 火 | burn | 2（ember_fan, flame_jian） | 4 |
| 木 | poison | 1（vine_lash） | 2 |
| 金 | bleed | 1（gold_bell） | 4 |
| 水 | freeze | 1（frost_nova） | 2 |
| 水 | slow | 1（tar_whip） | **1**（补齐空白） |
| 土 | stun | 2（thunder_gong, chaos_hammer） | **2**（补齐空白） |

### 数据位置
- 武器条目：`Config.WEAPONS` 追加 8 项
- 商店权重：`Config.WEAPON_SHOP_WEIGHTS` 追加 8 项
- 商店价格：`Config.WEAPON_PRICES` 追加 8 项

### 内容清单

| ID | 名称 | 五行 | 类型 | 图标 | 稀有度 | CD | DMG | 状态 | 触发率 | 叠层 | 价格 | 商店权重 |
|----|------|------|------|------|--------|-----|-----|------|-------|------|------|---------|
| `thunder_gong` | 震雷法锣 | 土 | projectile | 🔔 | epic | 1.10 | 22 | stun | 0.45 | 1 | 72 | 0.9 |
| `tar_whip` | 沥青长鞭 | 水 | melee | 🕸 | rare | 0.55 | 14 | slow | 0.65 | 1 | 42 | 1.5 |
| `ember_fan` | 赤焰折扇 | 火 | projectile | 🪭 | rare | 0.70 | 10 | burn | 0.50 | 1 | 46 | 1.3 |
| `vine_lash` | 青藤缠索 | 木 | projectile | 🌱 | rare | 0.90 | 13 | poison | 0.55 | 2 | 48 | 1.2 |
| `gold_bell` | 金铃破空 | 金 | projectile | 🛎 | epic | 0.85 | 26 | bleed | 0.55 | 2 | 74 | 1.0 |
| `frost_nova` | 玄冰新星 | 水 | projectile | 🧊 | epic | 1.30 | 18 | freeze | 0.40 | 1 | 78 | 0.9 |
| `flame_jian` | 火焰长剑 | 火 | melee | 🌋 | legendary | 0.48 | 24 | burn | 0.75 | 3 | 145 | **1.2** |
| `chaos_hammer` | 混沌重锤 | 土 | melee | 🔨 | mythic | 1.20 | 45 | stun | 0.60 | 1 | 105 | **1.0** |

### 数值详解

#### 1. `thunder_gong` 震雷法锣（土，stun）
```gdscript
"thunder_gong": {
    "name": "震雷法锣", "ico": "🔔", "attack_type": "projectile", "sfx": "shoot_rocket",
    "cd": 1.10, "dmg": 22.0, "bspeed": 340.0, "splash": 90.0,
    "status": "stun", "status_chance": 0.45, "status_stacks": 1,
    "shake": 2.5, "rarity": "epic",
    "desc": "锣声震荡，范围眩晕，控场利器",
},
```

#### 2. `tar_whip` 沥青长鞭（水，slow）
```gdscript
"tar_whip": {
    "name": "沥青长鞭", "ico": "🕸", "attack_type": "melee", "sfx": "shoot_knife",
    "cd": 0.55, "dmg": 14.0, "range": 110.0, "swing_arc": 2.0,
    "status": "slow", "status_chance": 0.65, "status_stacks": 1,
    "rarity": "rare",
    "desc": "长鞭横扫，高频减速，牵制群敌",
},
```

#### 3. `ember_fan` 赤焰折扇（火，burn）
```gdscript
"ember_fan": {
    "name": "赤焰折扇", "ico": "🪭", "attack_type": "projectile", "sfx": "shoot_smg",
    "cd": 0.70, "dmg": 10.0, "bspeed": 460.0, "pellets": 3, "arc": 0.55,
    "status": "burn", "status_chance": 0.50, "status_stacks": 1,
    "rarity": "rare",
    "desc": "扇形三射火舌，快速铺设燃烧",
},
```

#### 4. `vine_lash` 青藤缠索（木，poison）
```gdscript
"vine_lash": {
    "name": "青藤缠索", "ico": "🌱", "attack_type": "projectile", "sfx": "shoot_pistol",
    "cd": 0.90, "dmg": 13.0, "bspeed": 380.0, "splash": 60.0,
    "status": "poison", "status_chance": 0.55, "status_stacks": 2,
    "rarity": "rare",
    "desc": "藤蔓爆裂散毒，双层中毒叠加",
},
```

#### 5. `gold_bell` 金铃破空（金，bleed）
```gdscript
"gold_bell": {
    "name": "金铃破空", "ico": "🛎", "attack_type": "projectile", "sfx": "shoot_pistol",
    "cd": 0.85, "dmg": 26.0, "bspeed": 720.0, "bullet_life": 1.2,
    "status": "bleed", "status_chance": 0.55, "status_stacks": 2,
    "rarity": "epic",
    "desc": "金铃高速激射，双层流血叠加",
},
```

#### 6. `frost_nova` 玄冰新星（水，freeze）
```gdscript
"frost_nova": {
    "name": "玄冰新星", "ico": "🧊", "attack_type": "projectile", "sfx": "shoot_rocket",
    "cd": 1.30, "dmg": 18.0, "bspeed": 320.0, "splash": 110.0,
    "status": "freeze", "status_chance": 0.40, "status_stacks": 1,
    "shake": 1.5, "rarity": "epic",
    "desc": "寒冰爆发大范围冰冻，冻结目标易伤",
},
```

#### 7. `flame_jian` 火焰长剑（火，burn 高叠层）
```gdscript
"flame_jian": {
    "name": "火焰长剑", "ico": "🌋", "attack_type": "melee", "sfx": "shoot_knife",
    "cd": 0.48, "dmg": 24.0, "range": 118.0, "swing_arc": 2.2,
    "status": "burn", "status_chance": 0.75, "status_stacks": 3,
    "shake": 1.5, "rarity": "legendary",
    "desc": "剑身缠火，横扫三层燃烧，火系构筑顶点",
},
```

#### 8. `chaos_hammer` 混沌重锤（土，stun 高爆发）
```gdscript
"chaos_hammer": {
    "name": "混沌重锤", "ico": "🔨", "attack_type": "melee", "sfx": "shoot_knife",
    "cd": 1.20, "dmg": 45.0, "range": 130.0, "swing_arc": 2.4,
    "status": "stun", "status_chance": 0.60, "status_stacks": 1,
    "shake": 4.0, "rarity": "mythic",
    "desc": "开天一锤，眩晕 + 高爆发伤害",
},
```

### 武器校验对照（对齐 `Registry.register_weapon` 限制）
| 校验项 | 限制 | 本次最大 | 通过 |
|--------|------|---------|------|
| cd | [0.05, 5.0] | 1.30 | ✅ |
| dmg | [0, 500] | 45 | ✅ |
| price | [0, 300] | 145 | ✅ |
| shop_weight | [0, 5.0] | 1.5 | ✅ |
| shake | [0, 10] | 4.0 | ✅ |
| melee range | [0, 400] | 130 | ✅ |
| melee swing_arc | [0, TAU≈6.28] | 2.4 | ✅ |
| projectile bspeed | [1, 1200] | 720 | ✅ |
| projectile pellets | [1, 32] | 3 | ✅ |
| projectile arc | [0, TAU] | 0.55 | ✅ |
| projectile splash | [0, 400] | 110 | ✅ |
| projectile bullet_life | [0.05, 10] | 1.2 | ✅ |
| status_chance | [0, 1] | 0.75 | ✅ |
| status_stacks | [1, 10] | 3 | ✅ |

---

## 三、10 个新敌人（五行阵营）

### 设计原则
- 每个五行 2 只敌人（10 = 5×2）
- 五行抗性 `status_resist`：普通怪 0.30，精英怪 0.40
- 颜色沿用 `ELEMENT_COLOR`，形状/AI 差异化
- HP/speed/dmg 与现有敌人对标（W1 基准）

### 数据位置
- 敌人条目：`Config.ENEMIES` 追加 10 项
- AI 映射：`Registry._register_builtin()` 里 `ai_map` 追加 10 项
- 波次组合：`Config.wave_composition()` W6+ 加入新敌人（见"五、波次组合更新"）
- 精英池：`Config.ELITE_POOL` 加入 `ice_witch` 和 `stone_titan`

### 内容清单

| ID | 名称 | 五行 | 形状 | AI | HP | Speed | DMG | XP | Mat | 半径 | 心几率 | 抗性 |
|----|------|------|------|----|----|-------|-----|-----|-----|------|--------|------|
| `fire_imp` | 火鸦童子 | 火 | diamond | runner | 12 | 175 | 7 | 3 | 2 | 11 | 0.04 | 0.30 |
| `fire_shaman` | 赤焰巫师 | 火 | circle | shooter | 24 | 62 | 11 | 8 | 5 | 15 | 0.08 | 0.30 |
| `wood_sprite` | 木灵幼芽 | 木 | circle | chaser | 18 | 80 | 6 | 3 | 3 | 12 | 0.05 | 0.30 |
| `vine_beast` | 藤蔓妖 | 木 | diamond | chaser | 30 | 92 | 10 | 6 | 4 | 14 | 0.06 | 0.30 |
| `metal_puppet` | 金傀武士 | 金 | square | chaser | 42 | 62 | 14 | 7 | 6 | 18 | 0.10 | 0.30 |
| `blade_monk` | 刀锋武僧 | 金 | diamond | runner | 20 | 190 | 13 | 6 | 4 | 11 | 0.06 | 0.30 |
| `water_nymph` | 水泽鲛奴 | 水 | circle | shooter | 16 | 68 | 8 | 5 | 4 | 13 | 0.06 | 0.30 |
| `ice_witch` | 玄冰女妖 | 水 | circle | shooter | 28 | 58 | 12 | 10 | 7 | 16 | 0.10 | 0.40 |
| `earth_golem` | 土灵石俑 | 土 | square | chaser | 75 | 38 | 18 | 12 | 8 | 24 | 0.12 | 0.30 |
| `stone_titan` | 山岳巨人 | 土 | square | chaser | 140 | 32 | 24 | 16 | 12 | 30 | 0.18 | 0.40 |

### 数值锚点对比
| 参考敌人 | HP | Speed | DMG |
|---------|-----|-------|-----|
| grunt（追击者） | 14 | 88 | 8 |
| runner（冲锋者） | 8 | 168 | 6 |
| tank（坦克） | 46 | 50 | 16 |
| shooter（射手） | 12 | 72 | 10 |
| shadow（暗影刺客） | 18 | 205 | 12 |
| guard（重装卫兵） | 120 | 42 | 20 |

**结论**：新敌人在 W1 基准下与现有敌人同档次，靠五行抗性/主题色/AI 差异化。

### 数值详解（ shooter AI 参数）
```gdscript
"fire_shaman": {
    "name": "赤焰巫师", "hp": 24.0, "speed": 62.0, "dmg": 11.0, "xp": 8, "mat": 5,
    "r": 15.0, "color": "#ff5e3a", "shape": "circle",
    "keep_dist": 300.0, "shoot_cd": 2.0, "bspeed": 320.0,
    "heart_chance": 0.08, "status_resist": 0.30,
},
"water_nymph": {
    "name": "水泽鲛奴", "hp": 16.0, "speed": 68.0, "dmg": 8.0, "xp": 5, "mat": 4,
    "r": 13.0, "color": "#8fd8ff", "shape": "circle",
    "keep_dist": 280.0, "shoot_cd": 2.4, "bspeed": 280.0,
    "heart_chance": 0.06, "status_resist": 0.30,
},
"ice_witch": {
    "name": "玄冰女妖", "hp": 28.0, "speed": 58.0, "dmg": 12.0, "xp": 10, "mat": 7,
    "r": 16.0, "color": "#5aa8d8", "shape": "circle",
    "keep_dist": 320.0, "shoot_cd": 1.8, "bspeed": 340.0,
    "heart_chance": 0.10, "status_resist": 0.40,
},
```

### 精英池扩展
`Config.ELITE_POOL`（W4+ 触发 `elite_chance` 时替换）：
```gdscript
const ELITE_POOL := [
    { "item": "guard", "w": 0.22 }, { "item": "wizard", "w": 0.22 },
    { "item": "shadow", "w": 0.18 }, { "item": "bomber", "w": 0.14 },
    { "item": "ice_witch", "w": 0.14 }, { "item": "stone_titan", "w": 0.10 },
]
```

### 敌人校验对照（对齐 `Registry.register_enemy` 限制）
| 校验项 | 限制 | 本次最大 | 通过 |
|--------|------|---------|------|
| hp（普通敌人） | [0, 5000] | 140 | ✅ |
| speed | [0, 400] | 190 | ✅ |
| dmg | [0, 200] | 24 | ✅ |
| r | [5, 120] | 30 | ✅ |
| xp | [0, 100] | 16 | ✅ |
| mat | [0, 100] | 12 | ✅ |
| heart_chance | [0, 1] | 0.18 | ✅ |
| status_resist | [0, 0.95] | 0.40 | ✅ |
| shooter keep_dist | [0, 600] | 320 | ✅ |
| shooter shoot_cd | [0.05, 10] | 2.4 | ✅ |
| shooter bspeed | [1, 800] | 340 | ✅ |
| color | HTML 合法 | 全部 | ✅ |
| shape | circle/square/diamond | 全部 | ✅ |
| ai | chaser/runner/shooter/boss | 全部 | ✅ |

---

## 四、3 个新 BOSS（五行主宰）

### 设计原则
- 用现有 BOSS 机制（环形弹幕/螺旋/召唤）组合，不引入新代码
- 每个 BOSS 对应一个五行，颜色/形状与主题匹配
- HP 阶梯：现有 3 BOSS 是 768k/640k/560k，新 3 BOSS 定在 720k/800k/900k（形成档次）
- BOSS_POOL 从 3 扩到 6，每日挑战轮换空间翻倍

### 数据位置
- BOSS 条目：`Config.ENEMIES` 追加 3 项
- BOSS_POOL：`Config.BOSS_POOL` 从 3 扩到 6
- BOSS_TITLES：`Config.BOSS_TITLES` 追加 3 项
- AI 映射：`Registry._register_builtin()` `ai_map` 追加 3 项

### 内容清单

| ID | 名称 | 五行 | 形状 | HP | Speed | DMG | 弹数 | 弹间隔 | 弹速 | 召唤 | 抗性 |
|----|------|------|------|-----|-------|-----|------|--------|------|------|------|
| `boss_phoenix` | 焚天凤凰 | 火 | diamond | 720000 | 78 | 26 | 12 | 1.8 | 320 | — | 0.55 |
| `boss_leviathan` | 沧溟蛟皇 | 水 | circle | 800000 | 60 | 24 | 18 | 2.0 | 260 | 3×water_nymph/8s | 0.55 |
| `boss_titan` | 玄武岩王 | 土 | square | 900000 | 42 | 32 | 10 | 2.4 | 220 | — | 0.70 |

### 数值详解

#### 1. `boss_phoenix` 焚天凤凰（火）
```gdscript
"boss_phoenix": {
    "name": "焚天凤凰", "hp": 720000.0, "speed": 78.0, "dmg": 26.0,
    "xp": 60, "mat": 100, "r": 52.0, "color": "#ff5e3a", "shape": "diamond",
    "ring_cd": 1.8, "ring_count": 12, "bspeed": 320.0,
    "status_resist": 0.55, "heart_chance": 1.0,
},
```
**特色**：速度最快的 BOSS（78），12 弹幕 + 高弹速（320）形成密集火力网。

#### 2. `boss_leviathan` 沧溟蛟皇（水）
```gdscript
"boss_leviathan": {
    "name": "沧溟蛟皇", "hp": 800000.0, "speed": 60.0, "dmg": 24.0,
    "xp": 60, "mat": 100, "r": 54.0, "color": "#5aa8d8", "shape": "circle",
    "ring_cd": 2.0, "ring_count": 18, "bspeed": 260.0,
    "summon_cd": 8.0, "summon_type": "water_nymph", "summon_count": 3,
    "status_resist": 0.55, "heart_chance": 1.0,
},
```
**特色**：18 弹幕最密（超过 boss_spiral 的 6+螺旋），每 8s 召唤 3 只水泽鲛奴形成群海战术。

#### 3. `boss_titan` 玄武岩王（土）
```gdscript
"boss_titan": {
    "name": "玄武岩王", "hp": 900000.0, "speed": 42.0, "dmg": 32.0,
    "xp": 60, "mat": 100, "r": 58.0, "color": "#c8a030", "shape": "square",
    "ring_cd": 2.4, "ring_count": 10, "bspeed": 220.0,
    "status_resist": 0.70, "heart_chance": 1.0,
},
```
**特色**：血量最高（900k）、体型最大（r=58）、伤害最高（32）、状态抗性最强（0.70，比常规 BOSS 0.55 高 27%）。10 弹幕少但慢速重击。

### BOSS_POOL 扩展
```gdscript
const BOSS_POOL := ["boss", "boss_spiral", "boss_summoner",
    "boss_phoenix", "boss_leviathan", "boss_titan"]

const BOSS_TITLES := {
    "boss": "土豆之王 · 弹幕压制",
    "boss_spiral": "深渊织网者 · 螺旋封锁",
    "boss_summoner": "腐土孵化者 · 群海战术",
    "boss_phoenix": "焚天凤凰 · 烈焰风暴",
    "boss_leviathan": "沧溟蛟皇 · 寒潮召唤",
    "boss_titan": "玄武岩王 · 山岳镇压",
}
```

### BOSS 校验对照
| 校验项 | 限制 | 本次最大 | 通过 |
|--------|------|---------|------|
| hp（BOSS） | [0, 1e9] | 900000 | ✅ |
| speed | [0, 400] | 78 | ✅ |
| dmg | [0, 200] | 32 | ✅ |
| r | [5, 120] | 58 | ✅ |
| ring_count | [1, 40] | 18 | ✅ |
| ring_cd | [0.05, 10] | 2.4 | ✅ |
| bspeed | [1, 800] | 320 | ✅ |
| status_resist | [0, 0.95] | 0.70 | ✅ |

---

## 五、波次组合更新（`Config.wave_composition`）

### 方案选择
- 方案 A（保守）：完全不动，新敌人只出现在精英池 + BOSS 召唤 → **不推荐**，新敌人几乎玩不到
- **方案 B（推荐）**：W1-5 不变（保护新手期体验），W6+ 逐步引入新敌人
- 方案 C（激进）：W1+ 就出现新敌人 → 会打乱现有难度曲线

### 具体调整（方案 B）

#### W1-5：不变
新手期完全使用现有敌人组合，保证前 5 波体验稳定。

#### W6-7：加入 2 种新敌人（火/木系）
```gdscript
if w <= 7:
    return [
        { "item": "grunt", "w": 0.16 }, { "item": "swarm", "w": 0.09 },
        { "item": "runner", "w": 0.20 }, { "item": "tank", "w": 0.13 },
        { "item": "shooter", "w": 0.14 }, { "item": "bomber", "w": 0.09 },
        { "item": "wizard", "w": 0.09 },
        { "item": "fire_imp", "w": 0.05 }, { "item": "wood_sprite", "w": 0.05 },
    ]
```

#### W8-9：加入 6 种新敌人（火/木/金/水/土全覆盖，普通档）
```gdscript
if w <= 9:
    return [
        { "item": "grunt", "w": 0.10 }, { "item": "swarm", "w": 0.06 },
        { "item": "runner", "w": 0.16 }, { "item": "tank", "w": 0.11 },
        { "item": "shooter", "w": 0.12 }, { "item": "bomber", "w": 0.09 },
        { "item": "wizard", "w": 0.08 }, { "item": "shadow", "w": 0.06 },
        { "item": "guard", "w": 0.03 },
        { "item": "fire_imp", "w": 0.04 }, { "item": "wood_sprite", "w": 0.04 },
        { "item": "vine_beast", "w": 0.04 }, { "item": "metal_puppet", "w": 0.04 },
        { "item": "water_nymph", "w": 0.04 }, { "item": "earth_golem", "w": 0.03 },
    ]
```

#### W10+（无尽）：加入全部 10 种新敌人（含精英档）
```gdscript
var t := minf(1.0, float(w - 9) / 21.0)
return [
    { "item": "grunt", "w": 0.10 - 0.04 * t }, { "item": "swarm", "w": 0.05 },
    { "item": "runner", "w": 0.14 }, { "item": "tank", "w": 0.10 + 0.02 * t },
    { "item": "shooter", "w": 0.10 }, { "item": "bomber", "w": 0.08 + 0.03 * t },
    { "item": "wizard", "w": 0.08 + 0.04 * t }, { "item": "shadow", "w": 0.06 + 0.04 * t },
    { "item": "guard", "w": 0.05 + 0.06 * t },
    { "item": "fire_imp", "w": 0.03 }, { "item": "fire_shaman", "w": 0.03 + 0.02 * t },
    { "item": "wood_sprite", "w": 0.03 }, { "item": "vine_beast", "w": 0.04 + 0.02 * t },
    { "item": "metal_puppet", "w": 0.04 + 0.02 * t }, { "item": "blade_monk", "w": 0.03 + 0.02 * t },
    { "item": "water_nymph", "w": 0.03 }, { "item": "ice_witch", "w": 0.02 + 0.03 * t },
    { "item": "earth_golem", "w": 0.03 + 0.02 * t }, { "item": "stone_titan", "w": 0.02 + 0.03 * t },
]
```

---

## 六、冒烟测试扩展计划

### 位置
`game/tests/smoke_test.gd` 追加新的 `_check_phase2_content()` 函数，接入 `_ready()` 主流程。

### 验证点（对齐 Phase 1 `_check_reactions` 的模式）

#### 1. Registry 加载完整性
```gdscript
# 12 个角色（7 原 + 5 新）
assert Registry.characters.size() >= 12
for cid in ["pyromancer", "druid", "swordmaster", "tidecaller", "geomancer"]:
    assert Registry.characters.has(cid), "角色 %s 未注册" % cid
    assert Registry.get_character(cid).start_weapon in Registry.weapons, \
        "角色 %s 起手武器不存在" % cid

# 22 把武器（14 原 + 8 新）
for wid in ["thunder_gong", "tar_whip", "ember_fan", "vine_lash",
        "gold_bell", "frost_nova", "flame_jian", "chaos_hammer"]:
    assert Registry.weapons.has(wid), "武器 %s 未注册" % wid

# 23 个敌人（13 原 + 10 新）
for eid in ["fire_imp", "fire_shaman", "wood_sprite", "vine_beast",
        "metal_puppet", "blade_monk", "water_nymph", "ice_witch",
        "earth_golem", "stone_titan"]:
    assert Registry.enemies.has(eid), "敌人 %s 未注册" % eid
```

#### 2. BOSS_POOL 完整性
```gdscript
assert Config.BOSS_POOL.size() == 6
for bid in Config.BOSS_POOL:
    assert Registry.enemies.has(bid), "BOSS %s 未注册" % bid
    assert Registry.enemies[bid].get("is_boss", false) or \
        Registry.enemies[bid].get("ai", "") == "boss", \
        "BOSS %s 未标记为 boss" % bid
    assert Config.BOSS_TITLES.has(bid), "BOSS %s 缺少称号" % bid
```

#### 3. 每日挑战合法性
```gdscript
for date_str in ["2026-09-09", "2026-12-31", "2027-01-01"]:
    var setup: Dictionary = Config.daily_setup(date_str)
    assert Registry.characters.has(setup.character_id), \
        "每日挑战角色 %s 不存在" % setup.character_id
    assert Registry.enemies.has(setup.boss_id) and \
        (Registry.enemies[setup.boss_id].get("is_boss", false) or \
         Registry.enemies[setup.boss_id].get("ai", "") == "boss"), \
        "每日挑战 BOSS %s 不是有效 BOSS" % setup.boss_id
```

#### 4. 波次组合合法性（W1-15）
```gdscript
for w in range(1, 16):
    if Config.is_boss_wave(w):
        continue
    var comp: Array = Registry.wave_composition(w)
    assert not comp.is_empty(), "第 %d 波组合为空" % w
    for entry in comp:
        assert Registry.enemies.has(entry.item), \
            "第 %d 波组合含未注册敌人 %s" % [w, entry.item]
        assert not (Registry.enemies[entry.item].get("is_boss", false)), \
            "第 %d 波组合含 BOSS %s" % [w, entry.item]
        assert entry.w > 0.0
```

#### 5. 精英池合法性
```gdscript
for entry in Config.ELITE_POOL:
    assert Registry.enemies.has(entry.item), \
        "精英池含未注册敌人 %s" % entry.item
    assert entry.w > 0.0
```

#### 6. 五行覆盖检查（每个五行至少 2 把武器）
```gdscript
var elem_coverage := {}
for eid in ["burn", "poison", "bleed", "freeze", "slow", "stun"]:
    var elem := Config.get_element(eid)
    elem_coverage[elem] = 0
for wid in Registry.weapons:
    var st := String(Registry.weapons[wid].get("status", ""))
    if st == "" or st == "none":
        continue
    var elem2 := Config.get_element(st)
    if elem_coverage.has(elem2):
        elem_coverage[elem2] += 1
for elem in ["fire", "wood", "metal", "water", "earth"]:
    assert elem_coverage[elem] >= 2, \
        "五行 %s 武器覆盖不足（%d < 2）" % [elem, elem_coverage[elem]]
```

### 通过标准
- 冒烟测试输出 `SMOKE: PASS`
- 连续 3 次运行都通过（对齐 Phase 1 验收标准）
- 无 `push_warning` 输出（Registry 拒绝任何一条新内容都会 push_warning）

---

## 七、实现清单（文件 + 位置）

### 1. `game/scripts/core/config.gd`
- 追加 `WEAPONS` 8 项（第 190-207 行附近）
- 追加 `WEAPON_SHOP_WEIGHTS` 8 项（第 211 行）
- 追加 `WEAPON_PRICES` 8 项（第 212 行）
- 追加 `ENEMIES` 13 项（10 敌人 + 3 BOSS，第 215-229 行附近）
- 修改 `BOSS_POOL` 从 3 到 6（第 232 行）
- 修改 `BOSS_TITLES` 追加 3 项（第 235-239 行）
- 修改 `ELITE_POOL` 加入 ice_witch 和 stone_titan（第 242-245 行）
- 修改 `wave_composition()` W6-7 / W8-9 / W10+ 三段（第 441-465 行）
- 修改 `daily_setup()` `chars` 数组扩到 12（第 274 行）

### 2. `game/scripts/core/registry.gd`
- 修改 `_register_builtin()` `characters` 字典追加 5 项（第 547-596 行附近）
- 修改 `_register_builtin()` `ai_map` 追加 13 项（10 敌人 + 3 BOSS）（第 614-617 行）

### 3. `game/tests/smoke_test.gd`
- 追加 `_check_phase2_content()` 函数
- 在 `_ready()` 主流程中调用（放在 `_check_reactions` 之后）

### 4. **不动**的文件
- `enemy.gd`（BOSS AI 逻辑不变）
- `player.gd`（角色 stats 已支持覆盖）
- `combat.gd`（战斗系统不变）
- `wave_manager.gd`（波次生成不变）
- `codex_data.gd`（图鉴自动收录 Registry 内容，无需改）
- `main.gd`（Phase 1 五行反应特效不变）

### 5. 预估代码量
- `config.gd`：+40 行（8 武器 + 13 敌人 + 波次组合调整）
- `registry.gd`：+80 行（5 角色详解 + ai_map 追加）
- `smoke_test.gd`：+100 行（新验证函数）
- **合计：+220 行**，纯数据 + 测试，不动核心逻辑

---

## 八、未决问题（挂账到后续 Phase）

| 问题 | 挂账到 | 备注 |
|------|-------|------|
| 复合状态武器（status2 字段） | Phase 3 法宝系统 | 法宝可能天然带复合状态，一起设计更合理 |
| BOSS 死亡技能 / 特殊机制 | Phase 5 平衡性调优 | 需改 enemy.gd，本 Phase 保守跳过 |
| 敌人给玩家上异常（反向五行） | Phase 5 | 需改 player.gd 和 enemy.gd |
| 门派专属天赋树 | 后续 Phase | 5 门派 × 5 天赋 = 25 项，工作量大 |
| 五行地图主题化 | Phase 5 | 已在 Phase 5 计划里 |
| 新敌人的击杀成就 | 后续 Phase | 现有成就 slayer_100/1000 已覆盖 |
| 图鉴分类展示（按五行筛选） | 后续 Phase | 现有图鉴已能收录，五行筛选是 UI 增强 |

---

## 八之二、平衡性风险（需用户知情）

### 风险 1：新 BOSS 血量比现有 BOSS 高 17-29%
| BOSS | HP | 相对现有均值 |
|------|-----|-------------|
| boss_summoner（现有最弱） | 560000 | 基准 |
| boss_spiral（现有中） | 640000 | +14% |
| boss（现有最强） | 768000 | +37% |
| **boss_phoenix（新，火）** | 720000 | **+29%** |
| **boss_leviathan（新，水）** | 800000 | **+43%** |
| **boss_titan（新，土）** | 900000 | **+61%** |

**影响**：每日挑战 / 标准模式的 BOSS 战时长会因 BOSS 而异，最弱 boss_summoner 和最强 boss_titan 差距 61%。

**缓解选项**：
- A. 保留原设计（形成明确档次，火/水/土 progressively harder）
- B. 把 3 新 BOSS HP 拉到 640k-720k 区间（与现有持平）
- C. 保留 HP 但给 boss_titan 降低 status_resist（0.70 → 0.55）

**推荐 A**：BOSS 有档次是好事，boss_titan 定位就是"最难 BOSS"。

**✅ 已拍板（2026-09-09）**：选项 A，保留 720k/800k/900k 血量档次设计。

### 风险 2：`boss_leviathan` 召唤 `water_nymph`（shooter AI）可能远离战场
- `water_nymph` 是 shooter AI，`keep_dist: 280`，会主动跟玩家保持 280 距离
- BOSS 战场中央，召唤出来的 water_nymph 可能会往场外跑，形成"打了半天召不出"的体验
- 现有 `boss_summoner` 召唤的是 `swarm`（chaser），行为简单直接冲脸

**缓解选项**：
- A. 把 `boss_leviathan.summon_type` 改成 chaser AI 的水系敌人（如新增 `water_sprite`）
- B. 保留 water_nymph，接受"射手 BOSS 召唤射手随从"的定位
- C. 改用现有 `swarm`（放弃水系主题一致性）

**推荐 B**：water_nymph 会保持距离射击，符合"沧溟蛟皇 · 寒潮召唤"的远程压制定位，玩家需要主动追击，是有趣的战术挑战。

**✅ 已拍板（2026-09-09）**：选项 A（= 推荐 B），保留 water_nymph 作为召唤物，不新增 water_sprite。

### 风险 3：`flame_jian` / `chaos_hammer` 商店可见度极低
- legendary 稀有度基础权重 0.018，mythic 0.055
- shop_weight 0.4 / 0.5 乘以稀有度权重后，实际商店出现概率 = 0.4 × 0.018 = 0.0072（legendary）
- 加上波次加成（W10 时 legendary × 1.28）也只有 0.0092
- 玩家可能整局都见不到这两把武器

**缓解选项**：
- A. 保留原设计（legendary/mythic 本来就应该是稀有惊喜）
- B. 提高 shop_weight 到 1.0-1.5，让它们在 W8+ 有可见度
- C. 把 flame_jian 降到 epic（0.22 权重），chaos_hammer 降到 legendary

**推荐 B**：Phase 2 是"内容注入"，如果新武器玩家看不到就等于没做。提到 1.0-1.5 后，W8+ 商店大约有 5-10% 概率刷出，符合"后期构筑成型期惊喜"定位。

**✅ 已拍板（2026-09-09）**：选项 B，flame_jian shop_weight 0.4 → **1.2**，chaos_hammer 0.5 → **1.0**，已同步更新到第二章武器表和第七章实现清单。

---

## 九、验收标准

### 必须通过
- [x] 冒烟测试 `SMOKE: PASS`（连续 3 次）
- [x] 无 `push_warning` 输出（Registry 拒绝任何一条新内容都会 push_warning）
- [x] 12 个角色都能在角色选择界面出现（现已扩到 18 个）
- [x] 22 把武器都能在商店出现（现已扩到 26 把）
- [x] 23 个敌人都能在波次中出现（现为 21 种普通敌人）
- [x] 6 个 BOSS 都能在第 10 波出现（依赖 `Registry.boss_id()`）

### 应该通过
- [x] 每个五行至少 2 把武器覆盖（冒烟测试验证点 6）
- [x] 5 个新角色的 stats 与现有 7 角色形成差异化（人工审查）
- [x] 3 个新 BOSS 与现有 3 BOSS 打法差异化（人工审查）

### 可以延后
- [ ] 图鉴分类按五行筛选
- [x] 门派专属天赋树（**2026-09-10**：MetaProgress 新增 5 门派 × 3 级 = 15 项，仅对应角色生效）
- [x] BOSS 特殊机制（死亡技能等）（**2026-09-10**：6 个 BOSS 各配专属死亡技能）

---

## 附录：五行状态覆盖矩阵（Phase 2 完成后）

| 五行 | 状态 | 角色（新） | 武器（新+旧） | 敌人（新） | BOSS（新） | 反应数 |
|------|------|-----------|--------------|-----------|-----------|--------|
| 火 | burn | pyromancer | flamethrower, rocket, ember_fan, flame_jian | fire_imp, fire_shaman | boss_phoenix | 4（fire+wood/earth/metal/water） |
| 木 | poison | druid | venom_dagger, vine_lash | wood_sprite, vine_beast | — | 4（wood+fire/water/earth/metal） |
| 金 | bleed | swordmaster | knife, sniper, blade, gold_bell | metal_puppet, blade_monk | — | 4（metal+earth/water/fire/wood） |
| 水 | freeze/slow | tidecaller | frost_staff, frost_nova, tar_whip | water_nymph, ice_witch | boss_leviathan | 4（water+metal/wood/earth/fire） |
| 土 | stun | geomancer | thunder_gong, chaos_hammer | earth_golem, stone_titan | boss_titan | 4（earth+fire/metal/wood/water） |

**反应总数**：10 种（Phase 1 已完成，本 Phase 不新增）
**内容总数**：26 项（5 角色 + 8 武器 + 10 敌人 + 3 BOSS）
**五行覆盖**：完整（每个五行都有角色/武器/敌人，火/水/土 有专属 BOSS）
