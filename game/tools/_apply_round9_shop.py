# -*- coding: utf-8 -*-
"""第 9 轮 · 需求 3：商店刷新倾向性（非幂等：重跑只会安全失败，不会二次污染）。

改动：
  config.gd    —— 新增 4 个常量 + `is_assim_entry()` 判据
  player.gd    —— 新增 `weapon_side_saturated()`（武器侧已无处可升）
  shop_ui.gd   —— 已持有武器加权 / 同化度保底 / 让出的份额锁定给升级池

规则：每处 (old, new) 断言 old 在全文命中恰好 1 次，全部通过才写盘。
"""
import io
import os
import sys

ROOT = r"D:\code\firstProject-ai\TheGreatestProject"
FILES = {
    "config": os.path.join(ROOT, "game", "scripts", "core", "config.gd"),
    "player": os.path.join(ROOT, "game", "scripts", "characters", "player.gd"),
    "shop": os.path.join(ROOT, "game", "scripts", "ui", "shop_ui.gd"),
}


def rd(p):
    with io.open(p, encoding="utf-8", newline="") as f:
        return f.read()


def wr(p, s):
    with io.open(p, "w", encoding="utf-8", newline="") as f:
        f.write(s)


def apply(text, edits, tag):
    for i, (old, new) in enumerate(edits):
        n = text.count(old)
        if n != 1:
            print("FAIL %s #%d 命中 %d 次（要求 1）" % (tag, i, n))
            print("   old[:160]=%r" % (old[:160],))
            return None
        text = text.replace(old, new, 1)
        print("  ok %s #%d" % (tag, i))
    return text


# ============================================================ config.gd
cfg_edits = []

cfg_edits.append((
    "const SHOP_UPGRADE_CHANCE := 0.29   # 商店刷出升级属性的概率（武器 42% 之外再分摊）\n",
    "const SHOP_UPGRADE_CHANCE := 0.29   # 商店刷出升级属性的概率（武器 42% 之外再分摊）\n"
    "\n"
    "## ---- 商店刷新倾向性（第 9 轮 · 用户要求）----\n"
    "## 意图：别让「与构筑无关的道具」挤占货架，核心构筑件（武器 / 同化度）该来的时候要来。\n"
    "## 三条规则各自独立，全部只在 shop_ui 的抽取路径上生效，不改任何结算。\n"
    "\n"
    "## 1. 倾向已有武器：买到同名武器的权重 ×该倍率 —— 进化要 3 把同名，\n"
    "##    不加权的话「凑 3 把」在 5 把武器 × 6 格里几乎不可期。\n"
    "const SHOP_OWNED_WEAPON_MULT := 3.0\n"
    "## 2. 同化度保底：某次刷新整店没出同化度 → 下次其权重 ×(1 + step × 连续落空店数)，\n"
    "##    刷到一次立刻归零重算；倍率本身封顶（否则连着十几店空手会概率失控）。\n"
    "const SHOP_ASSIM_PITY_STEP := 0.35\n"
    "const SHOP_ASSIM_PITY_MAX := 3      # 倍率上限（1 + 0.35×3 = 2.05×）\n"
    "## 连续落空到该店数时**直接塞一格**同化度（0 = 只加权、不做硬保底）\n"
    "const SHOP_ASSIM_FORCE_AT := 3\n"
    "## 3. 武器侧「已无处可升」时的武器概率比例。\n"
    "##    ⚠️ 两个常量都刻意留 0，但要**分层**：满槽时买武器会被 `buy()` 拦下（死格），\n"
    "##       所以不刷；将来若要放开「满槽也能买同名凑进化」，只需改其中一个值。\n"
    "##    ⚠️ 关键不在「降到多少」，而在**让出的份额去哪**：见 shop_ui._roll_one ——\n"
    "##       腾出的比例**全部并进升级池**，不流向普通道具。这是「道具挤占核心构筑件」的根治点。\n"
    "const WEAPON_CHANCE_SLOTS_FULL := 0.0    # 满槽（买了会被拦 = 死格）\n"
    "const WEAPON_CHANCE_SATURATED := 0.0     # 武器侧饱和（满槽 + 全是进化体）\n"
    "\n"
    "## 同化度类条目的唯一稳定判据：`effects` 里带 `assim_*` 键。\n"
    "## ⚠️ 别去比 id 前缀 —— 同化度横跨两套命名：道具是 `i-assim-*`，升级是 `wu_*`，\n"
    "##    按前缀判会**静默漏掉升级那一支**（池子看着还有货，保底却永远刷不到）。\n"
    "static func is_assim_entry(e: Dictionary) -> bool:\n"
    "\tfor k in e.get(\"effects\", {}):\n"
    "\t\tif String(k).begins_with(\"assim_\"):\n"
    "\t\t\treturn true\n"
    "\treturn false\n",
))

