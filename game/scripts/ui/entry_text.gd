extends RefCounted
class_name EntryText
## EntryText —— 条目文案的**唯一真值来源**（第 8 轮新增）
##
## 【为什么要有这个文件】
## 用户需求：「悬浮属性名称看到属性具体描述，点击道具名称看到道具加成和描述」。
## 于是「效果字典 → 中文」这件事要在**三处**同时出现：
##   1. 图鉴详情（codex.gd，原本唯一实现）
##   2. 商店商品卡的点击详情（shop_ui.gd，第 8 轮新增）
##   3. 暂停面板的已购道具点击详情（main.gd，第 8 轮新增）
##
## ⚠️ 如果各写一份，新增一个效果键（例：第 8 轮的 `throw_speed_bonus`）就要改三遍，
##    漏一处**不会报错**，只是那一处永远显示成 `throw_speed_bonus +0.20` 的裸键名 ——
##    又是本项目最典型的「静默算错」。所以收敛到这里，其余两处只做调用。
##
## 【属性说明表按「显示名」索引，而不是内部键】
## 侧栏属性行（`_stat_row("攻速", "x1.20")`）手上只有**显示名**，没有内部键。
## 与其把 13 个调用点全改成带键的重载（改漏一个就少一个悬浮说明，且同样不报错），
## 不如直接按显示名建表 —— 表就是给玩家看的，键就是玩家看到的字。
## ⚠️ 代价：写错一个字（"攻击速度" vs "攻速"）会静默失效。
##    ⚠️ 本条注释曾写「冒烟里有 `_check_stat_help()` 双向钉死」—— 第 11 轮核实：
##    该用例**已不存在**（全仓 grep `stat_help` 只剩 3 个调用点，没有任何断言）。
##    也就是说现在**没有东西在守这张表**，加/改键之后请自己核对调用点的显示名。
##    表本身保持**全集**（单一真值来源，不随 UI 口味增删）；
##    「哪些属性才值得弹悬浮」由调用点按 `HOVER_HELP` 决定。

## ---------------- 属性说明（显示名 → 一句话解释）----------------
## 口径来源（写说明时逐条回源码核对，别凭印象）：
##   攻速 `cd / as_mult`（player.gd:237）· 暴击上限 `Config.CRIT_CHANCE_CAP`
##   护甲递减曲线 + 穿甲 `armor *= (1-pierce)` · 同化度 `Config.hit_mult / out_mult`
const STAT_HELP := {
	"生命": "当前生命 / 上限。归零即阵亡；由最大生命、回复与减伤共同决定。",
	"武器": "已持有武器数 / 武器槽上限。同一把武器可叠加持有，各自独立开火 —— 拿 3 把就是 3 份输出。",
	"伤害": "全部武器伤害的乘数（面板伤害 × 此倍率）。",
	"攻速": "攻击速度倍率：**武器冷却 = 面板冷却 ÷ 此倍率**，所以它是一条线性输出乘数（对带溅射的群伤武器收益更大）。",
	"移速": "基础移速 × 移速倍率，单位 px/秒。",
	"暴击率": "每次命中判定暴击的概率，上限 90%。",
	"暴击伤害": "暴击时的伤害倍率（基线 2.00 = 200%）。",
	"护甲": "降低受到的伤害，但走递减曲线 —— 越高每点收益越低；可被敌人的穿甲削弱。",
	"闪避": "受击时完全免伤的概率（上限 95%）。",
	"拾取范围": "自动吸取材料与经验的半径（px）。",
	"回复": "每秒自动恢复的生命值。",
	"收获率": "击杀掉落材料的加成（+X%）。",
	"吸血": "每次击杀恢复的生命值。",
	"五行同化": "同化度是**双向**的：① 挨该元素的打 → 按「受击侧」减伤；② 用该元素打人 → 按「输出侧」增伤。⚠️ 两条通道都要求**角色自身有五行属性**（player.gd:813 / player.gd:502），白板角色堆同化度不生效。",
	"异常强化": "分三项：异常伤害倍率 / 异常持续时长 / 命中时施加异常的概率。",
}

