# -*- coding: utf-8 -*-
"""给《五行体系重设计_规划.md》补 §12.11 第 7 轮回填清单。"""
import sys

DOC = r"D:/code/firstProject-ai/TheGreatestProject/docs/plans/五行体系重设计_规划.md"

NOTE = ('> ⚠️ **2026-09-17 第 7 轮：本节所有绝对值已过期** —— 全表武器 `dmg` ×0.5（价格未动）\n'
        '> → 单体 DPS / DoT / 总账 **÷2**、价/DPS **×2**。比值类结论不变。见 §12.11。\n'
        '\n')

SEC = '''### 12.11 第 7 轮：全局减半 / 金红唯一件 / 出怪 ×3 / 工坊包移出（2026-09-17 回填 · `SMOKE: PASS`）

> ⚠️ **本节与 §12.1~§12.10 的绝对值口径不同**：第 7 轮把**全部 10 把武器 `dmg` ×0.5**（价格未动），
> 所以上面各节写下的单体 DPS / DoT / 总账数字都要 **÷2**、价/DPS 要 **×2**。
> **比值类结论（极差 / 排序 / 克制方向 / AOE 倍率 / 进化 2.0×）一律不变** —— 减半是全表等比的。

用户本轮 5 项需求，逐项落点：

| # | 需求 | 落点 | 备注 |
|---|---|---|---|
| 1 | 去掉初始动画背景 | `main_menu.gd:_ready()` 不再 spawn `MenuElementLoop` | 根因：`menu_loop` 只被 `home.visible` 定格、**不推时间轴**，但 `_draw()` 永不停 → 五边形在非首页面板背后仍可见 |
| 2 | 角色 / 武器为何还能选到 | `game/mods/brotato_lite_core` → `game/mods_disabled/` | `registry.gd:146` 只扫 `res://mods` / `user://mods`；内置回到 **6 角色 / 10 武器** |
| 3 | 同化度没显示在角色面板 | `main.gd:_refresh_pause_content()` + `shop_ui.gd:_refresh_left()` | 新增「五行同化度」节，只列 `assim_<e> > 0` 的元素 |
| 4 | 底部 WASD 文字遮挡 UI | `main.tscn` 的 `Hint` 上移 + `main.gd:_process()` 按相位显隐 | 仅在 `PLAYING` / `INTRO` 显示 |
| 5a | 出怪速度 ×2 / 怪物量 ×2 | `Config.SPAWN_RATE_MULT = 3.0` / `SPAWN_CAP_MULT = 3.0` | 用户拍板「增加两倍 = 原来的 **3 倍**」；BOSS 波干扰怪**刻意不吃** |
| 5b | 金 / 红物品改为唯一 | `Config.is_unique_rarity` / `unique_pool_ok` + 6 处池闸门 + 2 处硬闸门 | 见下面「唯一件」小节 |
| 5c | 攻速 / 暴击率加成减半 | `as_mult` / `crit_ch` 全来源 ÷2 | ⚠️ 角色 `stats.as_mult` 是**倍率**：`(v−1.0)×0.5+1.0`，**不能直接 `v/2`** |
| 5d | 所有武器数值减半 | `Config.WEAPONS` 10 条 `dmg` ×0.5 | 含 5 个进化体；**`price` 未动**（拍板只点了 dmg） |

**唯一件（金 mythic / 红 legendary）**：全库原本**没有** `unique` 机制，只有法宝事实上唯一
（`registry.gd:239` 用 `artifacts_owned` 剔除）。本轮把同一语义推广到**升级 + 道具 + 事件卡**：

- **策略单一来源**：`Config.is_unique_rarity` / `Config.unique_pool_ok`（别在各处重写判据）。
- **硬闸门**：`player.apply_item` / `player.apply_upgrade`（改为返回 `bool`）—— **不可绕过**，
  mod / 调试面板等旁路也会经过它。
- **池闸门共 6 处**：`shop_ui._rarity_pool`（升级 + 道具两路）、`shop_ui._ensure_affinity_goods`、
  `level_up_ui.open` / `_ensure_affinity_choice` / 均匀兜底、`main._grant_random_item`、
  `wave_manager` 宝箱波。
- **事件卡本身不需要新机制**：`config.gd:1267` 早已按 `GameState.events_seen` 排重（每张每局一次）。
- ⚠️ **升级过去完全没有记账** → 新增 `player.upgrades_owned`，**必须进存档**
  （`save_run.gd` 写入 + 恢复 + 结构校验三处），否则续档后归空、同一张金升级能再刷一遍，
  **不报错、只是不再唯一**。
- 判据用「**当前持有**」而非「曾经获得」—— 与法宝一致（卖掉后回到池里，但只能半价卖、原价买，净亏）。

**连带修掉的 4 处「包停用后失效的旧断言」**（不修必红，且表象都像「实现坏了」）：

1. `Config.DAILY_CHARACTERS` 仍列 11 个已冻结角色 → 收敛到内置 6。
2. 「每元素 ≥2 把武器」按 `status → element` 统计 → 木弓与进化体刻意**无 `status`**，恒为 0；
   改为校验 `Config.LOADOUT_WEAPONS` 恰好铺满 5 元素、一元素一把、不重不漏。
3. 「所有 `TRAIT_KINDS` 必须有角色在用」→ 内置 6 角色**全是 `stats`**；
   改为 content 侧 **OR** 机制侧（临时 `char_trait` 探针实跑）双来源覆盖。
4. `Registry.WEAPON_FX` 的 23 条冻结映射变孤儿 → 加 `FROZEN_PACK_WEAPONS` 白名单 +
   **反向计数断言**（白名单数 == 冻结条目数 == `WEAPON_FX.size() − Config.WEAPONS.size()`）。

**新增冒烟断言**：`SMOKE: 金红唯一件 OK（硬闸门 道具+升级 / 池闸门 / 反向对照 / 事件卡排重）`
—— 样本从 `Registry` 扫出（不硬编码 id）、每条正向断言都配**反向对照**（common 必须仍在池里 /
仍能叠到 2，防空池假绿）、探针全程可还原；存档往返用例补 `upgrades_owned` 一致性断言
（先种一条账，否则两边都空 = 假绿）。

改完跑冒烟 → `SMOKE: PASS`。`BALANCE base` 五把全部减半
（`knife` 15.56 / `flamethrower` 15.00 / `blight_bow` 12.00 / `frost_staff` 11.67 / `thunder_gong` 11.11），
5 个进化体倍数仍恒 **2.00×**。

**体检表同步**：抬头加第 7 轮记录、§1 抬头横幅 + 主表 + DoT 总账、**新增 §1.1d 全局减半账**、
§1.2 读法、§2.1 / §2.2 两张矩阵 + 极差、§3 rank 与读法、§4 反向对照行、§5 同化度斜率表、
§6 观察点、§9.1 / §9.2 / §9.3 / §9.5 / §9.6、§10.3 进化体数值表、§10.4 三槽换一槽的账，
以及**新增 §12 第 7 轮专章**。

'''

