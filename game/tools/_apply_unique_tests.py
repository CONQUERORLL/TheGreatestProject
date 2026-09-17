# -*- coding: utf-8 -*-
"""给「金/红唯一件」补冒烟断言。

断言纪律（见项目 MEMORY）：
  ① 样本从 Registry 扫出来，不硬编码 id
  ② 每条正向断言配反向对照（common 必须仍在池里 / 仍可叠加），防空池假绿
  ③ 探针全程可还原，不给后面的用例留脏状态
"""
import sys

SMOKE = r"D:/code/firstProject-ai/TheGreatestProject/game/tests/smoke_test.gd"

FUNC = '''## 第 7 轮：金（mythic）/ 红（legendary）= 「唯一件」——升级 / 道具全来源本局各限 1 件
## （事件卡**本身**已有排重，见 ⑧）。语义与法宝 artifacts_owned 一致，只是过去只盖住了法宝。
## ⚠️ 断言纪律：① 样本从 Registry 扫出来（不硬编码 id）；② 每条正向断言配反向对照
## （common 品阶必须仍在池里 / 仍可叠加），否则「池子空了」也会判绿；
## ③ 全程可还原 —— 现场先留档，结束前一次性还原，不给后面的用例留脏状态。
func _check_unique_items() -> void:
\tvar err := ""
\t# ① 品阶判定 + 反向对照（不能每个品阶都算唯一）
\tif not Config.is_unique_rarity("mythic") or not Config.is_unique_rarity("legendary"):
\t\terr = "唯一件：mythic / legendary 应判为唯一品阶"
\telif Config.is_unique_rarity("common") or Config.is_unique_rarity("rare") \\
\t\t\tor Config.is_unique_rarity("epic"):
\t\terr = "唯一件：common / rare / epic 不该被判为唯一品阶"

\tvar pl := _main.get_node("Player")
\tvar shop: Control = _main.get_node("UI/Shop")
\t# ② 样本（带 entry_weapon_relevant 过滤：本来就不进池的条目拿来断言会误红）
\tvar mid := ""
\tvar pid := ""
\tfor it in Registry.item_list():
\t\tif not Config.entry_weapon_relevant(it, pl.weapons):
\t\t\tcontinue
\t\tif mid == "" and Config.is_unique_rarity(String(it.get("rarity", "common"))):
\t\t\tmid = String(it.get("id", ""))
\t\telif pid == "" and String(it.get("rarity", "common")) == "common" \\
\t\t\t\tand not it.get("effects", {}).is_empty():
\t\t\tpid = String(it.get("id", ""))
\tvar uid := ""
\tvar puid := ""
\tfor u in Registry.upgrade_list():
\t\tif not Config.entry_weapon_relevant(u, pl.weapons):
\t\t\tcontinue
\t\tif uid == "" and Config.is_unique_rarity(String(u.get("rarity", "common"))):
\t\t\tuid = String(u.get("id", ""))
\t\telif puid == "" and String(u.get("rarity", "common")) == "common":
\t\t\tpuid = String(u.get("id", ""))
\tif err == "" and (mid == "" or pid == "" or uid == "" or puid == ""):
\t\terr = "唯一件：样本不足（金道具=%s / common 道具=%s / 金红升级=%s / common 升级=%s）" \\
\t\t\t% [mid, pid, uid, puid]

\t# ③ 现场留档
\tvar s_stats: Dictionary = pl.stats.duplicate()
\tvar s_items: Dictionary = pl.items_owned.duplicate()
\tvar s_ups: Dictionary = pl.upgrades_owned.duplicate()
\tvar s_mats: int = GameState.materials

\tif err == "":
\t\t# ④ 池闸门（道具）：持有金道具后必须从池里消失，而 common 道具仍在
\t\tpl.items_owned = { mid: 1 }
\t\tvar has_mid := false
\t\tvar has_pid := false
\t\tfor e in shop._rarity_pool(Registry.item_list(), pl.items_owned):
\t\t\tvar eid := String(e.get("item", {}).get("id", ""))
\t\t\tif eid == mid:
\t\t\t\thas_mid = true
\t\t\telif eid == pid:
\t\t\t\thas_pid = true
\t\tif has_mid:
\t\t\terr = "唯一件：已持有的金道具 %s 仍出现在道具抽取池" % mid
\t\telif not has_pid:
\t\t\terr = "唯一件：common 道具 %s 被误剔出池（反向对照失败）" % pid

\tif err == "":
\t\t# ⑤ 硬闸门（道具）：第二次 apply_item 必须被拒，且 stats 一个键都不能动
\t\tpl.items_owned = {}
\t\tpl.stats = s_stats.duplicate()
\t\tvar ok1: bool = pl.apply_item(mid)
\t\tvar stats1: Dictionary = pl.stats.duplicate()
\t\tvar ok2: bool = pl.apply_item(mid)
\t\tif not ok1:
\t\t\terr = "唯一件：首次 apply_item(%s) 就该成功" % mid
\t\telif ok2:
\t\t\terr = "唯一件：第二次 apply_item(%s) 应被拒（硬闸门失效）" % mid
\t\telif int(pl.items_owned.get(mid, 0)) != 1:
\t\t\terr = "唯一件：金道具 %s 持有数应为 1，实为 %d" % [mid, int(pl.items_owned.get(mid, 0))]
\t\telse:
\t\t\tfor k in stats1:
\t\t\t\tif not is_equal_approx(float(stats1[k]), float(pl.stats.get(k, 1e9))):
\t\t\t\t\terr = "唯一件：被拒的那次 apply_item 仍改动了 stats[%s]" % k
\t\t\t\t\tbreak

\tif err == "":
\t\t# ⑥ 反向对照（道具）：common 品阶必须仍能叠加
\t\tpl.items_owned = {}
\t\tvar n1: bool = pl.apply_item(pid)
\t\tvar n2: bool = pl.apply_item(pid)
\t\tvar ncnt: int = int(pl.items_owned.get(pid, 0))
\t\tif not n1 or not n2 or ncnt != 2:
\t\t\terr = "唯一件反向对照：common 道具 %s 应可叠到 2（ok=%s/%s cnt=%d）" \\
\t\t\t\t% [pid, str(n1), str(n2), ncnt]

\tif err == "":
\t\t# ⑦ 硬闸门（升级）：金红升级同理，且 upgrades_owned 要记上
\t\tpl.upgrades_owned = {}
\t\tvar u1: bool = pl.apply_upgrade(uid)
\t\tvar u2: bool = pl.apply_upgrade(uid)
\t\tvar ucnt: int = int(pl.upgrades_owned.get(uid, 0))
\t\tif not u1 or u2 or ucnt != 1:
\t\t\terr = "唯一件：金红升级 %s 应首次成功、二次被拒（ok=%s/%s cnt=%d）" \\
\t\t\t\t% [uid, str(u1), str(u2), ucnt]

\tif err == "":
\t\t# ⑧ 池闸门（升级）：同一批断言搬到升级池
\t\tpl.upgrades_owned = { uid: 1 }
\t\tvar has_u := false
\t\tvar has_pu := false
\t\tfor e2 in shop._rarity_pool(Registry.upgrade_list(), pl.upgrades_owned):
\t\t\tvar eid2 := String(e2.get("item", {}).get("id", ""))
\t\t\tif eid2 == uid:
\t\t\t\thas_u = true
\t\t\telif eid2 == puid:
\t\t\t\thas_pu = true
\t\tif has_u:
\t\t\terr = "唯一件：已获得的金红升级 %s 仍出现在升级抽取池" % uid
\t\telif not has_pu:
\t\t\terr = "唯一件：common 升级 %s 被误剔出池（反向对照失败）" % puid

\tif err == "":
\t\t# ⑨ 事件卡：**不新增机制**，钉住既有的 events_seen 排重（每张每局一次）这个约定
\t\tvar epool: Array = Config.event_card_pool([], 12)
\t\tif epool.is_empty():
\t\t\terr = "唯一件：事件卡池为空，无法校验排重"
\t\telse:
\t\t\tvar first_id := String(epool[0].get("item", {}).get("id", ""))
\t\t\tfor e3 in Config.event_card_pool([first_id], 12):
\t\t\t\tif String(e3.get("item", {}).get("id", "")) == first_id:
\t\t\t\t\terr = "唯一件：事件卡 %s 已看过却仍出现在池里" % first_id
\t\t\t\t\tbreak

\t_restore_unique_probe(pl, s_stats, s_items, s_ups, s_mats)
\tif err != "":
\t\t_fail(err)
\t\treturn
\tprint("SMOKE: 金红唯一件 OK（硬闸门 道具+升级 / 池闸门 / 反向对照 / 事件卡排重）")

## 还原「唯一件」探针动过的现场（stats / items_owned / upgrades_owned / 材料）
func _restore_unique_probe(pl: Node, stats: Dictionary, items: Dictionary,
\t\tups: Dictionary, mats: int) -> void:
\tpl.stats = stats
\tpl.items_owned = items
\tpl.upgrades_owned = ups
\tpl.hp = minf(float(pl.hp), float(pl.stats.max_hp))
\tpl._sanitize_stats()
\tGameState.materials = mats
\tpl.queue_redraw()

'''

