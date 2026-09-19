extends Node
## ============================================================
## 唯一配置源 CONFIG —— 从 Web 原型（index.html, brotato-lite-v1.0）1:1 移植
## 数值调整只改这里；后续可迁移为 resources/ 下的 .tres 资源
## ============================================================

const RULESET_ID := "brotato-lite-v1.0"

const WORLD := { "w": 1600.0, "h": 1600.0 }

const PLAYER := {
	"radius": 16.0, "accel": 1500.0, "base_speed": 742.0,
	"max_hp": 100.0, "regen": 0.0, "armor": 0.0, "dodge": 0.0,
	"dmg_mult": 1.0, "as_mult": 1.0, "crit_ch": 0.05, "crit_mult": 2.0,
	"speed_mult": 1.0, "pickup_range": 95.0, "harvesting": 0.0, "lifesteal": 0.0,
	"iframes": 0.45, "touch_tick": 0.6,
}

## 暴击率硬上限：堆再多暴击道具 / 升级也只能到 90%，永远保留 10% 不暴击的运气空间。
## 这是**唯一真值** —— Registry.STAT_LIMITS / EFFECT_LIMITS、SaveRun 读档校验、
## Player._sanitize_stats、DevPanel 滑块全部引用它，改这里等于全局生效。
## （对比：闪避上限 0.95 是各文件里写死的，历史遗留；新增的数值上限都收敛到常量。）
const CRIT_CHANCE_CAP := 0.9

## 怪物击杀掉落材料系数：全局下调 10%，直接乘在敌人 cfg.mat 上（先于收获加成生效）。
## 用系数而非改 NPC_ENEMIES 里 40+ 条 mat 字段：一处可见、一处可回滚。
const MATERIAL_DROP_MULT := 0.9

## 场上掉落物硬上限（2026-09-19 卡顿修复）：事件波/高收获构筑会把 loot 撒到
## 拾取半径之外长期积压（实测第 15 波 563 件 → fps 144 掉到 10）。
## 生成侧（enemy._spawn_loot）在达到上限时改为「直接入账」：玩家收益一分不少，
## 只是不再为远处够不着的掉落物维持节点（波末本来就由全场回收兜底，等价）。
const LOOT_MAX := 200

## ============================================================
## 状态效果（异常状态）—— 数据驱动，武器/道具/升级只引用状态 id
## 字段说明：
##   duration       基础持续时间（秒）
##   tick           伤害跳数间隔（0 = 无持续伤害）
##   dot_scale      每跳伤害 = 施加时伤害 × dot_scale × 层数
##   dot_max_hp_pct 每跳伤害 = 目标最大生命 × 该比例 × 层数（优先于 dot_scale）
##   speed_mult     持续期间移速倍率（0 = 完全定身）
##   dmg_taken_mult 持续期间受到伤害倍率（冰冻易伤）
##   stack_max      最大叠层；重复施加叠加层数并刷新时长
## 施加入口：Enemy.apply_status() / Enemy.apply_hit_roll()；敌人字段 status_resist 可减免时长
## ============================================================
const STATUS := {
	"burn": { "name": "燃烧", "ico": "🔥", "color": "#ff7a3c",
		"desc": "持续伤害，最多 5 层", "duration": 3.0, "tick": 0.5, "dot_scale": 0.18,
		"stack_max": 5, "speed_mult": 1.0, "dmg_taken_mult": 1.0 },
	"poison": { "name": "中毒", "ico": "🧪", "color": "#7ec850",
		"desc": "按最大生命百分比掉血", "duration": 4.0, "tick": 0.8, "dot_max_hp_pct": 0.008,
		"stack_max": 5, "speed_mult": 1.0, "dmg_taken_mult": 1.0 },
	"bleed": { "name": "流血", "ico": "🩸", "color": "#e0564f",
		"desc": "持续伤害，高频武器叠加快", "duration": 4.0, "tick": 0.6, "dot_scale": 0.12,
		"stack_max": 6, "speed_mult": 1.0, "dmg_taken_mult": 1.0 },
	"freeze": { "name": "冰冻", "ico": "❄", "color": "#8fd8ff",
		"desc": "定身，受到伤害 +25%", "duration": 1.1, "tick": 0.0, "dot_scale": 0.0,
		"stack_max": 1, "speed_mult": 0.0, "dmg_taken_mult": 1.25 },
	"slow": { "name": "减速", "ico": "🐌", "color": "#b9a6ff",
		"desc": "移速降低 45%", "duration": 2.6, "tick": 0.0, "dot_scale": 0.0,
		"stack_max": 1, "speed_mult": 0.55, "dmg_taken_mult": 1.0 },
	"stun": { "name": "眩晕", "ico": "💫", "color": "#ffd24a",
		"desc": "短暂无法行动", "duration": 0.9, "tick": 0.0, "dot_scale": 0.0,
		"stack_max": 1, "speed_mult": 0.0, "dmg_taken_mult": 1.0 },
}

static func status_cfg(id: String) -> Dictionary:
	return STATUS.get(id, {})

static func status_ids() -> Array:
	return STATUS.keys()

## ============================================================
## 五行归属映射 —— 每个状态归属一个五行（金木水火土）
## 用于五行相生相克反应系统
## ============================================================
const STATUS_ELEMENT := {
	"burn": "fire",      # 火
	"poison": "wood",    # 木
	"bleed": "metal",    # 金
	"freeze": "water",   # 水
	"slow": "water",     # 水
	"stun": "earth",     # 土
}

## 五行集合（字母序）：REACTIONS 的 key = 两五行按本表顺序拼接
const ELEMENTS := ["earth", "fire", "metal", "water", "wood"]

## 五行配色（反应粒子 / 中央提示 / 图鉴与 HUD 反应表共用）
## 除金之外均沿用对应状态色，便于玩家建立 状态→五行 映射
const ELEMENT_COLOR := {
	"wood": "#7ec850",   # 同中毒
	"fire": "#ff7a3c",   # 同燃烧
	"earth": "#ffd24a",  # 同眩晕
	"metal": "#dfe6f0",  # 金：银白（与流血红区分，避免与火反应混淆）
	"water": "#8fd8ff",  # 同冰冻
}

## 五行中文名（HUD / 图鉴展示）
const ELEMENT_NAME := {
	"wood": "木", "fire": "火", "earth": "土", "metal": "金", "water": "水",
}

## ---- 五行基础怪（§12-S3）----
## 每个五行一只「机制代言怪」，承担「让玩家从早期就能感受到五行克制」的反馈闭环（§5.4）。
## ⚠️ 这里是**唯一**的元素怪清单：`wave_composition` 的注入、冒烟断言、S3.5 的区块轮转
##    都读它。新增元素怪时改这一处，别在 wave_composition 里散写 id。
##
## S3.5 会把「固定权重注入」换成「按区块主题轮转」，届时本表仍保留为「每元素一名代言怪」。
const ELEMENT_MOB_FOR := {
	"metal": "metal_guard",     # 护盾 + 护盾期减伤 + 穿甲
	"wood": "wood_healer",      # 持续回血（受击停顿）
	"water": "water_splitter",  # 死亡分裂（一代）
	"fire": "fire_caster",      # 远程（复用 shooter AI）
	"earth": "earth_bulwark",   # 纯数值对照（血厚慢速高伤，无机制）
}

## 元素怪全量 id（顺序 = ELEMENTS 字母序，方便与冒烟断言对照）
const ELEMENT_MOB_IDS := ["earth_bulwark", "fire_caster", "metal_guard",
	"water_splitter", "wood_healer"]

static func get_element(status_id: String) -> String:
	return String(STATUS_ELEMENT.get(status_id, ""))

## 两五行 → 反应表 key；同元素/非法元素返回 ""（无反应）
## 排序保证 (a,b) 与 (b,a) 得到同一 key，反应无方向性
static func reaction_key(element_a: String, element_b: String) -> String:
	if element_a == element_b or not ELEMENTS.has(element_a) \
			or not ELEMENTS.has(element_b):
		return ""
	var pair := [element_a, element_b]
	pair.sort()
	return String(pair[0]) + "+" + String(pair[1])

## ============================================================
## 五行相生相克（唯一真值 · 第 5/6 轮定稿）
##
## 生：木→火→土→金→水→木      （我生 = 后面那个；生我 = 前面那个）
## 克：木→土→水→火→金→木      （我克 = 后面那个；克我 = 前面那个）
##
## ⚠️ 不要解析 REACTIONS 的 id 反推方向 —— 历史遗留：
##    `REACTIONS["fire+water"].id == "fire_water"` 而那条是**水克火**，
##    与其余 9 条的「克制方_被克方」约定方向相反（不得改名，见 MEMORY）。
##    本表是显式的、方向正确的唯一真值。
## ============================================================
const GENERATES := {   # 我 -> 我生的那个
	"wood": "fire", "fire": "earth", "earth": "metal",
	"metal": "water", "water": "wood",
}
const OVERCOMES := {   # 我 -> 我克的那个
	"wood": "earth", "earth": "water", "water": "fire",
	"fire": "metal", "metal": "wood",
}

## 关系枚举（6 维）—— 输出侧与受击侧共用一套 id，但**取用的档位不同**。
##
## 字段语义（务必区分，否则会写出「相生两侧落 other 档」的错值）：
##   out  = 输出侧**基础修正**（§2.3-A），无上限，直接叠加同化度与道具
##   hit  = 受击侧**关系基数**（§2.3-B 的「关系基数」列），同化度再把它往下推
##   hcap = 该关系在**受击侧**的减伤 cap（§2.3-B 的 cap 列；怪物侧另有 75% 总闸）
##
##   id        名      out      hit     hcap   受击最终区间
##   i_beat   我克它   +0.25   -0.25   0.75   -25% → -75%
##   gen_me   它生我   +0.15    0.00   0.50    0   → -50%   ← 落「其他」档
##   same     同属性   +0.10   -0.10   0.90   -10% → -90%
##   i_gen    我生它   -0.15    0.00   0.50    0   → -50%   ← 落「其他」档
##   beats_me 它克我   -0.25   +0.25   0.25   +25% →   0
##   other    无关      0.00    0.00   0.50    0   → -50%
##
## ⚠️ **输出侧 6 档 / 受击侧 4 档的刻意不对称**：
##    挨打时只问「谁克谁」，不问「谁生谁」→ gen_me 与 i_gen 与 other **同基数同 cap**，
##    三者合并为受击侧的第 4 档（「其他」= 0 → -50%）。
##    这是保住 §2.3-C 标定（-90 / -75 / 0 / -50）逐条不变的关键 ——
##    两边都改成 6 档会让标定与「其他属性最多减 50%」的原话同时失效。
const ELEMENT_RELATION := {
	"i_beat":   { "name": "我克", "out": +0.25, "hit": -0.25, "hcap": 0.75 },
	"gen_me":   { "name": "生我", "out": +0.15, "hit":  0.00, "hcap": 0.50 },
	"same":     { "name": "同属", "out": +0.10, "hit": -0.10, "hcap": 0.90 },
	"i_gen":    { "name": "我生", "out": -0.15, "hit":  0.00, "hcap": 0.50 },
	"beats_me": { "name": "克我", "out": -0.25, "hit": +0.25, "hcap": 0.25 },
	"other":    { "name": "其他", "out":  0.00, "hit":  0.00, "hcap": 0.50 },
}

## 受击侧只有 4 档：把 6 个关系 id 折到 4 个「档位名」，供 UI 与 cap 查询使用。
## 相生两侧（gen_me / i_gen）与「生克之外」都折进 other 档 —— 见上方说明。
const HIT_TIER := {
	"same": "same", "i_beat": "i_beat", "beats_me": "beats_me",
	"gen_me": "other", "i_gen": "other", "other": "other",
}

## 输出侧与受击侧各自「按伤害从优到劣」的顺序（用于 UI 排序 / 图表）
const OUT_RELATION_ORDER := ["i_beat", "gen_me", "same", "i_gen", "beats_me", "other"]
const HIT_RELATION_ORDER := ["same", "i_beat", "other", "beats_me"]

## 两个合法五行元素之间的关系 id。
## attacker = 出手方元素；target = 承受方元素。
static func element_relation(attacker: String, target: String) -> String:
	if attacker == "" or target == "":
		return "other"          # 无元素（白板角色）不参与任何修正
	if not ELEMENTS.has(attacker) or not ELEMENTS.has(target):
		return "other"
	if attacker == target:
		return "same"
	if String(OVERCOMES.get(attacker, "")) == target:
		return "i_beat"         # 我克它
	if String(OVERCOMES.get(target, "")) == attacker:
		return "beats_me"       # 它克我
	if String(GENERATES.get(attacker, "")) == target:
		return "i_gen"          # 我生它（泄力）
	if String(GENERATES.get(target, "")) == attacker:
		return "gen_me"         # 它生我（被滋养）
	return "other"              # 生克之外的两对（如 木 与 金 已由克覆盖，此路径的是 土/水 等）

## 关系 id → 输出侧倍率（无上限；§2.3-A）
static func out_mult(attacker: String, target: String) -> float:
	return float(ELEMENT_RELATION.get(element_relation(attacker, target), {}).get("out", 0.0))

## ⚠️⚠️ 受击侧三兄弟（hit_base / hit_cap / hit_tier）的**参考系**是防御方，不是攻击方。
##
## element_relation(a, b) 返回的 id 是**以 a 为第一人称**说的（"我克它" = a 克 b）。
## 而 §2.3-B 的表是写给**挨打的人**看的：「我克它 → 挨它打时减伤 25%」。
## 于是查受击表必须把防御方放在第一人称位 —— 即 element_relation(target, attacker)，
## 而不是 element_relation(attacker, target)。写反了会把「木克土」读成「土克木」，
## 减伤变增伤、cap 也从 0.75 读成 0.25，且方向性错误不会报错、只会静默算错。
##
## 例：木被土打 → element_relation("wood", "earth") == "i_beat"（木：我克它）→ -25% / cap 0.75 ✔
##     若误写 element_relation("earth", "wood") == "beats_me"（土：我克我？）→ +25% / cap 0.25 ✘
static func hit_relation(attacker: String, target: String) -> String:
	return element_relation(target, attacker)

## 受击侧**关系基数**（未扣同化度；§2.3-B）。参考系 = 防御方，见 hit_relation 说明。
static func hit_base(attacker: String, target: String) -> float:
	return float(ELEMENT_RELATION.get(hit_relation(attacker, target), {}).get("hit", 0.0))

## 受击侧 cap（§2.3-B）。注意相生两侧与 other 同为 0.50。参考系 = 防御方。
static func hit_cap(attacker: String, target: String) -> float:
	return float(ELEMENT_RELATION.get(hit_relation(attacker, target), {}).get("hcap", 0.50))

## 受击侧「4 档」归一（把 6 个关系 id 折成 UI 要显示的 4 档名）。参考系 = 防御方。
##
## 空元素时返回 ""（而非 "other"）—— 无属性墙不该在 UI 上显示成「其他 0~50%」，
## 那会让玩家以为堆同化度有用。调用方需自行判空。
static func hit_tier(attacker: String, target: String) -> String:
	if attacker == "" or target == "":
		return ""
	return String(HIT_TIER.get(hit_relation(attacker, target), "other"))

## 受击修正的**最终值**（§2.3-B 公式）：
##   受击修正 = clamp(关系基数 − 对该攻击元素的同化度, floor, +∞)
##
## ⚠️ floor 不是简单的 −cap，而是 **−cap + max(0, 基数)**。原因见下：
##
##   cap 的语义是「**最多能减掉多少**」，不是「结果的绝对下限」。验证 §2.3-B 四档：
##     关系      基数    cap     §2.3-B 最终区间      floor = −cap+max(0,基数)
##     same     -0.10   0.90    -10% → -90%          -0.90 + 0    = -0.90  ✔
##     i_beat   -0.25   0.75    -25% → -75%          -0.75 + 0    = -0.75  ✔
##     other     0.00   0.50      0  → -50%          -0.50 + 0    = -0.50  ✔
##     beats_me +0.25   0.25    +25% →   0           -0.25 + 0.25 =  0.00  ✔
##
##   若写成「floor = −cap」，beats_me 会算出下限 −0.25 —— 那意味着玩家靠同化度
##   把「挨克我的打更疼」硬生生变成「挨打还减伤 25%」，与 §2.3-B 的「+25% → 0」
##   矛盾，也让「克我」这个最该疼的关系变成净收益。故基数 > 0 时上限只能削到 0。
##
## attacker = 出手方元素，target = 防御方元素，assim = 防御方对 attacker 元素的同化度。
## 任一方无元素 → 返回 0.0（无属性不参与修正）。
static func hit_mult(attacker: String, target: String, assim: float) -> float:
	if attacker == "" or target == "":
		return 0.0
	var base := hit_base(attacker, target)
	var cap := hit_cap(attacker, target)
	var floor_v := -cap + maxf(0.0, base)
	return maxf(base - assim, floor_v)

## ---- 两条「落地方程」：伤害两端各自只调这一个函数 ----
##
## 输出侧（攻击方 → 受击方）：
##   dmg = raw * (1 + 关系基础值 + 攻击方同化度 + 道具加成)
##   无上限 —— 克制就该能打出夸张数字（§2.3-A）
##   attacker 为空 或 target 为空 → 倍率 1.0（白板不参与）
static func apply_out_mult(raw: float, attacker: String, target: String,
		assim: float = 0.0, item_bonus: float = 0.0) -> float:
	if attacker == "" or target == "":
		return raw
	return raw * (1.0 + out_mult(attacker, target) + assim + item_bonus)

## 受击侧（受击方承受）：
##   dmg = raw * (1 + clamp(关系基数 − 受击方同化度, −cap))
##   注意这里是**减伤**：结果为负即「打得更少」。
##   attacker 为空 或 target 为空 → 倍率 1.0
##
## ⚠️ 两端都用同一套 ELEMENT_RELATION 表，但取的是不同列（out / hit）。
##    敌我双方的"同化度"角色互换 —— 输出侧用主动方对自身元素的同化度，
##    受击侧用被动方对**来袭元素**的同化度。别把两者写成同一个变量。
static func apply_hit_mult(raw: float, attacker: String, target: String,
		assim: float = 0.0, item_bonus: float = 0.0) -> float:
	if attacker == "" or target == "":
		return raw
	return raw * (1.0 + hit_mult(attacker, target, assim) + item_bonus)

## ============================================================
## 怪物侧元素抗性（§5.5 · §12-S3）
## ============================================================

## 怪物侧「有效 cap」表（§5.5.1）：与玩家侧**刻意不对称**。
##
## 与玩家侧 `ELEMENT_RELATION.*.hcap` 的差异**只有 `same` 一行**（0.90 → 0.75）：
##     i_beat / beats_me / other 三行完全一致。
##
## 为什么不对称：玩家保留 90% 的同属性减伤、怪物只有 75%，同一元素正面对轰时
## 玩家多 15 个点的便宜 → 「堆同化度」永远是玩家占优的选择（§7）。
## 90% 只在「同属性 BOSS 波 + BOSS 光环」这一个口子开（见 CAP_MOB_SAME_BOSS）。
const ELEMENT_TAKEN_CAP_MOB := {
	"same": 0.75, "i_beat": 0.75, "beats_me": 0.25, "other": 0.50,
}

## 同属性 BOSS + 光环下，`same` 行的 cap 提到玩家档 —— **全项目唯一的 90% 通道**
const CAP_MOB_SAME_BOSS := 0.90

## ---- 抗性曲线常量（§5.5.2）----
const RESIST_WAVE_GROWTH_DENOM := 19.0   # 波次成长分母：W1 = 0 → W20 = 1.0（按 20 波制标定）
const RESIST_BLOCK_BIAS := 0.10          # 区块偏置：本区块主元素的怪 +0.10
const RESIST_BOSS_AURA := 0.15           # BOSS 光环：光环内同元素怪 +0.15
## BOSS 光环半径。⚠️ 规划 §5.5.5 只写「光环内」没给数值 —— 这里先按「约一屏半径」取 400，
## 并由 `Enemy.AURA_BOSS_RADIUS` 引用；手感不对时改这一处即可（S8 复核）。
const BOSS_AURA_RADIUS := 400.0

## 怪物元素抗性标量 R（§5.5.2）。**每只怪一个标量**，不像玩家有 5 个 `assim_*`。
##
## ⚠️⚠️ 难度系数与波次成长是**相乘**，不是相加 —— 这是规划 §5.5.2 的一处笔误，务必别改回去：
##     规划正文把公式写成 `波次成长 + 难度系数 + 区块偏置 + BOSS光环`，
##     但同一节的标定表给的是「简单 W20 = 0.45 / 困难 W20 = 0.60 / 噩梦 W20 = 0.75」，
##     这三个数**正好等于三档难度系数本身**，只有乘法能得到。
##     若按加法，三档在 W20 分别是 1.45 / 1.60 / 1.75，全部撞上 0.75 的 cap
##     → 后期三档难度**完全没有区别**，与沧溟原话「正常来说，即使是噩梦难度，
##     最后一波，怪物的伤害抵抗也就 75%，这是怪物的极限」直接矛盾
##     （原话暗示噩梦高于其他档、但极限在 75%，不是"所有档都顶到 75%"）。
##
## 语义清晰化：
##     `resist_mult` = 该难度在**满进度**时的抗性上限（简单 0.45 / 困难 0.60 / 噩梦 0.75）
##     `w_growth`    = 当前走到满进度的百分比（W1 = 0、W20 = 1.0）
##     → 两者相乘 = 当前进度下的抗性
##     `block_bias` / `aura` 是**独立加项**（与难度无关的「地利」与「光环」）
##
## 标定（逐条对 §5.5.2）：
##     噩梦 W20 普通怪        = 1.00 × 0.75            = 0.75  ✅「怪物的极限就是 75%」
##     困难 W20 普通怪        = 1.00 × 0.60            = 0.60  ✅
##     简单 W20 普通怪        = 1.00 × 0.45            = 0.45  ✅
##     噩梦 W20 同属 BOSS 光环 = 1.00 × 0.75 + 0.15    = 0.90  ✅（cap 提到 CAP_MOB_SAME_BOSS）
##
## `cap` 由调用方按关系给：普通怪一律 ELEMENT_TAKEN_CAP_MOB.same = 0.75；
## 同属性 BOSS 存活且自身吃光环时传 CAP_MOB_SAME_BOSS = 0.90。
## `zone` = 地形区域加成（第 9 轮 · 需求 4）：怪站在本区地形内且元素与本区相同时由
## `enemy.zone_bonus` 传入。与 block_bias / aura 同一个加法项 —— 因此它**天然受 `cap` 约束**，
## 这正是用户要的「加成不超过上限」（普通怪 0.75、同属 BOSS 0.90）。
## ⚠️ 参数追加在**最后**且带默认值：既有的位置调用（含 5 条冒烟断言）一字不用改。
static func mob_resist(wave: int, resist_mult: float, block_bias: float = 0.0,
		aura: float = 0.0, cap: float = 0.75, zone: float = 0.0) -> float:
	var w_growth := clampf(float(wave - 1) / RESIST_WAVE_GROWTH_DENOM, 0.0, 1.0)
	return clampf(w_growth * resist_mult + block_bias + aura + zone, 0.0, cap)

## 怪物侧某个关系的有效 cap（§5.5.1）。参考系 = **防御方**（与 hit_cap 一致）。
## 同属性且「同属性 BOSS + 光环」成立时，same 行提到 0.90。
static func mob_cap(attacker: String, target: String, same_boss_aura: bool = false) -> float:
	if attacker == "" or target == "":
		return 0.0
	var tier := String(HIT_TIER.get(hit_relation(attacker, target), "other"))
	if tier == "same" and same_boss_aura:
		return CAP_MOB_SAME_BOSS
	return float(ELEMENT_TAKEN_CAP_MOB.get(tier, 0.50))

## ============================================================
## 五行反应表 —— 相生（增强）+ 相克（爆发）
## 相生 generate：不消耗层数，温和增强（加层/延时/提伤/扩散）
## 相克 overcome：消耗层数，爆发伤害（AOE/处决/破甲/DoT 翻倍）
## key = 两五行按 ELEMENTS 字母序拼接（如木生火 = "fire+wood"）
## 运行时查询走 Registry.find_reaction()，使 mod 可注册/覆盖反应
## ============================================================
const REACTIONS := {
	# ---- 相生反应（5 种）----
	# ⚠️ 每条补显式 from/to（§15.6）：方向取 name 真值，绝不解析 id（fire_water 的 id 反了）。
	"fire+wood": {
		"id": "wood_fire", "name": "木生火", "ico": "🌿🔥",
		"from": "wood", "to": "fire",
		"type": "generate", "rarity": "common",
		"desc": "中毒 + 燃烧 → 燃烧层数+1，持续时间延长 50%",
		"effect": {"add_stacks": {"burn": 1}, "duration_mult": {"burn": 1.5}},
		"sfx": "reaction_wood_fire", "shake": 1.6,
	},
	"earth+fire": {
		"id": "fire_earth", "name": "火生土", "ico": "🔥⛰",
		"from": "fire", "to": "earth",
		"type": "generate", "rarity": "common",
		"desc": "燃烧 + 眩晕 → 眩晕延长 0.5s，燃烧伤害+30%",
		"effect": {"duration_add": {"stun": 0.5}, "dmg_mult": {"burn": 1.3}},
		"sfx": "reaction_fire_earth", "shake": 1.6,
	},
	"earth+metal": {
		"id": "earth_metal", "name": "土生金", "ico": "⛰⚔",
		"from": "earth", "to": "metal",
		"type": "generate", "rarity": "rare",
		"desc": "眩晕 + 流血 → 流血层数+2，眩晕期间流血必暴击",
		"effect": {"add_stacks": {"bleed": 2}, "crit_guarantee": {"bleed": true}},
		"sfx": "reaction_earth_metal", "shake": 2.0,
	},
	"metal+water": {
		"id": "metal_water", "name": "金生水", "ico": "⚔💧",
		"from": "metal", "to": "water",
		"type": "generate", "rarity": "rare",
		"desc": "流血 + 冰冻/减速 → 冰冻延长 0.3s，流血伤害转为冰伤",
		"effect": {"duration_add": {"freeze": 0.3}, "convert_dmg": {"bleed": "freeze"}},
		"sfx": "reaction_metal_water", "shake": 2.0,
	},
	"water+wood": {
		"id": "water_wood", "name": "水生木", "ico": "💧🌿",
		"from": "water", "to": "wood",
		"type": "generate", "rarity": "epic",
		"desc": "冰冻/减速 + 中毒 → 中毒扩散到周围敌人（半径 100）",
		"effect": {"spread": {"poison": 100.0}},
		"sfx": "reaction_water_wood", "shake": 2.2,
	},
	# ---- 相克反应（5 种）----
	"earth+wood": {
		"id": "wood_earth", "name": "木克土", "ico": "🌿⛰",
		"from": "wood", "to": "earth",
		"type": "overcome", "rarity": "rare",
		"desc": "中毒 + 眩晕 → 消耗双方，AOE 伤害（半径 100，状态强度×2）",
		"effect": {"consume": {"poison": 1, "stun": 1}, "aoe_dmg_scale": 2.0, "aoe_radius": 100.0},
		"sfx": "reaction_wood_earth", "shake": 3.0,
	},
	"earth+water": {
		"id": "earth_water", "name": "土克水", "ico": "⛰💧",
		"from": "earth", "to": "water",
		"type": "overcome", "rarity": "legendary",
		"desc": "眩晕 + 冰冻/减速 → 消耗双方，目标碎裂（血量<20% 直接死亡）",
		"effect": {"consume": {"stun": 1, "freeze": 1, "slow": 1}, "execute_threshold": 0.20},
		"sfx": "reaction_earth_water", "shake": 5.0,
	},
	"fire+water": {
		"id": "fire_water", "name": "水克火 · 蒸汽爆炸", "ico": "💧🔥",
		"from": "water", "to": "fire",
		"type": "overcome", "rarity": "rare",
		"desc": "冰冻/减速 + 燃烧 → 消耗双方，蒸汽爆炸（半径 120 AOE 伤害×2.5）",
		"effect": {"consume": {"freeze": 1, "slow": 1, "burn": 2}, "aoe_dmg_scale": 2.5, "aoe_radius": 120.0},
		"sfx": "reaction_fire_water", "shake": 4.0,
	},
	"fire+metal": {
		"id": "fire_metal", "name": "火克金", "ico": "🔥⚔",
		"from": "fire", "to": "metal",
		"type": "overcome", "rarity": "epic",
		"desc": "燃烧 + 流血 → 消耗双方，目标熔金（受伤+50%，持续 3s）",
		"effect": {"consume": {"burn": 2, "bleed": 1}, "armor_break": 0.5, "armor_break_duration": 3.0},
		"sfx": "reaction_fire_metal", "shake": 3.5,
	},
	"metal+wood": {
		"id": "metal_wood", "name": "金克木 · 败血症", "ico": "⚔🌿",
		"from": "metal", "to": "wood",
		"type": "overcome", "rarity": "mythic",
		"desc": "流血 + 中毒 → 消耗双方，败血症（持续伤害翻倍，持续 4s）",
		"effect": {"consume": {"bleed": 1, "poison": 1}, "dot_mult": 2.0, "dot_duration": 4.0},
		"sfx": "reaction_metal_wood", "shake": 4.5,
	},
}

