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

## 武器：dmg 基础伤害，cd 基础冷却秒；近战用 range / swing_arc
## evolve_need：持有同名武器达到该数量，波末自动合成为 evolve_to（吸血鬼幸存者式）
const WEAPONS := {
	"pistol": { "name": "手枪", "ico": "🔫", "attack_type": "projectile", "sfx": "shoot_pistol", "cd": 0.55, "dmg": 12.0, "bspeed": 540.0, "rarity": "common", "evolve_need": 4, "evolve_to": "pistol_ex", "desc": "稳定单体远程" },
	"smg": { "name": "冲锋枪", "ico": "💢", "attack_type": "projectile", "sfx": "shoot_smg", "cd": 0.16, "dmg": 5.0, "bspeed": 600.0, "spread": 0.13, "rarity": "rare", "evolve_need": 4, "evolve_to": "smg_ex", "desc": "极快射速，轻微散射" },
	"shotgun": { "name": "霰弹枪", "ico": "💥", "attack_type": "projectile", "sfx": "shoot_shotgun", "cd": 0.90, "dmg": 7.0, "bspeed": 480.0, "pellets": 5, "arc": 0.7, "bullet_life": 0.55, "shake": 2.0, "rarity": "rare", "evolve_need": 3, "evolve_to": "shotgun_ex", "desc": "一次射出5发扇形弹丸" },
	"knife": { "name": "砍刀", "ico": "🔪", "attack_type": "melee", "sfx": "shoot_knife", "cd": 0.38, "dmg": 16.0, "range": 82.0, "swing_arc": 1.5, "status": "bleed", "status_chance": 0.30, "rarity": "common", "evolve_need": 4, "evolve_to": "blade_ex", "desc": "近战弧形挥砍，概率造成流血" },
	"rocket": { "name": "火箭筒", "ico": "🚀", "attack_type": "projectile", "sfx": "shoot_rocket", "cd": 1.30, "dmg": 34.0, "bspeed": 380.0, "splash": 88.0, "shake": 2.5, "status": "burn", "status_chance": 0.45, "rarity": "epic", "desc": "命中范围爆炸 AOE，概率点燃" },
	"sniper": { "name": "狙击枪", "ico": "🎯", "attack_type": "projectile", "sfx": "shoot_pistol", "cd": 1.55, "dmg": 58.0, "bspeed": 920.0, "bullet_life": 1.4, "shake": 1.5, "status": "bleed", "status_chance": 0.35, "rarity": "epic", "desc": "一发入魂的超远距重击，概率造成流血" },
	"blade": { "name": "太刀", "ico": "🗡", "attack_type": "melee", "sfx": "shoot_knife", "cd": 0.50, "dmg": 30.0, "range": 108.0, "swing_arc": 1.9, "status": "bleed", "status_chance": 0.45, "rarity": "epic", "desc": "大开大合的宽弧重斩，高概率造成流血" },
	# ---- 状态效果武器（数据驱动：status = Config.STATUS 键） ----
	"flamethrower": { "name": "火焰喷射器", "ico": "🔥", "attack_type": "projectile", "sfx": "shoot_smg", "cd": 0.10, "dmg": 4.0, "bspeed": 300.0, "spread": 0.34, "bullet_life": 0.34, "status": "burn", "status_chance": 0.85, "rarity": "rare", "desc": "短程火舌，高频叠加燃烧" },
	"frost_staff": { "name": "霜冻法杖", "ico": "❄", "attack_type": "projectile", "sfx": "shoot_rocket", "cd": 0.80, "dmg": 9.0, "bspeed": 420.0, "splash": 58.0, "status": "freeze", "status_chance": 0.55, "rarity": "epic", "desc": "范围冰冻定身，冻结目标受到额外伤害" },
	"venom_dagger": { "name": "毒牙匕首", "ico": "🐍", "attack_type": "melee", "sfx": "shoot_knife", "cd": 0.42, "dmg": 12.0, "range": 88.0, "swing_arc": 1.6, "status": "poison", "status_chance": 0.70, "rarity": "rare", "desc": "淬毒近战，按最大生命持续掉血" },
	# ---- 进化形态（不进商店池：shop_weight 极低但保持可注册校验；波末合成获得） ----
	"pistol_ex": { "name": "双管神射", "ico": "🔱", "attack_type": "projectile", "sfx": "shoot_pistol", "cd": 0.32, "dmg": 20.0, "bspeed": 680.0, "pellets": 2, "arc": 0.12, "rarity": "mythic", "shop_weight": 0.001, "desc": "进化：双联齐射，单发伤害 +67%" },
	"smg_ex": { "name": "蜂巢风暴", "ico": "🌪", "attack_type": "projectile", "sfx": "shoot_smg", "cd": 0.10, "dmg": 7.0, "bspeed": 640.0, "spread": 0.20, "pellets": 3, "arc": 0.5, "rarity": "mythic", "shop_weight": 0.001, "desc": "进化：三管齐喷的弹幕风暴" },
	"shotgun_ex": { "name": "毁灭炮", "ico": "💣", "attack_type": "projectile", "sfx": "shoot_shotgun", "cd": 0.75, "dmg": 12.0, "bspeed": 520.0, "pellets": 8, "arc": 1.1, "bullet_life": 0.6, "splash": 60.0, "shake": 3.0, "rarity": "legendary", "shop_weight": 0.001, "desc": "进化：8 弹丸 + 爆炸溅射" },
	"blade_ex": { "name": "斩魄刀", "ico": "⚔", "attack_type": "melee", "sfx": "shoot_knife", "cd": 0.34, "dmg": 42.0, "range": 132.0, "swing_arc": 2.4, "shake": 1.5, "rarity": "mythic", "shop_weight": 0.001, "desc": "进化：全域横扫，伤害 +162%" },
}