## 五行同化行的后缀：`"　金同化"` → 用表头那条说明
const ASSIM_SUFFIX := "同化"

## ---- 悬浮粒度：只有「不看说明就不知道」的属性才弹气泡 ----
## 用户第 11 轮原话：「基础属性，比如说血量，攻击，攻速这种，不需要描述的就不用悬浮显示，
## 同化度，异常状态之类的，就应该有」。于是把「表里有说明」与「界面上值得弹」拆开：
##   · `STAT_HELP` 保持**全集**（单一真值来源）；
##   · 弹不弹由这里决定 —— 只留三类字面看不懂的（武器 = 同名可叠各自开火 / 同化度 = 双向 /
##     异常强化 = 三项合成一个数字）。
## 刻意**不**收进来的（自解释，弹了只是噪音）：生命 / 伤害 / 攻速 / 移速 / 暴击率 /
##   暴击伤害 / 护甲 / 闪避 / 拾取范围 / 回复 / 收获率 / 吸血。
const HOVER_HELP := ["武器", "五行同化", "异常强化"]

## 该显示名是否值得弹悬浮说明（`"　金同化"` 这类带前缀的行算作「五行同化」）。
static func needs_help(display_name: String) -> bool:
	var key := display_name.strip_edges()
	if key in HOVER_HELP:
		return true
	return key.ends_with(ASSIM_SUFFIX) and HOVER_HELP.has("五行同化")

## 按显示名取说明。取不到返回空串（调用方据此决定不挂悬浮）。
## 前缀兜底：`"　金同化"` / `"金同化"` 这类带全角空格与元素名的行，落到「五行同化」那条。
static func stat_help(display_name: String) -> String:
	var key := display_name.strip_edges()
	if STAT_HELP.has(key):
		return String(STAT_HELP[key])
	if key.ends_with(ASSIM_SUFFIX):
		return String(STAT_HELP["五行同化"])
	return ""

## ---------------- 效果字典 → 中文行 ----------------
## 图鉴 / 商店 / 暂停三处共用。新增效果键**只改这里**。
##
## ⚠️ `match` 的分支头必须比 `match` 深一级（本项目踩过：同级会让整个脚本
##    `Parse Error`，并连锁让引用它的脚本一起加载失败，表象完全不像缩进错）。
static func effect_lines(effects: Dictionary) -> Array:
	var out: Array = []
	for k in effects:
		var key := String(k)
		var v := float(effects[k])
		match key:
			"max_hp": out.append("最大生命 +%.0f" % v)
			"regen": out.append("生命回复 +%.1f / 秒" % v)
			"armor": out.append("护甲 +%.0f" % v)
			"dodge": out.append("闪避 +%d%%" % roundi(v * 100.0))
			"dmg_mult": out.append("伤害 +%d%%" % roundi(v * 100.0))
			"as_mult": out.append("攻速 +%d%%" % roundi(v * 100.0))
			"crit_ch": out.append("暴击率 +%d%%" % roundi(v * 100.0))
			"crit_mult": out.append("暴击伤害 +%d%%" % roundi(v * 100.0))
			"speed_mult": out.append("移速 +%d%%" % roundi(v * 100.0))
			"base_speed": out.append("基础移速 +%.0f" % v)
			"pickup_range": out.append("拾取范围 +%.0f" % v)
			"harvesting": out.append("收获率 +%d%%" % roundi(v * 100.0))
			"lifesteal": out.append("击杀回复 +%.0f" % v)
			"heal_flat": out.append("最大生命 +%.0f（并立即回复）" % v)
			"heal_pct": out.append("立即回复最大生命 %d%%" % roundi(v * 100.0))
			"status_chance": out.append("异常命中率 +%d%%" % roundi(v * 100.0))
			"status_dmg_mult": out.append("状态伤害 +%d%%" % roundi(v * 100.0))
			"status_dur_mult": out.append("异常时长 +%d%%" % roundi(v * 100.0))
			"status_spread": out.append("中毒目标死亡时传染")
			"melee_range_bonus": out.append("斩击范围 +%d%%（近战）" % roundi(v * 100.0))
			"bullet_speed_bonus": out.append("子弹速度 +%d%%（弹幕武器）" % roundi(v * 100.0))
			"bullet_range_bonus": out.append("弹丸射程 +%d%%（弹幕武器）" % roundi(v * 100.0))
			"throw_speed_bonus": out.append("投掷物飞行速度 +%d%%（土质炸弹 / 厚土雷）" % roundi(v * 100.0))
			"throw_range_bonus": out.append("投掷物飞行距离 +%d%%（土质炸弹 / 厚土雷）" % roundi(v * 100.0))
			"aoe_radius_bonus": out.append("爆炸范围 +%d%%（带溅射的武器）" % roundi(v * 100.0))
			"low_hp_dmg_bonus": out.append("残血增伤 最高 +%d%%（越残血越强）" % roundi(v * 100.0))
			"momentum_dmg_bonus": out.append("战意增伤 +%d%%（按本波击杀累积）" % roundi(v * 100.0))
			_:
				if key.begins_with("on_hit_"):
					var sid := key.trim_prefix("on_hit_")
					var st: Dictionary = Config.status_cfg(sid)
					if not st.is_empty():
						out.append("命中 %d%% 施加%s（同类可叠加，概率相加）"
							% [roundi(v * 100.0), String(st.get("name", sid))])
					else:
						out.append("%s +%d%%" % [key, roundi(v * 100.0)])
				elif key.begins_with("assim_"):
					var eid := key.trim_prefix("assim_")
					out.append("%s同化度 +%d%%（受击减伤 ↑ / 输出增伤 ↑）"
						% [String(Config.ELEMENT_NAME.get(eid, eid)), roundi(v * 100.0)])
				else:
					out.append("%s +%.2f" % [key, v])
	return out