# ============================================================ player.gd
pl_edits = []

pl_edits.append((
    "## 下一个进化目标名（多分支时优先「尚未持有」的方向），供商店/图鉴提示；无进化返回空串\n",
    "## 武器侧「已无处可升」：槽位已满、没有还能凑满 3 把的基础武器、且每把都是进化体。\n"
    "## 用途：商店据此降低武器刷新概率（把货架让给同化度 / 升级这类还能提升的构筑件）。\n"
    "## ⚠️ 别写成「槽位满就算饱和」—— 满槽但手里还有 2 把基础武器时，波末仍会进化，\n"
    "##    那时把武器刷率砍掉会把「凑第 3 把」的最后机会一起砍掉。\n"
    "func weapon_side_saturated() -> bool:\n"
    "\tif weapons.size() < MetaProgress.weapon_slots():\n"
    "\t\treturn false\n"
    "\tif not evolve_progress().is_empty():\n"
    "\t\treturn false   # 还有能凑到 3 把再进化的基础武器\n"
    "\tfor w in weapons:\n"
    "\t\tif not _is_evolved_form(String(w.type)):\n"
    "\t\t\treturn false\n"
    "\treturn true\n"
    "\n"
    "## 下一个进化目标名（多分支时优先「尚未持有」的方向），供商店/图鉴提示；无进化返回空串\n",
))

# ============================================================ shop_ui.gd
sh_edits = []

# (1) 成员变量：同化度保底状态
sh_edits.append((
    "var _save_dirty := false    # 有未落盘的商店操作\n"
    "var _save_pending := false  # 合并写定时器已排队\n",
    "var _save_dirty := false    # 有未落盘的商店操作\n"
    "var _save_pending := false  # 合并写定时器已排队\n"
    "var _assim_pity := 0        # 连续「整店没出同化度」的店数，刷到即归零（第 9 轮保底）\n"
    "var _forced_assim := false  # 本店是否由同化度保底塞了一格（测试观测，同 forced_synergy）\n",
))