const WEAPON_SLOTS := 6
const WEAPON_SHOP_CHANCE := 0.42
const WEAPON_SHOP_WEIGHTS := { "pistol": 3.0, "smg": 2.4, "knife": 2.4, "shotgun": 1.6, "rocket": 0.8, "sniper": 0.7, "blade": 1.0, "flamethrower": 1.5, "frost_staff": 0.9, "venom_dagger": 1.4, "pistol_ex": 0.0, "smg_ex": 0.0, "shotgun_ex": 0.0, "blade_ex": 0.0 }
const WEAPON_PRICES := { "pistol": 25, "smg": 35, "knife": 28, "shotgun": 42, "rocket": 60, "sniper": 75, "blade": 68, "flamethrower": 52, "frost_staff": 72, "venom_dagger": 48, "pistol_ex": 30, "smg_ex": 30, "shotgun_ex": 30, "blade_ex": 30 }

## 敌人：W1 基础值；血量/伤害随波次缩放（见 wave_* 系列函数）
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
	"boss": { "name": "巨型土豆王", "hp": 768000.0, "speed": 64.0, "dmg": 28.0, "xp": 60, "mat": 100, "r": 56.0, "color": "#b01e2e", "shape": "circle", "ring_cd": 2.2, "ring_count": 16, "bspeed": 260.0, "status_resist": 0.55, "heart_chance": 1.0 },
	"boss_spiral": { "name": "深渊织网者", "hp": 640000.0, "speed": 56.0, "dmg": 24.0, "xp": 60, "mat": 100, "r": 50.0, "color": "#7a3df0", "shape": "diamond", "ring_cd": 1.6, "ring_count": 6, "bspeed": 300.0, "spiral_mode": true, "status_resist": 0.55, "heart_chance": 1.0 },
	"boss_summoner": { "name": "腐土孵化者", "hp": 560000.0, "speed": 48.0, "dmg": 22.0, "xp": 60, "mat": 100, "r": 54.0, "color": "#3d8a3d", "shape": "square", "ring_cd": 3.0, "ring_count": 10, "bspeed": 240.0, "summon_cd": 4.5, "summon_type": "swarm", "summon_count": 6, "status_resist": 0.55, "heart_chance": 1.0 },
}

## BOSS 轮换池：标准第 10 波 / 无尽每 10 波，按种子随机轮换（每日挑战全服同 BOSS）
const BOSS_POOL := ["boss", "boss_spiral", "boss_summoner"]

## BOSS id → 中文称号（HUD/横幅展示用）
const BOSS_TITLES := {
	"boss": "土豆之王 · 弹幕压制",
	"boss_spiral": "深渊织网者 · 螺旋封锁",
	"boss_summoner": "腐土孵化者 · 群海战术",
}