## 效果行拼成一行（商店卡 / 悬浮气泡用；图鉴用 `effect_lines` 逐行显示）
static func effect_summary(effects: Dictionary) -> String:
	var lines := effect_lines(effects)
	if lines.is_empty():
		return ""
	return "、".join(lines)

## ---------------- 条目详情（点击道具名时弹的那张卡）----------------
## 返回 { "title": String, "body": String }。
## `kind` 只用于抬头那一行的「类别」，取值：道具 / 升级 / 武器 / 法宝。
static func entry_detail(data: Dictionary, kind: String) -> Dictionary:
	if data.is_empty():
		return { "title": "（条目已失效）", "body": "该条目已不存在（可能来自已停用的 mod）。" }
	var title := "%s %s" % [String(data.get("ico", "❓")), String(data.get("name", ""))]
	var rows: Array = []
	rows.append("类别：%s" % kind)
	rows.append("稀有度：%s" % Config.rarity_name(String(data.get("rarity", "common"))))
	if data.has("price"):
		rows.append("价格：%d ◆" % int(data.get("price", 0)))
	var eff := effect_summary(data.get("effects", {}))
	if eff != "":
		rows.append("")
		rows.append("加成：")
		for ln in effect_lines(data.get("effects", {})):
			rows.append("· " + String(ln))
	else:
		rows.append("")
		rows.append("加成：无属性效果（触发式 / 见下方描述）")
	var desc := String(data.get("desc", ""))
	if desc != "":
		rows.append("")
		rows.append("描述：%s" % desc)
	# 武器补一行射程口径 —— 玩家最需要它，而「射程」在本项目是算出来的（reach = bspeed×life+26）
	if kind == "武器":
		var splash := float(data.get("splash", 0.0))
		var reach := float(data.get("bspeed", 0.0)) * float(data.get("bullet_life", 1.1)) + 26.0
		if String(data.get("attack_type", "projectile")) == "melee":
			reach = float(data.get("range", 0.0))
		var thrown := String(data.get("proj_kind", "bullet")) == "thrown"
		rows.append("射程：%.0fpx%s" % [reach, "（有效 %.0fpx = 射程 + 溅射）" % (reach + splash) if splash > 0.0 else ""])
		rows.append("加成通道：%s" % ("投掷类（不吃弹速/射程）" if thrown else "弹幕类（不吃投掷类）"))
	return { "title": title, "body": "\n".join(rows) }