## 内置反应查询（只查内置 REACTIONS 表）。
##
## ⚠ 战斗逻辑请一律走 Registry.find_reaction —— 本函数看不到 mod 覆盖/新增的反应，
##   误用会让 mod 反应静默失效（返回空字典，调用方拿到空继续跑，不报任何错）。
##   为把这个静默失败暴露出来：当两个状态「都有五行归属」却查不到内置反应时告警 ——
##   这种组合要么是内容缺失，要么就是有人在生产代码里误用了本函数。
##   「同五行」与「无五行归属」返回空属正常，不告警（例：freeze+slow 都是水，本就无反应）。
static func get_reaction(status_a: String, status_b: String) -> Dictionary:
	var ea := get_element(status_a)
	var eb := get_element(status_b)
	var hit: Dictionary = REACTIONS.get(reaction_key(ea, eb), {})
	if hit.is_empty() and ea != "" and eb != "" and ea != eb:
		push_warning("[Config] 内置反应表查不到 %s+%s（%s+%s）。若这是 mod 反应，请改用 Registry.find_reaction"
			% [status_a, status_b, ea, eb])
	return hit

## ============================================================
## 五行反应伤害护栏（Phase 5 平衡性）
## 约束：单次相克爆发对单个目标的伤害 ≤「玩家单次命中伤害 × 该倍率」。
## 参考值由状态携带的 power 反推——power 就是施加该状态时那次命中的玩家伤害，
## 因此这个上限与玩家当前的构筑强度同步，不会出现「后期反应伤害形同虚设」。
##
## 内置相克的等效倍率（层数 × aoe_dmg_scale）最高约 10×：
##   水克火 = (燃烧2 + 冰冻1 + 减速1) × 2.5 = 10×
## 故取 12× 作为护栏：只砍掉「异常叠层被堆到极端」时的失控爆发（例如多层燃烧 + 水克火），
## 不改动正常手感。若封闭测试反馈「异常流仍然无敌」，把这个值下调到 3.0 即可——
## 那是总计划里更保守的口径，会明显削弱相克爆发，属于需要实测手感再定的取舍。
## ============================================================
const REACTION_BURST_CAP_MULT := 12.0

## DoT 单跳伤害护栏（2026-09-19）：单跳 ≤「施加该状态时的命中伤害（power）× 该倍率」。
## 与 `REACTION_BURST_CAP_MULT` 同一思路 —— power 与当前构筑同步，所以不削弱正常手感，
## 只砍掉乘区被叠到极端时的失控值。
## 合法上限参照：燃烧 dot_scale 0.18 × 5 层 × 金克木 dot_mult 2.0 = 1.8×，取 2.0 留余量。
## ⚠️ 只作用于「按 power 结算」的 DoT（燃烧/流血）；中毒走 `dot_max_hp_pct`，按设计
##    就该随敌人最大生命成长，不套这个闸门。
const DOT_TICK_CAP_MULT := 2.0