# (2) 抽完一轮的收尾：先同化度保底，没触发才走亲和保底
sh_edits.append((
    "	goods = []\n"
    "	_affinity_cache.clear()   # 开店时重算一次构筑亲和（本店期间武器/法宝不会变）\n"
    "	var weapon_full: bool = player.weapons.size() >= MetaProgress.weapon_slots()\n"
    "	for _i in Config.SHOP_SLOTS:\n"
    "		goods.append(_roll_one(weapon_full))\n"
    "	_ensure_affinity_goods()\n",
    "	goods = []\n"
    "	_affinity_cache.clear()   # 开店时重算一次构筑亲和（本店期间武器/法宝不会变）\n"
    "	var weapon_full: bool = player.weapons.size() >= MetaProgress.weapon_slots()\n"
    "	for _i in Config.SHOP_SLOTS:\n"
    "		goods.append(_roll_one(weapon_full))\n"
    "	_after_roll()\n"
    "\n"
    "## 一轮抽取后的收尾（第 9 轮）。两个保底都只抢「最后一格」，所以必须互斥 ——\n"
    "## 后跑的那个会把前一个刚塞进去的换掉，表现为「保底明明该触发却没生效」。\n"
    "## 顺序：同化度保底优先（它带连续落空计数，是更强的承诺），未触发才轮到亲和保底。\n"
    "func _after_roll() -> void:\n"
    "	_forced_assim = false\n"
    "	var has_assim := false\n"
    "	for g in goods:\n"
    "		if _is_assim_good(g):\n"
    "			has_assim = true\n"
    "			break\n"
    "	if has_assim:\n"
    "		_assim_pity = 0\n"
    "	else:\n"
    "		_assim_pity += 1\n"
    "		if Config.SHOP_ASSIM_FORCE_AT > 0 and _assim_pity >= Config.SHOP_ASSIM_FORCE_AT:\n"
    "			_forced_assim = _force_assim_slot()\n"
    "	if not _forced_assim:\n"
    "		_ensure_affinity_goods()\n"
    "\n"
    "## 同化度倾向倍率：连续落空越多越容易出（刷到一次即归零）\n"
    "func _assim_weight_mult() -> float:\n"
    "	return 1.0 + Config.SHOP_ASSIM_PITY_STEP * float(mini(_assim_pity, Config.SHOP_ASSIM_PITY_MAX))\n"
    "\n"
    "## 货架项是不是「同化度」类。武器与法宝天然不是（它们没有 effects）。\n"
    "func _is_assim_good(g: Dictionary) -> bool:\n"
    "	return Config.is_assim_entry(_good_entry(g))\n"
    "\n"
    "## 从货架项反查注册表条目（武器走 wtype，升级/道具走 id，法宝走 artifacts）\n"
    "func _good_entry(g: Dictionary) -> Dictionary:\n"
    "	match String(g.get(\"kind\", \"\")):\n"
    "		\"weapon\":\n"
    "			return Registry.weapons.get(String(g.get(\"wtype\", \"\")), {})\n"
    "		\"upgrade\":\n"
    "			return Registry.upgrades.get(String(g.get(\"id\", \"\")), {})\n"
    "		\"item\":\n"
    "			return Registry.items.get(String(g.get(\"id\", \"\")), {})\n"
    "	return {}\n"
    "\n"
    "## 同化度保底：连续 N 店没出同化度时，把最后一个未锁定格换成同化度条目。\n"
    "## 池子取「升级 + 道具」两条（同化度两套 id 分别落在两边，见 Config.is_assim_entry）；\n"
    "## 金/红唯一件与对当前武器无用的条目照旧被闸门挡掉。返回 true = 本店已塞入。\n"
    "func _force_assim_slot() -> bool:\n"
    "	if goods.is_empty():\n"
    "		return false\n"
    "	var idx := goods.size() - 1\n"
    "	if bool(goods[idx].get(\"locked\", false)) or bool(goods[idx].get(\"sold\", false)):\n"
    "		return false\n"
    "	var taken := {}\n"
    "	for g in goods:\n"
    "		taken[String(g.get(\"id\", \"\"))] = true\n"
    "	var pool: Array = []\n"
    "	for u in Registry.upgrade_list():\n"
    "		if taken.has(String(u.get(\"id\", \"\"))):\n"
    "			continue\n"
    "		if not Config.is_assim_entry(u):\n"
    "			continue\n"
    "		if not Config.unique_pool_ok(u, player.upgrades_owned):\n"
    "			continue\n"
    "		pool.append({ \"item\": u,\n"
    "			\"w\": Config.rarity_weight(String(u.get(\"rarity\", \"common\")), _wave) })\n"
    "	for it in Registry.item_list():\n"
    "		if taken.has(String(it.get(\"id\", \"\"))):\n"
    "			continue\n"
    "		if not Config.is_assim_entry(it):\n"
    "			continue\n"
    "		if not Config.unique_pool_ok(it, player.items_owned):\n"
    "			continue\n"
    "		pool.append({ \"item\": it, \"w\": Config.rarity_weight(String(it.get(\"rarity\", \"common\")), _wave) })\n"
    "	if pool.is_empty():\n"
    "		return false\n"
    "	# 同 _ensure_affinity_goods：weighted_pick 返回的是 entry.item（条目本身），\n"
    "	# 所以 kind 只能靠条目归属反查，别指望从池里带出来\n"
    "	var e: Dictionary = GameRng.weighted_pick(pool)\n"
    "	if e.is_empty():\n"
    "		return false\n"
    "	var kind := \"upgrade\" if Registry.upgrades.has(String(e.get(\"id\", \"\"))) else \"item\"\n"
    "	goods[idx] = {\n"
    "		\"kind\": kind, \"id\": e.id, \"ico\": e.ico, \"name\": e.name,\n"
    "		\"desc\": e.desc, \"rarity\": e.get(\"rarity\", \"common\"),\n"
    "		\"base_price\": int(e.get(\"price\", 22)),\n"
    "		\"synergy\": _synergy(e), \"sold\": false, \"locked\": false,\n"
    "		\"forced_assim\": true,   # 测试观测：这一格是同化度保底塞进来的\n"
    "	}\n"
    "	return true\n"
    "\n"
    "## 武器出现概率的折扣系数（1.0 = 原样）。满槽 → 买不了（`buy()` 会拦）= 死格，\n"
    "## 武器侧饱和（满槽 + 全是进化体）另给一档，便于以后只放开其中一个。\n"
    "## ⚠️ 刻意不在这两个分支之间留「部分降权」：满槽时无论是哪种，格子里放武器都是浪费。\n"
    "func _weapon_chance_ratio(weapon_full: bool) -> float:\n"
    "	if not weapon_full:\n"
    "		return 1.0\n"
    "	if player != null and is_instance_valid(player) and player.weapon_side_saturated():\n"
    "		return Config.WEAPON_CHANCE_SATURATED\n"
    "	return Config.WEAPON_CHANCE_SLOTS_FULL\n"
    "\n"
    "## 商店武器池：与 Registry.shop_weapon_pool() 同一口径，额外给**已持有的同名武器**加权。\n"
    "## 只在商店侧加权，不改注册表 —— Registry.shop_weapon_pool 还有别的调用方（main 的发武器），\n"
    "## 在那里改语义会连带影响「事件卡送武器」这类路径。\n"
    "## ⚠️ 不能顺手把进化体 weight 改掉：`shop_weight == 0` 是「不进商店池」的既有契约，\n"
    "##    冒烟专门钉过这一条。\n"
    "func _shop_weapon_pool() -> Array:\n"
    "	var pool: Array = Registry.shop_weapon_pool()\n"
    "	var owned := {}\n"
    "	for w in player.weapons:\n"
    "		owned[String(w.type)] = true\n"
    "	if owned.is_empty():\n"
    "		return pool\n"
    "	for e in pool:\n"
    "		if owned.has(String(e.get(\"item\", \"\"))):\n"
    "			e[\"w\"] = float(e.get(\"w\", 1.0)) * Config.SHOP_OWNED_WEAPON_MULT\n"
    "	return pool\n",
))

