"""第 8 轮 · 第 4 条：逐波平衡日志 BalanceLog 的接入点。

原则：**每处都必须命中恰好 1 次**才写盘（命中 0 / >1 都算失败并整体退出）。
只做「加一行 / 加一个形参」这类加法，不改任何既有结算语句。
"""
import io
import sys

ROOT = "D:/code/firstProject-ai/TheGreatestProject/game/scripts/"

# ---- player.gd 新增函数（插在 func _draw() 之前）----
PLAYER_FUNCS = '''## 该武器「实际打多远」（px）—— 与开火路径同源：弹速 / 溅射走 `_weapon_runtime_cfg()`，
## 就是开火时用的那个函数，所以日志与 UI 读到的数字==实机在用的数字（含特性 / 道具加成）。
##   · 投射：枪口射程（弹速 × 存活时长）＋ 溅射半径
##           —— 溅射武器的**有效杀伤半径** = 弹体射程 + splash（`smoke_test.gd` 早已钉过这条口径）
##   · 近战：斩击半径 range（含 `melee_range_bonus`，与 `_melee_slash` 同一算法）
## ⚠️ `+ 26` 是枪口到角色中心的距离（见 `_spawn_bullet` 的 `Vector2.from_angle(ang) * 18.0` 与
##    `_ignite_flame_jet` 的同款推算）。漏了它会读出「比实际短 26px」。
func weapon_reach(cfg: Dictionary) -> float:
	var wc := _weapon_runtime_cfg(cfg)
	if String(wc.get("attack_type", "projectile")) == "melee":
		return float(wc.get("range", 0.0)) * (1.0 + float(stats.melee_range_bonus))
	return float(wc.get("bspeed", 0.0)) * float(wc.get("bullet_life", 1.1)) + 26.0 \\
		+ float(wc.get("splash", 0.0))

## 该武器是否为**进化形态**：在「任一基础武器的 evolve_branches」里出现过即为进化体。
## 刻意从注册表反查，而不是判 `id.ends_with("_ex")` —— 后缀只是内置命名习惯，
## mod 完全可以用别的 id 命名进化体，那时后缀判据会静默失效。
func _is_evolved_form(wtype: String) -> bool:
	for base_id in Registry.weapons:
		if wtype in Registry.weapons[base_id].get("evolve_branches", []):
			return true
	return false

## 逐波平衡日志（第 8 轮需求 4）用的玩家快照：全量属性 + 武器 / 道具 / 法宝清单。
##
## 口径：
##   · **数值全部取运行时真值**（`stats` / `weapons` / `Registry`），这里不另算一份；
##   · **刻意不写「预估 DPS」**：日志只给原始因子（dmg / cd / dmg_mult / crit_ch / crit_mult …），
##     让分析脚本按自己的口径算。日志里塞一个半成品 DPS，等体检表口径一变它就成了第二个真值。
func balance_snapshot() -> Dictionary:
	var counts := {}
	for w in weapons:
		var wt := String(w.type)
		counts[wt] = int(counts.get(wt, 0)) + 1
	var wl: Array = []
	for wtype in counts:
		var cfg: Dictionary = Registry.weapons.get(wtype, {})
		if cfg.is_empty():
			continue
		var wc := _weapon_runtime_cfg(cfg)
		wl.append({
			"id": wtype,
			"name": String(cfg.get("name", wtype)),
			"count": int(counts[wtype]),
			"evolved": _is_evolved_form(wtype),
			"element": String(cfg.get("element", "")),
			"family": String(cfg.get("family", "")),
			"attack_type": String(cfg.get("attack_type", "projectile")),
			"proj_kind": String(cfg.get("proj_kind", "bullet")),
			"dmg": float(cfg.get("dmg", 0.0)),
			"cd": float(cfg.get("cd", 0.0)),
			# 实战冷却 = 面板 cd ÷ 攻速倍率（与 try_fire 的算法一字不差）
			"cd_effective": float(cfg.get("cd", 0.0)) / maxf(0.01, float(stats.as_mult)),
			"reach": weapon_reach(cfg),
			"splash": float(wc.get("splash", 0.0)),
			"pellets": int(wc.get("pellets", 1)),
			"status": String(cfg.get("status", "")),
			"price": int(cfg.get("price", 0)),
			"desc": String(cfg.get("desc", "")),
		})
	var items: Array = []
	for iid in items_owned:
		var it: Dictionary = Registry.items.get(String(iid), {})
		items.append({
			"id": String(iid),
			"name": String(it.get("name", iid)),
			"count": int(items_owned[iid]),
			"rarity": String(it.get("rarity", "")),
			# 原始 effects 字典（键 = stats 键）：中文文案归 UI 层（EntryText），
			# 日志只存机器可分析的原值，免得同一份说明在两处各写一遍。
			"effects": (it.get("effects", {}) as Dictionary).duplicate(),
		})
	var arts: Array = []
	for aid in artifacts_owned:
		var a: Dictionary = Registry.get_artifact(String(aid))
		arts.append({
			"id": String(aid),
			"name": String(a.get("name", aid)),
			"stacks": int(artifact_stacks.get(String(aid), 0)),
			"desc": String(a.get("desc", "")),
		})
	return {
		"hp": hp,
		"max_hp": float(stats.max_hp),
		"element": element,
		"sigil": sigil,
		"char_trait": char_trait.duplicate(),
		"skill": skill.duplicate(),
		"stats": stats.duplicate(),
		"weapons": wl,
		"items": items,
		"artifacts": arts,
		"upgrades": upgrades_owned.keys(),
		"family_synergy": _family_synergy_bonus.duplicate(),
	}

'''