## 把法宝 patch 应用到反应 effect 上，返回新字典（不改原数据）
##   set：整键覆盖（字典值也是整体替换）
##   add：数值相加；字典值按子键合并（缺失则新建）；类型不兼容时退化为覆盖
## 纯函数：Registry 注册校验与 ArtifactSystem 运行时共用，保证“验的就是跑的”
static func apply_patch(base: Variant, patch: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if typeof(base) == TYPE_DICTIONARY:
		out = (base as Dictionary).duplicate(true)
	for op in patch:
		if typeof(patch[op]) != TYPE_DICTIONARY:
			continue
		var delta: Dictionary = patch[op]
		if String(op) == "set":
			out.merge(delta, true)
			continue
		if String(op) != "add":
			continue
		for k in delta:
			if typeof(delta[k]) == TYPE_DICTIONARY:
				var sub: Dictionary = {}
				if typeof(out.get(k)) == TYPE_DICTIONARY:
					sub = (out[k] as Dictionary).duplicate(true)
				sub.merge(delta[k], true)
				out[k] = sub
			elif out.has(k) and _is_number(out[k]) and _is_number(delta[k]):
				out[k] = float(out[k]) + float(delta[k])
			else:
				out[k] = delta[k]
	return out

static func _is_number(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT

## 武器：dmg 基础伤害，cd 基础冷却秒；近战用 range / swing_arc
## price 商店基价 / shop_weight 商店出货权重（0 = 不进商店池，进化形态用）
## evolve_need：持有同名武器达到该数量，波末自动合成为 evolve_to（吸血鬼幸存者式）
##
## ⭐ 五行体系 §4.1（S2 定稿）：**内置基础武器只有这 5 把**，每把恰好承载一个元素。
##    其余 23 把旧武器（含它们各自的进化形态）已整体迁入官方工坊包
##    `game/mods/brotato_lite_core/manifest.json`，走标准 mods 通道注册 ——
##    所以「武器 = 元素载体」这条核心决策不会被无元素武器稀释。
##    element 字段语义见 register_weapon（武器自带元素**覆盖**角色归属元素，§2.5）。
##
##    ⚠️ S8 起本表共 **10 条**：5 把基础五行武器 + 5 个五行进化形态（见下方「进化树」段）。
##    两者都**自带 element**，所以「内置 = 都带元素」这条不变式仍然成立 ——
##    冒烟 `_check_phase3_counts` 断言的是「内置条目数 == `Config.WEAPONS.size()`」，
##    而不是写死 5（写死会在补进化体时红，且红得像是「收缩失败了」）。
##    进不进开局池由 `LOADOUT_WEAPONS` 单独管，与「是不是内置」无关。
##
## ✅ **进化树已在 S8 补回（2026-09-17）**：S2 时它**指向空气**而被清空 ——
##    改造前 `knife.evolve_branches` 指向 `["blade","blade_ex"]`，这两个 ID 都已迁入工坊包，
##    留着就是「玩家凑满 3 把金剑 → `evolve_weapons()` 找不到目标 → 合成静默不发生」。
##    当时按 §4.4 的许可留到 S8 平衡阶段再补，现已补齐。
##
##    补做口径（§4.4）：**每个元素给 1 个进化体，且进化体必须自带 `element`** ——
##    否则「元素武器 → 无属性武器」会把五行体系打穿（进化后不吃任何关系加成，**且不报错**）。
##    5 把基础武器统一 `evolve_need: 3` + **单分支** `evolve_branches`：
##    单分支由 `player.evolve_weapons()` 在波末**自动合成**，不弹进化选择 UI
##    （多分支才走 `pending_evolve_choices()` → `evolve_choose.gd`）。
##    进化形态 `shop_weight: 0` → **不进商店池**，只能靠合成获得（与工坊包既有惯例一致）。
##
##    ⚠️ 数值口径：单体 DPS **统一 2.0×**，另按原定位给 AOE / 控制 / 射程强化 ——
##    **进化只放大该武器原本的定位，不换定位**（贴脸的还是贴脸，风筝的还是风筝）。
##
##    ⚠️⚠️ 为什么是 **2.0× 而不是 1.4×**（本轮最容易被改错的一处）：
##    `player.gd:123-126` 里**每把武器各占一个槽、各自独立开火** →
##    持有 3 把同名武器 = **3 份输出**。`evolve_weapons()` 是把 3 把**合成 1 把**，
##    所以进化本质是「**用 3 个槽换 1 个槽**」—— 若只给 1.4×，进化的那一瞬间
##    总输出是净亏的（3 → 1.4，相当于白丢 1.6 把），自动进化会变成惩罚。
##    2.0× = 「1 把顶 2 把」：腾出的 2 个槽去补别的元素，补满即回本，
##    且顺带把「一个元素一把」的五行环补回来（3 把同名 = 五行环缺 2 环）。
##    ⚠️ 若哪天改成「进化保留槽位」或「多把同名共用 CD」，这条口径必须重算。
##    逐把账目见 `docs/武器DPS体检表.md` §10。
##
## ⚠️ 想要「纯五行池」时，把那个 mod 目录移出/改名即可停用，无需改动本文件。
##
## ✅ 2026-09-17（第 7 轮）**已执行**：`game/mods/brotato_lite_core/` 整体搬到
##    `game/mods_disabled/brotato_lite_core/`（文件保留、未删）。所以现在
##    `Registry.weapons` 恰好就是本表这 10 条，商店池（`shop_weapon_pool`）里
##    只剩 5 把 `shop_weight > 0` 的基础五行武器，**不会再刷出旧枪械/刀类**。
##    要恢复：移回 `game/mods/`，并同步改回 `smoke_test.gd` 的两组断言
##    （内置内容计数 `chars/weapons` + 印记分支的探针）。
##
## ⚠️ 2026-09-17 第 7 轮数值改动：**本表 10 条的 `dmg` 一律 ×0.5**（用户要求
##    「所有武器数值减半」）。进化体同步减半 → 「进化 = 基础 2.0×」这条口径
##    **恒等保持**，不需要额外重算。逐把账目见 `docs/武器DPS体检表.md` §12。
const WEAPONS := {
	# ⚠️⚠️ 2026-09-18（第 11 轮）用户反馈：「金剑的加成太离谱，距离加成对金剑的加成太高了，
	#    搞几关就变的攻击范围很大」。
	#   查证：**根因是几何**——近战 `reach = range × (1 + melee_range_bonus)`（player.gd:422），
	#   而扇形 AOE = ½·r²·θ **∝ reach²** → **每 +10% range ≈ +21% 面积**。
	#   4 张近战 range 道具全叠 = **+110%**（旧：edge+18 / swordmanual+22 / whetstone+35 / swordcase+35）
	#   → reach 95→199.5、AOE 11,814→**52,098（×4.41）**；再叠铭刻 +12% 就是 ×4.93。
	#   同期喷火枪堆满 range（+103%）只把 reach 110→223（射程乘算、**splash 不吃 range**）→ AOE 仍 5,027。
	#   同样「+100% 射程」，一个把面积推到 4.4 倍、一个只是射程 ×2 —— 这才是「被金剑替代」的真机制。
	# ✅ 修法（用户拍板「**只砍数值 + 提品**，不动公式」）：
	#   1. 本体：`cd` 0.45→**0.55**（−18% 攻速）、`range` 95→**88**。
	#      单体 DPS 15.56→12.73；DoT 稳态按 1/cd 算层数 → 也同步下降，合计 19.91→**≈16.3**。
	#      进化体 `knife_ex` 同步 **cd 0.55 / range 106**（守住「进化 = 基础 2.0×」与面积比 1.69×）。
	#   2. 4 张近战 range 道具加成量**砍到约 60%** 并**提品**：
	#      edge +18%→**+11%**（**保持 rare**）、swordmanual +22%→**+13%**（epic→mythic）、
	#      whetstone +35%→**+21%**（epic→mythic）、swordcase +35%→**+21%**（epic→mythic）。
	#      ⚠️ 提到 mythic = 金「**唯一件**」（本局每种最多 1 件）+ 池权重更低 → 双重「更难刷出来」。
	#      ⚠️⚠️ `edge` **刻意留在 rare**（第 11 轮冒烟实测拦下）：`rarity_weight` 按波次压权重
	#        （epic 要 progress≥3、mythic ≥6，见本文件 1716-1724），而商店「亲和保底」
	#        （`shop_ui._ensure_affinity_goods`）要求**任意波次**都能找到一条契合商品。
	#        4 张近战射程道具若全部 ≥epic，W1~W2 的近战构筑就没有任何可保底条目
	#        （实测：池非空但全是 0 权重 → weighted_pick 报错返回 null → 撞 SCRIPT ERROR）。
	#        留最弱的这张在 rare 顶住低波，既当保底锚点，也符合「最弱的那个不必提品」。
	#   ⚠️ 刻意**没动公式**：改成「加固定 px」能根治雪崩，但会改近战手感，用户选了保守路线。
	#      所以「堆满仍会雪崩」的形状还在，只是来得更晚、更贵 —— 下次再失衡**先看这一段**。
	"knife": { "name": "金剑", "ico": "🗡", "attack_type": "melee", "sfx": "shoot_knife", "cd": 0.55, "dmg": 7.0, "range": 88.0, "swing_arc": 2.618, "status": "bleed", "status_chance": 0.35, "rarity": "common", "family": "blade", "element": "metal", "desc": "五行·金：150° 大开大合横扫，概率造成流血。单目标不算最强，靠群扫吃多目标", "price": 28, "shop_weight": 2.4, "evolve_need": 3, "evolve_branches": ["knife_ex"] },
	# ⚠️ 2026-09-16 S8 调数值：dmg 3.5→2.5（−1）、射程 128px→110px（`bullet_life` 0.34→0.28）、
	#    新增 `splash` 变成 AOE。定位从「贴脸单体最高 DPS」改为「中近距离范围灼烧」。
	#    ⚠️ 2026-09-17 二轮修正（综合战力口径）：splash 60→**75**、price 52→**42**。
	#       原因：它与金剑同风险档（reach 110 vs 95，都要贴脸），但单体 DPS 低 20%、
	#       AOE 面积几乎相同（旧 11,310 vs 金剑扇形 11,814）→ **高风险却无对等回报**。
	#       当时 dmg **保持用户定的 2.5 不动**，只把 AOE 做强（面积 17,671 = 金剑 1.50×）
	#       并把溢价降下来（价/DPS 2.08→1.68），让它成为明确的「群战工具」而非「弱化单体系」。
	#       射程口径：`reach = bspeed × bullet_life + 26`（player.gd:321）= 300×0.28+26 = **110px**
	#       （84 只是子弹飞行距离，+26 是枪口到角色中心 —— 旧 desc 写 84 是与代码不符的）。
	#    ✅ 2026-09-17 三轮修正：**dmg 2.5 → 3.0**（用户拍板「回调至 3.0」—— 这是本轮唯一
	#       一次动这个数值，前两轮刻意没动）。单体 DPS 25.0 → **30.0**，价/DPS 1.68 → **1.40**。
	#       ⚠️ **已知副作用（刻意接受）**：30.0 与金剑 31.11 几乎持平，而它的 AOE 面积是
	#       金剑扇形的 **1.50×** → 喷火枪在「单体 + 群扫」两项上都不再吃亏，金剑的相对优势
	#       只剩「更便宜（28 vs 42）+ 流血 + blade 族共鸣」。
	#       ⚠️ **不要因为「金剑被压过」再回头动这两把的数值** —— 按体检表 §9 的三维口径
	#       （距离 / AOE / 生存）评判，金剑的 −225px 安全裕度本就是它的定价来源。
	#       连带：进化体 `flamethrower_ex` 同步 5.0 → **6.0**（保住「进化 = 基础 2.0×」口径）。
	#    ⚠️ 2026-09-17 **第 7 轮全局减半**：**dmg 3.0 → 1.5**（用户拍板「所有武器数值减半」，
	#       范围＝全部 10 把含进化体）。单体 DPS 30.0 → **15.0**，价/DPS 1.40 → **2.80**。
	#       ⚠️ **价格刻意没动**（42 保持）——拍板只点了 dmg，所以全表「价/DPS」统一翻倍，
	#       这是**全局口径变化**（材料→DPS 的兑换率减半），不是这把武器单独变贵，别当成失衡去改单把价格。
	#       ✅ 与金剑的相对关系**不变**：15.0 vs 15.56 = 0.964，与减半前的 30.0 vs 31.11 同比值
	#       → 上面三轮的结论（尤其「喷火枪单体+群扫都不吃亏」）**全部继续成立**。
	#       连带：进化体 `flamethrower_ex` 同步 6.0 → **3.0**（守住「进化 = 基础 2.0×」口径）。
	#    ⚠️ 注意：cd 0.10 = 每秒 10 发，每发都会起一次溅射 —— 成群时收益放大明显，
	#       同时粒子/爆炸特效数量也翻了 10 倍，若实测掉帧优先收半径而不是收 cd
	#       （已配 `explosion.gd` 的 `"flame"` 轻量分支：不震屏、粒子 6 粒）。
	# ⚠️⚠️ 2026-09-17（第 8 轮）用户反馈「喷火器范围好像也有问题，太远了」。
	#   查证：它自称「射程≈110px」，但**真实伤害半径 = 110 + splash 75 = 185px**
	#   （`smoke_test.gd:6781` 早就写明：旧口径把它读短了整整 75px），而**火焰视觉只画到 110px**
	#   （`flame_jet.gd` 的 `reach`）→ 看到的比打到的近 75px。用户看到的就是这个错位。
	#   ✅ 修法（用户拍板：「削溅射 + 视觉对齐」）：
	#     1. `splash` 75 → **40**：有效射程 185 → **150px**，回到「贴脸烧」的定位。
	#     2. 火焰锥改画到**有效射程**（见 `_ignite_flame_jet`）→ 从此「看到的 = 打到的」。
	#     进化体 `flamethrower_ex` 同步 105 → **56**（保持原 1.4× 比例）。
	#   ⚠️ 代价：AOE 面积 17,671 → **5,027**（−71%），进化体 34,636 → 9,852。
	#     它本来就是全场第二大 AOE（仅次于土炸弹），现在回到「高频单体 + 小范围溅射」。
	#     ⚠️ 这是**用户明确要求的削弱**，不是失衡修正 —— 不要因为「金剑反而更强」再把它加回去。
	"flamethrower": { "name": "喷火枪", "ico": "🔥", "attack_type": "projectile", "sfx": "shoot_smg", "cd": 0.10, "dmg": 1.5, "bspeed": 300.0, "spread": 0.34, "bullet_life": 0.28, "splash": 40.0, "status": "burn", "status_chance": 0.80, "rarity": "common", "family": "element", "element": "fire", "desc": "五行·火：中近距离范围灼烧（射程≈110px），高频叠燃烧并带 40px 溅射（有效射程≈150px）", "price": 42, "shop_weight": 1.5, "evolve_need": 3, "evolve_branches": ["flamethrower_ex"] },
	"frost_staff": { "name": "水枪", "ico": "💧", "attack_type": "projectile", "sfx": "shoot_rocket", "cd": 0.30, "dmg": 5.0, "bspeed": 560.0, "bullet_life": 1.1, "status": "slow", "status_chance": 0.60, "rarity": "common", "family": "element", "element": "water", "desc": "五行·水：单发伤害最低，高射速铺减速，为队伍创造输出窗口", "price": 72, "shop_weight": 0.9, "evolve_need": 3, "evolve_branches": ["frost_staff_ex"] },
	# ⚠️⚠️ 2026-09-17（第 8 轮）用户反馈「有个加子弹攻速的加成太变态了，土质炸弹吃子弹攻速加成太高了」。
	#   查证：这里的「子弹攻速」指**弹速类道具**（`bullet_speed_bonus` / `bullet_range_bonus`）。
	#   机制：`reach = bspeed × bullet_life + 26`（player.gd:321）→ 弹速 +38% 会让土炸弹弹体射程
	#   340→469、`reach` 400→542；再叠「铳匠长管」+35% 射程 → **731px 的大范围 AOE**。
	#   ⚠️ 关键：土炸弹**原本没写 `bullet_life`**，一直吃 `bullet.gd:35` 的默认 1.1 —— 于是它的
	#   射程是「隐式」的，看起来像普通弹幕，才会被弹速类道具按同一套公式放大。
	#
	# ✅ 修法（用户拍板口径）：「弹幕改为投掷物/爆炸物，单独做加成，不和其他弹幕混到一起」。
	#   1. 新增武器字段 `proj_kind`（默认 `"bullet"`）：土炸弹两态标 `"thrown"`。
	#   2. `player._weapon_runtime_cfg` 按 `proj_kind` 分流：
	#      · `bullet` → 吃 `bullet_speed_bonus` / `bullet_range_bonus`（原有行为不变）
	#      · `thrown` → 改吃 `throw_speed_bonus` / `throw_range_bonus`（**新通道**，与弹幕互不串味）
	#      · 两者都吃 `aoe_radius_bonus`（那是「爆炸多大」，与「飞多远」正交）
	#   3. `Config.entry_weapon_relevant` 同步：只有**真持有弹幕武器**才会刷出弹速类道具，
	#      只有持有投掷武器才会刷出投掷类道具 —— 否则商店会给一屋子废属性。
	#   4. 同时把 `bullet_life` 由「隐式默认」改成**显式 1.1**：射程自此写在表里、可审计。
	#      （数值本身没变：340×1.1+26 = 400px，与第 7 轮体检表一致。）
	"thunder_gong": { "name": "土质炸弹", "ico": "💣", "attack_type": "projectile", "proj_kind": "thrown", "sfx": "shoot_rocket", "cd": 1.35, "dmg": 15.0, "bspeed": 340.0, "bullet_life": 1.1, "splash": 95.0, "status": "stun", "status_chance": 0.35, "status_stacks": 1, "shake": 2.5, "rarity": "common", "family": "element", "element": "earth", "desc": "五行·土：投掷爆炸物，400px 外爆开 95px 范围（眩晕 35%）。⚠️ 只吃「投掷类」加成，不吃弹速/射程类", "price": 54, "shop_weight": 0.9, "evolve_need": 3, "evolve_branches": ["thunder_gong_ex"] },
	"blight_bow": { "name": "木弓", "ico": "🏹", "attack_type": "projectile", "sfx": "shoot_pistol", "cd": 0.75, "dmg": 12.0, "bspeed": 620.0, "bullet_life": 1.1, "rarity": "common", "family": "element", "element": "wood", "desc": "五行·木：攻速最慢（0.75s），单发最重，靠高单发与吸血续航而非爆发", "price": 52, "shop_weight": 1.3, "evolve_need": 3, "evolve_branches": ["blight_bow_ex"] },
	# ---- 五行进化形态（S8 补做）：持满 3 把基础武器 → 波末自动合成；shop_weight 0 = 不进商店池 ----
	"knife_ex": { "name": "庚金剑域", "ico": "⚔", "attack_type": "melee", "sfx": "shoot_knife", "cd": 0.55, "dmg": 14.0, "range": 106.0, "swing_arc": 3.054, "status": "bleed", "status_chance": 0.45, "rarity": "rare", "family": "blade", "element": "metal", "desc": "金剑·进化：reach 106px + 175° 剑域（面积 1.69×），单体 DPS 2.0×，流血 45%", "price": 84, "shop_weight": 0 },
	#  ⚠️ dmg 3.0 是跟着基础体走的：基础 1.5 × 2.0（进化倍数）= 3.0 → 单体 30.0。
	#     基础体改数值时**必须同步这里**，否则进化倍数会悄悄跌破 2.0× 而不报错。
	"flamethrower_ex": { "name": "焚天焰", "ico": "☄", "attack_type": "projectile", "sfx": "shoot_smg", "cd": 0.10, "dmg": 3.0, "bspeed": 300.0, "spread": 0.34, "bullet_life": 0.28, "splash": 56.0, "status": "burn", "status_chance": 0.90, "rarity": "rare", "family": "element", "element": "fire", "desc": "喷火枪·进化：56px 溅射（有效射程≈166px），单体 DPS 2.0×，燃烧 90%", "price": 126, "shop_weight": 0 },
	"frost_staff_ex": { "name": "玄冰潮", "ico": "❄", "attack_type": "projectile", "sfx": "shoot_rocket", "cd": 0.30, "dmg": 7.0, "bspeed": 560.0, "bullet_life": 1.2, "status": "slow", "status_chance": 0.80, "rarity": "rare", "family": "element", "element": "water", "desc": "水枪·进化：reach 698px + 减速 80%，单体 DPS 2.0×", "price": 216, "shop_weight": 0 },
	"thunder_gong_ex": { "name": "厚土雷", "ico": "🌋", "attack_type": "projectile", "proj_kind": "thrown", "sfx": "shoot_rocket", "cd": 1.35, "dmg": 30.0, "bspeed": 340.0, "bullet_life": 1.1, "splash": 115.0, "status": "stun", "status_chance": 0.45, "status_stacks": 1, "shake": 2.5, "rarity": "rare", "family": "element", "element": "earth", "desc": "土炸弹·进化：投掷爆炸物，面积 1.47×，单体 DPS 2.0×，眩晕 45%（仅吃投掷类加成）", "price": 162, "shop_weight": 0 },
	"blight_bow_ex": { "name": "青木弓", "ico": "🌿", "attack_type": "projectile", "sfx": "shoot_pistol", "cd": 0.75, "dmg": 18.0, "bspeed": 620.0, "bullet_life": 1.2, "rarity": "rare", "family": "element", "element": "wood", "desc": "木弓·进化：单发 18、reach 770px，单体 DPS 2.0×（仍是最高单发 + 最远射程）", "price": 156, "shop_weight": 0 },
}

## 武器槽 = **5**：与五行一一对应，「一个元素一把」正好铺满五行环（S8 定）。
##
## ⚠️⚠️ 改这个值必须同步另外 **2 处硬编码副本**（都是「改主常量忘同步」的经典坑）：
##   1. `run_rules.gd:59` 里 `weapon_slots` 规则的 `"default"`（自定义规则局的基准；同行的 `min/max` 是区间，不用改）
##   2. `run_rules.gd:166` 的评分基线 `(get_value("weapon_slots") - 5.0)`（否则默认局凭空扣分）
## ✅ `smoke_test.gd` 的两条槽位断言（未购/已购军火专家）**已改为引用本常量**，自动跟随，不必手改。
## 其余 11 处调用点走 `MetaProgress.weapon_slots()` → `RunRules.weapon_slots_total()`，自动感知，无需改。
const WEAPON_SLOTS := 5
## 商店临时武器槽数量（第 13+ 轮需求 3）：永久槽满后，仍可买武器放进临时槽（用于凑齐 3 把进化），
## 退出商店时半价卖出。武器总容量 = WEAPON_SLOTS + TEMP_WEAPON_SLOTS。
const TEMP_WEAPON_SLOTS := 2
const WEAPON_SHOP_CHANCE := 0.42
## 同族武器共鸣：持有同 family 武器 ≥2 把时，每多一把叠加一次加成（见 player._refresh_family_synergy）。
## 设计意图：鼓励玩家围绕单一武器家族构筑，让进化树各分支之间产生联动收益。
## 例：手枪 + 冲锋枪 + 霰弹枪（gun ×3）→ 共鸣 2 层 = 攻速 +8%、暴击 +2%。
const WEAPON_FAMILY_SYNERGY := {
	"gun": { "as_mult": 0.04, "crit_ch": 0.01 },       # 枪械族：每多一把 +攻速 +暴击
	"blade": { "dmg_mult": 0.10, "crit_mult": 0.15 },  # 近战族：每多一把 +伤害 +暴伤
	"element": { "status_dmg_mult": 0.15 },            # 元素族：+状态伤害
	"heavy": { "dmg_mult": 0.12 },                     # 重火力：+伤害
}

## ============================================================
## 开局内容池（Loadout）—— 开局向导（角色→武器→道具）的可选范围
##
## ⭐ 五行体系（§4.1.5 第 5 轮定稿）：「**开局池 = 5 把，商店放开**」
##
##   - **开局武器 = 五把五行武器**，每把恰好承载一个元素（§4.1）：
##       金剑 `knife`（melee 群扫）/ 木弓 `blight_bow`（高单发远程）/
##       水枪 `frost_staff`（高速铺减速）/ 喷火枪 `flamethrower`（贴脸烧）/
##       土质炸弹 `thunder_gong`（远程 AOE）
##     开局向导第 2 步把这一条讲清楚：**「武器 = 元素」是这套体系的第一课** ——
##     玩家选武器不只是选手感，更是在选「角色元素 vs 武器元素」的输出关系（§2.3-A）。
##   - **商店池放开**（`Registry.shop_weapon_pool()` 不动）：已注册的全部武器都能刷到。
##     ⚠️ 两条通路本就独立：本表单管「开局能选什么」，shop_weapon_pool 管「商店能刷什么」。
##     ⚠️ 2026-09-17（第 7 轮）：工坊包已停用 → 「已注册的全部武器」现在就是本表 10 条，
##        其中商店能刷的只有 5 把基础五行（进化体 `shop_weight = 0`）。
##        用户反馈的「游戏进行中还能选到其他武器」正是这条通路漏进旧枪械导致的，现已闭合。
##
##   - 开局道具只开放「前期过渡档」（common/rare），且按当前角色+武器的构筑亲和排序，
##     相关道具优先展示；高品阶道具只能局内通过商店/掉落/事件逐步获得。
##   - 这两张白名单刻意从 Registry 反查（不在表里的 mod 内容默认不进开局池），
##     既保证内置平衡，也不阻断 mod 内容在局内的正常获取。
## ============================================================
const LOADOUT_WEAPONS := ["knife", "blight_bow", "frost_staff", "flamethrower", "thunder_gong"]
#                          金剑     木弓          水枪          喷火枪         土质炸弹

## 兜底武器：任何「拿不到合法武器」的空值路径都回退到这里。
## ⚠️ 必须是 `LOADOUT_WEAPONS` 的成员 —— 旧代码回退 `"pistol"`，
##    而 `pistol` 已在 S2 迁入工坊包、默认加载与否可变（移出后就成了死引用，
##    会让玩家开局空手、且全程无报错）。这里把「兜底 = 开局池第一把」钉成显式约束。
const FALLBACK_WEAPON := "knife"

## 敌人：W1 基础值；血量/伤害随波次缩放（见 wave_* 系列函数）
##
## element 字段（五行体系 §12-S1）：敌人所属五行，`""` = 无属性（不吃元素修正，
## 也不对玩家施加元素修正）。基础敌 10 条沿用「原土豆兄弟」的白板定位，
## 保持 ""；主题包 10 条按命名填对应五行；6 BOSS 各自代表一行。
## ⚠️ BOSS 的 element 必须与 §5.5.3 区域元素序对应（同属 BOSS 落在区块末波），
##    否则「同属性 +90% 减伤」的 cap 永远触发不了。
const ENEMIES := {
	"grunt": { "name": "追击者", "hp": 14.0, "speed": 88.0, "dmg": 8.0, "xp": 2, "mat": 2, "r": 14.0, "color": "#d9534f", "shape": "circle", "heart_chance": 0.04 },
	"runner": { "name": "冲锋者", "hp": 8.0, "speed": 168.0, "dmg": 6.0, "xp": 3, "mat": 2, "r": 11.0, "color": "#e8902a", "shape": "diamond", "heart_chance": 0.04 },
	"tank": { "name": "坦克", "hp": 46.0, "speed": 50.0, "dmg": 16.0, "xp": 8, "mat": 6, "r": 23.0, "color": "#8e5bbf", "shape": "circle", "heart_chance": 0.12 },
	"shooter": { "name": "射手", "hp": 12.0, "speed": 72.0, "dmg": 10.0, "xp": 5, "mat": 4, "r": 14.0, "color": "#3bbfae", "shape": "square", "keep_dist": 270.0, "shoot_cd": 2.2, "bspeed": 300.0, "heart_chance": 0.08 },
	"swarm": { "name": "蜂群幼体", "hp": 5.0, "speed": 118.0, "dmg": 4.0, "xp": 2, "mat": 1, "r": 8.0, "color": "#cdd94f", "shape": "circle", "heart_chance": 0.02 },
	"bomber": { "name": "自爆虫", "hp": 10.0, "speed": 150.0, "dmg": 14.0, "xp": 4, "mat": 3, "r": 12.0, "color": "#ff5e3a", "shape": "diamond", "heart_chance": 0.05 },
	"wizard": { "name": "蛊惑法师", "hp": 26.0, "speed": 66.0, "dmg": 12.0, "xp": 9, "mat": 6, "r": 16.0, "color": "#b05ae0", "shape": "circle", "keep_dist": 320.0, "shoot_cd": 1.7, "bspeed": 340.0, "heart_chance": 0.10 },
	"shadow": { "name": "暗影刺客", "hp": 18.0, "speed": 205.0, "dmg": 12.0, "xp": 6, "mat": 4, "r": 10.0, "color": "#3d4356", "shape": "diamond", "heart_chance": 0.05 },
	"guard": { "name": "重装卫兵", "hp": 120.0, "speed": 42.0, "dmg": 20.0, "xp": 14, "mat": 10, "r": 30.0, "color": "#5a6dbf", "shape": "square", "heart_chance": 0.18 },
	"chest_guard": { "name": "宝箱守卫", "hp": 90.0, "speed": 60.0, "dmg": 14.0, "xp": 12, "mat": 15, "r": 24.0, "color": "#c9a24a", "shape": "square", "heart_chance": 0.10 },
	# ============================================================
	# 五行基础元素怪（§5.1 · §12-S3）
	#
	# 与下方「Phase 2 阵营怪」的分工：
	#   这里 5 只是**基础元素怪** —— 每个五行各一只，各带一个**可独立复现的机制**，
	#   承担「让玩家从 W1 起就能感受到五行克制」的反馈闭环（§5.4）。
	#   下方 fire_imp / wood_sprite 等 10 只是**进阶阵营怪**（数值更强、机制更少），
	#   计划作为元素怪的高波次替代形态，本步不动。
	#
	# ⚠️ 每只怪必须**显式**声明 element —— 元素是设计常量，
	#    「从 id / 名字猜元素」会埋雷（blood → metal 之类），见 register_enemy 的校验注释。
	# ⚠️ 数值尺度对齐现役阵营怪（metal_puppet 42hp/62spd/14dmg、wood_sprite 18/80/6、
	#    water_nymph 16/68/8、fire_imp 12/175/7、earth_golem 75/38/18），不突变。
	# ============================================================
	# 金·金甲卫：护盾（先扣盾再扣血）+ 护盾期减伤 + 穿甲（打玩家的护甲按 pierce 加权）
	"metal_guard": { "name": "金甲卫", "hp": 40.0, "speed": 60.0, "dmg": 12.0, "xp": 7, "mat": 6,
		"r": 18.0, "color": "#dfe6f0", "shape": "square", "heart_chance": 0.10,
		"status_resist": 0.30, "element": "metal",
		"shield": 40.0, "shield_resist": 0.5, "armor_pierce": 1.0 },
	# 木·回春灵：持续回血（受击后停 2 秒，避免"打不死的挫败感"）
	"wood_healer": { "name": "回春灵", "hp": 22.0, "speed": 90.0, "dmg": 7.0, "xp": 5, "mat": 4,
		"r": 13.0, "color": "#7ec850", "shape": "circle", "heart_chance": 0.06,
		"status_resist": 0.30, "element": "wood",
		"regen": 3.0, "regen_delay": 2.0 },
	# 水·分裂水灵：死亡分裂 ×3（分裂体 50% 血、且**只允许一代** —— 递归护栏在 die()）
	"water_splitter": { "name": "分裂水灵", "hp": 26.0, "speed": 85.0, "dmg": 8.0, "xp": 5, "mat": 4,
		"r": 13.0, "color": "#8fd8ff", "shape": "diamond", "heart_chance": 0.06,
		"status_resist": 0.30, "element": "water",
		"split_on_death": { "type": "water_splitter", "count": 3, "hp_pct": 0.5 } },
	# 火·赤焰法师：远程（复用既有 shooter AI，不新增 AI 形态）
	"fire_caster": { "name": "赤焰法师", "hp": 18.0, "speed": 70.0, "dmg": 10.0, "xp": 5, "mat": 3,
		"r": 14.0, "color": "#ff7a3c", "shape": "circle", "heart_chance": 0.06,
		"status_resist": 0.30, "element": "fire",
		"ai": "shooter", "keep_dist": 280.0, "shoot_cd": 2.0, "bspeed": 320.0 },
	# 土·岩卫：纯数值（血厚慢速高伤）—— 刻意不给机制，作为「基础解」的对照基准
	"earth_bulwark": { "name": "岩卫", "hp": 80.0, "speed": 40.0, "dmg": 16.0, "xp": 12, "mat": 8,
		"r": 24.0, "color": "#ffd24a", "shape": "square", "heart_chance": 0.14,
		"status_resist": 0.40, "element": "earth" },
	# ---- Phase 2 主题包新增（10 敌人 + 3 BOSS，五行阵营） ----
	"fire_imp": { "name": "火鸦童子", "hp": 12.0, "speed": 175.0, "dmg": 7.0, "xp": 3, "mat": 2, "r": 11.0, "color": "#ff7a3c", "shape": "diamond", "heart_chance": 0.04, "status_resist": 0.30, "element": "fire" },
	"fire_shaman": { "name": "赤焰巫师", "hp": 24.0, "speed": 62.0, "dmg": 11.0, "xp": 8, "mat": 5, "r": 15.0, "color": "#ff5e3a", "shape": "circle", "keep_dist": 300.0, "shoot_cd": 2.0, "bspeed": 320.0, "heart_chance": 0.08, "status_resist": 0.30, "element": "fire" },
	"wood_sprite": { "name": "木灵幼芽", "hp": 18.0, "speed": 80.0, "dmg": 6.0, "xp": 3, "mat": 3, "r": 12.0, "color": "#7ec850", "shape": "circle", "heart_chance": 0.05, "status_resist": 0.30, "element": "wood" },
	"vine_beast": { "name": "藤蔓妖", "hp": 30.0, "speed": 92.0, "dmg": 10.0, "xp": 6, "mat": 4, "r": 14.0, "color": "#5aa040", "shape": "diamond", "heart_chance": 0.06, "status_resist": 0.30, "element": "wood" },
	"metal_puppet": { "name": "金傀武士", "hp": 42.0, "speed": 62.0, "dmg": 14.0, "xp": 7, "mat": 6, "r": 18.0, "color": "#dfe6f0", "shape": "square", "heart_chance": 0.10, "status_resist": 0.30, "element": "metal" },
	"blade_monk": { "name": "刀锋武僧", "hp": 20.0, "speed": 190.0, "dmg": 13.0, "xp": 6, "mat": 4, "r": 11.0, "color": "#c0c8d4", "shape": "diamond", "heart_chance": 0.06, "status_resist": 0.30, "element": "metal" },
	"water_nymph": { "name": "水泽鲛奴", "hp": 16.0, "speed": 68.0, "dmg": 8.0, "xp": 5, "mat": 4, "r": 13.0, "color": "#8fd8ff", "shape": "circle", "keep_dist": 280.0, "shoot_cd": 2.4, "bspeed": 280.0, "heart_chance": 0.06, "status_resist": 0.30, "element": "water" },
	"ice_witch": { "name": "玄冰女妖", "hp": 28.0, "speed": 58.0, "dmg": 12.0, "xp": 10, "mat": 7, "r": 16.0, "color": "#5aa8d8", "shape": "circle", "keep_dist": 320.0, "shoot_cd": 1.8, "bspeed": 340.0, "heart_chance": 0.10, "status_resist": 0.40, "element": "water" },
	"earth_golem": { "name": "土灵石俑", "hp": 75.0, "speed": 38.0, "dmg": 18.0, "xp": 12, "mat": 8, "r": 24.0, "color": "#ffd24a", "shape": "square", "heart_chance": 0.12, "status_resist": 0.30, "element": "earth" },
	"stone_titan": { "name": "山岳巨人", "hp": 140.0, "speed": 32.0, "dmg": 24.0, "xp": 16, "mat": 12, "r": 30.0, "color": "#c8a030", "shape": "square", "heart_chance": 0.18, "status_resist": 0.40, "element": "earth" },
	"boss": { "name": "巨型土豆王", "hp": 768000.0, "speed": 64.0, "dmg": 28.0, "xp": 60, "mat": 100, "r": 56.0, "color": "#b01e2e", "shape": "circle", "ring_cd": 2.2, "ring_count": 16, "bspeed": 260.0, "death_skill": "ring", "status_resist": 0.55, "heart_chance": 1.0, "dmg_cap_pct": 0.005, "element": "earth", "skills": [
		{ "type": "fan", "name": "弹幕压制", "cd": 4.2, "count": 5, "arc": 0.9, "bspeed": 300.0, "dmg_mult": 0.65 },
		{ "type": "charge", "name": "王者冲撞", "cd": 7.0, "warn": 0.5, "duration": 0.45, "speed_mult": 6.0 },
	] },
	"boss_spiral": { "name": "深渊织网者", "hp": 640000.0, "speed": 56.0, "dmg": 24.0, "xp": 60, "mat": 100, "r": 50.0, "color": "#7a3df0", "shape": "diamond", "ring_cd": 1.6, "ring_count": 6, "bspeed": 300.0, "spiral_mode": true, "death_skill": "double_ring", "status_resist": 0.55, "heart_chance": 1.0, "dmg_cap_pct": 0.005, "element": "metal", "skills": [
		{ "type": "aimed", "name": "织网锁定", "cd": 3.6, "count": 3, "interval": 0.16, "bspeed": 420.0, "dmg_mult": 0.7 },
		{ "type": "nova", "name": "深渊落雷", "cd": 5.5, "count": 2, "radius": 78.75, "warn": 0.8, "dmg_mult": 0.9 },
	] },
	"boss_summoner": { "name": "腐土孵化者", "hp": 560000.0, "speed": 48.0, "dmg": 22.0, "xp": 60, "mat": 100, "r": 54.0, "color": "#3d8a3d", "shape": "square", "ring_cd": 3.0, "ring_count": 10, "bspeed": 240.0, "summon_cd": 4.5, "summon_type": "swarm", "summon_count": 6, "death_skill": "miasma", "status_resist": 0.55, "heart_chance": 1.0, "dmg_cap_pct": 0.005, "element": "wood", "skills": [
		{ "type": "nova", "name": "腐土毒沼", "cd": 6.0, "count": 3, "radius": 60.0, "warn": 1.0, "dmg_mult": 0.7, "spread_radius": 200.0 },
		{ "type": "fan", "name": "腐蚀喷吐", "cd": 4.5, "count": 7, "arc": 1.2, "bspeed": 280.0, "dmg_mult": 0.6 },
	] },
	"boss_phoenix": { "name": "焚天凤凰", "hp": 720000.0, "speed": 78.0, "dmg": 26.0, "xp": 60, "mat": 100, "r": 52.0, "color": "#ff5e3a", "shape": "diamond", "ring_cd": 1.8, "ring_count": 12, "bspeed": 320.0, "death_skill": "rebirth", "status_resist": 0.55, "heart_chance": 1.0, "dmg_cap_pct": 0.005, "element": "fire", "skills": [
		{ "type": "charge", "name": "烈焰俯冲", "cd": 5.0, "warn": 0.45, "duration": 0.5, "speed_mult": 7.0 },
		{ "type": "nova", "name": "天火坠落", "cd": 4.5, "count": 3, "radius": 63.75, "warn": 0.95, "dmg_mult": 0.7, "spread_radius": 210.0 },
	] },
	"boss_leviathan": { "name": "沧溟蛟皇", "hp": 800000.0, "speed": 60.0, "dmg": 24.0, "xp": 60, "mat": 100, "r": 54.0, "color": "#5aa8d8", "shape": "circle", "ring_cd": 2.0, "ring_count": 18, "bspeed": 260.0, "summon_cd": 8.0, "summon_type": "water_nymph", "summon_count": 3, "death_skill": "double_ring", "status_resist": 0.55, "heart_chance": 1.0, "dmg_cap_pct": 0.005, "element": "water", "skills": [
		{ "type": "aimed", "name": "寒水连狙", "cd": 3.2, "count": 4, "interval": 0.13, "bspeed": 440.0, "dmg_mult": 0.65 },
		{ "type": "fan", "name": "冰潮扇", "cd": 4.0, "count": 7, "arc": 1.0, "bspeed": 300.0, "dmg_mult": 0.6 },
	] },
	"boss_titan": { "name": "玄武岩王", "hp": 900000.0, "speed": 42.0, "dmg": 32.0, "xp": 60, "mat": 100, "r": 58.0, "color": "#c8a030", "shape": "square", "ring_cd": 2.4, "ring_count": 10, "bspeed": 220.0, "death_skill": "shockwave", "status_resist": 0.70, "heart_chance": 1.0, "dmg_cap_pct": 0.004, "element": "earth", "skills": [
		{ "type": "charge", "name": "山崩冲撞", "cd": 8.0, "warn": 0.7, "duration": 0.55, "speed_mult": 5.0 },
		{ "type": "nova", "name": "落石", "cd": 5.0, "count": 2, "radius": 97.5, "warn": 0.9, "dmg_mult": 1.0 },
	] },
}

## BOSS 轮换池：标准第 20 波 / 无尽每 10 波，按种子随机轮换（每日挑战全服同 BOSS）
const BOSS_POOL := ["boss", "boss_spiral", "boss_summoner", "boss_phoenix", "boss_leviathan", "boss_titan"]

## BOSS id → 中文称号（HUD/横幅展示用）
const BOSS_TITLES := {
	"boss": "土豆之王 · 弹幕压制",
	"boss_spiral": "深渊织网者 · 螺旋封锁",
	"boss_summoner": "腐土孵化者 · 群海战术",
	"boss_phoenix": "焚天凤凰 · 烈焰风暴",
	"boss_leviathan": "沧溟蛟皇 · 寒潮召唤",
	"boss_titan": "玄武岩王 · 山岳镇压",
}

## 高难度精英替换池（难度 elite_chance 触发时从中抽取，W4+ 生效）
const ELITE_POOL := [
	{ "item": "guard", "w": 0.22 }, { "item": "wizard", "w": 0.22 },
	{ "item": "shadow", "w": 0.18 }, { "item": "bomber", "w": 0.14 },
	{ "item": "ice_witch", "w": 0.14 }, { "item": "stone_titan", "w": 0.10 },
]

## 事件波：每 4 波触发一次（波 3/7/11/15…，跳过 BOSS 波），从 3 种事件随机
## - treasure 宝箱守卫波：全场只刷宝箱守卫，清完必掉 1 件高品阶道具（紫/金/红加权）
## - hunt 精英狩猎波：少量精英怪 + 常规怪，波末存活精英数越少奖励材料越多
## - meteor 流星雨波：常规怪 + 天降流星（预警圈 0.9s 后砸落 AOE），考验走位
const EVENT_WAVE_INTERVAL := 4
const EVENT_WAVE_FIRST := 3
const METEOR_WARN_TIME := 0.9
const METEOR_DAMAGE := 22.0
const METEOR_RADIUS := 78.0
const METEOR_FALL_CD := 1.5

static func is_event_wave(w: int) -> bool:
	if w < EVENT_WAVE_FIRST or Config.is_boss_wave(w):
		return false
	return (w - EVENT_WAVE_FIRST) % EVENT_WAVE_INTERVAL == 0

## ---- 每日挑战（全服同局）：当日日期决定种子/角色/难度/BOSS ----
## 日期串（如 "2026-09-08"）→ 稳定哈希（FNV-1a 32 位）
static func daily_hash(date_str: String) -> int:
	var h := 0x811C9DC5
	for i in date_str.length():
		h = ((h ^ (date_str.unicode_at(i) & 0xFF)) * 0x01000193) & 0xFFFFFFFF
	return h

## 每日挑战的角色池。
##
## ⚠️ **当前已整体冻结**（沧溟 2026-09-14 拍板「先暂时冻结每日挑战」）：
## 入口在 `main_menu.gd` 侧隐藏，`daily_setup()` 仍在，但**不会被玩家触发**。
##
## 冒烟对该池的断言是「**池内条目必须都已注册**」（防悬空 id），
## 而不是「池子必须等于注册数」—— 后者会在内容收缩时必然误红。
##
## ⚠️ 2026-09-17（第 7 轮）：本池原本保留**全量旧池**（12 角色，含 11 个冻结角色），
##    理由是「解冻时直接恢复原样」。但官方工坊包 `brotato_lite_core` 已按用户要求
##    移出 `game/mods/` → 那 11 个 id **不再注册**，池子立刻变成 11 条悬空 id，
##    `_check_phase3_content` 的守卫断言直接红。
##    → 按本常量自己的注释「解冻前须与内置角色池对齐」**对齐到内置 6 角色**：
##      池子与 `_register_builtin()` 一字不差，解冻后 `daily_setup` 立刻可用；
##      要恢复旧角色，必须先把工坊包移回 `game/mods/`（同一条链，不能只改这里）。
const DAILY_CHARACTERS := ["potato", "metal_adept", "wood_adept", "water_adept",
	"fire_adept", "earth_adept"]

## 今日挑战配置：{seed, character_id, difficulty_id, boss_id}（全服一致）
static func daily_setup(date_str: String) -> Dictionary:
	var h := daily_hash(date_str)
	var chars: Array = DAILY_CHARACTERS
	var diffs := ["normal", "hard", "nightmare"]
	var pool: Array = BOSS_POOL.duplicate()
	return {
		"seed": h,
		"character_id": chars[h % chars.size()],
		"difficulty_id": diffs[(h >> 5) % diffs.size()],
		"boss_id": String(pool[(h >> 11) % pool.size()]),
	}

# ============================================================
# 解锁系统（内容逐层解锁）：角色 / 武器的开局选择门槛。
# 条件由 CodexData 的「累计统计」实时推导 —— 解锁即永久，无需单独持久化解锁态。
# 未列入下表的内容默认已解锁（含开局基础内容与创意工坊 mod）。
# stat 键必须落在 UNLOCK_STAT_KEYS 白名单内（对应 CodexData 的累计计数器）。
# ============================================================
const CHARACTER_UNLOCKS := {
	# ---- 五行修士（§3.2.5 第 5 轮定稿：内置只启用 6 个角色） ----
	# 白板 potato 与五修士**刻意全部默认解锁**：五行体系的第一课是「元素对抗」，
	# 若把五个元素修士锁在解锁条件后面，新玩家开局只能看到白板，
	# 「选角色 = 选元素」这条核心决策就被藏起来了。
	# → 因此本表**当前为空**（空表 = 全部默认解锁，见 unlock_entry 的注释）。
	#
	# ⚠️ 被冻结的 11 个角色（berserker/ranger/farmer/vampire/guardian/pyromancer/
	#    druid/swordmaster/tidecaller/gunner/warlord）的解锁条目已随之移入
	#    `game/mods/brotato_lite_core/`（作为 mod 内容，默认解锁）。
	#    解冻时把它们搬回来即可，条件原文见 git 历史与 S2 迁移前的本表。
}

const WEAPON_UNLOCKS := {
	# 同上：内置 5 把五行武器**全部默认解锁**（开局池 = 这 5 把，见 LOADOUT_WEAPONS）。
	# 原来锁 thunder_gong / blight_bow 的两条也一并解除 —— 开局池必须完整可选，
	# 否则向导第 2 步会出现「5 个位置只有 3 个能点」的破体验。
	# 其余 11 条指向的内容已迁入工坊包，随之失效。
}

## 解锁条件的统计键白名单：必须对应到 CodexData 的累计计数器（冒烟测试据此校验）
const UNLOCK_STAT_KEYS := ["kills", "best_wave", "boss_kills", "victories",
	"status_triggers", "reactions", "runs"]

## 取某内容的解锁条目（空字典 = 未锁定，默认已解锁）
static func unlock_entry(kind: String, id: String) -> Dictionary:
	var table: Dictionary = CHARACTER_UNLOCKS if kind == "character" else WEAPON_UNLOCKS
	return table.get(id, {})

## 升级池（**非金红可重复叠加**；金 mythic / 红 legendary = 「唯一件」，本局每张最多 1 次，
## 见 is_unique_rarity —— 闸门在 level_up_ui / shop_ui / player.apply_upgrade 三处；
## effects 键 = player.stats 键，创意工坊数据驱动；
## 特例：heal_flat = 最大生命+立即回复同值，heal_pct = 立即回复最大生命百分比）
const UPGRADES := [
	{ "id": "hp", "ico": "❤", "name": "强壮", "desc": "最大生命 +18，并立即回复 18", "rarity": "common", "effects": { "heal_flat": 18.0 } },
	{ "id": "dmg", "ico": "⚔", "name": "蛮力", "desc": "伤害 +10%", "rarity": "common", "effects": { "dmg_mult": 0.10 } },
	{ "id": "as", "ico": "⚡", "name": "急速", "desc": "攻击速度 +4%", "rarity": "common", "effects": { "as_mult": 0.04 } },
	{ "id": "spd", "ico": "👟", "name": "飞毛腿", "desc": "移动速度 +8%", "rarity": "common", "effects": { "speed_mult": 0.08 } },
	{ "id": "crit", "ico": "🎯", "name": "锐利", "desc": "暴击率 +3%", "rarity": "rare", "effects": { "crit_ch": 0.03 } },
	{ "id": "critd", "ico": "✦", "name": "狂暴", "desc": "暴击伤害 +30%", "rarity": "rare", "effects": { "crit_mult": 0.30 } },
	{ "id": "armor", "ico": "🛡", "name": "坚甲", "desc": "护甲 +2（递减减伤）", "rarity": "rare", "effects": { "armor": 2.0 } },
	{ "id": "dodge", "ico": "🍃", "name": "灵巧", "desc": "闪避率 +6%", "rarity": "rare", "effects": { "dodge": 0.06 } },
	{ "id": "magnet", "ico": "🧲", "name": "磁力", "desc": "拾取范围 +35", "rarity": "common", "effects": { "pickup_range": 35.0 } },
	{ "id": "regen", "ico": "✚", "name": "再生", "desc": "生命回复 +0.6 / 秒", "rarity": "rare", "effects": { "regen": 0.6 } },
	{ "id": "harv", "ico": "🌾", "name": "丰收", "desc": "材料获取 +18%", "rarity": "rare", "effects": { "harvesting": 0.18 } },
	{ "id": "heal", "ico": "🥔", "name": "急救土豆", "desc": "立即回复 35% 最大生命", "rarity": "epic", "effects": { "heal_pct": 0.35 } },
	{ "id": "precision", "ico": "🔭", "name": "精密校准", "desc": "暴击率 +6%", "rarity": "mythic", "effects": { "crit_ch": 0.06 } },
	{ "id": "greed", "ico": "💰", "name": "贪婪之心", "desc": "材料获取 +50%", "rarity": "mythic", "effects": { "harvesting": 0.50 } },
	{ "id": "frenzy", "ico": "🎶", "name": "狂热节拍", "desc": "攻击速度 +9%", "rarity": "mythic", "effects": { "as_mult": 0.09 } },
	{ "id": "berserk", "ico": "💀", "name": "血之狂怒", "desc": "伤害 +35%", "rarity": "legendary", "effects": { "dmg_mult": 0.35 } },
	{ "id": "overdrive", "ico": "🔥", "name": "极限超频", "desc": "攻速 +12.5%，暴击伤害 +40%", "rarity": "legendary", "effects": { "as_mult": 0.125, "crit_mult": 0.40 } },
	{ "id": "titanheart", "ico": "🫀", "name": "泰坦心脏", "desc": "最大生命 +60（并回复 60），护甲 +3", "rarity": "legendary", "effects": { "heal_flat": 60.0, "armor": 3.0 } },
	# ---- 状态效果升级（异常流构筑） ----
	{ "id": "pyromancy", "ico": "🔥", "name": "纵火", "desc": "状态伤害 +25%", "rarity": "rare", "effects": { "status_dmg_mult": 0.25 } },
	{ "id": "lingering", "ico": "⏳", "name": "延烧", "desc": "异常持续时间 +30%", "rarity": "epic", "effects": { "status_dur_mult": 0.30 } },
	{ "id": "hex", "ico": "🕯", "name": "咒术", "desc": "异常命中率 +10%", "rarity": "epic", "effects": { "status_chance": 0.10 } },
	# ---- 武器向升级：只强化特定武器形态，属于「构筑向」而非泛用强化 ----
	# （这些键在角色特性里先出现，此处把它们开放给升级池，让构筑有成长路径）
	{ "id": "edge", "ico": "🗡", "name": "开刃", "desc": "斩击范围 +11%（近战武器）", "rarity": "rare", "effects": { "melee_range_bonus": 0.11 } },
	{ "id": "barrel", "ico": "🏹", "name": "加长枪管", "desc": "弹丸射程 +20%（投射武器）；代价：攻速 -5%", "rarity": "rare", "effects": { "bullet_range_bonus": 0.20, "as_mult": -0.05 } },
	{ "id": "velocity", "ico": "💨", "name": "高初速", "desc": "子弹速度 +20%，命中更跟手；代价：伤害 -5%", "rarity": "rare", "effects": { "bullet_speed_bonus": 0.20, "dmg_mult": -0.05 } },
	{ "id": "warhead", "ico": "💥", "name": "高爆装药", "desc": "爆炸范围 +20%（溅射武器：火箭筒 / 冰霜新星 / 震雷法锣…）；代价：伤害 -5%", "rarity": "rare", "effects": { "aoe_radius_bonus": 0.20, "dmg_mult": -0.05 } },
	# ---- 角色向升级：effects 刻意集中在**单一标签族**（近战范围 / 弹速射程 / 异常 / 残血 / 经济），
	# 于是对对应角色的亲和倍率天然高达 ×2.7~3.55，对无关角色接近不出现 ——
	# 不用新增「专属」机制，靠既有的 affinity 推导就形成了角色向内容池
	{ "id": "swordmanual", "ico": "📜", "name": "剑冢图谱", "desc": "斩击范围 +13%，暴击伤害 +60（近战构筑）", "rarity": "mythic", "effects": { "melee_range_bonus": 0.13, "crit_mult": 0.60 } },
	{ "id": "ballistic", "ico": "📐", "name": "弹道校准", "desc": "子弹速度 +25%，弹丸射程 +18%（投射构筑）", "rarity": "epic", "effects": { "bullet_speed_bonus": 0.25, "bullet_range_bonus": 0.18 } },
	{ "id": "burningheart", "ico": "🔥", "name": "灼心诀", "desc": "命中时 12% 概率点燃，状态伤害 +35%", "rarity": "epic", "effects": { "on_hit_burn": 0.12, "status_dmg_mult": 0.35 } },
	{ "id": "frostmantra", "ico": "🧊", "name": "玄冰诀", "desc": "命中时 10% 概率冻结，异常持续 +45%；重复获取可叠加（概率相加）", "rarity": "epic", "effects": { "on_hit_freeze": 0.10, "status_dur_mult": 0.45 } },
	{ "id": "bloodoath", "ico": "🩸", "name": "血战令", "desc": "生命越低伤害越高，濒死时最高 +30%", "rarity": "epic", "effects": { "low_hp_dmg_bonus": 0.30 } },
	{ "id": "harvestrite", "ico": "🌾", "name": "丰饶祭", "desc": "材料获取 +45%，拾取范围 +70", "rarity": "epic", "effects": { "harvesting": 0.45, "pickup_range": 70.0 } },
	# ---- S5 新增：五行之悟 ×5（§7.4；对应元素同化度 +12%，走通用 apply 管线）----
	{ "id": "wu_metal", "ico": "🜚", "name": "金之悟", "desc": "金同化度 +12%", "rarity": "rare", "effects": { "assim_metal": 0.12 } },
	{ "id": "wu_wood", "ico": "🌱", "name": "木之悟", "desc": "木同化度 +12%", "rarity": "rare", "effects": { "assim_wood": 0.12 } },
	{ "id": "wu_water", "ico": "💦", "name": "水之悟", "desc": "水同化度 +12%", "rarity": "rare", "effects": { "assim_water": 0.12 } },
	{ "id": "wu_fire", "ico": "🔆", "name": "火之悟", "desc": "火同化度 +12%", "rarity": "rare", "effects": { "assim_fire": 0.12 } },
	{ "id": "wu_earth", "ico": "⛰", "name": "土之悟", "desc": "土同化度 +12%", "rarity": "rare", "effects": { "assim_earth": 0.12 } },
]

## 商店道具（被动 = 永久属性；**金 mythic / 红 legendary = 「唯一件」，本局每种最多 1 件**，
## 与法宝 artifacts_owned 同款语义，判定见 is_unique_rarity / unique_pool_ok；
## effects 键 = player.stats 键，创意工坊数据驱动；
## i-hp 只加上限不立即回血，与原型一致）
const ITEMS := [
	{ "id": "i-hp", "ico": "🍅", "name": "番茄", "desc": "最大生命 +28", "price": 30, "rarity": "common", "effects": { "max_hp": 28.0 } },
	{ "id": "i-dmg", "ico": "🧨", "name": "弹药袋", "desc": "伤害 +14%", "price": 38, "rarity": "rare", "effects": { "dmg_mult": 0.14 } },
	{ "id": "i-as", "ico": "🔋", "name": "弹簧", "desc": "攻速 +6%", "price": 38, "rarity": "rare", "effects": { "as_mult": 0.06 } },
	{ "id": "i-spd", "ico": "👟", "name": "运动鞋", "desc": "移速 +10%", "price": 26, "rarity": "common", "effects": { "speed_mult": 0.10 } },
	{ "id": "i-crit", "ico": "🔭", "name": "瞄准镜", "desc": "暴击率 +5%", "price": 42, "rarity": "epic", "effects": { "crit_ch": 0.05 } },
	{ "id": "i-arm", "ico": "⚙", "name": "钢板", "desc": "护甲 +3", "price": 36, "rarity": "rare", "effects": { "armor": 3.0 } },
	{ "id": "i-dod", "ico": "🧥", "name": "斗篷", "desc": "闪避 +8%", "price": 32, "rarity": "rare", "effects": { "dodge": 0.08 } },
	{ "id": "i-mag", "ico": "🧲", "name": "大磁铁", "desc": "拾取范围 +55", "price": 22, "rarity": "common", "effects": { "pickup_range": 55.0 } },
	{ "id": "i-reg", "ico": "💊", "name": "再生器", "desc": "生命回复 +1.0 / 秒", "price": 42, "rarity": "epic", "effects": { "regen": 1.0 } },
	{ "id": "i-harv", "ico": "💰", "name": "金币袋", "desc": "材料获取 +25%；代价：伤害 -6%", "price": 32, "rarity": "rare", "effects": { "harvesting": 0.25, "dmg_mult": -0.06 } },
	{ "id": "i-ls", "ico": "🩸", "name": "血蛭", "desc": "每击杀 1 个敌人回复 1 点生命（可叠加）", "price": 48, "rarity": "epic", "effects": { "lifesteal": 1.0 } },
	# ---- 状态效果道具（on_hit_* = 命中时施加概率；status_dmg_mult = 持续伤害加成） ----
	{ "id": "i-ember", "ico": "🔥", "name": "余烬", "desc": "命中时 20% 概率点燃（伤害随攻击力）；代价：伤害 -4%", "price": 44, "rarity": "rare", "effects": { "on_hit_burn": 0.20, "dmg_mult": -0.04 } },
	{ "id": "i-venom", "ico": "🧪", "name": "毒囊", "desc": "命中时 20% 概率使目标中毒；代价：伤害 -4%", "price": 44, "rarity": "rare", "effects": { "on_hit_poison": 0.20, "dmg_mult": -0.04 } },
	{ "id": "i-hemo", "ico": "🩸", "name": "放血针", "desc": "命中时 25% 概率造成流血；代价：护甲 -1", "price": 40, "rarity": "rare", "effects": { "on_hit_bleed": 0.25, "armor": -1.0 } },
	{ "id": "i-frost", "ico": "❄", "name": "霜核", "desc": "命中时 12% 概率冰冻目标；**重复购买概率相加**（买 2 件 = 24%）", "price": 58, "rarity": "epic", "effects": { "on_hit_freeze": 0.12 } },
	{ "id": "i-tar", "ico": "🕸", "name": "沥青网", "desc": "命中时 18% 概率减速目标", "price": 42, "rarity": "rare", "effects": { "on_hit_slow": 0.18 } },
	{ "id": "i-thunder", "ico": "🌩", "name": "雷击石", "desc": "命中时 8% 概率眩晕目标", "price": 66, "rarity": "epic", "effects": { "on_hit_stun": 0.08 } },
	{ "id": "i-plague", "ico": "☠", "name": "瘟疫之心", "desc": "中毒伤害 +60%，中毒目标死亡时传染", "price": 175, "rarity": "mythic", "effects": { "status_dmg_mult": 0.60, "status_spread": 1.0 } },
	{ "id": "i-pyro", "ico": "🌋", "name": "熔火核心", "desc": "状态伤害 +35%，异常持续时间 +25%", "price": 195, "rarity": "mythic", "effects": { "status_dmg_mult": 0.35, "status_dur_mult": 0.25 } },
	{ "id": "i-conductor", "ico": "⚡", "name": "异常导体", "desc": "异常命中率 +15%，状态伤害 +20%", "price": 230, "rarity": "legendary", "effects": { "status_chance": 0.15, "status_dmg_mult": 0.20 } },
	{ "id": "i-goldcore", "ico": "✨", "name": "黄金核心", "desc": "伤害 +25%，攻速 +7.5%", "price": 200, "rarity": "mythic", "effects": { "dmg_mult": 0.25, "as_mult": 0.075 } },
	{ "id": "i-fortress", "ico": "🏰", "name": "堡垒之心", "desc": "护甲 +6，最大生命 +45", "price": 185, "rarity": "mythic", "effects": { "armor": 6.0, "max_hp": 45.0 } },
	{ "id": "i-fortune", "ico": "🤑", "name": "财神金蟾", "desc": "材料获取 +80%，拾取范围 +80", "price": 170, "rarity": "mythic", "effects": { "harvesting": 0.80, "pickup_range": 80.0 } },
	{ "id": "i-bladesoul", "ico": "🗡", "name": "剑圣之魂", "desc": "暴击率 +7.5%，暴击伤害 +80%", "price": 210, "rarity": "mythic", "effects": { "crit_ch": 0.075, "crit_mult": 0.80 } },
	{ "id": "i-titan", "ico": "🏆", "name": "泰坦之力", "desc": "伤害 +45%，最大生命 +30", "price": 260, "rarity": "legendary", "effects": { "dmg_mult": 0.45, "max_hp": 30.0 } },
	{ "id": "i-gale", "ico": "🌪", "name": "风神羽靴", "desc": "移速 +35%，攻速 +15%，闪避 +10%", "price": 250, "rarity": "legendary", "effects": { "speed_mult": 0.35, "as_mult": 0.15, "dodge": 0.10 } },
	{ "id": "i-sanguine", "ico": "🧛", "name": "血族圣冠", "desc": "击杀回血 +3，生命回复 +2 / 秒", "price": 280, "rarity": "legendary", "effects": { "lifesteal": 3.0, "regen": 2.0 } },
	{ "id": "i-crown", "ico": "👑", "name": "王者桂冠", "desc": "伤害 +15%，攻速 +7.5%，暴击 +4%，暴伤 +50%", "price": 300, "rarity": "legendary", "effects": { "dmg_mult": 0.15, "as_mult": 0.075, "crit_ch": 0.04, "crit_mult": 0.50 } },
	# ---- Phase 3 内容扩充（8 件：低阶补位 3 + 带代价的中阶取舍 3 + 高阶 2） ----
	{ "id": "i-warden", "ico": "🛡", "name": "守望徽章", "desc": "护甲 +2，闪避 +4%", "price": 30, "rarity": "common", "effects": { "armor": 2.0, "dodge": 0.04 } },
	{ "id": "i-hunter", "ico": "📕", "name": "猎人手记", "desc": "暴击率 +3.5%，移速 +5%", "price": 28, "rarity": "common", "effects": { "crit_ch": 0.035, "speed_mult": 0.05 } },
	{ "id": "i-lodestone", "ico": "🧿", "name": "磁极核心", "desc": "拾取范围 +85，材料获取 +10%", "price": 32, "rarity": "common", "effects": { "pickup_range": 85.0, "harvesting": 0.10 } },
	{ "id": "i-thorn", "ico": "🌵", "name": "荆棘重铠", "desc": "生命 +45，护甲 +3；代价：移速 -5%", "price": 44, "rarity": "rare", "effects": { "max_hp": 45.0, "armor": 3.0, "speed_mult": -0.05 } },
	{ "id": "i-feather", "ico": "🪶", "name": "轻羽披风", "desc": "移速 +18%，闪避 +5%；代价：护甲 -2", "price": 40, "rarity": "rare", "effects": { "speed_mult": 0.18, "dodge": 0.05, "armor": -2.0 } },
	{ "id": "i-focus", "ico": "🔮", "name": "凝神宝珠", "desc": "攻速 +10%；代价：伤害 -8%", "price": 46, "rarity": "rare", "effects": { "as_mult": 0.10, "dmg_mult": -0.08 } },
	{ "id": "i-plaguevial", "ico": "⚗", "name": "疫病瓶", "desc": "命中时 25% 概率使目标中毒，状态伤害 +25%", "price": 72, "rarity": "epic", "effects": { "on_hit_poison": 0.25, "status_dmg_mult": 0.25 } },
	{ "id": "i-sunstone", "ico": "☀", "name": "日曜石", "desc": "生命回复 +1.6 / 秒，最大生命 +30", "price": 68, "rarity": "epic", "effects": { "regen": 1.6, "max_hp": 30.0 } },
	# ---- 武器向道具（Phase 3.5）：把「武器形态强化」做成可购买的构筑件 ----
	# 与泛用道具不同，这些只对特定武器形态生效 —— 买之前先想清楚自己在玩什么
	{ "id": "i-whetstone", "ico": "🪨", "name": "磨刀石", "desc": "斩击范围 +21%：近战刀光挥得更远，太刀/长剑尤其明显", "price": 58, "rarity": "mythic", "effects": { "melee_range_bonus": 0.21 } },
	{ "id": "i-longbarrel", "ico": "🔩", "name": "铳匠长管", "desc": "弹丸射程 +35%：火焰喷射距离、弹药飞行距离同步拉长", "price": 62, "rarity": "epic", "effects": { "bullet_range_bonus": 0.35 } },
	# ---- 喷射散布角通道（第 11 轮新增）：喷嘴类道具 ----
	# 用户反馈喷火枪「加不动距离、容易被金剑替代」。查证：射程通道本来就有
	# （`bullet_range_bonus`），真正的空白是 **`spread`（扇形随机散布角）零道具消费** ——
	# 火焰锥的「胖瘦」此前完全没有构筑维度。这两件把它补上，一收一放：
	#   · 高压喷嘴：再加 25% 射程，同时把锥体**收窄 40%** → 单点更集中、更像一束火矛
	#   · 多孔喷嘴：锥体**扩散 60%**（覆盖面更广、更容易同时撩到多只），代价是伤害 -10%
	# ⚠️ `proj_spread_mult` 是**有符号**的（负 = 收窄），与其余武器加成通道不同。
	# ⚠️ 品质口径沿用「阈值制副作用」：`i-multihole` 是 rare 且单条 +60% → 必须带代价；
	#    `i-highpressure` 是 epic，其内部取舍（覆盖角变窄）已写在 desc 里，不另加代价。
	{ "id": "i-highpressure", "ico": "🔻", "name": "高压喷嘴", "desc": "喷射距离 +25%、火焰锥收窄 40%（喷火枪类）：单点更集中；代价：同时覆盖的角度变窄", "price": 64, "rarity": "epic", "effects": { "bullet_range_bonus": 0.25, "proj_spread_mult": -0.40 } },
	{ "id": "i-multihole", "ico": "🔱", "name": "多孔喷嘴", "desc": "火焰锥扩散 60%（喷火枪类）：覆盖面更广、更易同时灼烧多只；代价：伤害 -10%", "price": 46, "rarity": "rare", "effects": { "proj_spread_mult": 0.60, "dmg_mult": -0.10 } },
	# 投掷类专属通道（第 8 轮）：与弹幕类的 `bullet_speed_bonus` / `bullet_range_bonus`
	# 互不串味（见 `player._weapon_runtime_cfg` 的 `proj_kind` 分流）。
	# 之前土炸弹被弹速类道具按弹幕公式放大，射程能被拉到 731px —— 这两件把那份收益收回到「主动选投掷构筑」才能拿到。
	{ "id": "i-fuse", "ico": "🧨", "name": "火绳引信", "desc": "投掷物飞行速度 +20%（土质炸弹 / 厚土雷）；代价：攻速 -5%", "price": 46, "rarity": "rare", "effects": { "throw_speed_bonus": 0.20, "as_mult": -0.05 } },
	{ "id": "i-powder", "ico": "⚗", "name": "重装药罐", "desc": "投掷物飞行距离 +20%（土质炸弹 / 厚土雷）", "price": 64, "rarity": "epic", "effects": { "throw_range_bonus": 0.20 } },
	# ⚠️ 高爆装荗（`warhead`）/ 霜爆核心（`i-frostcore`）等 `aoe_radius_bonus` 道具**因果不变**：它管「爆多大」，与「飞多远」正交，两类投射物都吃。
	{ "id": "i-frostcore", "ico": "🧊", "name": "霜爆核心", "desc": "爆炸范围 +42%：冰冻、毒爆、火箭的覆盖面大幅提升", "price": 66, "rarity": "epic", "effects": { "aoe_radius_bonus": 0.42 } },
	{ "id": "i-accelerator", "ico": "⚙", "name": "高速膛线", "desc": "子弹速度 +38%，弹道更直更难被走位躲开；代价：伤害 -6%", "price": 48, "rarity": "rare", "effects": { "bullet_speed_bonus": 0.38, "dmg_mult": -0.06 } },
	{ "id": "i-venomsac", "ico": "☣", "name": "毒爆囊", "desc": "爆炸范围 +22%，异常持续时间 +20%；代价：伤害 -5%", "price": 44, "rarity": "rare", "effects": { "aoe_radius_bonus": 0.22, "status_dur_mult": 0.20, "dmg_mult": -0.05 } },
	# ---- 元素附魔向（Phase 3.6）：让**任意武器**都能挂上某种状态。
	# 与状态流 / 五行反应构筑天然关联，且因为用了 on_hit_* 键，
	# 会被 Config.entry_tags 自动打上对应元素标签 → 抽取时自动亲和（见 affinity_mult）
	{ "id": "i-emberdust", "ico": "🔥", "name": "火绒", "desc": "命中时 18% 概率点燃，状态伤害 +20%；代价：攻速 -5%", "price": 50, "rarity": "rare", "effects": { "on_hit_burn": 0.18, "status_dmg_mult": 0.20, "as_mult": -0.05 } },
	{ "id": "i-venomgland", "ico": "🐍", "name": "毒腺", "desc": "命中时 18% 概率使目标中毒，异常持续 +20%；代价：攻速 -5%", "price": 50, "rarity": "rare", "effects": { "on_hit_poison": 0.18, "status_dur_mult": 0.20, "as_mult": -0.05 } },
	{ "id": "i-bloodvial", "ico": "🩸", "name": "血瓶", "desc": "命中时 20% 概率造成流血，击杀回复 +1.5；代价：护甲 -1", "price": 52, "rarity": "rare", "effects": { "on_hit_bleed": 0.20, "lifesteal": 1.5, "armor": -1.0 } },
	{ "id": "i-frostshard", "ico": "❄", "name": "霜片", "desc": "命中时 12% 概率冻结目标，异常持续 +15%；重复购买概率相加", "price": 58, "rarity": "epic", "effects": { "on_hit_freeze": 0.12, "status_dur_mult": 0.15 } },
	{ "id": "i-thunderrod", "ico": "⚡", "name": "雷杵", "desc": "命中时 10% 概率眩晕目标，子弹速度 +15%", "price": 58, "rarity": "epic", "effects": { "on_hit_stun": 0.10, "bullet_speed_bonus": 0.15 } },
	# ---- 角色向道具：与元素附魔同一思路，但标签更集中（对对应角色的亲和倍率更高）----
	# 近战（太白剑客 / 无相武僧 / 百战军侯）/ 投射（游侠 / 弹雨枪手）/ 火（焚天祭司）/
	# 冰（沧海鲛人）/ 残血（狂战士 / 血族）/ 经济（收获者）各有 1 件
	{ "id": "i-swordcase", "ico": "🗡", "name": "剑匣", "desc": "斩击范围 +21%，暴击率 +3%", "price": 72, "rarity": "mythic", "effects": { "melee_range_bonus": 0.21, "crit_ch": 0.03 } },
	{ "id": "i-calibrator", "ico": "🎯", "name": "校准仪", "desc": "弹丸射程 +30%，子弹速度 +20%", "price": 68, "rarity": "epic", "effects": { "bullet_range_bonus": 0.30, "bullet_speed_bonus": 0.20 } },
	{ "id": "i-pyrotalisman", "ico": "🧧", "name": "焚天符", "desc": "命中时 16% 概率点燃，状态伤害 +40%", "price": 74, "rarity": "epic", "effects": { "on_hit_burn": 0.16, "status_dmg_mult": 0.40 } },
	{ "id": "i-frostmirror", "ico": "🪞", "name": "霜心镜", "desc": "命中时 14% 概率冻结，异常持续 +50%；重复购买概率相加", "price": 72, "rarity": "epic", "effects": { "on_hit_freeze": 0.14, "status_dur_mult": 0.50 } },
	{ "id": "i-ragecloak", "ico": "🧥", "name": "怒血披风", "desc": "濒死时最高 +28% 伤害，闪避 +5%；代价：护甲 -1", "price": 54, "rarity": "rare", "effects": { "low_hp_dmg_bonus": 0.28, "dodge": 0.05, "armor": -1.0 } },
	{ "id": "i-luckypouch", "ico": "👝", "name": "聚宝囊", "desc": "材料获取 +50%，拾取范围 +60；代价：伤害 -8%", "price": 48, "rarity": "rare", "effects": { "harvesting": 0.50, "pickup_range": 60.0, "dmg_mult": -0.08 } },
	# ---- 前期过渡道具（Phase 6 平衡）：common 低价小件，补开局与前 3 波的空窗 ----
	# 数值温和但覆盖移动 / 续航 / 元素三大前期需求，让新手开局也有明确的可选方向
	{ "id": "i-boots", "ico": "👢", "name": "旧皮靴", "desc": "移速 +6%，闪避 +3%", "price": 20, "rarity": "common", "effects": { "speed_mult": 0.06, "dodge": 0.03 } },
	{ "id": "i-bread", "ico": "🍞", "name": "行军干粮", "desc": "最大生命 +20，生命回复 +0.3/秒", "price": 24, "rarity": "common", "effects": { "max_hp": 20.0, "regen": 0.3 } },
	{ "id": "i-flint", "ico": "🪨", "name": "打火石", "desc": "命中时 10% 概率点燃（伤害随攻击力）", "price": 26, "rarity": "common", "effects": { "on_hit_burn": 0.10 } },
	# ---- 后期神品道具（Phase 6 平衡）：legendary 终极件，9 波后才有机会刷出 ----
	# 数值对标王者桂冠 / 泰坦之力，但定位更极致：一件撑起输出 / 一件撑起生存
	{ "id": "i-dragonsoul", "ico": "🐉", "name": "龙魂玉", "desc": "伤害 +50%，暴击伤害 +100%，攻速 +10%", "price": 300, "rarity": "legendary", "effects": { "dmg_mult": 0.50, "crit_mult": 1.00, "as_mult": 0.10 } },
	{ "id": "i-immortal", "ico": "🏮", "name": "不灭真元", "desc": "最大生命 +80，护甲 +8，生命回复 +2.5/秒，闪避 +10%", "price": 300, "rarity": "legendary", "effects": { "max_hp": 80.0, "armor": 8.0, "regen": 2.5, "dodge": 0.10 } },
	# ---- S5 新增：元素同化度道具（§6.2；effects 用 assim_<元素> 扁平键，走通用 apply 管线）----
	# 同化度双向：受击侧抵扣该元素伤害（有 cap，见 §7.2），输出侧加成该元素伤害（无 cap）。文案点明双向。
	{ "id": "i-assim-metal", "ico": "🪙", "name": "金髓", "desc": "金同化度 +15%：受到的金伤更低，用金打人更痛", "price": 48, "rarity": "rare", "effects": { "assim_metal": 0.15 } },
	{ "id": "i-assim-wood", "ico": "🌿", "name": "青木汁", "desc": "木同化度 +15%：受到的木伤更低，用木打人更痛", "price": 48, "rarity": "rare", "effects": { "assim_wood": 0.15 } },
	{ "id": "i-assim-water", "ico": "💧", "name": "玄水露", "desc": "水同化度 +15%：受到的水伤更低，用水打人更痛", "price": 48, "rarity": "rare", "effects": { "assim_water": 0.15 } },
	{ "id": "i-assim-fire", "ico": "🔥", "name": "离火髓", "desc": "火同化度 +15%：受到的火伤更低，用火打人更痛", "price": 48, "rarity": "rare", "effects": { "assim_fire": 0.15 } },
	{ "id": "i-assim-earth", "ico": "🪨", "name": "厚土丸", "desc": "土同化度 +15%：受到的土伤更低，用土打人更痛", "price": 48, "rarity": "rare", "effects": { "assim_earth": 0.15 } },
	# ---- 五行精华 ×5：对应元素同化度 +30%（epic）----
	{ "id": "i-assim-greater-metal", "ico": "💎", "name": "金精华", "desc": "金同化度 +30%：受到的金伤更低，用金打人更痛", "price": 96, "rarity": "epic", "effects": { "assim_metal": 0.30 } },
	{ "id": "i-assim-greater-wood", "ico": "💎", "name": "木精华", "desc": "木同化度 +30%：受到的木伤更低，用木打人更痛", "price": 96, "rarity": "epic", "effects": { "assim_wood": 0.30 } },
	{ "id": "i-assim-greater-water", "ico": "💎", "name": "水精华", "desc": "水同化度 +30%：受到的水伤更低，用水打人更痛", "price": 96, "rarity": "epic", "effects": { "assim_water": 0.30 } },
	{ "id": "i-assim-greater-fire", "ico": "💎", "name": "火精华", "desc": "火同化度 +30%：受到的火伤更低，用火打人更痛", "price": 96, "rarity": "epic", "effects": { "assim_fire": 0.30 } },
	{ "id": "i-assim-greater-earth", "ico": "💎", "name": "土精华", "desc": "土同化度 +30%：受到的土伤更低，用土打人更痛", "price": 96, "rarity": "epic", "effects": { "assim_earth": 0.30 } },
	# ---- 五行归一石：全元素同化度 +8%（mythic）----
	{ "id": "i-assim-all", "ico": "☯", "name": "五行归一石", "desc": "全元素同化度 +8%：受到的五元素伤害更低，用五元素打人更痛", "price": 180, "rarity": "mythic", "effects": { "assim_metal": 0.08, "assim_wood": 0.08, "assim_water": 0.08, "assim_fire": 0.08, "assim_earth": 0.08 } },
]

## 开局道具池：只开放前期过渡档（common/rare），高品阶道具局内逐步获得。
## 向导里会按「当前角色 + 武器」的构筑亲和排序，相关道具优先展示（见 main_menu）
# S5 收敛：开局道具白名单 = §6.1 的 29 件「与元素无关、只碰基础属性」道具。
# 元素附魔 / 状态 / 武器形态类（i-ember/i-venom/i-hemo/i-tar/i-frost/i-thunder/i-pyro/i-plague/…/
# i-ragecloak/i-flint 等）已从白名单剔除（§6.1「冻结的 29 件」）。
# ⚠️ 注：S4.5 删道具步后本常量当前无运行时消费方，仅作为「白名单真值」留存，供冒烟与未来复用。
const LOADOUT_ITEMS := ["i-hp", "i-bread", "i-dmg", "i-as", "i-focus", "i-spd", "i-boots", "i-feather",
	"i-crit", "i-hunter", "i-arm", "i-warden", "i-thorn", "i-dod", "i-mag", "i-lodestone",
	"i-harv", "i-luckypouch", "i-reg", "i-sunstone", "i-ls", "i-sanguine", "i-goldcore",
	"i-crown", "i-titan", "i-fortress", "i-gale", "i-immortal", "i-dragonsoul"]

## ============================================================
## 法宝（Phase 3）—— 触发式特效，区别于 ITEMS 的纯属性被动
## 每种限 1 件、无总上限；重复获得转化为 ARTIFACT_DUP_MATERIALS 材料
## 字段说明：
##   element  五行归属（ELEMENTS 之一），图鉴/商店分组与五行加成用
##   trigger  触发时机，必须是 ARTIFACT_TRIGGERS 之一
##   params   触发过滤条件：element / key（五行反应）/ status / hp_below
##   effect   动作载荷，键随 trigger 而变（见各条目行内注释）
## effect 载荷约定（ArtifactSystem 按存在的键分派）：
##   patch          改写五行反应效果本身：set 覆盖 / add 叠加合并。
##                  由 enemy.gd 在执行反应效果【之前】同步调用
##                  ArtifactSystem.patch_reaction_effect() 应用（信号太晚）
##   bonus_dmg_pct  对反应目标追加 = 玩家攻击力 × 该比例 的伤害
##   chance + apply_status + radius + stacks + duration
##                  概率对半径内敌人施加状态（凤凰翎/寒镜/潮汐珠）
##   stat + per_stack + stack_max + stack_reset
##                  叠层属性：stack_reset = "wave"（每波重置）/ "run"（仅局终重置）
##   dmg_mult       命中低血量目标时的伤害倍率（配合 params.hp_below）
##   heal_pct       按最大生命百分比回复（建木枝）
##   high_hp / high_hp_armor / low_hp / low_hp_dmg_reduce
##                  受击前修正：由 player.take_damage 同步查询（岩肤符）
##   add_stacks     概率给已施加的状态追加层数（缠藤结）
##   bonus_materials 概率额外获得材料（后土符）
## ============================================================
const ARTIFACT_TRIGGERS := ["on_reaction", "on_kill", "on_status_apply",
	"on_deal_hit", "on_take_hit", "on_wave_end"]

const ARTIFACT_ELITE_DROP_CHANCE := 0.12     # 精英怪（实例 elite 标志）击杀掉法宝概率
const ARTIFACT_BOSS_LEGENDARY_MULT := 3.0    # BOSS 掉落时 legendary 权重倍率
const ARTIFACT_SHOP_CHANCE := 0.25           # 商店每格刷出法宝（而非武器/道具/升级）概率
const ARTIFACT_DUP_MATERIALS := 60           # 重复获得已持有法宝的材料补偿

const ARTIFACTS := [
	# ---- 火 · 爆发 ----
	{ "id": "art_cinder_seal", "ico": "🔥", "name": "焚天印", "element": "fire", "rarity": "common",
		"desc": "火系五行反应触发时，对反应目标追加 40% 攻击力的额外伤害",
		"trigger": "on_reaction", "params": { "element": "fire" },
		"effect": { "bonus_dmg_pct": 0.40 }, "price": 110, "shop_weight": 1.0 },
	{ "id": "art_phoenix_plume", "ico": "🪶", "name": "凤凰翎", "element": "fire", "rarity": "epic",
		"desc": "击杀燃烧中的敌人时，12% 概率点燃周围 120 范围内敌人 1 层",
		"trigger": "on_kill", "params": { "status": "burn" },
		"effect": { "chance": 0.12, "radius": 120.0, "apply_status": "burn",
			"stacks": 1, "duration": 3.0 }, "price": 210, "shop_weight": 1.0 },
	{ "id": "art_molten_crucible", "ico": "🌋", "name": "熔金炉", "element": "fire", "rarity": "legendary",
		"desc": "「火克金」熔金强化：受伤 +50%→+80%，持续 3 秒→5 秒",
		"trigger": "on_reaction", "params": { "key": "fire+metal" },
		"effect": { "patch": { "set": { "armor_break": 0.8, "armor_break_duration": 5.0 } } },
		"price": 300, "shop_weight": 1.0 },
	# ---- 木 · 持续 / 回复 ----
	{ "id": "art_vine_knot", "ico": "🌿", "name": "缠藤结", "element": "wood", "rarity": "common",
		"desc": "施加中毒时 15% 概率额外 +1 层",
		"trigger": "on_status_apply", "params": { "status": "poison" },
		"effect": { "chance": 0.15, "add_stacks": 1 }, "price": 110, "shop_weight": 1.0 },
	{ "id": "art_spore_heart", "ico": "🍄", "name": "孢心", "element": "wood", "rarity": "epic",
		"desc": "「水生木」毒素扩散半径 100→180",
		"trigger": "on_reaction", "params": { "key": "water+wood" },
		"effect": { "patch": { "set": { "spread": { "poison": 180.0 } } } },
		"price": 210, "shop_weight": 1.0 },
	{ "id": "art_world_tree", "ico": "🌳", "name": "建木枝", "element": "wood", "rarity": "legendary",
		"desc": "每波结束回复 18% 最大生命",
		"trigger": "on_wave_end", "params": {},
		"effect": { "heal_pct": 0.18 }, "price": 300, "shop_weight": 1.0 },
	# ---- 金 · 暴击 / 处决 ----
	{ "id": "art_notch_blade", "ico": "⚔", "name": "断刃锋", "element": "metal", "rarity": "common",
		"desc": "击杀流血中的敌人 +2% 暴击率（本波内有效，最多 8 层）",
		"trigger": "on_kill", "params": { "status": "bleed" },
		"effect": { "stat": "crit_ch", "per_stack": 0.02, "stack_max": 8,
			"stack_reset": "wave" }, "price": 110, "shop_weight": 1.0 },
	{ "id": "art_executioner", "ico": "🪓", "name": "刑天斧", "element": "metal", "rarity": "epic",
		"desc": "对生命低于 25% 的敌人伤害 +45%",
		"trigger": "on_deal_hit", "params": { "hp_below": 0.25 },
		"effect": { "dmg_mult": 1.45 }, "price": 210, "shop_weight": 1.0 },
	{ "id": "art_soul_bell", "ico": "🔔", "name": "落魂钟", "element": "metal", "rarity": "legendary",
		"desc": "「金克木」败血症期间，目标受到的伤害额外 +35%",
		"trigger": "on_reaction", "params": { "key": "metal+wood" },
		"effect": { "patch": { "add": { "armor_break": 0.35, "armor_break_duration": 4.0 } } },
		"price": 300, "shop_weight": 1.0 },
	# ---- 水 · 控制 / 生存 ----
	{ "id": "art_frost_mirror", "ico": "❄", "name": "寒镜", "element": "water", "rarity": "common",
		"desc": "水系五行反应触发时，12% 概率冰冻周围 140 范围内敌人 0.8 秒",
		"trigger": "on_reaction", "params": { "element": "water" },
		"effect": { "chance": 0.12, "radius": 140.0, "apply_status": "freeze",
			"stacks": 1, "duration": 0.8 }, "price": 110, "shop_weight": 1.0 },
	{ "id": "art_tide_pearl", "ico": "🫧", "name": "潮汐珠", "element": "water", "rarity": "epic",
		"desc": "受到攻击时 18% 概率释放寒冰新星，减速周围 150 范围内敌人 2 秒",
		"trigger": "on_take_hit", "params": {},
		"effect": { "chance": 0.18, "radius": 150.0, "apply_status": "slow",
			"stacks": 1, "duration": 2.0 }, "price": 210, "shop_weight": 1.0 },
	{ "id": "art_leviathan_eye", "ico": "👁", "name": "蛟皇目", "element": "water", "rarity": "legendary",
		"desc": "「土克水」碎裂阈值 20%→32%，碎裂成功时回复 8 点生命",
		"trigger": "on_reaction", "params": { "key": "earth+water" },
		"effect": { "patch": { "set": { "execute_threshold": 0.32, "execute_heal": 8.0 } } },
		"price": 300, "shop_weight": 1.0 },
	# ---- 土 · 防御 / 资源 ----
	{ "id": "art_stone_skin", "ico": "🪨", "name": "岩肤符", "element": "earth", "rarity": "common",
		"desc": "生命高于 70% 时护甲 +4；低于 30% 时受到的伤害 -22%",
		"trigger": "on_take_hit", "params": {},
		"effect": { "high_hp": 0.70, "high_hp_armor": 4.0,
			"low_hp": 0.30, "low_hp_dmg_reduce": 0.22 }, "price": 110, "shop_weight": 1.0 },
	{ "id": "art_earth_tally", "ico": "🏵", "name": "后土符", "element": "earth", "rarity": "epic",
		"desc": "每次击杀 8% 概率额外获得 1 份材料",
		"trigger": "on_kill", "params": {},
		"effect": { "chance": 0.08, "bonus_materials": 1 }, "price": 210, "shop_weight": 1.0 },
	{ "id": "art_titan_core", "ico": "⛰", "name": "玄武核", "element": "earth", "rarity": "legendary",
		"desc": "土系五行反应触发时获得 1 层「磐石」（护甲 +1.5，永久，最多 12 层）",
		"trigger": "on_reaction", "params": { "element": "earth" },
		"effect": { "stat": "armor", "per_stack": 1.5, "stack_max": 12,
			"stack_reset": "run" }, "price": 300, "shop_weight": 1.0 },
	# ---- rare 档（Phase 3.6）：补齐 common(110) → epic(210) 的梯度。
	# 三件都走 on_status_apply，刻意挑现有法宝未覆盖的状态（燃烧 / 流血 / 减速）避免同质，
	# 并且因为 element 与 params.status 都会被 entry_tags 打标，
	# 玩状态流 / 对应元素流的构筑会明显更容易刷到它们
	{ "id": "art_pyre_brand", "ico": "🔥", "name": "燎原印", "element": "fire", "rarity": "rare",
		"desc": "施加燃烧时 30% 概率额外 +1 层",
		"trigger": "on_status_apply", "params": { "status": "burn" },
		"effect": { "chance": 0.30, "add_stacks": 1 }, "price": 160, "shop_weight": 1.0 },
	{ "id": "art_blood_fang", "ico": "🦷", "name": "饮血齿", "element": "metal", "rarity": "rare",
		"desc": "施加流血时 28% 概率额外 +1 层",
		"trigger": "on_status_apply", "params": { "status": "bleed" },
		"effect": { "chance": 0.28, "add_stacks": 1 }, "price": 160, "shop_weight": 1.0 },
	{ "id": "art_mist_veil", "ico": "🌫", "name": "雾隐纱", "element": "water", "rarity": "rare",
		"desc": "施加减速时 25% 概率额外 +1 层",
		"trigger": "on_status_apply", "params": { "status": "slow" },
		"effect": { "chance": 0.25, "add_stacks": 1 }, "price": 160, "shop_weight": 1.0 },
]

## ============================================================
## 江湖奇遇事件卡（Phase 4）—— 商店后的三选一叙事决策
## 触发：每波商店关闭后 30% 概率，每局上限随局随机 3~5 次
## 字段说明：
##   theme   所属地域主题（bamboo/temple/nether），与 Phase 5 地图主题呼应
##   rarity  稀有度，仅用于抽取权重与卡面配色（复用 RARITY_*）
##   choices 三选一，每项 { text, hint, effect }
## choice.effect 载荷约定（由 main._execute_event_effect 按存在的键分派）：
##   cost_materials  前置消耗；材料不足时该选项禁用（不出现在可选状态）
##   hp_pct_cost     前置消耗：按最大生命百分比扣血（可能致死，不致死时保底 1 点）
##   effects         属性增益字典，键 = player.stats 键（走 player.apply_effects）
##   grant_materials 直接获得材料
##   grant_item_rarity  随机获得该品阶道具（"epic"/"mythic"/"legendary"）
##   grant_weapon    随机获得一把武器（占用武器槽，槽满则转材料补偿）
##   grant_relic     随机获得一件未持有法宝
##   free_upgrade    免费升级次数（进 GameState.level_queue，下波开场补弹）
##   next_wave_elite 下一波开始时额外生成的精英数量（风险选项）
## ============================================================
const EVENT_CARD_CHANCE := 0.30        # 商店关闭后触发概率
const EVENT_CARD_MIN := 3              # 每局触发次数下限
const EVENT_CARD_MAX := 5              # 每局触发次数上限

const EVENT_CARDS := [
	{ "id": "ev_bamboo_spring", "title": "竹海清泉", "ico": "🎋", "theme": "bamboo", "rarity": "common",
		"desc": "林间一泓清泉，水面浮着薄薄竹叶。饮下它，能洗去一路风尘。",
		"choices": [
			{ "text": "掬水而饮", "hint": "回复 30% 生命", "effect": { "effects": { "heal_pct": 0.30 } } },
			{ "text": "涤荡经脉", "hint": "最大生命 +22", "effect": { "effects": { "max_hp": 22.0 } } },
			{ "text": "取竹而去", "hint": "获得 55 ◆", "effect": { "grant_materials": 55 } },
		] },
	{ "id": "ev_old_monk", "title": "古刹老僧", "ico": "🪷", "theme": "temple", "rarity": "common",
		"desc": "破败古刹只剩一位老僧，他不看你，只看着你身后的路。",
		"choices": [
			{ "text": "静听禅音", "hint": "免费升级一次", "effect": { "free_upgrade": 1 } },
			{ "text": "布施香火", "hint": "消耗 80 ◆ · 随机法宝", "effect": { "cost_materials": 80, "grant_relic": true } },
			{ "text": "合十而去", "hint": "回复 15% 生命 · 获得 40 ◆", "effect": { "effects": { "heal_pct": 0.15 }, "grant_materials": 40 } },
		] },
	{ "id": "ev_ghost_lantern", "title": "幽冥鬼灯", "ico": "🏮", "theme": "nether", "rarity": "rare",
		"desc": "一盏青灯悬在岔路口，灯芯是冷的，火是活的。",
		"choices": [
			{ "text": "续上灯油", "hint": "消耗 60 ◆ · 伤害 +18%", "effect": { "cost_materials": 60, "effects": { "dmg_mult": 0.18 } } },
			{ "text": "一口吹灭", "hint": "回复 40% 生命", "effect": { "effects": { "heal_pct": 0.40 } } },
			{ "text": "提灯照路", "hint": "暴击率 +4%", "effect": { "effects": { "crit_ch": 0.04 } } },
		] },
	{ "id": "ev_sword_grave", "title": "剑冢遗藏", "ico": "🗡", "theme": "blade", "rarity": "rare",
		"desc": "万剑插于荒丘，剑锋皆朝内。最中央那一柄，还在轻轻震颤。",
		"choices": [
			{ "text": "拔剑出鞘", "hint": "随机获得一把武器", "effect": { "grant_weapon": true } },
			{ "text": "只取剑穗", "hint": "暴击伤害 +35%", "effect": { "effects": { "crit_mult": 0.35 } } },
			{ "text": "以血祭剑", "hint": "消耗 15% 生命 · 伤害 +22%", "effect": { "hp_pct_cost": 0.15, "effects": { "dmg_mult": 0.22 } } },
		] },
	{ "id": "ev_fox_spirit", "title": "白狐讨封", "ico": "🦊", "theme": "bamboo", "rarity": "rare",
		"desc": "白狐立起身子，学人作揖：「你看我，像人还是像仙？」",
		"choices": [
			{ "text": "封它作仙", "hint": "收获率 +35%", "effect": { "effects": { "harvesting": 0.35 } } },
			{ "text": "讨要好处", "hint": "获得 110 ◆", "effect": { "grant_materials": 110 } },
			{ "text": "挥手驱赶", "hint": "伤害 +20% · 下波多 2 精英", "effect": { "effects": { "dmg_mult": 0.20 }, "next_wave_elite": 2 } },
		] },
	{ "id": "ev_iron_abbot", "title": "铁臂武僧", "ico": "🥋", "theme": "temple", "rarity": "epic",
		"desc": "武僧双臂如铁，在石阶上等你开口。他不出招，只等你先动。",
		"choices": [
			{ "text": "与他对练", "hint": "护甲 +4 · 最大生命 +15", "effect": { "effects": { "armor": 4.0, "max_hp": 15.0 } } },
			{ "text": "切磋招式", "hint": "攻速 +7.5% · 移速 +6%", "effect": { "effects": { "as_mult": 0.075, "speed_mult": 0.06 } } },
			{ "text": "供奉兵器", "hint": "消耗 140 ◆ · 随机史诗道具", "effect": { "cost_materials": 140, "grant_item_rarity": "epic" } },
		] },
	{ "id": "ev_nether_market", "title": "鬼市交易", "ico": "👺", "theme": "nether", "rarity": "epic",
		"desc": "鬼市只在子时开张，摊主不收钱，只收你身上还热着的东西。",
		"choices": [
			{ "text": "买下无名之物", "hint": "消耗 180 ◆ · 随机法宝", "effect": { "cost_materials": 180, "grant_relic": true } },
			{ "text": "典当一块血肉", "hint": "消耗 25% 生命 · 获得 240 ◆", "effect": { "hp_pct_cost": 0.25, "grant_materials": 240 } },
			{ "text": "转身离开", "hint": "拾取范围 +60", "effect": { "effects": { "pickup_range": 60.0 } } },
		] },
	{ "id": "ev_bamboo_spirit", "title": "竹灵赐福", "ico": "🌱", "theme": "bamboo", "rarity": "epic",
		"desc": "竹节裂开，走出一位只有半尺高的竹灵，捧着一枚沉甸甸的竹实。",
		"choices": [
			{ "text": "收下竹实", "hint": "回复 +1.6/秒 · 最大生命 +20", "effect": { "effects": { "regen": 1.6, "max_hp": 20.0 } } },
			{ "text": "求一段灵竹", "hint": "随机获得一把武器", "effect": { "grant_weapon": true } },
			{ "text": "求一场富贵", "hint": "获得 150 ◆", "effect": { "grant_materials": 150 } },
		] },
	{ "id": "ev_blood_moon", "title": "血月当空", "ico": "🌑", "theme": "nether", "rarity": "legendary",
		"desc": "月亮红了。你听见自己的心跳，比平时快了一倍。",
		"choices": [
			{ "text": "沐浴血光", "hint": "消耗 30% 生命 · 伤害 +45%", "effect": { "hp_pct_cost": 0.30, "effects": { "dmg_mult": 0.45 } } },
			{ "text": "持咒镇之", "hint": "护甲 +6 · 闪避 +6%", "effect": { "effects": { "armor": 6.0, "dodge": 0.06 } } },
			{ "text": "远遁避祸", "hint": "移速 +20%", "effect": { "effects": { "speed_mult": 0.20 } } },
		] },
	{ "id": "ev_dragon_gate", "title": "龙门试炼", "ico": "🐉", "theme": "temple", "rarity": "legendary",
		"desc": "石门高百丈，门上刻着一行字：「跃过者，脱胎换骨；落败者，尸骨无存。」",
		"choices": [
			{ "text": "跃龙门", "hint": "伤害 +35% · 暴击 +5% · 下波多 3 精英",
				"effect": { "effects": { "dmg_mult": 0.35, "crit_ch": 0.05 }, "next_wave_elite": 3 } },
			{ "text": "取龙门鳞", "hint": "随机法宝 · 最大生命 +25", "effect": { "grant_relic": true, "effects": { "max_hp": 25.0 } } },
			{ "text": "养精蓄锐", "hint": "回复 60% 生命 · 最大生命 +40", "effect": { "effects": { "heal_pct": 0.60, "max_hp": 40.0 } } },
		] },
	# ---- S3.5 新增：第 5 区块（归元道场）的主题卡 ----
	# 为什么要加这张：`_check_event_cards` 断言「奇遇卡必须覆盖全部地图主题」，
	# 主题从 3 个扩到 5 个后必须补卡，否则该断言会红 —— 而那条断言是**故意**留着的
	# （它守的是「config 里写了一个永不出现的主题」，是数据完整性的哨兵）。
	{ "id": "ev_origin_dao", "title": "归元问道", "ico": "☯", "theme": "origin", "rarity": "epic",
		"desc": "道场空无一人，蒲团上留有余温。你坐下时，听见自己的心跳与钟声同频。",
		"choices": [
			{ "text": "入定观心", "hint": "生命回复 +1.2/秒 · 闪避 +8%", "effect": { "effects": { "regen": 1.2, "dodge": 0.08 } } },
			{ "text": "以气养兵", "hint": "攻速 +9% · 伤害 +12%", "effect": { "effects": { "as_mult": 0.09, "dmg_mult": 0.12 } } },
			{ "text": "取走香火钱", "hint": "获得 170 ◆", "effect": { "grant_materials": 170 } },
		] },
]

static func event_card(id: String) -> Dictionary:
	for e in EVENT_CARDS:
		if String(e.get("id", "")) == id:
			return e
	return {}

static func event_card_ids() -> Array:
	var out: Array = []
	for e in EVENT_CARDS:
		out.append(String(e.get("id", "")))
	return out

## 事件卡抽取池：[{ item: 卡片, w: rarity_weight(稀有度, 当前波次) }]
## 排除本局已抽到过的卡，保证 10 个事件都能被见到
static func event_card_pool(seen: Array, wave: int) -> Array:
	var pool: Array = []
	for e in EVENT_CARDS:
		if seen.has(String(e.get("id", ""))):
			continue
		pool.append({ "item": e,
			"w": rarity_weight(String(e.get("rarity", "common")), wave) })
	return pool

## ============================================================
## 地图主题（Phase 5 · S3.5 扩到 5 区块）—— 按**区块**切换的竞技场氛围
## 字段说明：
##   name    中文名（横幅/图鉴展示）
##   bg      竞技场底色（main._draw 填充）
##   grid    网格线颜色（与底色同系，保持可读性）
##   accent  边框与装饰强调色（运行期会再与「本区区域元素色」混合，见 main._draw）
##   particle 主题氛围粒子（fx/ 下的粒子脚本键）
##   waves   适用波次区间 [起, 止]（**文档字段**；真值由 `block_of` 推导，冒烟交叉校验）
##
## ⚠️ **主题 id ↔ 区域元素不是一一对应**，别把两者绑死：
##    区域元素是「玩家相关」的（按区域元素序轮转，木玩家的区块 1 是土、火玩家是金），
##    而主题是**地点**。所以主题名保持「地名」而非「火域/金域」，
##    区域元素由横幅动态显示（"万剑归墟 · 金境"）。
##
## 注：原 `obstacle` 字段（障碍物外观 id）已随地形系统整体移除（2026-09-14）。
## 主题现在只负责颜色与氛围粒子，不再影响玩法。
## ============================================================
const MAP_THEMES := {
	# §16.2 新增三字段（接口预留，纯数据可换不改代码）：
	#   element  = 该区块主元素（区域加成 + 怪物偏置的取值源；此处取 §5.5.3 木角色区域序 earth→water→fire→metal→wood）
	#   bg_tint  = 可选元素染色（"" = 用 bg 原色，见 main._draw 的 bg_base 层）
	#   ambient  = 可选区块专属氛围粒子（"" = 用主题默认 particle，见 main._rebuild_theme_fx）
	"bamboo": { "name": "幽篁竹林", "bg": "#16221a", "grid": "#1f3325", "accent": "#3f6b46",
		"element": "earth", "bg_tint": "", "ambient": "",
		"particle": "bamboo_leaf", "waves": [1, 4] },
	"temple": { "name": "荒古废庙", "bg": "#241a17", "grid": "#33241f", "accent": "#6b4a3a",
		"element": "water", "bg_tint": "", "ambient": "",
		"particle": "incense", "waves": [5, 8] },
	"nether": { "name": "幽冥鬼域", "bg": "#141728", "grid": "#1d2138", "accent": "#4a3f7a",
		"element": "fire", "bg_tint": "", "ambient": "",
		"particle": "ghost_fire", "waves": [9, 12] },
	"blade": { "name": "万剑归墟", "bg": "#1b1d22", "grid": "#272b33", "accent": "#8f9aae",
		"element": "metal", "bg_tint": "", "ambient": "",
		"particle": "ghost_fire", "waves": [13, 16] },
	"origin": { "name": "归元道场", "bg": "#1a211d", "grid": "#253029", "accent": "#7fc7a8",
		"element": "wood", "bg_tint": "", "ambient": "",
		"particle": "incense", "waves": [17, 20] },
}

const MAP_THEME_ORDER := ["bamboo", "temple", "nether", "blade", "origin"]

## 波次 → 主题 id。**与 `block_of` 同源**（不再另写一套区间表）：
## 区块 1→ORDER[0]、区块 2→ORDER[1] …，无尽局随区块号自然循环。
static func map_theme_for_wave(w: int) -> String:
	var b := block_of(w)
	return String(MAP_THEME_ORDER[(b - 1) % MAP_THEME_ORDER.size()])

static func map_theme(id: String) -> Dictionary:
	return MAP_THEMES.get(id, {})

static func map_theme_name(id: String) -> String:
	return String(MAP_THEMES.get(id, {}).get("name", id))

## ============================================================
## 区块与区域元素（五行体系 §8 / §5.5.3 · 20 波 = 5 区块 × 4 波）
##
## 区域元素序的**唯一真值**。第 6 轮拍板：「同属」放末位
## （土 → 水 → 火 → 金 → 木），让 W20 的同属性 BOSS 能实打实触发
## §5.5.1 的 90% cap —— 若末位放「克我」，那条规则在标准 20 波里永不触发。
##
## 序位语义（对玩家而言，从左到右威胁递增）：
##   区1 我克 → 区2 生我 → 区3 我生 → 区4 克我 → 区5 同属
## 注意：本序是**给「木」角色写的**（木 = 玩家元素）。
## 其它角色用 `region_sequence(player_element)` 按同一套关系序推导，
## 不需要 5 张表（同 §9.3 的思路）。
## ============================================================
const BLOCK_COUNT := 5
const BLOCK_WAVES := 4   # 每区波数；BLOCK_COUNT × BLOCK_WAVES == WAVES_TOTAL

## 关系序位 → 该位对应的「玩家元素的关系」。
## 第 5 位固定为 same（同属），这是 90% cap 可达性的守门约定（断言 47 / 50c）。
const REGION_SLOT_RELATIONS := ["i_beat", "gen_me", "i_gen", "beats_me", "same"]

## 波次 → 区块号（1 起）。W1-4 = 1、W5-8 = 2 …；无尽局继续按 4 波循环。
static func block_of(wave: int) -> int:
	var w := maxi(1, wave)
	return ((w - 1) / BLOCK_WAVES) % BLOCK_COUNT + 1

## 区块号 → 区域元素序的下标（0 起）。无尽局按区块循环。
static func block_element_index(block: int) -> int:
	var b := clampi(block, 1, BLOCK_COUNT)
	if GameState.endless:
		return (b - 1) % BLOCK_COUNT
	return b - 1

## 木角色的区域元素序（**断言参照值**，不是运行期真值）
## ⚠️ 运行期一律走 `region_sequence(player_element)` 推导；这个常量只给冒烟做交叉校验
##    （「推导结果 == 手写期望」），改推导逻辑时手写值要跟着改 —— 那正是它存在的意义。
const REGION_SEQUENCE_WOOD := ["earth", "water", "fire", "metal", "wood"]

## 求「与 owner 的关系恰好是 rel」的那个元素（反向查表）。
##   i_beat   → owner 克它      → OVERCOMES[owner]
##   gen_me   → 它生 owner      → GENERATES 的逆
##   i_gen    → owner 生它      → GENERATES[owner]
##   beats_me → 它克 owner      → OVERCOMES 的逆
##   same     → owner 自己
## ⚠️ 一律从 GENERATES / OVERCOMES **反查**，不另写一份数组 ——
##    区域序、S4 的闸门表、S7 的菜单生克动画都靠它推导，
##    另写一份就等于多一处真值，必有一天对不上（铁律 1）。
static func element_with_relation(owner: String, rel: String) -> String:
	if owner == "" or not ELEMENTS.has(owner):
		return ""
	match rel:
		"same":
			return owner
		"i_beat":
			return String(OVERCOMES.get(owner, ""))
		"i_gen":
			return String(GENERATES.get(owner, ""))
		"gen_me":
			for e in ELEMENTS:
				if String(GENERATES.get(String(e), "")) == owner:
					return String(e)
			return ""
		"beats_me":
			for e in ELEMENTS:
				if String(OVERCOMES.get(String(e), "")) == owner:
					return String(e)
			return ""
	return ""

## 该角色的区域元素序（长度 = BLOCK_COUNT）。
## 位序 = `REGION_SLOT_RELATIONS`（我克 → 生我 → 我生 → 克我 → 同属），
## 对**玩家元素**而言威胁由低到高；末位固定 same，保证 W20 的 90% cap 可达。
##
## ⚠️ 白板角色（`element == ""`，如土豆勇者）没有「同属」可言 → 回落到木序。
##    这是纯内容编排的默认值，不代表土豆变成了木属性（它的 element 仍是空串，
##    攻守两侧都不吃元素修正）。别把这个回落误读成「给土豆补了五行归属」。
static func region_sequence(player_element: String) -> Array:
	var owner := player_element if ELEMENTS.has(player_element) else "wood"
	var out: Array = []
	for rel in REGION_SLOT_RELATIONS:
		out.append(element_with_relation(owner, String(rel)))
	return out

## 区块 → 该区区域元素（以**玩家元素**为参照）。越界返回 ""。
static func block_area_element(player_element: String, block: int) -> String:
	var seq := region_sequence(player_element)
	var idx := block_element_index(block)
	if idx < 0 or idx >= seq.size():
		return ""
	return String(seq[idx])

## 波次 → 该波所属区块的区域元素（S3.5 的主入口）。
static func wave_area_element(player_element: String, wave: int) -> String:
	return block_area_element(player_element, block_of(wave))

## 区域加成（§5.5.3）：**进入某区块时**一次性给玩家的该元素同化度增量。
## 受 §7.2 上限约束（`player._sanitize_stats` 会 clamp），可叠加、不重置：
## 20 波走完 5 区，同一个元素最多被叠加到 0.50（区域序里每个元素只出现一次）。
const AREA_BONUS := 0.10

## ---- 场景属性地形区域（第 9 轮 · 用户需求 4）----
## 每 4 波（= 一个区块）换一片**圆形**地形，属性 = 本区区域元素（`wave_area_element`）。
##   · 玩家站进区内 → 对该元素的**同化度临时 +`TERRAIN_ZONE_BONUS`**；
##   · 区内且元素与本区相同的**怪** → 抗性临时 +同值；
##   · 离区即撤销（进出可逆）→ 它是"站位收益"，不是"进区奖励"。
##
## 【与 `AREA_BONUS` 的分工，刻意并存】`AREA_BONUS` 是**进区首波一次性、永久**的养成轴
##   （选择在哪个区深耕）；本机制是**区块内一片有边界的临时区域**（这四波你要不要站进去）。
##   硬合并会同时破坏「一次性发放的幂等」与「站进去才有用」两条规则。
##
## 【圆心是纯函数】圆心只由 `(玩家元素, 区块号)` 哈希得出，**不用 GameRng** ——
##   读档重进同一波、每日挑战全服，看到的都是同一片区域（与商店/BOSS 的确定性口径一致）。
##   刻意**不使用波次**：同一区块四波位置固定，玩家才能记住"这片地在这"并据此规划走位；
##   每波换位置只会让它退化成随机踩点。
##
## 【上限】玩家侧：增量本身夹到 `TERRAIN_ZONE_CAP`，最终仍受 `_sanitize_stats` 的 assim ≤ 2.0
##   与 `apply_hit_mult` 的逐关系 cap 约束；怪物侧：并入 `mob_resist` 的加法项，受其 cap 约束。
const TERRAIN_ZONE_BONUS := 0.20
const TERRAIN_ZONE_CAP := 0.30
const TERRAIN_ZONE_RADIUS := 260.0

static func terrain_zone_for_wave(player_element: String, wave: int) -> Dictionary:
	var elem := wave_area_element(player_element, wave)
	if elem == "":
		return {}
	var blk := block_of(wave)
	var h: int = absi(hash("terrain|%s|%d" % [player_element, blk]))
	var ang := float(h % 360) * PI / 180.0
	# 距场地中心 300~479：既保证玩家出生点（场地正中）**永远不在区内**，
	# 又保证整片圆都落在世界边界内（479 + 260 < 800）。
	var dist := 300.0 + float((h / 360) % 180)
	var center := Vector2(WORLD.w, WORLD.h) * 0.5 + Vector2.from_angle(ang) * dist
	return {
		"element": elem,
		"center": center,
		"radius": TERRAIN_ZONE_RADIUS,
		"bonus": TERRAIN_ZONE_BONUS,
		"cap": TERRAIN_ZONE_CAP,
	}

## §7.4 角色特性：元素角色在**本元素**上开局自带的同化度（白板角色 `element==""` 不吃）。
## 与元素亲和 ±10%（§2.3）是两回事：**亲和改伤害倍率，同化度改减伤/增伤额度**。
## ⚠️ 读档局不会重复加：player 是子节点、`_ready()` 更早，`main._ready()` 里的
##    `SaveRun.restore()` 会整体覆盖 `stats` —— 与 MetaProgress 天赋同一个防重模式。
const CHAR_START_ASSIM := 0.25

## §7.4 五行反应：给**参与的两个元素**（`REACTIONS[].from` / `.to`）各加这么多。
## 目的是「围绕反应打就能加深对该元素的同化」，鼓励围绕反应构筑。
## ⚠️ 会 clamp 到 `Registry.STAT_LIMITS` 的 assim 上限（2.0），不会溢出。
##
## ⚠️⚠️ 2026-09-19 实测修正：原为 `0.03` 且**无频率闸**。而 `EventBus.element_reaction`
##   是**每只怪各发一次**（AOE / 中毒扩散打中 N 只怪 = 一帧 N 次），增益因此随
##   「同屏怪数」而不是「时间」增长 —— 实测 W7 就把五系全部灌到 2.0（日志 assim_sum=10.0）。
##   现改为「单次 1% + 按 reaction_id 冷却 `REACTION_ASSIM_COOLDOWN_MS`」：
##   增益只由时间决定、与怪数解耦，20 波全力堆也未必五系全满。
const REACTION_ASSIM_GAIN := 0.01

## 同一反应 id 两次「发放同化度」之间的最小间隔（毫秒）。理由见上。
## ⚠️ 只约束同化度发放；反应本身的伤害 / 特效 / 图鉴完全不受影响。
const REACTION_ASSIM_COOLDOWN_MS := 5000

const WAVES_TOTAL := 20
const BOSS_WAVE := 20
const ENDLESS_MAX_WAVE := 9999   # 无尽模式波次上限（防溢出的护栏值）
const ENEMY_HARD_CAP := 240      # 同屏敌人绝对上限（大规模敌群性能护栏）

## ---- 中间 BOSS（第 9 轮 · 用户需求 4）----
## 改版后标准局共 5 个 BOSS 波：W4 / W8 / W12 / W16（中间，限时）+ W20（最终，不限时）。
##
## 【为什么中间 BOSS 的血量**不能**按最终 BOSS 的比例缩】
##   最终 BOSS 的 56~90 万血量是按**无限时消耗战**标定的（打多久都行，靠 `dmg_cap_pct`
##   兜住爆发）。而中间 BOSS 必须能在限时内打完 —— 否则「时间到没有击杀则不掉落」
##   会变成常态，法宝盒子永远拿不到，功能等于没做。两者刻意**不共用一条曲线**。
##
## ⚠️ 本表是**首次落地的估价，待墙钟实测校准**。偏肉的症状很好认：
##    「时间到 BOSS 还剩一大半血」。修法是先降本表，**不要去拉长限时** ——
##    限时拉长会让「没击杀就不掉落」这条规则失去意义。
const BOSS_BOX_CHOICES := 3          # 法宝盒子开出的候选数（三选一）

## 标准局 5 个 BOSS 波（W4/W8/W12/W16/W20）血量占该 BOSS **基础血量**的比例，下标 = 区块 - 1（→ 0..4）。
## 第 14 轮：在「第 9 轮估价」上整体再砍一档 = 原值 ×(1 − 0.75/0.50/0.40/0.30/0.15)。
const BOSS_HP_FRAC := [0.0075, 0.035, 0.084, 0.175, 0.85]

## 中间 BOSS 限时 = 同波普通波时长 × 本倍率。比普通波宽（要边躲弹幕边打），
## 但**必须有**限时 —— 它正是「时间到不掉落」的前提。
const MIDBOSS_TIME_MULT := 2.5

## 打击感特效的存活上限（全场同屏计数；超出则丢弃新特效保帧率）
## 集中在此而非各自硬编码在 fx/ 里：与 ENEMY_HARD_CAP 同一口径，
## 便于统一调参，也避免「同屏特效预算」散落在多个文件里难以整体评估。
## 注意三者的寿命不同（Burst 0.2~0.5s / 飘字 0.7s / 冲击波 0.5s），
## 因此上限值不可直接互相套用。
const FX_BURST_MAX_LIVE := 60        # 粒子迸发（命中/死亡）
const FX_FLOAT_TEXT_MAX_LIVE := 70   # 伤害飘字
const FX_SKILL_MAX_LIVE := 14        # 技能冲击波
const HEAL_DROP_CHANCE := 0.05
const SHOP_HEAL_PRICE := 15
const SHOP_UPGRADE_CHANCE := 0.29   # 商店刷出升级属性的概率（武器 42% 之外再分摊）

## ---- 商店刷新倾向性（第 9 轮 · 用户要求）----
## 意图：别让「与构筑无关的道具」挤占货架，核心构筑件（武器 / 同化度）该来的时候要来。
## 三条规则各自独立，全部只在 shop_ui 的抽取路径上生效，不改任何结算。

## 1. 倾向已有武器：买到同名武器的权重 ×该倍率 —— 进化要 3 把同名，
##    不加权的话「凑 3 把」在 5 把武器 × 6 格里几乎不可期。
const SHOP_OWNED_WEAPON_MULT := 3.0
## 2. 同化度保底：某次刷新整店没出同化度 → 下次其权重 ×(1 + step × 连续落空店数)，
##    刷到一次立刻归零重算；倍率本身封顶（否则连着十几店空手会概率失控）。
const SHOP_ASSIM_PITY_STEP := 0.35
const SHOP_ASSIM_PITY_MAX := 3      # 倍率上限（1 + 0.35×3 = 2.05×）
## 连续落空到该店数时**直接塞一格**同化度（0 = 只加权、不做硬保底）
const SHOP_ASSIM_FORCE_AT := 3
## 3. 武器侧「已无处可升」时的武器概率比例。
##    ⚠️ 两个常量都刻意留 0，但要**分层**：满槽时买武器会被 `buy()` 拦下（死格），
##       所以不刷；将来若要放开「满槽也能买同名凑进化」，只需改其中一个值。
##    ⚠️ 关键不在「降到多少」，而在**让出的份额去哪**：见 shop_ui._roll_one ——
##       腾出的比例**全部并进升级池**，不流向普通道具。这是「道具挤占核心构筑件」的根治点。
const WEAPON_CHANCE_SLOTS_FULL := 0.0    # 满槽（买了会被拦 = 死格）
const WEAPON_CHANCE_SATURATED := 0.0     # 武器侧饱和（满槽 + 全是进化体）

## 同化度类条目的唯一稳定判据：`effects` 里带 `assim_*` 键。
## ⚠️ 别去比 id 前缀 —— 同化度横跨两套命名：道具是 `i-assim-*`，升级是 `wu_*`，
##    按前缀判会**静默漏掉升级那一支**（池子看着还有货，保底却永远刷不到）。
static func is_assim_entry(e: Dictionary) -> bool:
	for k in e.get("effects", {}):
		if String(k).begins_with("assim_"):
			return true
	return false

## 商店货架格数。6 格 = 选择面足够宽，又不至于让单波收入能全清货架。
## ShopUI 构建 / 重掷 / 冒烟断言都读这里，加货架只改这一个数。
const SHOP_SLOTS := 6

## 是否 BOSS 波（第 9 轮 · 用户需求 4「每四关一个 boss」）。
##   · 标准 / 每日 / 自定义 = **每 `BLOCK_WAVES`(4) 波一个**，最后一波恒为 BOSS。
##     刻意复用 `BLOCK_WAVES` 而不是写死 4：区块划分（每 4 波换景 / 换区域元素）与
##     BOSS 节奏由此**同一处真值**驱动 —— 以后改区块长度，BOSS 节奏自动跟上。
##   · 无尽炼狱 = 每 10 波一轮（**保持不变**，既有平衡与冒烟断言都建立在它上面）。
##
## ⚠️ `w < 1` 必须挡在最前面：`0 % 4 == 0` → 不挡的话 `is_boss_wave(0)` 会变成 true，
##    而 `is_event_wave` / `wave_composition` 都可能用 0 号波做兜底查询。
static func is_boss_wave(w: int) -> bool:
	if w < 1:
		return false
	if GameState.endless:
		return w % 10 == 0
	return w >= RunRules.wave_total(BOSS_WAVE) or w % BLOCK_WAVES == 0

## 是否**最终** BOSS 波（打不过就通不了关的那一波）= 标准 / 每日 / 自定义局的最后一波。
## 无尽局恒 false —— 无尽的 BOSS 只是"更深的一波"，不承担通关语义。
##
## ⚠️ 这是「BOSS 击破后怎么收尾」的**唯一分叉口**，两处消费：
##     · `main._on_boss_killed`：最终 → 通关结算（VICTORY / 日报榜）；中间 → 只发法宝盒子。
##     · `wave_manager._on_boss_killed`：最终 → **不做波次收尾**；中间 → 发 wave_ended → 商店。
##    两边必须读同一个函数 —— 一边按"最终"、另一边按"中间"处理会同时踩到
##    「通关面板底下又开了商店」和「中间 BOSS 打完直接通关」两个相反的坑。
static func is_final_boss_wave(w: int) -> bool:
	if GameState.endless:
		return false
	return w >= RunRules.wave_total(BOSS_WAVE)

## 是否**中间** BOSS 波（改版后标准局的 W4 / W8 / W12 / W16）。
## 与最终 BOSS 的三点差别（全部有对应的消费点）：
##   ① **限时** `midboss_duration()` —— 时间到未击杀 = BOSS 退场且**不掉落**（用户明确要求）；
##   ② 击破只给「法宝盒子」（`GameState.boss_boxes`），波末开盒三选一，不进通关结算；
##   ③ 血量按 `BOSS_HP_FRAC` 压缩 —— 限时战不能照搬"无限时消耗战"的标定。
## ⚠️ 无尽 BOSS **不是**中间 BOSS：它既不限时、也不换掉"击杀直掉法宝"的既有口径。
static func is_mid_boss_wave(w: int) -> bool:
	return not GameState.endless and is_boss_wave(w) and not is_final_boss_wave(w)

## BOSS 血量倍率（第 9 轮 · 用户要求「血量随波次成长」）。
##   · 无尽：沿用既有曲线（W10 = 1.0，每深一波 +30%）—— **不动它**。
##   · 标准：最终波 = 1.0（与改动前**完全一致**，W20 的既有平衡不受影响）；
##     中间 BOSS 查 `BOSS_HP_FRAC`，是"随波次成长"的那条腿；
##     **非 BOSS 波 = 1.0**（测试/工具会在任意波次造 BOSS，见下）。
##
## ⚠️⚠️ 本函数是 BOSS 血量的**唯一真值**，消费点在 `enemy.gd::setup()` 的 BOSS 分支。
##    第 9 轮踩过一次静默坑：函数写好了、纯函数断言也绿，**但没人调用它**
##    → 中间 BOSS 血量从未被压缩（与最终 BOSS 同值却多背限时，必然打不死）。
##    **只断言纯函数返回值抓不到「声明了没人读」** —— 消费点断言在冒烟 §4b。
static func boss_hp_scale(w: int) -> float:
	if GameState.endless:
		return 1.0 + 0.30 * float(maxi(0, w - 10))
	# 非 BOSS 波返 1.0：测试 / 工具会在任意波次（如 W10）造 BOSS 验技能与 dmg_cap，
	# 那里若也按 frac 缩，`dmg_cap = max_hp × 0.005` 会变小、断言被静默截断。
	if not is_boss_wave(w):
		return 1.0
	# 标准局 5 个 BOSS 波（含最终 W20）按区块查 BOSS_HP_FRAC。第 14 轮整体再砍一档
	# （W20 终 = 0.85，不再是既有的 1.0）。
	var blk := clampi(block_of(w), 1, BOSS_HP_FRAC.size())
	return float(BOSS_HP_FRAC[blk - 1])

## 中间 BOSS 的限时时长（秒）。最终 BOSS / 无尽 BOSS 都不走这里（它们不限时）。
static func midboss_duration(w: int) -> float:
	return wave_duration(w) * MIDBOSS_TIME_MULT

## 击杀积分（无尽模式）：基础 + 经验/材料折算，精英/BOSS 天然更值钱
static func kill_score(cfg: Dictionary) -> int:
	return 5 + int(cfg.get("xp", 1)) * 3 + int(cfg.get("mat", 1)) * 2

## BOSS 击破积分奖励（无尽模式）
static func boss_kill_score(w: int) -> int:
	return 800 + w * 30

## 波次清场积分奖励（无尽模式）
static func wave_clear_score(w: int) -> int:
	return w * 30

## 稀有度枚举（低 → 高）：common 白 / rare 蓝 / epic 紫 / mythic 金 / legendary 红
const RARITIES := ["common", "rare", "epic", "mythic", "legendary"]

## 稀有度色（商店/向导/暂停页卡片背景与边框共用）
const RARITY_COLORS := {
	"common": Color("e6e6e6"),
	"rare": Color("5aa9e6"),
	"epic": Color("b07fe0"),
	"mythic": Color("ffb42e"),
	"legendary": Color("e0564f"),
}

## 稀有度中文名（图鉴/商店展示）
const RARITY_NAMES := {
	"common": "普通", "rare": "稀有", "epic": "史诗",
	"mythic": "神话", "legendary": "传说",
}

## 商店/升级池按稀有度抽取的基础权重（单条目权重，品阶越高越稀有）
const RARITY_BASE_WEIGHTS := {
	"common": 1.0, "rare": 0.50, "epic": 0.22, "mythic": 0.055, "legendary": 0.018,
}

## 稀有度抽取权重：progress = 波次（商店）或等级（升级三选一），
## 越往后高品阶权重越高，构筑成型期才有机会刷出金色/红色
## 品阶门槛：进度不足时高品阶完全不出（权重 0），保证「LV1 红品概率为 0」、
## 前期只出现白/蓝、紫品 3 级、金品 6 级、红品 9 级才逐步解锁 ——
## 既让开局不崩，也保留后期刷出神品的期待感
static func rarity_weight(rarity: String, progress: int) -> float:
	var w := float(RARITY_BASE_WEIGHTS.get(rarity, 1.0))
	match rarity:
		"epic":
			if progress < 3: return 0.0
		"mythic":
			if progress < 6: return 0.0
		"legendary":
			if progress < 9: return 0.0
	var t := maxf(0.0, float(progress - 1))
	match rarity:
		"mythic": w *= 1.0 + 0.22 * t
		"legendary": w *= 1.0 + 0.28 * t
		"epic": w *= 1.0 + 0.06 * t
	return w

## ---- 「唯一件」闸门（2026-09-17 第 7 轮）----
## 金（mythic）/ 红（legendary）= **唯一件**：本局每种最多 1 件，取到后即从所有抽取池剔除。
## 这与法宝**同款语义**（`Registry.artifact_pool` 早就用 `artifacts_owned` 做同一件事），
## 区别只是这一层过去**只盖住了法宝** —— 同一件金道具能叠到 10 层，全库也没有 `unique` 字段。
##
## ⚠️ **闸门必须盖住全部 4 类来源**，漏一处就等于没做：
##   1. 商店 `_rarity_pool`（升级 + 道具两路都走它）
##   2. 商店亲和保底 `_ensure_affinity_goods`
##   3. 升级三选一 `level_up_ui`（抽取 + 亲和保底 + 均匀兜底，共 3 处）
##   4. 事件「按品阶发道具」`main._grant_random_item` + 宝箱波战利品 `wave_manager`
## 事件卡**本身**不需要加：`event_card_pool` 已用 `GameState.events_seen` 排重（每张每局一次）。
## 最后还有 `player.apply_item` / `apply_upgrade` 里的**硬闸门**兜底 ——
## 池子过滤只是「让玩家看不到」，mod / 调试面板等旁路绕过池子，只有硬闸门拦得住。
static func is_unique_rarity(rarity: String) -> bool:
	return rarity == "mythic" or rarity == "legendary"

## 抽取闸门：唯一件已在 `owned` 里 → 返回 false（该条目应被剔出池）。
## `owned` 传「当前持有表」（Dictionary，键 = 条目 id）；非唯一品阶恒 true。
## 判据刻意用「当前持有」而非「曾经获得」—— 与法宝一致：卖掉后可以再刷到
## （只能 50% 折价卖出、原价买回，净亏一半，不构成刷取漏洞）。
static func unique_pool_ok(entry: Dictionary, owned: Dictionary) -> bool:
	if not is_unique_rarity(String(entry.get("rarity", "common"))):
		return true
	return not owned.has(String(entry.get("id", "")))

## ---- 属性饱和闸门（2026-09-19 · 用户需求 8-a）----
## 「概率/上限类」属性一旦顶格，再加就是白买。典型：`status_chance` 到 100%、
## `crit_ch` 到 90% 上限、某个 `on_hit_*` 到 100% —— 此时再刷出「只加这些」的条目
## 就是废格（玩家买完发现数值没动）。商店与升级三选一都应把它剔出池。
##
## 判据（刻意保守，只砍真正没用的）：
##   · 「可饱和键」= 出现在 `Registry.STAT_LIMITS` 里的键（上限即饱和线）；
##     `heal_flat` / `heal_pct` 等不在表内的一次性效果**永远算有用**，不被本闸门吃掉。
##   · 条目至少要有 1 个可饱和键，且**每个**可饱和键都已到上限，才判饱和。
##     例：`on_hit_burn` 满了但同时给 `status_dmg_mult`（上限 10，远未到）→ 仍有用。
##   · `dmg_mult`(上限100) / `armor`(1000) / `max_hp`(10000) 这类上限极宽松，
##     实际永远不会被判饱和 —— 这正是想要的效果，不需要另立一张「有效上限表」。
## ⚠️ 与 `unique_pool_ok` 同一层次：只负责「让玩家看不到」，
##    硬闸门仍由 `player.apply_item` / `apply_upgrade` 兜底。
static func is_saturated_entry(entry: Dictionary, stats: Dictionary) -> bool:
	var effects: Dictionary = entry.get("effects", {})
	if effects.is_empty():
		return false
	var saturable := 0
	for k in effects:
		var key := String(k)
		if not Registry.STAT_LIMITS.has(key):
			continue          # 不可饱和的键（heal_* 等）→ 不算数，也不阻止判定
		saturable += 1
		var lim: Vector2 = Registry.STAT_LIMITS[key]
		if float(stats.get(key, 0.0)) < float(lim.y) - 1e-6:
			return false      # 还有没顶格的可饱和键 → 这件仍然有用
	return saturable > 0

# ============================================================
# 构筑亲和（Affinity）：让商店 / 升级三选一 / 法宝掉落的抽取
# 向「当前角色 + 当前武器」靠拢，而不是纯随机。
#
# 做法：把角色特性、武器形态、已持有法宝归纳成一组标签，
# 再给每个候选条目按 effects 键自动打标（entry_tags），交集越多权重越高。
# 全部由数据推导 —— 不手工维护对照表，因此 mod 内容与后续新增内容
# 都会自动获得亲和能力。
# ============================================================
const AFFINITY_BONUS := 0.85      # 每命中一个亲和标签的权重增幅
const AFFINITY_MAX_TAGS := 3      # 最多按 3 个匹配计（防止叠满后抽取池被锁死）

## 从角色 + 武器 + 已持有法宝推导「当前构筑的亲和标签」
## 需读 Registry，故为实例方法（Config 是 autoload）
func affinity_tags(character_id: String, weapons: Array, artifacts_owned: Dictionary) -> Array:
	var tags := {}
	# ① 武器：状态元素 / 攻击形态 / 溅射 / 弹速 / 多发
	for w in weapons:
		var wid := ""
		if typeof(w) == TYPE_DICTIONARY:
			wid = String(w.get("type", ""))
		else:
			wid = String(w)
		var wcfg: Dictionary = Registry.weapons.get(wid, {})
		if wcfg.is_empty():
			continue
		var sid := String(wcfg.get("status", ""))
		if sid != "":
			tags[sid] = true
		if String(wcfg.get("attack_type", "")) == "melee":
			tags["melee"] = true
		else:
			tags["ranged"] = true
		if float(wcfg.get("splash", 0.0)) > 0.0:
			tags["aoe"] = true
		if float(wcfg.get("bspeed", 0.0)) >= 600.0:
			tags["speed"] = true
		if int(wcfg.get("pellets", 1)) > 1:
			tags["multi"] = true
	# ② 角色特性：光环元素 / 荆棘 / 战意 / 属性加成
	var tr: Dictionary = Registry.get_character(character_id).get("trait", {})
	var kind := String(tr.get("kind", ""))
	if kind == "aura":
		var asid := String(tr.get("status", ""))
		if asid != "":
			tags[asid] = true
	elif kind == "thorns":
		tags["tank"] = true
	elif kind == "momentum":
		tags["atkspeed"] = true
	for k in tr.get("effects", {}):
		for t in effect_tags(String(k)):
			tags[t] = true
	# ③ 已持有法宝：继续深耕同一元素（玩家已经选了这条路，就该继续给同系）
	for aid in artifacts_owned:
		var et := element_tag(String(Registry.get_artifact(String(aid)).get("element", "")))
		if et != "":
			tags[et] = true
	return tags.keys()

## 单个 effects 键 → 标签（道具 / 升级 / 法宝共用同一套推导规则）
static func effect_tags(key: String) -> Array:
	var out: Array = []
	if key.begins_with("on_hit_"):
		out.append(key.substr(7))     # on_hit_burn → burn
		out.append("status")
		return out
	match key:
		"status_dmg_mult", "status_dur_mult", "status_chance", "status_spread":
			out.append("status")
		"melee_range_bonus":
			out.append("melee")
			out.append("range")
		"bullet_speed_bonus":
			out.append("speed")
		"bullet_range_bonus":
			out.append("range")
		"throw_speed_bonus":
			out.append("speed")
		"throw_range_bonus":
			out.append("range")
		"proj_spread_mult":
			# 第 11 轮：喷射散布角。只对「有 spread 的武器」有意义（当前仅喷火枪一族），
			# 与 range（飞多远）/ aoe（爆多大）都不同族，单列一个标签。
			out.append("spread")
		"aoe_radius_bonus":
			out.append("aoe")
		"max_hp", "armor", "regen", "heal_flat", "heal_pct", "lifesteal":
			out.append("tank")
		"harvesting", "pickup_range":
			out.append("economy")
		"crit_ch", "crit_mult":
			out.append("crit")
		"as_mult":
			out.append("atkspeed")
		"dodge", "speed_mult", "base_speed":
			out.append("mobility")
		"low_hp_dmg_bonus":
			out.append("lowhp")
	return out

## 元素 ↔ 状态标签归一：法宝用 element、武器用 status，统一到状态 id 才能比较
static func element_tag(element: String) -> String:
	return { "fire": "burn", "wood": "poison", "metal": "bleed",
		"water": "freeze", "earth": "stun" }.get(element, "")

## 条目（道具 / 升级 / 法宝）自动打标
static func entry_tags(cfg: Dictionary) -> Array:
	var tags := {}
	if cfg.has("element"):
		var et := element_tag(String(cfg.element))
		if et != "":
			tags[et] = true
	var params: Variant = cfg.get("params", null)
	if typeof(params) == TYPE_DICTIONARY:
		var pd: Dictionary = params
		var ps := String(pd.get("status", ""))
		if ps != "":
			tags[ps] = true
			tags["status"] = true
		var pe := element_tag(String(pd.get("element", "")))
		if pe != "":
			tags[pe] = true
	for key in ["effects", "effect"]:
		var eff: Variant = cfg.get(key, null)
		if typeof(eff) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = eff
		var asid := String(d.get("apply_status", ""))
		if asid != "":
			tags[asid] = true
			tags["status"] = true
		for k in d:
			for t in effect_tags(String(k)):
				tags[t] = true
	return tags.keys()

## 亲和倍率：条目标签与构筑亲和的交集数量 → 权重倍数（无交集返回 1.0）
static func affinity_mult(item_tags: Array, affinity: Array) -> float:
	if item_tags.is_empty() or affinity.is_empty():
		return 1.0
	var hit := 0
	for t in item_tags:
		if t in affinity:
			hit += 1
			if hit >= AFFINITY_MAX_TAGS:
				break
	if hit <= 0:
		return 1.0
	return 1.0 + AFFINITY_BONUS * float(hit)

## ╭──────────────────────────────────────────────────────────────────╮
## │ 第 13 轮：商店刷新的「边际递减」+「补短板」倾向                    │
## ╰──────────────────────────────────────────────────────────────────╯
##
## 起因（用户反馈）：「炸弹的范围这类属性，越大收益率越高，不合理」。
## 数学根因**不是数值填错**，而是收益的次数不同：
##   · 范围类作用于**面积**：覆盖面积 ∝ (1+b)²，敌人密度固定 → DPS ∝ (1+b)²
##     边际收益 dDPS/db ∝ (1+b) —— **越叠越强**（递增）
##   · dmg_mult / as_mult / crit 是**线性**的：边际收益恒定
## 所以同样一件「+20%」，第 4 张范围给的**绝对面积增量**远大于第 1 张。
## 例：土炸弹 splash 95px，叠 3 张高爆装药(+20%) → 半径 ×1.728 → 覆盖面积 2.99×，
##     而代价只是 3 个格子 + dmg −15%。
##
## 对策刻意**不改数值**（那会动到体检表与冒烟的既有口径），而是降低它继续出现的概率：
## 投入越多 → 该族在商店里越难刷到 → 强度增长被压回波次曲线附近。

## ---- 范围类加成：面积 → 半径 的换算（#9 · 2026-09-19 用户需求）----
##
## 约定：范围类加成一律按**面积**定义 ——「范围 +20%」= 覆盖面积 +20%。
## 半径因此只能涨 `sqrt(1.2) − 1 ≈ 9.5%`，而不是 20%：
## 直接用 `1 + bonus` 当半径倍率，面积会变成 `(1.2)² = 1.44` 倍（平方放大），
## 这就是「范围道具一多就雪崩」的几何根因（第 11 轮金剑复盘）。
##
## ⚠️ 只用于**半径**通道：
##    · `melee_range_bonus` → 近战扇形 reach（面积 ∝ reach²）
##    · `aoe_radius_bonus`  → 爆炸 / 溅射 splash（面积 ∝ splash²）
## ⚠️ **不用于** `bullet_range_bonus` / `throw_range_bonus` —— 那是**射程（距离）**，
##    收益线性（弹道扫过的是一条带，长度翻倍面积才翻倍），不当平方处理。
static func radius_scale(area_bonus: float) -> float:
	return sqrt(maxf(0.0, 1.0 + area_bonus))

## 几何类：收益是二次的（面积），边际递增 —— 抑制最狠的一族
const GEOMETRIC_STATS := ["melee_range_bonus", "aoe_radius_bonus",
	"bullet_range_bonus", "throw_range_bonus", "proj_spread_mult"]
## 线性乘法类：边际恒定，但堆高后绝对值同样会超出波次难度 —— 轻度抑制
const LINEAR_STATS := ["dmg_mult", "as_mult", "crit_ch", "crit_mult", "status_dmg_mult"]

## ⚠️⚠️ 受控属性的**基准值**：dmg_mult / as_mult / crit_mult 是**倍率语义**（1.0 基准），
## 其余是**增量语义**（0.0 基准）。apply_item / apply_effects 一律走**加法**
## （player.gd:686 `stats[k] = stats.get(k,0.0) + effects[k]`），
## 所以「玩家额外投入了多少」= stats[k] − 基准[k]。混用会差一个数量级（实测坑）。
const DIM_BASE := {
	"melee_range_bonus": 0.0, "aoe_radius_bonus": 0.0, "bullet_range_bonus": 0.0,
	"throw_range_bonus": 0.0, "proj_spread_mult": 0.0,
	"dmg_mult": 1.0, "as_mult": 1.0, "crit_ch": 0.05, "crit_mult": 2.0,
	"status_dmg_mult": 0.0,
}

## 衰减参数：free = 免费额度（投入不超过它完全不衰减）／soft = 陡度／floor = 权重下限
## 曲线：w = max(floor, 1 / (1 + (cur − free) / soft))
## 几何类（用户选「中等」）：+25% 内不衰减 → +50%:0.67 → +100%:0.40 → +200%:0.22 → 下限 0.20
const DIM_GEO_FREE := 0.25
const DIM_GEO_SOFT := 0.50
const DIM_GEO_FLOOR := 0.20
## 线性类「轻度」（用户选「几何类 + 线性乘法类」里的线性那一档）：
## +50% 内不衰减 → +100%:0.67 → +200%:0.45，下限 0.45 —— 不至于让输出件彻底绝迹
const DIM_LIN_FREE := 0.50
const DIM_LIN_SOFT := 1.00
const DIM_LIN_FLOOR := 0.45

## 波次放宽（第 13 轮补充）：免费额度随波次增大。
## 后期波次怪物 / BOSS 强度本就按曲线指数级上涨，玩家相应的数值投入也应被允许更高，
## 不该在波次早期就被边际递减压死。公式：
##   free(wave) = base + min(CAP, max(0, wave − 1) × PER_WAVE)
## 几何类与线性类各用各自的 base，享受同一个放宽节奏；CAP 封顶避免无尽模式里免费额度无限膨胀。
const DIM_FREE_PER_WAVE := 0.03
const DIM_FREE_CAP_BONUS := 0.60
static func dim_free_geo(wave: int) -> float:
	return DIM_GEO_FREE + minf(DIM_FREE_CAP_BONUS, maxf(0.0, float(wave) - 1.0) * DIM_FREE_PER_WAVE)
static func dim_free_lin(wave: int) -> float:
	return DIM_LIN_FREE + minf(DIM_FREE_CAP_BONUS, maxf(0.0, float(wave) - 1.0) * DIM_FREE_PER_WAVE)

## 补短板用的维度归属（键 → 维度），与上面两张 STATS 表同源
const DIM_OF_KEY := {
	"dmg_mult": "offense", "as_mult": "offense", "crit_ch": "offense",
	"crit_mult": "offense", "status_dmg_mult": "offense", "status_chance": "offense",
	"melee_range_bonus": "area", "aoe_radius_bonus": "area", "bullet_range_bonus": "area",
	"throw_range_bonus": "area", "proj_spread_mult": "area",
	"max_hp": "tank", "armor": "tank", "dodge": "tank", "regen": "tank", "lifesteal": "tank",
	"speed_mult": "utility", "base_speed": "utility", "harvesting": "utility",
	"pickup_range": "utility",
}
## 短板提权：投入最少的维度 ×1.35，次少 ×1.15，其余 1.0
const SHORTFALL_MULT_WORST := 1.35
const SHORTFALL_MULT_SECOND := 1.15

## 玩家在该属性上**额外投入**了多少（相对基准，负值归 0）
static func dim_invested(stats: Dictionary, key: String) -> float:
	var base: float = float(DIM_BASE.get(key, 0.0))
	return maxf(0.0, float(stats.get(key, base)) - base)

static func _dim_curve(cur: float, free_q: float, soft: float, floor_v: float) -> float:
	var over := maxf(0.0, cur - free_q)
	if over <= 0.0:
		return 1.0
	return maxf(floor_v, 1.0 / (1.0 + over / soft))

## 边际递减系数：条目每命中一个受控属性，就按该属性的**当前投入量**衰减。
## ⚠️ 命中多个时取**最狠的一个**（min）而不是连乘 —— 连乘会让「范围+暴击」这类复合条目
##    被双重惩罚，可它的实际强度并没有翻倍。
## ⚠️ 只惩罚**正投入**：dmg_mult / proj_spread_mult 可能为**负**（那是代价不是收益），
##    负值若也抑制，会出现「带代价的强力道具反而更好刷」的反向激励。
static func diminish_mult(entry: Dictionary, stats: Dictionary, wave: int = 1) -> float:
	var eff: Dictionary = entry.get("effects", {})
	if eff.is_empty():
		return 1.0
	var gfree := dim_free_geo(wave)
	var lfree := dim_free_lin(wave)
	var m := 1.0
	for k in GEOMETRIC_STATS:
		if eff.has(k):
			m = minf(m, _dim_curve(dim_invested(stats, String(k)),
				gfree, DIM_GEO_SOFT, DIM_GEO_FLOOR))
	for k2 in LINEAR_STATS:
		if eff.has(k2):
			m = minf(m, _dim_curve(dim_invested(stats, String(k2)),
				lfree, DIM_LIN_SOFT, DIM_LIN_FLOOR))
	return m

## 返回当前**正在被抑制**的受控属性键（投入已超该波次的免费额度）。
## 空数组 = 未受抑制。货架角标用它告诉玩家「这件为什么老不出 / 出现概率被压」。
static func dim_suppressed_keys(entry: Dictionary, stats: Dictionary, wave: int = 1) -> PackedStringArray:
	var eff: Dictionary = entry.get("effects", {})
	var out: PackedStringArray = []
	var gfree := dim_free_geo(wave)
	var lfree := dim_free_lin(wave)
	for k in GEOMETRIC_STATS:
		if eff.has(k) and dim_invested(stats, String(k)) > gfree:
			out.append(String(k))
	for k2 in LINEAR_STATS:
		if eff.has(k2) and dim_invested(stats, String(k2)) > lfree:
			out.append(String(k2))
	return out

## 货架角标用的中文名：告诉玩家「这件为什么被压」（具体是哪个属性）
const DIM_KEY_LABEL := {
	"melee_range_bonus": "近战范围", "aoe_radius_bonus": "AOE范围", "bullet_range_bonus": "弹程",
	"throw_range_bonus": "投掷范围", "proj_spread_mult": "散射角",
	"dmg_mult": "增伤", "as_mult": "攻速", "crit_ch": "暴击率", "crit_mult": "暴伤",
	"status_dmg_mult": "异常增伤",
}

static func dim_key_label(k: String) -> String:
	return String(DIM_KEY_LABEL.get(k, k))

## 条目属于哪个短板维度（取命中的第一个；复合条目按第一个算，够用且稳定）
static func entry_dim(entry: Dictionary) -> String:
	var eff: Dictionary = entry.get("effects", {})
	for k in eff:
		var d := String(DIM_OF_KEY.get(String(k), ""))
		if d != "":
			return d
	return ""

## 补短板系数：投入到最少的那个维度时提权。
## `counts` = 各维度已持有条目数（shop_ui 开店时统计一次，见 _dim_counts）。
## ⚠️ counts 为空（刚开局一件没买）→ 一律 1.0，不做任何引导。
static func shortfall_mult(entry: Dictionary, counts: Dictionary) -> float:
	if counts.is_empty():
		return 1.0
	var d := entry_dim(entry)
	if d == "":
		return 1.0
	var mine: int = int(counts.get(d, 0))
	var worst := -1
	var second := -1
	for k in counts:
		var c: int = int(counts[k])
		if worst < 0 or c < worst:
			second = worst
			worst = c
		elif second < 0 or c < second:
			second = c
	if mine <= worst:
		return SHORTFALL_MULT_WORST
	if second >= 0 and mine <= second:
		return SHORTFALL_MULT_SECOND
	return 1.0

## 判断一个道具/升级是否与当前武器阵容相关（过滤掉「对当前武器无用」的武器专属强化）。
## 规则：
##   - melee_range_bonus 需要至少一把近战（melee）武器，否则是废属性
##   - bullet_speed_bonus / bullet_range_bonus 需要至少一把**弹幕**武器
##     （投射且 `proj_kind != "thrown"` —— 土质炸弹是投掷物，不吃这一族，见 WEAPONS 抬头注释）
##   - throw_speed_bonus / throw_range_bonus 需要至少一把**投掷**武器
##   - aoe_radius_bonus 需要至少一把带溅射（splash）的武器
##   - proj_spread_mult 需要至少一把**带喷射散布**（spread>0）的武器（第 11 轮，当前仅喷火枪一族）
## 其余通用属性（伤害/攻速/生命/暴击等）无条件保留。
## 需读 Registry，故为实例方法（Config 是 autoload）。
func entry_weapon_relevant(cfg: Dictionary, weapons: Array) -> bool:
	var has_melee := false
	var has_ranged := false
	var has_aoe := false
	var has_bullet := false
	var has_thrown := false
	var has_spread := false   # 第 11 轮：有喷射散布的武器（喷嘴类道具只对它有意义）
	for w in weapons:
		var wid := ""
		if typeof(w) == TYPE_DICTIONARY:
			wid = String(w.get("type", ""))
		else:
			wid = String(w)
		var wcfg: Dictionary = Registry.weapons.get(wid, {})
		if wcfg.is_empty():
			continue
		if String(wcfg.get("attack_type", "")) == "melee":
			has_melee = true
		else:
			has_ranged = true
			if String(wcfg.get("proj_kind", "bullet")) == "thrown":
				has_thrown = true
			else:
				has_bullet = true
		if float(wcfg.get("splash", 0.0)) > 0.0:
			has_aoe = true
		if float(wcfg.get("spread", 0.0)) > 0.0:
			has_spread = true
	var eff: Variant = cfg.get("effects", null)
	if typeof(eff) != TYPE_DICTIONARY:
		return true
	for k in eff:
		match String(k):
			"melee_range_bonus":
				if not has_melee:
					return false
			"bullet_speed_bonus", "bullet_range_bonus":
				if not has_bullet:
					return false
			"throw_speed_bonus", "throw_range_bonus":
				if not has_thrown:
					return false
			"aoe_radius_bonus":
				if not has_aoe:
					return false
			"proj_spread_mult":
				if not has_spread:
					return false
	return true

# ============================================================
# 角色印记（SIGIL）—— 角色的元素 / 风格在武器表现上的专属痕迹
#
# 与「武器外观族」正交：外观族回答「这是什么武器」（火舌 / 冰晶 / 刀光），
# 印记回答「这是谁在用」（焚天祭司的火星 / 沧海鲛人的霜粒 / 太白剑客的刃光）。
# 于是同一个角色换武器，画面里仍留有他的味道；同一把武器换角色，表现也随之改变。
#
# 每个印记只用四种绘制原语之一，避免为每个印记各写一套绘制代码：
#   spark 飞散火星（火 / 爆 / 血）    mote 漂浮微粒（水 / 木 / 土 / 生）
#   edge  附加锋线（金 / 剑 / 疾）    ring 脉动光环（守 / 运）
#
# ⚠️ 五行印记必须五行齐全（`SIGILS` 的 fire/water/wood/earth/metal 五键），
#    否则「按五行给角色标一个元素」时会出现某一行的角色无印记可配。
# ============================================================
const SIGIL_GLYPHS := ["spark", "mote", "edge", "ring"]
const SIGILS := {
	"fire":  { "name": "烈焰", "color": "#ff7a3c", "glyph": "spark" },
	"water": { "name": "寒霜", "color": "#8fd8ff", "glyph": "mote" },
	"wood":  { "name": "青瘴", "color": "#6ab04c", "glyph": "mote" },
	"earth": { "name": "厚土", "color": "#ffd24a", "glyph": "mote" },
	"metal": { "name": "锐金", "color": "#dfe6f0", "glyph": "edge" },
	"blade": { "name": "剑意", "color": "#e8eef8", "glyph": "edge" },
	"swift": { "name": "疾风", "color": "#9fe8d8", "glyph": "edge" },
	"blast": { "name": "轰爆", "color": "#ffb347", "glyph": "spark" },
	"guard": { "name": "坚守", "color": "#8fa8ff", "glyph": "ring" },
	"luck":  { "name": "鸿运", "color": "#ffd76a", "glyph": "ring" },
	"blood": { "name": "血怒", "color": "#c23b52", "glyph": "spark" },
	"vigor": { "name": "生生", "color": "#a8e6a0", "glyph": "mote" },
}

## 五行状态 → 印记
static func element_sigil(status: String) -> String:
	return {
		"burn": "fire", "poison": "wood", "bleed": "blood",
		"freeze": "water", "slow": "water", "stun": "earth",
	}.get(status, "")

## effects 键 → 印记（角色特性 / 升级 / 道具共用同一张表）
static func effect_sigil(key: String) -> String:
	return {
		"melee_range_bonus": "blade",
		"bullet_speed_bonus": "swift",
		"bullet_range_bonus": "swift",
		"proj_spread_mult": "swift",
		"throw_speed_bonus": "blast",
		"throw_range_bonus": "blast",
		"aoe_radius_bonus": "blast",
		"low_hp_dmg_bonus": "blood",
		"momentum_dmg_bonus": "blade",
		"status_dmg_mult": "wood",
		"status_dur_mult": "wood",
		"status_chance": "wood",
		"crit_ch": "luck",
		"crit_mult": "luck",
		"harvesting": "vigor",
		"pickup_range": "vigor",
		"regen": "vigor",
		"lifesteal": "blood",
		"max_hp": "guard",
		"armor": "guard",
		"dodge": "swift",
		"speed_mult": "swift",
		"base_speed": "swift",
	}.get(key, "")

## 角色印记推导：trait.sigil 显式声明优先（显式写空串 = 刻意「无印记」，
## 如土豆勇者的「均衡之道」），否则按 kind → status → effects 顺序推断。
## 返回 "" 表示该角色不带印记。
static func sigil_for(character_id: String) -> String:
	var tr: Dictionary = Registry.get_character(character_id).get("trait", {})
	if tr.is_empty():
		return ""
	if tr.has("sigil"):
		return String(tr["sigil"])
	match String(tr.get("kind", "")):
		"aura":
			return element_sigil(String(tr.get("status", "")))
		"thorns":
			return "guard"
		"momentum":
			return "blade"
	for k in tr.get("effects", {}):
		var s := effect_sigil(String(k))
		if s != "":
			return s
	return ""

## 角色所属五行（五行体系 §12-S1）。空串 = 无属性。
##
## 推导顺序（先显式、后推断，与 sigil_for 同一套哲学）：
##   1. trait.element 显式声明（显式空串 = 刻意无属性，如土豆勇者的「均衡之道」）
##   2. 五行印记 id 本身就是元素名 → 直接取用（sigil=="fire" → element=="fire"）
##   3. 主动技能自带的 status（焚天烈焰 → fire）→ 五行映射
##   4. 特性光环 status（毒雾 → wood）→ 五行映射
## 全部落空 → ""（白板角色，攻守均不参与元素修正）
##
## ⚠️ 第 2 步只认「五行印记」五个 id（fire/water/wood/earth/metal）。
##    风格印记（blade/swift/blast/guard/luck/blood/vigor）**不是**元素，不得映射成五行 ——
##    「剑意」或「血怒」没有对应五行，硬塞会让太白剑客莫名变成金/火。
static func element_for_character(character_id: String) -> String:
	var tr: Dictionary = Registry.get_character(character_id).get("trait", {})
	if tr.has("element"):
		var e := String(tr["element"])
		return e if e == "" or ELEMENTS.has(e) else ""
	var sg := sigil_for(character_id)
	if ELEMENTS.has(sg):
		return sg
	var sk_status: String = String(Registry.get_character(character_id).get("skill", {}).get("status", ""))
	if sk_status != "" and STATUS_ELEMENT.has(sk_status):
		return String(STATUS_ELEMENT[sk_status])
	var tr_status := String(tr.get("status", ""))
	if tr_status != "" and STATUS_ELEMENT.has(tr_status):
		return String(STATUS_ELEMENT[tr_status])
	return ""

## 印记是否合法（空串合法 = 无印记）
static func sigil_valid(id: String) -> bool:
	return id == "" or SIGILS.has(id)

static func sigil_color(id: String) -> Color:
	if not SIGILS.has(id):
		return Color(0, 0, 0, 0)
	return Color(String(SIGILS[id].get("color", "#ffffff")))

static func sigil_glyph(id: String) -> String:
	return String(SIGILS.get(id, {}).get("glyph", ""))

static func rarity_color(r: String) -> Color:
	return RARITY_COLORS.get(r, Color("9aa3b2"))

static func rarity_name(r: String) -> String:
	return RARITY_NAMES.get(r, r)

## 难度色阶（向导卡片）
const DIFFICULTY_COLORS := {
	"normal": Color("7ec850"),
	"hard": Color("e8902a"),
	"nightmare": Color("e0564f"),
}

# ---- 波次曲线（对应原型 JS 内联函数） ----

## 出怪强度总倍率（2026-09-17 第 7 轮 · 用户拍板）。
##
## 用户原话：「出怪速度增加两倍，怪物量增加两倍」。**中文口径 = 原来的 3 倍**
## （「增加两倍」= 原值 + 2×原值），用户在两选项里明确选了 ×3 而非 ×2。
##
## 两个键分开写（而不是合成一个）是因为它们**不是同一件事**：
##   `SPAWN_RATE_MULT` 只影响**出怪间隔**（waiting 时间 ÷3，怪来得更密）；
##   `SPAWN_CAP_MULT`  只影响**同屏上限**（cap ×3，同屏能站更多怪）。
##   实测意义见下方 ⚠️ —— 后期真正起作用的只有前者。
##
## ⚠️⚠️ 上限最终仍被 `ENEMY_HARD_CAP`（240，性能护栏）夹住：
##   `wave_cap(w) = 24 + 6w`，×3 后 W5 = 162、W7 = 216、**W11 起常态撞顶 240**。
##   → 标准局后半段实际生效的是「出怪更密」，而不是「同屏更多」。
##   若实测掉帧，**先收 `SPAWN_CAP_MULT` / 抬高 `ENEMY_HARD_CAP` 的判断门槛，
##   别去收 `wave_cap`** —— 后者是波次曲线的真值，不止出怪用。
const SPAWN_RATE_MULT := 3.0
const SPAWN_CAP_MULT := 3.0

## 波次时长（§8 定稿 · 20 波制）：`30 + 3w` → W1 = 33s、W20 = 90s。
##
## 为什么不是旧的 `45 + 5(w-1)`：那是 10 波制的曲线，W20 要 140s ——
## 20 波制下单局时长直接翻倍失控。短波时 + 多波次还有个副作用是好的：
## 每区块 4 波的切换节奏更明显，「换区」这件事玩家更容易感知到。
static func wave_duration(w: int) -> float:
	return 30.0 + 3.0 * float(maxi(1, w))

static func wave_interval(w: int) -> float:
	return maxf(0.4, 1.0 - 0.07 * (w - 1))   # 前期刷怪更密，保证经验/材料流转

static func wave_cap(w: int) -> int:
	return 24 + w * 6

## ---- 分段难度曲线（第 11 轮 · 用户需求 7）----
## 用户原话：「难度曲线分段计划：W1-4 难、W4-8 易、W10-12 远程多、W12-16 小精英、W16-20 渐肉」。
##
## 形态选**控制点 + 线性插值**而不是继续叠系数：分段曲线的全部意义在「哪一段陡、哪一段平」，
## 控制点把这件事写成可读的一张表，斜率一眼看得出来；写成 `1 + a(w-1) + b·max(0,w-4)…`
## 就没人能再核对它。
##
## ⚠️ 控制点与区块边界**对齐**（W1/4/8/12/16/20）—— 区块划分正是
##    W1-4 / W5-8 / W9-12 / W13-16 / W17-20（`block_of`），与用户要的五段天然一一对应。
##    对齐之后「这一段的难度斜率」和「这一段的怪构成」说的是同一件事。
##
## ⚠️ **端点刻意不动**：W1 = 1.0（开局基准）、W20 与旧的线性公式基本持平
##    （HP 6.70 / DMG 4.42）—— 「难 / 易」是**曲线内部的重新分配**，不是整体调高。
##    否则等于把整局难度抬了一档，而用户要的是节奏变化。
##
## 各段斜率（HP，每波增量）：W1→4 **0.383**（难）｜W4→8 0.175（易）｜
##                          W8→12 0.313｜W12→16 0.338（小精英）｜W16→20 0.313（渐肉 + 构成变肉）
const WAVE_HP_CURVE := [
	[1, 1.00], [4, 2.15], [8, 2.85], [12, 4.10], [16, 5.45], [20, 6.70],
]
const WAVE_DMG_CURVE := [
	[1, 1.00], [4, 1.15], [8, 1.55], [12, 2.05], [16, 2.60], [20, 3.15],
]

## 控制点查表 + 波间线性插值。越界按端点夹取（无尽局 W21+ 沿用末段斜率继续涨，
## 见下面的 `_curve_slope` 分支）。
## 纯函数：只读常量，无任何运行局状态 —— 冒烟 / 图鉴 / 存档校验都直接调它。
static func curve_at(points: Array, w: int) -> float:
	var wave := maxi(1, w)
	var first: Array = points[0]
	if wave <= int(first[0]):
		return float(first[1])
	for i in range(1, points.size()):
		var lo: Array = points[i - 1]
		var hi: Array = points[i]
		if wave <= int(hi[0]):
			var span := maxf(1.0, float(int(hi[0]) - int(lo[0])))
			var t := float(wave - int(lo[0])) / span
			return lerpf(float(lo[1]), float(hi[1]), t)
	# 超出最后一个控制点：按**末段斜率**外推（无尽局靠这条继续变难，而不是撞上限）
	var last: Array = points[points.size() - 1]
	var prev: Array = points[points.size() - 2]
	var last_span := maxf(1.0, float(int(last[0]) - int(prev[0])))
	var slope := (float(last[1]) - float(prev[1])) / last_span
	return float(last[1]) + slope * float(wave - int(last[0]))


static func wave_hp_scale(w: int) -> float:
	return curve_at(WAVE_HP_CURVE, w)

static func wave_dmg_scale(w: int) -> float:
	return curve_at(WAVE_DMG_CURVE, w)

static func wave_spd_scale(w: int) -> float:
	return 1.0 + minf(0.18, 0.015 * (w - 1))

## ---- 连升（第 9 轮合并 → 第 12 轮撤回）----
## 第 9 轮把「连升 N 级」合并成**一次**选择（选中那张生效 N 次，点击 N → 1），
## 第 12 轮按用户反馈**撤回**：改回**一级选一次**（每级各弹一次三选一、每次重抽三张）。
## ⚠️ 撤回后 `level_queue` 每次只 `-1`，不再有「合并上限」与「溢出折材料」——
##    `LEVEL_MERGE_CAP` / `LEVEL_MERGE_OVERFLOW_MAT` 已删除（留着就是死常量）。
##    ⚠️⚠️ 别只把 CAP 改成 1 就了事：合并版的 `_choose` 会把**整个队列清零**
##        并把超出部分折成材料，那样「连升 3 级」只会弹 1 次、白丢 2 级。
##        必须同时改回「减 1 后若仍有积压就继续弹」（见 level_up_ui.gd `_choose`）。

## 第 12 轮：经验获取速度减半 —— 升级所需经验 ×2。
## ⚠️ 用「需求翻倍」而不是「掉落 ×0.5」实现减半：mob 的 xp 是 2~3 点的小整数，
##    ×0.5 会被 int 截断（3 → 1），实际减速约 1/3 而非 1/2；需求翻倍才是精确减半。
const XP_NEED_MULT := 2.0

static func xp_need(level: int) -> int:
	return int(round((4 + (level - 1) * 3) * XP_NEED_MULT))

## 刷怪权重组合：[{ "item": 敌人类型, "w": 权重 }]
##
## ⚠️⚠️ **S3.5 拆开了标准局与无尽局**（§8.2 标出的「本次最容易踩的坑」）：
##   旧代码里 `w >= 10` 那段是**给无尽用的**「精英占比逐步拉满」公式。
##   20 波制下 W10-20 属于**标准局的主线后段**，若继续掉进那个分支，
##   主线后 10 波的敌人构成会失控（精英权重随 21 波爬升曲线走）。
##   → 判据：`GameState.endless` 才走旧公式；标准局一律走下面的 20 波区块表。
##
## 三层叠加（§8.4）：
##   ① 基础池 = `BASE_POOL_LADDER[区块]`（普通怪梯度，按区块升级）
##   ② 阵营怪 = `THEMED_POOL_LADDER[区块]`（Phase 2 那 10 只带元素的进阶怪）
##   ③ 元素怪 = `ELEMENT_MOB_IDS`（五行基础怪，区块 1 的 W1 刻意不放）
## 第四层「本区主元素怪权重翻倍」放在 `compose_pool()` —— 它需要**玩家元素**，
## 而本函数是纯波次函数（冒烟与图鉴都直接调它）。
##
## ⚠️ 权重是**相对值**（`GameRng.weighted_pick` 按总权重归一），新增条目不需要
##    等比缩小原权重 —— 但为可读性，这里让每档大致加起来接近 1.0。

## 基础池梯度：下标 = 区块号（1 起）。区块 1 的 W1 另走短路径（见下）。
const BASE_POOL_LADDER := [
	# ---- 区块 1（W2-4）：只有最基础的三只 ----
	[{ "item": "grunt", "w": 0.42 }, { "item": "swarm", "w": 0.28 }, { "item": "runner", "w": 0.30 }],
	# ---- 区块 2（W5-8）：引入 tank / shooter / bomber ----
	[{ "item": "grunt", "w": 0.24 }, { "item": "swarm", "w": 0.14 }, { "item": "runner", "w": 0.22 },
		{ "item": "tank", "w": 0.16 }, { "item": "shooter", "w": 0.16 }, { "item": "bomber", "w": 0.08 }],
	# ---- 区块 3（W9-12）：引入 wizard / shadow ----
	[{ "item": "grunt", "w": 0.18 }, { "item": "swarm", "w": 0.10 }, { "item": "runner", "w": 0.18 },
		{ "item": "tank", "w": 0.14 }, { "item": "shooter", "w": 0.15 }, { "item": "bomber", "w": 0.11 },
		{ "item": "wizard", "w": 0.08 }, { "item": "shadow", "w": 0.06 }],
	# ---- 区块 4（W13-16）：引入 guard，普通怪整体被压薄 ----
	[{ "item": "grunt", "w": 0.14 }, { "item": "swarm", "w": 0.08 }, { "item": "runner", "w": 0.16 },
		{ "item": "tank", "w": 0.13 }, { "item": "shooter", "w": 0.14 }, { "item": "bomber", "w": 0.12 },
		{ "item": "wizard", "w": 0.10 }, { "item": "shadow", "w": 0.08 }, { "item": "guard", "w": 0.05 }],
	# ---- 区块 5（W17-20）：全谱系，精英味最重 ----
	[{ "item": "grunt", "w": 0.12 }, { "item": "swarm", "w": 0.07 }, { "item": "runner", "w": 0.15 },
		{ "item": "tank", "w": 0.12 }, { "item": "shooter", "w": 0.13 }, { "item": "bomber", "w": 0.12 },
		{ "item": "wizard", "w": 0.11 }, { "item": "shadow", "w": 0.09 }, { "item": "guard", "w": 0.09 }],
]

## Phase 2 阵营怪梯度：下标 = 区块号（1 起），每只固定 0.03 权重。
## ⚠️ 区块 3 必须 ≥ 5 种：既有冒烟断言要求「W10 至少含 5 只 Phase 2 新敌人」，
##    而 W10 落在区块 3。
const THEMED_POOL_LADDER := [
	[],
	["wood_sprite", "fire_imp", "water_nymph"],
	["wood_sprite", "fire_imp", "water_nymph", "metal_puppet", "earth_golem",
		"vine_beast", "blade_monk"],
	["fire_imp", "fire_shaman", "wood_sprite", "vine_beast", "metal_puppet", "blade_monk",
		"water_nymph", "ice_witch", "earth_golem", "stone_titan"],
	["fire_imp", "fire_shaman", "wood_sprite", "vine_beast", "metal_puppet", "blade_monk",
		"water_nymph", "ice_witch", "earth_golem", "stone_titan"],
]

## 每只 Phase 2 阵营怪的固定权重
const THEMED_MOB_WEIGHT := 0.03

## 元素怪的基础权重：下标 = 区块号（1 起）。随区块缓慢上升。
## ⚠️ 区块 1 的 **W1 仍然不放元素怪**（见 wave_composition 的短路径）：
##    开局武器是 95px 近战 `knife`，首杀本就需 t≈11.6s，
##    W1 再塞盾怪/回血怪会把首杀窗口拖到冒烟断言之外（§13 第 13 条）。
const ELEMENT_MOB_BLOCK_WEIGHT := [0.0, 0.03, 0.04, 0.05, 0.05, 0.06]

## ---- 波段怪构成（第 11 轮 · 用户需求 7）----
## 用户原话里的三段构成要求：「W10-12 远程多」「W12-16 小精英」「W16-20 渐肉」。
##
## ⚠️ 倍率必须**按区块**给常量，不能逐波变化：冒烟钉死了「区块内出怪池完全一致」
##    （W10 == W11 必须成立、W8 ≠ W9 必须成立，见 `_check_element_engine`）。
##    区块划分（`block_of`）= W1-4 / W5-8 / W9-12 / W13-16 / W17-20，与用户要的五段一一对应，
##    所以「按区块给」不但合规，还正好是用户要的分段。
##
## 三张名单**必须两两不相交**：同一只怪同时命中两张名单会吃到两次倍率
##    （典型症状是「小精英」段里远程精英被平方放大）。冒烟有断言守住。
##
## ⚠️ 名单是**手写**的（`wave_composition` 是纯波次函数，不能去读 `Registry.enemies` 的 ai ——
##    那会让图鉴 / 存档校验这些调用点依赖注册表就绪）。防漂移靠冒烟：
##    断言「Registry 里所有 ai=="shooter" 的内置怪都在 `BAND_RANGED_MOB_IDS` 里」
##    且「名单里的 id 都存在」—— 两边任一侧漏了就红。

## 远程怪（`ai == "shooter"`，6 只，`keep_dist` 270~320 —— 见 `_check_reach_safety`）
const BAND_RANGED_MOB_IDS := ["shooter", "wizard", "fire_caster", "fire_shaman",
	"water_nymph", "ice_witch"]
## 精英怪：高生命 / 高护甲的「硬目标」（`guard` 120 / `stone_titan` 140 / `earth_bulwark` 80 …）
const BAND_ELITE_MOB_IDS := ["tank", "guard", "stone_titan", "earth_bulwark",
	"earth_golem", "metal_puppet", "metal_guard"]
## 杂兵：数量型，构成变「精英化」时要把它们的份额让出来
const BAND_TRASH_MOB_IDS := ["grunt", "swarm", "runner", "bomber", "shadow",
	"wood_sprite", "fire_imp", "vine_beast", "blade_monk", "wood_healer", "water_splitter"]

## 下标 = 区块号（1 起）。空字典 = 该区块不做构成偏移。
##   · 区块 1（W1-4）：远程怪概率 ×0.5 —— 前期只靠 95px 近战，再叠弹幕会把新手直接卡死
##     （首杀窗口本就 16s），所以前期把火法/巫师/水妖/冰妖这些远程怪压到一半。
##   · 区块 2（W5-8）：远程怪概率 ×0.6 —— 玩家把构筑搭起来的窗口，远程压力也先压一档。
##   · 区块 3（W9-12）**远程多**：远程权重 ×2.2（占比约 21% → 37%）。
##   · 区块 4（W13-16）**小精英**：精英 ×2.0、杂兵 ×0.70 —— 两头都动，
##     否则「全都乘 2」看起来也像生效了（冒烟用**份额**断言，正是一对反向对照）。
##   · 区块 5（W17-20）**渐肉**：精英 ×1.7、杂兵 ×0.85，配合曲线末段继续涨。
const WAVE_BAND_WEIGHTS := [
	{ "ranged": 0.5 },
	{ "ranged": 0.6 },
	{ "ranged": 2.2 },
	{ "elite": 2.0, "trash": 0.70 },
	{ "elite": 1.7, "trash": 0.85 },
]

## 第 14 轮需求 1「前八波无远程弹幕」：远程怪**照常出场、但 W1~W8 不开火**。
## ⚠️ 为什么不是「把远程怪踢出早期池」：`ELEMENT_MOB_IDS` 五元素怪里有且只有火代表
##    `fire_caster` 是远程（ai=shooter）；踢掉它 → W4 缺火 → 直接打破「W4 五行齐全」
##    的元素闸门（难度=元素出场节奏），而区块 1 的三层池里也没有近战火怪可替补
##    （`fire_imp` 从区块 2 才进池）。⇒ 压「弹幕」的正确落点是**不开火**，池与元素闸门一字不动。
const RANGED_NO_SHOOT_THROUGH_WAVE := 8

## 给一张出怪池按波段倍率改写权重。**只改 `w`、不改条目集合** ——
## 「区块 5 必须含全部阵营怪」那条断言靠条目集合，动集合会挂。
## 未命中任何名单的 id（mod 新加的敌人）一律保持原权重，不被静默改动。
static func _apply_band_weights(pool: Array, block: int) -> Array:
	var b := clampi(block, 1, WAVE_BAND_WEIGHTS.size())
	var band: Dictionary = WAVE_BAND_WEIGHTS[b - 1]
	if band.is_empty():
		return pool
	var out: Array = []
	for e in pool:
		var d: Dictionary = (e as Dictionary).duplicate()
		var mid := String(d.get("item", ""))
		var mult := 1.0
		if BAND_RANGED_MOB_IDS.has(mid):
			mult *= float(band.get("ranged", 1.0))
		if BAND_ELITE_MOB_IDS.has(mid):
			mult *= float(band.get("elite", 1.0))
		if BAND_TRASH_MOB_IDS.has(mid):
			mult *= float(band.get("trash", 1.0))
		if mult <= 0.0:
			continue            # 权重被压到 ≤0 → 直接剔除，不留 w=0 条目让 weighted_pick 报错返回 null
		if not is_equal_approx(mult, 1.0):
			d["w"] = float(d.get("w", 0.0)) * mult
		out.append(d)
	return out

## 区块 1 的 W2 渐入白名单：只放「最温和的两只」。
## 为什么单给 W2 开这个口子（S3 定下的节奏，S3.5 沿用）：
##   开局武器是 95px 近战 `knife`，首杀本就需 t≈11.6s（§13 第 13 条）。
##   W2 就上 `metal_guard`（护盾减伤）/ `fire_caster`（远程放风筝），
##   玩家会在还没有任何输出手段时被两个「反近战」机制同时卡住。
##   → 回血怪只是「打慢一点」，分裂怪只是「多打一下」，都不会让玩家打不到。
## W3 起五元素齐全（冒烟 S3-6 断言 W3 ≥ 3 只、W4 全部 5 只）。
const ELEMENT_MOB_W2_IDS := ["water_splitter", "wood_healer"]

## 区块加权：本区**区域元素**那只元素怪的权重翻倍（§8.4 第三层）
const BLOCK_WEIGHT_MULT := 2.0

## ============================================================
## 元素出场闸门（§9 · S4）—— 难度 = 元素出场节奏
##
## 沧溟的规则（§9.2 原话，以木角色为例）：
##   简单：第一次轮转前只有土属性怪；第二次前无木/金；第三、四次前无金
##   困难：第一次轮转前无木/金；第三次轮转前无金
##   噩梦：第一次轮转前无木/金
##
## ⚠️ 被禁的永远只有两个元素：**同属**（最难打死，cap 0.75）与**克我**（双向最劣）。
##    对木角色它们是「木 / 金」；换角色就是别的一对 —— 所以本表**只描述关系解锁的区块号**，
##    元素由 `element_relation` 现场推导，**不需要 5 张表**（§9.3 的关键一步）。
##
## 验算（木角色，区块 1）：
##   normal  strict → 只放 i_beat → 只剩土怪            ✓ 与原话「只有土属性怪」逐字吻合
##   hard/噩梦        → 放 i_beat+gen_me+i_gen → 土·水·火 ✓ 与原话「无木/金」吻合
## ============================================================
## strict_first_block：区块 1 是否收缩到「只有我克」。
##   只有简单档为 true —— 这正是「简单 = 危险元素最晚出现」的最强那一格。
const ELEMENT_GATE := {
	"normal":    { "same_block": 3, "beats_me_block": 5, "strict_first_block": true },
	"hard":      { "same_block": 2, "beats_me_block": 4, "strict_first_block": false },
	"nightmare": { "same_block": 2, "beats_me_block": 2, "strict_first_block": false },
}

## 区块 1（宽档）与区块 2-3 可用的关系集合 —— 即「非危险元素」：
## 我克（最弱，打它 +25%）/ 生我（被滋养 +15%）/ 我生（泄力 −15%）。
const GATE_BASE_RELATIONS := ["i_beat", "gen_me", "i_gen"]

## 未知难度 id 一律按**最保守**的 simple 档处理（闸门宁可多禁，不可静默放开）。
static func gate_allowed_relations(difficulty_id: String, block: int) -> Array:
	var g: Dictionary = ELEMENT_GATE.get(difficulty_id, ELEMENT_GATE["normal"])
	var b := maxi(1, block)
	var rels: Array = ["i_beat"] \
		if (b <= 1 and bool(g.get("strict_first_block", false))) \
		else GATE_BASE_RELATIONS.duplicate()
	if b >= int(g.get("same_block", 1)):
		rels.append("same")
	if b >= int(g.get("beats_me_block", 1)):
		rels.append("beats_me")
	return rels

## 该区块**被禁元素**的集合（`{ 元素: true }`）。
## 白板角色（`element == ""`）按**木序**推导 —— 与 `region_sequence` 的回落口径保持一致，
## 这样「区域加成给谁」与「闸门禁谁」对同一个角色始终指向同一张关系表。
## ⚠️ 不等于「给土豆补了五行归属」：它的 element 仍是空串，攻守两侧都不吃元素修正。
static func banned_elements(player_element: String, difficulty_id: String, block: int) -> Dictionary:
	var owner := player_element if ELEMENTS.has(player_element) else "wood"
	var allowed := gate_allowed_relations(difficulty_id, block)
	var out := {}
	for e in ELEMENTS:
		if not allowed.has(element_relation(owner, String(e))):
			out[String(e)] = true
	return out

## 敌人 id → 五行（从 `ENEMIES` 派生，不另写一份表）。
## ⚠️ 只认内置内容：`wave_composition` 注入的三个池全是内置 id；
##    mod 新加的敌人不在 `Config.ENEMIES` 里，故**不受闸门约束**（返回 "" = 无属性 = 放行）。
static func mob_element(mob_id: String) -> String:
	return String(ENEMIES.get(mob_id, {}).get("element", ""))

## 按闸门过滤一张出怪池（元素 = `{"item": id, "w": n}` 的数组）。
## 独立成函数是为了让 `Registry.wave_composition` 的 **mod `spawn_table` 覆盖路径**
## 也走同一道闸门 —— 否则工坊包只要覆盖一张波次表，三档难度的元素节奏就被整条绕过，
## 而这种绕过**不报错**，只会以「简单难度怎么还有金怪」的面目出现。
## ⚠️ 只认 `Config.ENEMIES` 里声明的 element：mod 新加的敌人不在其中 → `mob_element` 返回 ""
##    → 不受闸门约束。闸门管的是**内置内容的五行编排**，不是内容作者自己写的表。
static func gate_pool(pool: Array, difficulty_id: String, player_element: String,
		block: int) -> Array:
	if difficulty_id == "":
		return pool
	var banned := banned_elements(player_element, difficulty_id, block)
	var out: Array = []
	for e in pool:
		var d: Dictionary = (e as Dictionary).duplicate()
		if banned.has(mob_element(String(d.get("item", "")))):
			continue
		out.append(d)
	return out

## 波次出怪组合。
## `difficulty_id` 为空 = **不设闸门**（图鉴 / 存档校验 / 冒烟默认调用走这条）。
## 真实出怪路径必须带上难度 —— `wave_manager._spawn_pool()` 传 `GameState.difficulty_id`。
## ⚠️ 闸门**按元素过滤整张池**（含 10 只阵营怪）：只过滤那 5 只基础元素怪会漏穿 ——
##    `fire_imp` / `metal_puppet` 等同样带 `element`，简单档区块 1 的「只有土怪」
##    会被它们悄悄破坏。
static func wave_composition(w: int, difficulty_id: String = "",
		player_element: String = "") -> Array:
	# 无尽局：沿用旧的「精英占比逐步拉满」公式（与 20 波主线表无关）
	if GameState.endless:
		return _endless_composition(w)
	# W1 短路径：只有最基础的两只。刻意**不含**元素怪与阵营怪 ——
	# 这一波的任务是教「走位 + 自动攻击」，不是教学五行。
	if w <= 1:
		return [{ "item": "grunt", "w": 0.72 }, { "item": "swarm", "w": 0.28 }]
	var block := block_of(w)
	var out: Array = []
	for e in BASE_POOL_LADDER[block - 1]:
		out.append((e as Dictionary).duplicate())
	for tid in THEMED_POOL_LADDER[block - 1]:
		out.append({ "item": String(tid), "w": THEMED_MOB_WEIGHT })
	var ew := float(ELEMENT_MOB_BLOCK_WEIGHT[block]) if block < ELEMENT_MOB_BLOCK_WEIGHT.size() \
		else float(ELEMENT_MOB_BLOCK_WEIGHT[ELEMENT_MOB_BLOCK_WEIGHT.size() - 1])
	var ids: Array = ELEMENT_MOB_IDS
	if w <= 2:
		ids = ELEMENT_MOB_W2_IDS   # W2 渐入白名单，见该常量注释
	for mid in ids:
		out.append({ "item": String(mid), "w": ew })
	# 第四层：波段怪构成（第 11 轮 · 用户需求 7）。
	# 放在闸门**之前**（闸门只按元素整条剔除、不动权重，两处顺序等价）——
	# 这样本函数的输入永远是完整的四层池，便于断言「只改权重不改条目集合」。
	out = _apply_band_weights(out, block)
	# ⚠️ 「W2 白名单 ∩ 闸门」可能为空（简单档区块 1 只放「我克」）：本波就不出元素怪，
	#    这是刻意的（简单 = 元素最晚出现），不是漏写。
	#    池子不会被清空 —— 基础池那 9 只都不带 element，冒烟另有断言守住这条前提。
	return gate_pool(out, difficulty_id, player_element, block)

## 出怪池（区块感知 · §8.4 第三层）：把**本区区域元素**那只元素怪的权重翻倍。
## 「这块地出这种怪」的体感来源，与 §5.5.3 的区块偏置（抗性 +0.10）配成一对 ——
## 同一区块，主元素的怪**更多、也更硬**，玩家对本区主题的感知是双重的。
##
## ⚠️ 与 `wave_composition` 分开的原因：本函数需要**玩家元素**，
##    而 `wave_composition` 是纯波次函数（图鉴 / 冒烟 / 存档校验都直接调它），
##    把玩家状态塞进去会让那些调用点全部变得依赖运行局状态。
##
## `difficulty_id` 为空 = 不设闸门（与 `wave_composition` 同口径）。
## 真实出怪必须带上：`wave_manager._spawn_pool()` 传 `GameState.difficulty_id`。
static func compose_pool(w: int, player_element: String,
		difficulty_id: String = "") -> Array:
	var pool := wave_composition(w, difficulty_id, player_element)
	if GameState.endless or w <= 1:
		return pool
	var area := wave_area_element(player_element, w)
	var mob := String(ELEMENT_MOB_FOR.get(area, ""))
	if mob == "":
		return pool
	var out: Array = []
	for e in pool:
		var d: Dictionary = (e as Dictionary).duplicate()
		if String(d.get("item", "")) == mob:
			d["w"] = float(d.get("w", 0.0)) * BLOCK_WEIGHT_MULT
		out.append(d)
	return out

## 无尽局专用梯度（原 W>=10 公式，20 波制下**只给无尽用**）。
## 精英占比随波次渐进拉满（波 10 → 30），五行敌人全覆盖。
static func _endless_composition(w: int) -> Array:
	var t := minf(1.0, float(w - 9) / 21.0)
	return [{ "item": "grunt", "w": 0.10 - 0.04 * t }, { "item": "swarm", "w": 0.05 },
		{ "item": "runner", "w": 0.14 }, { "item": "tank", "w": 0.10 + 0.02 * t },
		{ "item": "shooter", "w": 0.10 }, { "item": "bomber", "w": 0.08 + 0.03 * t },
		{ "item": "wizard", "w": 0.08 + 0.04 * t }, { "item": "shadow", "w": 0.06 + 0.04 * t },
		{ "item": "guard", "w": 0.05 + 0.06 * t },
		{ "item": "fire_imp", "w": 0.03 }, { "item": "fire_shaman", "w": 0.03 + 0.02 * t },
		{ "item": "wood_sprite", "w": 0.03 }, { "item": "vine_beast", "w": 0.04 + 0.02 * t },
		{ "item": "metal_puppet", "w": 0.04 + 0.02 * t }, { "item": "blade_monk", "w": 0.03 + 0.02 * t },
		{ "item": "water_nymph", "w": 0.03 }, { "item": "ice_witch", "w": 0.02 + 0.03 * t },
		{ "item": "earth_golem", "w": 0.03 + 0.02 * t }, { "item": "stone_titan", "w": 0.02 + 0.03 * t },
		{ "item": "wood_healer", "w": 0.04 }, { "item": "water_splitter", "w": 0.04 },
		{ "item": "fire_caster", "w": 0.04 }, { "item": "metal_guard", "w": 0.04 },
		{ "item": "earth_bulwark", "w": 0.04 }]

# ---- 商店公式 ----

## 商店物价指数（#2 · 2026-09-19）：售价 / 刷新费 / 回血费共用的「随波次上浮」倍率。
## 形式 = 线性 + 二次项：前期几乎不动（W1 = 1.00），后期显著加速。
##
## 依据（balance_log 实测）：原线性口径 `1 + 0.11(w-1)` 下 W14 物价仅 ×2.43，
## 而该波材料收入已达 4843 —— 一波收入能清空整店，「买哪几件」不再构成取舍。
## 现口径：W5 ×2.16 / W10 ×5.64 / W14 ×10.04 / W20 ×19.34，
## 目标是「每波大致买得起 4~5 件」：购买力全程稳定，而不是越到后期越富。
## ⚠️ 只影响**买入价**；出售返还仍按 `base_price × 0.5` 计算、不含该指数
##    （见 shop_ui._sell）—— 后期「买了又卖」会亏差价，这是刻意设计。
const SHOP_PRICE_LINEAR := 0.11
const SHOP_PRICE_QUAD := 0.045

static func shop_price_mult(wave: int) -> float:
	var t := maxf(0.0, float(wave - 1))
	return 1.0 + SHOP_PRICE_LINEAR * t + SHOP_PRICE_QUAD * t * t

## 刷新费同样吃物价指数 —— 否则后期「刷新 68 ◆ vs 商品 1900 ◆」会让刷新
## 变成无脑最优解（#2 的连带面）。
static func shop_reroll_cost(wave: int) -> int:
	return int(round(float(8 + wave * 3) * shop_price_mult(wave)))

## 回血费同理：固定 15 ◆ 在后期等于免费（#2 的连带面）。
static func heal_price(wave: int) -> int:
	return int(round(float(SHOP_HEAL_PRICE) * shop_price_mult(wave)))

static func shop_price(base_price: int, wave: int) -> int:
	return int(round(float(base_price) * shop_price_mult(wave)))