# (3) 稀有度池：同化度加权（函数签名保持不变 —— 冒烟以精确参数直调它）
sh_edits.append((
    "		var w: float = Config.rarity_weight(String(e.get(\"rarity\", \"common\")), _wave) \\\n"
    "			* Config.affinity_mult(Config.entry_tags(e), aff)\n"
    "		pool.append({ \"item\": e, \"w\": w })\n",
    "		var w: float = Config.rarity_weight(String(e.get(\"rarity\", \"common\")), _wave) \\\n"
    "			* Config.affinity_mult(Config.entry_tags(e), aff)\n"
    "		if Config.is_assim_entry(e):\n"
    "			w *= _assim_weight_mult()   # 连续没刷到 → 越刷越容易出（第 9 轮）\n"
    "		pool.append({ \"item\": e, \"w\": w })\n",
))

# (4) 武器格：用折扣后的概率 + 加权池；让出的份额并进升级池
sh_edits.append((
    "	var r := GameRng.range_f(0.0, 1.0)\n"
    "	if not weapon_full and r < Config.WEAPON_SHOP_CHANCE:\n"
    "		var wt: String = GameRng.weighted_pick(Registry.shop_weapon_pool())\n",
    "	var r := GameRng.range_f(0.0, 1.0)\n"
    "	# 武器概率与「让出的份额去哪」在这里一次算清（第 9 轮）：\n"
    "	# 满槽 / 武器侧饱和时武器概率降为 0，**腾出的比例全部并进升级池**（wch + uch 恒等于\n"
    "	# 原来的 0.42 + 0.29），而不是流向普通道具 —— 这才是「道具挤占核心构筑件」的根治点。\n"
    "	var wch := Config.WEAPON_SHOP_CHANCE * _weapon_chance_ratio(weapon_full)\n"
    "	var uch := Config.SHOP_UPGRADE_CHANCE + (Config.WEAPON_SHOP_CHANCE - wch)\n"
    "	if r < wch:\n"
    "		var wt: String = GameRng.weighted_pick(_shop_weapon_pool())\n",
))

sh_edits.append((
    "	if r < Config.WEAPON_SHOP_CHANCE + Config.SHOP_UPGRADE_CHANCE:\n",
    "	if r < wch + uch:\n",
))

# (5) 刷新也走同一套收尾（原来重掷不过亲和保底，同化度保底同样不能漏）
sh_edits.append((
    "		else:\n"
    "			goods.append(_roll_one(weapon_full))\n"
    "	_refresh()\n",
    "		else:\n"
    "			goods.append(_roll_one(weapon_full))\n"
    "	_after_roll()\n"
    "	_refresh()\n",
))

# ============================================================ 执行
ok = True
for tag, edits in [("config", cfg_edits), ("player", pl_edits), ("shop", sh_edits)]:
    p = FILES[tag]
    src = rd(p)
    out = apply(src, edits, tag)
    if out is None:
        ok = False
        print("%s NOT WRITTEN" % tag)
        continue
    wr(p, out)
    print("%s: %d -> %d chars (已写盘)" % (tag, len(src), len(out)))

print("DONE" if ok else "FAILED")
sys.exit(0 if ok else 1)