JOBS = [
    # ============================================================
    # player.gd
    # ============================================================
    (ROOT + "characters/player.gd", [
        # ① 伤害 roll 里带上武器 id（下游逐级透传给 enemy.take_damage 的第 5 参）
        ('\treturn {\n\t\t"dmg": dmg, "crit": crit,\n\t\t"element": atk_element,',
         '\treturn {\n'
         '\t\t"dmg": dmg, "crit": crit,\n'
         '\t\t# 打出这一发的**武器 id**（第 8 轮平衡日志）：下游原样透传给 `enemy.take_damage`\n'
         '\t\t# 的第 5 参 → 逐波日志能拆出「这一波谁在输出」。空串 = 不是武器打的（特性 / 技能 / 状态）。\n'
         '\t\t"wtype": String(wcfg.get("id", "")),\n'
         '\t\t"element": atk_element,',
         "roll_damage.wtype"),
        # ② 近战斩击把 wtype 传下去
        ('\t\t\t\te.take_damage(roll.dmg, roll.crit, false, String(roll.element))\n',
         '\t\t\t\te.take_damage(roll.dmg, roll.crit, false, String(roll.element),\n'
         '\t\t\t\t\tString(roll.get("wtype", "")))\n',
         "melee.src"),
        # ③ 玩家受击：记受击总量（闪避成功的早早 return，天然不计）
        ('\thp -= dmg\n\tiframes = Config.PLAYER.iframes\n',
         '\thp -= dmg\n'
         '\tBalanceLog.add_damage_taken(dmg)   # 逐波平衡日志（第 8 轮）：本波受击总量\n'
         '\tiframes = Config.PLAYER.iframes\n',
         "take_damage"),
        # ④ 治疗效果：只统计走 heal() 的即时治疗（口径写在 BalanceLog.add_heal 的注释里）
        ('\tvar gained := hp - before\n',
         '\tvar gained := hp - before\n'
         '\tBalanceLog.add_heal(gained)   # 逐波平衡日志：仅即时治疗（不含被动回血 / 吸血）\n',
         "heal"),
        # ⑤ 每帧采样最低血量 —— 生存压力的直接读数
        ('\thp = minf(stats.max_hp, hp + stats.regen * delta)\n\tiframes = maxf(0.0, iframes - delta)\n',
         '\thp = minf(stats.max_hp, hp + stats.regen * delta)\n'
         '\tiframes = maxf(0.0, iframes - delta)\n'
         '\tBalanceLog.note_hp(hp)   # 逐波平衡日志：本波最低血量（生存压力的直接读数）\n',
         "note_hp"),
        # ⑥ 特性光环 DoT（带注释那条先替换，否则会与下一条无注释版本互相命中 2 次）
        ('\t\t\te.take_damage(dmg, false, true, _trait_element())   # dot 通道：不触发常规打击感反馈\n',
         '\t\t\te.take_damage(dmg, false, true, _trait_element(), "trait")'
         '   # dot 通道：不触发常规打击感反馈\n',
         "trait.dot1"),
        ('\t\t\te.take_damage(dmg, false, true, _trait_element())\n',
         '\t\t\te.take_damage(dmg, false, true, _trait_element(), "trait")\n',
         "trait.dot2"),
        # ⑦ 主动技能两条伤害通道
        ('\t\te.take_damage(dmg, false, true, _skill_element())\n',
         '\t\te.take_damage(dmg, false, true, _skill_element(), "skill")\n',
         "skill.dot"),
        ('\t\te.take_damage(dmg, false, false, _skill_element())\n',
         '\t\te.take_damage(dmg, false, false, _skill_element(), "skill")\n',
         "skill.hit"),
        # ⑧ 新增 weapon_reach / _is_evolved_form / balance_snapshot
        ('func _draw() -> void:\n\t# 角色+枪整体朝向 facing（射击时更新，移动时跟随输入方向）\n',
         PLAYER_FUNCS
         + 'func _draw() -> void:\n\t# 角色+枪整体朝向 facing（射击时更新，移动时跟随输入方向）\n',
         "player.funcs"),
    ]),
    # ============================================================
    # enemy.gd
    # ============================================================
    (ROOT + "enemies/enemy.gd", [
        ('func take_damage(dmg: float, crit: bool, dot: bool = false, element_atk: String = "") -> void:\n',
         '## src（第 5 参 · 2026-09-17 第 8 轮）：伤害来源标签，**只喂给逐波平衡日志**，\n'
         '## 不参与任何结算。缺省 "" = 未标注，结算行为与改动前逐字节一致。\n'
         'func take_damage(dmg: float, crit: bool, dot: bool = false, element_atk: String = "",\n'
         '\t\tsrc: String = "") -> void:\n',
         "signature"),
        ('\thp -= final_dmg\n\tbar_t = 0.9\n',
         '\thp -= final_dmg\n'
         '\t# 逐波平衡日志（第 8 轮）：记「实际打进血的量」（BOSS 单发上限、护盾吸收、\n'
         '\t# 元素抗性都已生效），含击杀那一下的溢出伤害 —— 它是玩家真实看到的输出。\n'
         '\tBalanceLog.add_damage_dealt(final_dmg, src)\n'
         '\tbar_t = 0.9\n',
         "dealt"),
        ('\ttake_damage(tick_dmg, false, true)\n',
         '\ttake_damage(tick_dmg, false, true, "", "status")\n',
         "dot.src"),
    ]),
    # ============================================================
    # bullet.gd / explosion.gd / artifact_system.gd：来源透传
    # ============================================================
    (ROOT + "weapons/bullet.gd", [
        ('\t\t\thit.take_damage(dmg, crit, false, String(roll_data.get("element", "")))\n',
         '\t\t\thit.take_damage(dmg, crit, false, String(roll_data.get("element", "")),\n'
         '\t\t\t\tString(roll_data.get("wtype", "")))\n',
         "bullet.src"),
    ]),
    (ROOT + "weapons/explosion.gd", [
        ('\t\t\t\t\te.take_damage(dmg, crit, false, String(status_roll.get("element", "")))\n',
         '\t\t\t\t\te.take_damage(dmg, crit, false, String(status_roll.get("element", "")),\n'
         '\t\t\t\t\t\tString(status_roll.get("wtype", "")))\n',
         "explosion.src"),
    ]),
    (ROOT + "systems/artifact_system.gd", [
        ('\t\tt.take_damage(dmg, false, false, "fire")   # 焚天印是火属性法宝（五行 §12-S1）\n',
         '\t\tt.take_damage(dmg, false, false, "fire", "artifact")   # 焚天印是火属性法宝（五行 §12-S1）\n',
         "artifact.src"),
    ]),
    # ============================================================
    # wave_manager.gd：出怪数 / 事件波类型
    # ============================================================
    (ROOT + "systems/wave_manager.gd", [
        ('\t\tpush_warning("WaveManager: 未知敌人 ID，跳过生成：" + type)\n\t\treturn\n',
         '\t\tpush_warning("WaveManager: 未知敌人 ID，跳过生成：" + type)\n\t\treturn\n'
         '\tBalanceLog.note_spawn()   # 逐波平衡日志（第 8 轮）：本波出怪数\n',
         "note_spawn"),
        ('\t\t{ "item": "meteor", "w": 0.33 }]))\n\tmatch event_kind:\n',
         '\t\t{ "item": "meteor", "w": 0.33 }]))\n'
         '\tBalanceLog.note_event(event_kind)   # 逐波平衡日志：本波是哪种事件波\n'
         '\tmatch event_kind:\n',
         "note_event"),
    ]),
    # ============================================================
    # main.gd：开局清零 / 每波起点 / 与存档同刻落盘
    # ============================================================
    (ROOT + "main.gd", [
        # ① 新局 ↔ 续档：一次覆盖两条分支
        ('\tif restored_wave > 0:\n',
         '\t# 逐波平衡日志（第 8 轮需求 4）：续档接着写（保住前面几波的历史），新局清空重记。\n'
         '\t# ⚠️ 必须在 `start_wave` 之前 —— `begin_wave` 的快照基线要取「本波尚未开始」时的计数。\n'
         '\tBalanceLog.begin_run(restored_wave > 0)\n'
         '\tif restored_wave > 0:\n',
         "begin_run"),
        # ② 每波起点
        ('func _on_wave_started(w: int) -> void:\n\tMusic.play_track(Music.track_for_wave(w), 0.35)\n',
         'func _on_wave_started(w: int) -> void:\n'
         '\tBalanceLog.begin_wave(w)   # 逐波平衡日志（第 8 轮）：从本波起点开始累计增量\n'
         '\tMusic.play_track(Music.track_for_wave(w), 0.35)\n',
         "begin_wave"),
        # ③ 与存档同刻落盘（收波 / 掉落回收 / 进化结算之后）
        ('\tif w > 0 and not SaveRun.save(w + 1, player, SaveRun.CHECKPOINT_SHOP):\n'
         '\t\tEventBus.banner_requested.emit("存档失败", "本次波次进度尚未写入", 2.0)\n',
         '\tif w > 0 and not SaveRun.save(w + 1, player, SaveRun.CHECKPOINT_SHOP):\n'
         '\t\tEventBus.banner_requested.emit("存档失败", "本次波次进度尚未写入", 2.0)\n'
         '\t# 逐波平衡日志（第 8 轮需求 4）：与存档**同刻**落盘，所以「日志里的状态 == 读档得到的状态」。\n'
         '\t# 这里也是「本波战斗数据」唯一完整的时刻 —— 掉落已回收（`_on_wave_ended`）、进化已结算。\n'
         '\t# 商店里买的东西不算进本波（它属于下一波的起点），这样逐波曲线才读得干净。\n'
         '\tif w > 0:\n'
         '\t\tBalanceLog.commit(w, player, "shop")\n',
         "commit.shop"),
        # ④ 阵亡：也记一笔（「死在第 N 波的什么构筑」正是分析要的）
        ('\tif SaveRun.current_run_owns_slot:\n\t\tSaveRun.clear()   # 仅清除已由本局成功写入/恢复的槽\n',
         '\tif SaveRun.current_run_owns_slot:\n\t\tSaveRun.clear()   # 仅清除已由本局成功写入/恢复的槽\n'
         '\t# 逐波平衡日志（第 8 轮）：阵亡也记一笔 —— 「死在第 N 波、什么构筑、最低血量多少」\n'
         '\t# 正是平衡分析最想看的一组数。⚠️ 放在 `SaveRun.clear()` 之后：\n'
         '\t# 存档该清就清，日志刻意留着（它是分析产物，不是进度）。\n'
         '\tBalanceLog.commit(wave_manager.wave, player, "death")\n',
         "commit.death"),
        # ⑤ 通关（标准局那条分支；每日分支的 set_phase/run_ended 与之同形，靠上一行区分）
        ('\tCodexData.set_stat_max("clear_" + GameState.character_id,\n'
         '\t\tRunRules.difficulty_index(GameState.difficulty_id))\n'
         '\tGameState.set_phase(GameState.Phase.VICTORY)\n',
         '\tCodexData.set_stat_max("clear_" + GameState.character_id,\n'
         '\t\tRunRules.difficulty_index(GameState.difficulty_id))\n'
         '\tBalanceLog.commit(wave_manager.wave, player, "victory")   # 逐波平衡日志：通关也记一笔\n'
         '\tGameState.set_phase(GameState.Phase.VICTORY)\n',
         "commit.victory"),
        # ⑥ 回主菜单：停止累计（日志文件保留）
        ('func _goto_main_menu() -> void:\n\tHaptics.rumble(0.3, 0.0, 0.1)\n',
         'func _goto_main_menu() -> void:\n'
         '\tBalanceLog.close_run()   # 逐波平衡日志（第 8 轮）：回主菜单即停止累计（盘上日志保留）\n'
         '\tHaptics.rumble(0.3, 0.0, 0.1)\n',
         "close_run"),
    ]),
]

fail = []
for path, repls in JOBS:
    src = io.open(path, encoding="utf-8").read()
    orig = src
    bad = False
    for old, new, tag in repls:
        n = src.count(old)
        if n != 1:
            fail.append("%s / %s -> 命中 %d 次" % (path.rsplit("/", 1)[-1], tag, n))
            bad = True
            continue
        src = src.replace(old, new)
    if bad:
        print("-- %-20s 未写（有锚点未命中）" % path.rsplit("/", 1)[-1])
        continue
    if src != orig:
        io.open(path, "w", encoding="utf-8", newline="").write(src)
        print("OK %-20s %d 处已写入" % (path.rsplit("/", 1)[-1], len(repls)))
    else:
        print("-- %-20s 无变化" % path.rsplit("/", 1)[-1])

if fail:
    print("!! 有替换没命中：")
    for f in fail:
        print("   - " + f)
    sys.exit(1)
print("全部完成")