PATCHES = [
	# 1) 在 _check_assim_items() 之后调用新用例
	(SMOKE,
		'\t_check_assim_items()\n',
		'\t_check_assim_items()\n\t_check_unique_items()\n'),
	# 2) 新函数插在 S5 用例结尾之后
	(SMOKE,
		'\tprint("SMOKE: S5 同化度道具 + 之悟升级 + 白名单收敛 OK")\n',
		'\tprint("SMOKE: S5 同化度道具 + 之悟升级 + 白名单收敛 OK")\n\n\n' + FUNC),
	# 3) 存档往返：先把升级记账种进档（否则两边都空 = 假绿）
	(SMOKE,
		'\tif not SaveRun.save(9, p2):\n',
		'\t# 第 7 轮：先种一条升级记账进档，否则下面的往返断言会在「两边都是空」时假绿\n'
		'\tp2.upgrades_owned = { "hp": 2, "berserk": 1 }\n'
		'\tif not SaveRun.save(9, p2):\n'),
	# 4) 留档
	(SMOKE,
		'\tvar s_items: Dictionary = p2.items_owned.duplicate()\n',
		'\tvar s_items: Dictionary = p2.items_owned.duplicate()\n'
		'\tvar s_ups: Dictionary = p2.upgrades_owned.duplicate()\n'),
	# 5) 篡改现场时把升级记账也清掉，逼 restore 真的去恢复它
	(SMOKE,
		'\tp2.hp = 1.0\n\tp2.weapons = []\n\tp2.items_owned = {}\n',
		'\tp2.hp = 1.0\n\tp2.weapons = []\n\tp2.items_owned = {}\n\tp2.upgrades_owned = {}\n'),
	# 6) 往返断言 + 探针清理
	(SMOKE,
		'\tif not items_ok:\n'
		'\t\t_fail("存档恢复后 items_owned 不一致")\n'
		'\t\treturn\n',
		'\tif not items_ok:\n'
		'\t\t_fail("存档恢复后 items_owned 不一致")\n'
		'\t\treturn\n'
		'\t# 第 7 轮：升级记账必须一起往返 —— 丢了这个键，续档后「金/红升级唯一」会**静默**失效\n'
		'\t# （upgrades_owned 归空 → 同一张金升级能再刷一遍），不报错、只是不再唯一。\n'
		'\tvar ups_ok: bool = p2.upgrades_owned.size() == s_ups.size()\n'
		'\tif ups_ok:\n'
		'\t\tfor k in s_ups:\n'
		'\t\t\tif int(p2.upgrades_owned.get(k, -1)) != int(s_ups[k]):\n'
		'\t\t\t\tups_ok = false\n'
		'\t\t\t\tbreak\n'
		'\tif not ups_ok:\n'
		'\t\t_fail("存档恢复后 upgrades_owned 不一致（存档=%s / 恢复=%s）" % [str(s_ups), str(p2.upgrades_owned)])\n'
		'\t\treturn\n'
		'\tp2.upgrades_owned = {}   # 探针清理：别把这条用例种下的账留给后面的用例\n'),
]


def main() -> int:
	raw = open(SMOKE, "rb").read()
	crlf = b"\r\n" in raw
	src = raw.decode("utf-8")
	nl = "\r\n" if crlf else "\n"
	for i, (path, old, new) in enumerate(PATCHES):
		o = old.replace("\n", nl)
		n = new.replace("\n", nl)
		cnt = src.count(o)
		if cnt != 1:
			print("FAIL #%d: old 命中 %d 次（应为 1）" % (i + 1, cnt))
			print(repr(o[:300]))
			return 1
		src = src.replace(o, n, 1)
		print("OK   #%d" % (i + 1))
	open(SMOKE, "w", encoding="utf-8", newline="").write(src)
	print("WROTE %s (LF=%s)" % (SMOKE, "no" if crlf else "yes"))
	return 0


if __name__ == "__main__":
	sys.exit(main())