## 高难度精英替换池（难度 elite_chance 触发时从中抽取，W4+ 生效）
const ELITE_POOL := [
	{ "item": "guard", "w": 0.30 }, { "item": "wizard", "w": 0.30 },
	{ "item": "shadow", "w": 0.22 }, { "item": "bomber", "w": 0.18 },
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

## 今日挑战配置：{seed, character_id, difficulty_id, boss_id}（全服一致）
static func daily_setup(date_str: String) -> Dictionary:
	var h := daily_hash(date_str)
	var chars := ["potato", "berserker", "ranger", "gambler", "farmer", "vampire", "guardian"]
	var diffs := ["normal", "hard", "nightmare"]
	var pool: Array = BOSS_POOL.duplicate()
	return {
		"seed": h,
		"character_id": chars[h % chars.size()],
		"difficulty_id": diffs[(h >> 5) % diffs.size()],
		"boss_id": String(pool[(h >> 11) % pool.size()]),
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
	{ "id": "precision", "ico": "🔭", "name": "精密校准", "desc": "暴击率 +12%", "rarity": "mythic", "effects": { "crit_ch": 0.12 } },
	{ "id": "greed", "ico": "💰", "name": "贪婪之心", "desc": "材料获取 +50%", "rarity": "mythic", "effects": { "harvesting": 0.50 } },
	{ "id": "frenzy", "ico": "🎶", "name": "狂热节拍", "desc": "攻击速度 +18%", "rarity": "mythic", "effects": { "as_mult": 0.18 } },
	{ "id": "berserk", "ico": "💀", "name": "血之狂怒", "desc": "伤害 +35%", "rarity": "legendary", "effects": { "dmg_mult": 0.35 } },
	{ "id": "overdrive", "ico": "🔥", "name": "极限超频", "desc": "攻速 +25%，暴击伤害 +40%", "rarity": "legendary", "effects": { "as_mult": 0.25, "crit_mult": 0.40 } },
	{ "id": "titanheart", "ico": "🫀", "name": "泰坦心脏", "desc": "最大生命 +60（并回复 60），护甲 +3", "rarity": "legendary", "effects": { "heal_flat": 60.0, "armor": 3.0 } },
	# ---- 状态效果升级（异常流构筑） ----
	{ "id": "pyromancy", "ico": "🔥", "name": "纵火", "desc": "状态伤害 +25%", "rarity": "rare", "effects": { "status_dmg_mult": 0.25 } },
	{ "id": "lingering", "ico": "⏳", "name": "延烧", "desc": "异常持续时间 +30%", "rarity": "epic", "effects": { "status_dur_mult": 0.30 } },
	{ "id": "hex", "ico": "🕯", "name": "咒术", "desc": "异常命中率 +10%", "rarity": "epic", "effects": { "status_chance": 0.10 } },
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
	{ "id": "i-dod", "ico": "🧥", "name": "斗篷", "desc": "闪避 +8%", "price": 32, "rarity": "rare", "effects": { "dodge": 0.08 } },
	{ "id": "i-mag", "ico": "🧲", "name": "大磁铁", "desc": "拾取范围 +55", "price": 22, "rarity": "common", "effects": { "pickup_range": 55.0 } },
	{ "id": "i-reg", "ico": "💊", "name": "再生器", "desc": "生命回复 +1.0 / 秒", "price": 42, "rarity": "epic", "effects": { "regen": 1.0 } },
	{ "id": "i-harv", "ico": "💰", "name": "金币袋", "desc": "材料获取 +25%", "price": 32, "rarity": "rare", "effects": { "harvesting": 0.25 } },
	{ "id": "i-ls", "ico": "🩸", "name": "血蛭", "desc": "每击杀 1 个敌人回复 1 点生命（可叠加）", "price": 48, "rarity": "epic", "effects": { "lifesteal": 1.0 } },
	# ---- 状态效果道具（on_hit_* = 命中时施加概率；status_dmg_mult = 持续伤害加成） ----
	{ "id": "i-ember", "ico": "🔥", "name": "余烬", "desc": "命中时 20% 概率点燃（伤害随攻击力）", "price": 44, "rarity": "rare", "effects": { "on_hit_burn": 0.20 } },
	{ "id": "i-venom", "ico": "🧪", "name": "毒囊", "desc": "命中时 20% 概率使目标中毒", "price": 44, "rarity": "rare", "effects": { "on_hit_poison": 0.20 } },
	{ "id": "i-hemo", "ico": "🩸", "name": "放血针", "desc": "命中时 25% 概率造成流血", "price": 40, "rarity": "rare", "effects": { "on_hit_bleed": 0.25 } },
	{ "id": "i-frost", "ico": "❄", "name": "霜核", "desc": "命中时 12% 概率冰冻目标", "price": 58, "rarity": "epic", "effects": { "on_hit_freeze": 0.12 } },
	{ "id": "i-tar", "ico": "🕸", "name": "沥青网", "desc": "命中时 18% 概率减速目标", "price": 42, "rarity": "rare", "effects": { "on_hit_slow": 0.18 } },
	{ "id": "i-thunder", "ico": "🌩", "name": "雷击石", "desc": "命中时 8% 概率眩晕目标", "price": 66, "rarity": "epic", "effects": { "on_hit_stun": 0.08 } },
	{ "id": "i-plague", "ico": "☠", "name": "瘟疫之心", "desc": "中毒伤害 +60%，中毒目标死亡时传染", "price": 175, "rarity": "mythic", "effects": { "status_dmg_mult": 0.60, "status_spread": 1.0 } },
	{ "id": "i-pyro", "ico": "🌋", "name": "熔火核心", "desc": "状态伤害 +35%，异常持续时间 +25%", "price": 195, "rarity": "mythic", "effects": { "status_dmg_mult": 0.35, "status_dur_mult": 0.25 } },
	{ "id": "i-conductor", "ico": "⚡", "name": "异常导体", "desc": "异常命中率 +15%，状态伤害 +20%", "price": 230, "rarity": "legendary", "effects": { "status_chance": 0.15, "status_dmg_mult": 0.20 } },
	{ "id": "i-goldcore", "ico": "✨", "name": "黄金核心", "desc": "伤害 +25%，攻速 +15%", "price": 200, "rarity": "mythic", "effects": { "dmg_mult": 0.25, "as_mult": 0.15 } },
	{ "id": "i-fortress", "ico": "🏰", "name": "堡垒之心", "desc": "护甲 +6，最大生命 +45", "price": 185, "rarity": "mythic", "effects": { "armor": 6.0, "max_hp": 45.0 } },
	{ "id": "i-fortune", "ico": "🤑", "name": "财神金蟾", "desc": "材料获取 +80%，拾取范围 +80", "price": 170, "rarity": "mythic", "effects": { "harvesting": 0.80, "pickup_range": 80.0 } },
	{ "id": "i-bladesoul", "ico": "🗡", "name": "剑圣之魂", "desc": "暴击率 +15%，暴击伤害 +80%", "price": 210, "rarity": "mythic", "effects": { "crit_ch": 0.15, "crit_mult": 0.80 } },
	{ "id": "i-titan", "ico": "🏆", "name": "泰坦之力", "desc": "伤害 +45%，最大生命 +30", "price": 260, "rarity": "legendary", "effects": { "dmg_mult": 0.45, "max_hp": 30.0 } },
	{ "id": "i-gale", "ico": "🌪", "name": "风神羽靴", "desc": "移速 +35%，攻速 +30%，闪避 +10%", "price": 250, "rarity": "legendary", "effects": { "speed_mult": 0.35, "as_mult": 0.30, "dodge": 0.10 } },
	{ "id": "i-sanguine", "ico": "🧛", "name": "血族圣冠", "desc": "击杀回血 +3，生命回复 +2 / 秒", "price": 280, "rarity": "legendary", "effects": { "lifesteal": 3.0, "regen": 2.0 } },
	{ "id": "i-crown", "ico": "👑", "name": "王者桂冠", "desc": "伤害 +15%，攻速 +15%，暴击 +8%，暴伤 +50%", "price": 300, "rarity": "legendary", "effects": { "dmg_mult": 0.15, "as_mult": 0.15, "crit_ch": 0.08, "crit_mult": 0.50 } },
]

const WAVES_TOTAL := 10
const BOSS_WAVE := 10
const ENDLESS_MAX_WAVE := 9999   # 无尽模式波次上限（防溢出的护栏值）
const ENEMY_HARD_CAP := 240      # 同屏敌人绝对上限（大规模敌群性能护栏）
const HEAL_DROP_CHANCE := 0.05
const SHOP_HEAL_PRICE := 15
const SHOP_UPGRADE_CHANCE := 0.29   # 商店刷出升级属性的概率（武器 42% 之外再分摊）

## 是否 BOSS 波：标准模式 = 第 10 波；无尽炼狱 = 每 10 波一轮
static func is_boss_wave(w: int) -> bool:
	return (w % 10 == 0) if GameState.endless else (w == BOSS_WAVE)

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
static func rarity_weight(rarity: String, progress: int) -> float:
	var w := float(RARITY_BASE_WEIGHTS.get(rarity, 1.0))
	var t := maxf(0.0, float(progress - 1))
	match rarity:
		"mythic": w *= 1.0 + 0.22 * t
		"legendary": w *= 1.0 + 0.28 * t
		"epic": w *= 1.0 + 0.06 * t
	return w

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

static func wave_duration(w: int) -> float:
	return 45.0 + (w - 1) * 5.0   # 初始 45s，每波 +5s

static func wave_interval(w: int) -> float:
	return maxf(0.4, 1.0 - 0.07 * (w - 1))   # 前期刷怪更密，保证经验/材料流转

static func wave_cap(w: int) -> int:
	return 24 + w * 6

static func wave_hp_scale(w: int) -> float:
	return 1.0 + 0.30 * (w - 1)

static func wave_dmg_scale(w: int) -> float:
	return 1.0 + 0.18 * (w - 1)

static func wave_spd_scale(w: int) -> float:
	return 1.0 + minf(0.18, 0.015 * (w - 1))

static func xp_need(level: int) -> int:
	return 4 + (level - 1) * 3

## 刷怪权重组合：[{ "item": 敌人类型, "w": 权重 }]
## w >= 10 仅无尽模式可达：精英占比随波次渐进上升（波 10 → 30 逐步拉满）
static func wave_composition(w: int) -> Array:
	if w <= 1:
		return [{ "item": "grunt", "w": 0.72 }, { "item": "swarm", "w": 0.28 }]
	if w == 2:
		return [{ "item": "grunt", "w": 0.42 }, { "item": "swarm", "w": 0.28 }, { "item": "runner", "w": 0.30 }]
	if w == 3:
		return [{ "item": "grunt", "w": 0.32 }, { "item": "swarm", "w": 0.20 }, { "item": "runner", "w": 0.26 }, { "item": "tank", "w": 0.22 }]
	if w <= 5:
		return [{ "item": "grunt", "w": 0.26 }, { "item": "swarm", "w": 0.14 }, { "item": "runner", "w": 0.24 },
			{ "item": "tank", "w": 0.16 }, { "item": "shooter", "w": 0.20 }]
	if w <= 7:
		return [{ "item": "grunt", "w": 0.18 }, { "item": "swarm", "w": 0.10 }, { "item": "runner", "w": 0.22 },
			{ "item": "tank", "w": 0.14 }, { "item": "shooter", "w": 0.16 }, { "item": "bomber", "w": 0.10 },
			{ "item": "wizard", "w": 0.10 }]
	if w <= 9:
		return [{ "item": "grunt", "w": 0.12 }, { "item": "swarm", "w": 0.07 }, { "item": "runner", "w": 0.20 },
			{ "item": "tank", "w": 0.14 }, { "item": "shooter", "w": 0.15 }, { "item": "bomber", "w": 0.11 },
			{ "item": "wizard", "w": 0.10 }, { "item": "shadow", "w": 0.07 }, { "item": "guard", "w": 0.04 }]
	# 无尽后期（w >= 10）：难度随波次上升，精英比重逐步拉满
	var t := minf(1.0, float(w - 9) / 21.0)
	return [{ "item": "grunt", "w": 0.14 - 0.06 * t }, { "item": "swarm", "w": 0.06 },
		{ "item": "runner", "w": 0.18 }, { "item": "tank", "w": 0.14 + 0.02 * t },
		{ "item": "shooter", "w": 0.14 }, { "item": "bomber", "w": 0.10 + 0.04 * t },
		{ "item": "wizard", "w": 0.10 + 0.05 * t }, { "item": "shadow", "w": 0.08 + 0.05 * t },
		{ "item": "guard", "w": 0.06 + 0.08 * t }]

# ---- 商店公式 ----

static func shop_reroll_cost(wave: int) -> int:
	return 8 + wave * 3

static func shop_price(base_price: int, wave: int) -> int:
	return int(round(float(base_price) * (1.0 + 0.08 * (wave - 1))))
