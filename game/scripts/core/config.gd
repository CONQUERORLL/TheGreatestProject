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

## 武器：dmg 基础伤害，cd 基础冷却秒；近战用 range / swing_arc
const WEAPONS := {
	"pistol": { "name": "手枪", "ico": "🔫", "cd": 0.55, "dmg": 12.0, "bspeed": 540.0, "rarity": "common", "desc": "稳定单体远程" },
	"smg": { "name": "冲锋枪", "ico": "💢", "cd": 0.16, "dmg": 5.0, "bspeed": 600.0, "spread": 0.13, "rarity": "rare", "desc": "极快射速，轻微散射" },
	"shotgun": { "name": "霰弹枪", "ico": "💥", "cd": 0.90, "dmg": 7.0, "bspeed": 480.0, "pellets": 5, "arc": 0.7, "rarity": "rare", "desc": "一次射出5发扇形弹丸" },
	"knife": { "name": "砍刀", "ico": "🔪", "cd": 0.38, "dmg": 16.0, "range": 82.0, "swing_arc": 1.5, "rarity": "common", "desc": "近战弧形挥砍" },
	"rocket": { "name": "火箭筒", "ico": "🚀", "cd": 1.30, "dmg": 34.0, "bspeed": 380.0, "splash": 88.0, "rarity": "epic", "desc": "命中范围爆炸 AOE" },
}

const WEAPON_SLOTS := 6
const WEAPON_SHOP_CHANCE := 0.42
const WEAPON_SHOP_WEIGHTS := { "pistol": 3.0, "smg": 2.4, "knife": 2.4, "shotgun": 1.6, "rocket": 0.8 }
const WEAPON_PRICES := { "pistol": 25, "smg": 35, "knife": 28, "shotgun": 42, "rocket": 60 }

## 敌人：W1 基础值；血量/伤害随波次缩放（见 wave_* 系列函数）
const ENEMIES := {
	"grunt": { "name": "追击者", "hp": 14.0, "speed": 88.0, "dmg": 8.0, "xp": 2, "mat": 2, "r": 14.0, "color": "#d9534f", "shape": "circle", "heart_chance": 0.04 },
	"runner": { "name": "冲锋者", "hp": 8.0, "speed": 168.0, "dmg": 6.0, "xp": 3, "mat": 2, "r": 11.0, "color": "#e8902a", "shape": "diamond", "heart_chance": 0.04 },
	"tank": { "name": "坦克", "hp": 46.0, "speed": 50.0, "dmg": 16.0, "xp": 8, "mat": 6, "r": 23.0, "color": "#8e5bbf", "shape": "circle", "heart_chance": 0.12 },
	"shooter": { "name": "射手", "hp": 12.0, "speed": 72.0, "dmg": 10.0, "xp": 5, "mat": 4, "r": 14.0, "color": "#3bbfae", "shape": "square", "keep_dist": 270.0, "shoot_cd": 2.2, "bspeed": 300.0, "heart_chance": 0.08 },
	"boss": { "name": "巨型土豆王", "hp": 750.0, "speed": 58.0, "dmg": 22.0, "xp": 30, "mat": 80, "r": 52.0, "color": "#b01e2e", "shape": "circle", "ring_cd": 2.4, "ring_count": 14, "bspeed": 240.0, "heart_chance": 1.0 },
}

## 升级池（可重复叠加；effects 键 = player.stats 键，创意工坊数据驱动；
## 特例：heal_flat = 最大生命+立即回复同值，heal_pct = 立即回复最大生命百分比）
const UPGRADES := [
	{ "id": "hp", "ico": "❤", "name": "强壮", "desc": "最大生命 +18，并立即回复 18", "rarity": "common", "effects": { "heal_flat": 18.0 } },
	{ "id": "dmg", "ico": "⚔", "name": "蛮力", "desc": "伤害 +10%", "rarity": "common", "effects": { "dmg_mult": 0.10 } },
	{ "id": "as", "ico": "⚡", "name": "急速", "desc": "攻击速度 +8%", "rarity": "common", "effects": { "as_mult": 0.08 } },
	{ "id": "spd", "ico": "👟", "name": "飞毛腿", "desc": "移动速度 +8%", "rarity": "common", "effects": { "speed_mult": 0.08 } },
	{ "id": "crit", "ico": "🎯", "name": "锐利", "desc": "暴击率 +6%", "rarity": "rare", "effects": { "crit_ch": 0.06 } },
	{ "id": "critd", "ico": "✦", "name": "狂暴", "desc": "暴击伤害 +30%", "rarity": "rare", "effects": { "crit_mult": 0.30 } },
	{ "id": "armor", "ico": "🛡", "name": "坚甲", "desc": "护甲 +2（递减减伤）", "rarity": "rare", "effects": { "armor": 2.0 } },
	{ "id": "dodge", "ico": "🍃", "name": "灵巧", "desc": "闪避率 +6%", "rarity": "rare", "effects": { "dodge": 0.06 } },
	{ "id": "magnet", "ico": "🧲", "name": "磁力", "desc": "拾取范围 +35", "rarity": "common", "effects": { "pickup_range": 35.0 } },
	{ "id": "regen", "ico": "✚", "name": "再生", "desc": "生命回复 +0.6 / 秒", "rarity": "rare", "effects": { "regen": 0.6 } },
	{ "id": "harv", "ico": "🌾", "name": "丰收", "desc": "材料获取 +18%", "rarity": "rare", "effects": { "harvesting": 0.18 } },
	{ "id": "heal", "ico": "🥔", "name": "急救土豆", "desc": "立即回复 35% 最大生命", "rarity": "epic", "effects": { "heal_pct": 0.35 } },
]