PATCHES = [
	('### 12.10 S8 实际改动清单（2026-09-16 回填 · `SMOKE: PASS`）\n',
	 '### 12.10 S8 实际改动清单（2026-09-16 回填 · `SMOKE: PASS`）\n\n' + NOTE),
	('\n---\n\n## 13. 验收标准 & 冒烟测试新增断言\n',
	 '\n---\n\n' + SEC + '---\n\n## 13. 验收标准 & 冒烟测试新增断言\n'),
]


def main() -> int:
	raw = open(DOC, "rb").read()
	crlf = b"\r\n" in raw
	src = raw.decode("utf-8")
	nl = "\r\n" if crlf else "\n"
	for i, (old, new) in enumerate(PATCHES):
		o = old.replace("\n", nl)
		n = new.replace("\n", nl)
		cnt = src.count(o)
		if cnt != 1:
			print("FAIL #%d: old 命中 %d 次（应为 1）" % (i + 1, cnt))
			print(repr(o[:300]))
			return 1
		src = src.replace(o, n, 1)
		print("OK   #%d" % (i + 1))
	open(DOC, "w", encoding="utf-8", newline="").write(src)
	print("WROTE %s (LF=%s)" % (DOC, "no" if crlf else "yes"))
	return 0


if __name__ == "__main__":
	sys.exit(main())