## 商店道具（被动 = 永久属性；effects 键 = player.stats 键，创意工坊数据驱动；
## i-hp 只加上限不立即回血，与原型一致）
const ITEMS := [
	{ "id": "i-hp", "ico": "🍅", "name": "番茄", "desc": "最大生命 +28", "price": 30, "rarity": "common", "effects": { "max_hp": 28.0 } },
	{ "id": "i-dmg", "ico": "🧨", "name": "弹药袋", "desc": "伤害 +14%", "price": 38, "rarity": "rare", "effects": { "dmg_mult": 0.14 } },
	{ "id": "i-as", "ico": "🔋", "name": "弹簧", "desc": "攻速 +12%", "price": 38, "rarity": "rare", "effects": { "as_mult": 0.12 } },
	{ "id": "i-spd", "ico": "👟", "name": "运动鞋", "desc": "移速 +10%", "price": 26, "rarity": "common", "effects": { "speed_mult": 0.10 } },
	{ "id": "i-crit", "ico": "🔭", "name": "瞄准镜", "desc": "暴击率 +10%", "price": 42, "rarity": "epic", "effects": { "crit_ch": 0.10 } },
	{ "id": "i-arm", "ico": "⚙", "name": "钢板", "desc": "护甲 +3", "price": 36, "rarity": "rare", "effects": { "armor": 3.0 } },
	{ "id": "i-dod", "ico": "斗篷", "name": "斗篷", "desc": "闪避 +8%", "price": 32, "rarity": "rare", "effects": { "dodge": 0.08 } },
	{ "id": "i-mag", "ico": "🧲", "name": "大磁铁", "desc": "拾取范围 +55", "price": 22, "rarity": "common", "effects": { "pickup_range": 55.0 } },
	{ "id": "i-reg", "ico": "💊", "name": "再生器", "desc": "生命回复 +1.0 / 秒", "price": 42, "rarity": "epic", "effects": { "regen": 1.0 } },
	{ "id": "i-harv", "ico": "💰", "name": "金币袋", "desc": "材料获取 +25%", "price": 32, "rarity": "rare", "effects": { "harvesting": 0.25 } },
	{ "id": "i-ls", "ico": "🩸", "name": "血蛭", "desc": "每击杀 1 个敌人回复 1 点生命（可叠加）", "price": 48, "rarity": "epic", "effects": { "lifesteal": 1.0 } },
]

const WAVES_TOTAL := 10
const BOSS_WAVE := 10
const HEAL_DROP_CHANCE := 0.05
const SHOP_HEAL_PRICE := 15
const SHOP_UPGRADE_CHANCE := 0.29   # 商店刷出升级属性的概率（武器 42% 之外再分摊）

## 稀有度色（商店/向导/暂停页卡片背景与边框共用）
const RARITY_COLORS := {
	"common": Color("e6e6e6"),
	"rare": Color("5aa9e6"),
	"epic": Color("b07fe0"),
	"legendary": Color("e0564f"),
}

static func rarity_color(r: String) -> Color:
	return RARITY_COLORS.get(r, Color("9aa3b2"))

## 难度色阶（向导卡片）
const DIFFICULTY_COLORS := {
	"normal": Color("7ec850"),
	"hard": Color("e8902a"),
	"nightmare": Color("e0564f"),
}

# ---- 波次曲线（对应原型 JS 内联函数） ----

static func wave_duration(w: int) -> float:
	return 45.0 + (w - 1) * 5.0   # 初始 45s，每波 +5s

static func wave_interval(w: int) -> float:
	return maxf(0.4, 1.25 - 0.085 * (w - 1))

static func wave_cap(w: int) -> int:
	return 26 + w * 4

static func wave_hp_scale(w: int) -> float:
	return 1.0 + 0.30 * (w - 1)

static func wave_dmg_scale(w: int) -> float:
	return 1.0 + 0.18 * (w - 1)

static func wave_spd_scale(w: int) -> float:
	return 1.0 + minf(0.18, 0.015 * (w - 1))

static func xp_need(level: int) -> int:
	return 4 + (level - 1) * 3

## 刷怪权重组合：[{ "item": 敌人类型, "w": 权重 }]
static func wave_composition(w: int) -> Array:
	if w <= 1:
		return [{ "item": "grunt", "w": 1.0 }]
	if w == 2:
		return [{ "item": "grunt", "w": 0.8 }, { "item": "runner", "w": 0.2 }]
	if w == 3:
		return [{ "item": "grunt", "w": 0.6 }, { "item": "runner", "w": 0.25 }, { "item": "tank", "w": 0.15 }]
	if w <= 5:
		return [{ "item": "grunt", "w": 0.5 }, { "item": "runner", "w": 0.25 }, { "item": "tank", "w": 0.13 }, { "item": "shooter", "w": 0.12 }]
	return [{ "item": "grunt", "w": 0.38 }, { "item": "runner", "w": 0.27 }, { "item": "tank", "w": 0.17 }, { "item": "shooter", "w": 0.18 }]

# ---- 商店公式 ----

static func shop_reroll_cost(wave: int) -> int:
	return 8 + wave * 3

static func shop_price(base_price: int, wave: int) -> int:
	return int(round(float(base_price) * (1.0 + 0.08 * (wave - 1))))
