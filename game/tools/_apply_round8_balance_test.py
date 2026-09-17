"""第 8 轮 · 第 4 条：冒烟用例 —— 逐波平衡日志（BalanceLog）。"""
import io
import sys

P = "D:/code/firstProject-ai/TheGreatestProject/game/tests/smoke_test.gd"

CHECK = '''## 逐波平衡日志（2026-09-17 第 8 轮需求 4）：结构 / 增量 / 波次隔离 / 射程口径。
##
## 断言口径：
##   · 期望值**从被测数据算**（Config.WEAPONS 的 evolve_branches、Registry 里的武器表），不写死 id；
##   · 每条 A→B 的断言都先造出「不满足」的反向情形（未开局不落盘 / 波次之间必须清零），
##     否则「池子空了」也能判绿；
##   · 用完把 stats 还原（租进来的变量必须还回去，否则污染后续用例）。
func _check_balance_log() -> void:
	if _failed:
		return
	var p: Node2D = _main.get_node("Player")
	BalanceLog.set_storage_root_for_tests(TEST_SAVE_ROOT)
	var log_path := BalanceLog.path()
	if FileAccess.file_exists(log_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(log_path))
	# ---- ① 反向对照：未开局（菜单 / 图鉴里跑到的战斗代码）一个字节都不该写 ----
	BalanceLog.close_run()
	BalanceLog.begin_wave(2)
	BalanceLog.add_damage_dealt(999.0, "knife")
	BalanceLog.add_damage_taken(999.0)
	if BalanceLog.commit(2, p, "shop"):
		_fail("BalanceLog: 未 begin_run 就落盘了")
		return
	if FileAccess.file_exists(log_path):
		_fail("BalanceLog: 未开局不应产生日志文件")
		return
	# ---- ② 开局 + 本波累计：总量 / 按来源拆分 / 出怪数 / 事件波 ----
	BalanceLog.begin_run()
	BalanceLog.begin_wave(2)
	BalanceLog.add_damage_dealt(120.0, "knife")
	BalanceLog.add_damage_dealt(80.0, "knife")
	BalanceLog.add_damage_dealt(50.0, "thunder_gong")
	BalanceLog.add_damage_dealt(30.0, "")        # 无来源 → 归 "other"
	BalanceLog.add_damage_taken(40.0)
	BalanceLog.add_heal(7.0)
	BalanceLog.note_hp(p.hp)
	BalanceLog.note_spawn(5)
	BalanceLog.note_event("meteor")
	if not BalanceLog.commit(2, p, "shop"):
		_fail("BalanceLog: 开局后应能落盘")
		return
	if not FileAccess.file_exists(log_path):
		_fail("BalanceLog: 落盘后文件不存在（%s）" % log_path)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.open(log_path, FileAccess.READ).get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail("BalanceLog: 日志不是合法 JSON")
		return
	var d: Dictionary = parsed
	var latest: Dictionary = d.get("latest", {})
	var wd: Dictionary = latest.get("wave_data", {})
	if int(latest.get("wave", 0)) != 2 or String(latest.get("outcome", "")) != "shop":
		_fail("BalanceLog: latest 的波次/outcome 不对（%s）" % str(latest))
		return
	if not is_equal_approx(float(wd.get("damage_dealt", 0.0)), 280.0):
		_fail("BalanceLog: 本波总伤害应为 120+80+50+30=280，实际 %s" % str(wd.get("damage_dealt")))
	var bysrc: Dictionary = wd.get("by_source", {})
	if not is_equal_approx(float(bysrc.get("knife", 0.0)), 200.0) \\
			or not is_equal_approx(float(bysrc.get("thunder_gong", 0.0)), 50.0) \\
			or not is_equal_approx(float(bysrc.get("other", 0.0)), 30.0):
		_fail("BalanceLog: 伤害来源拆分错误 %s" % str(bysrc))
	if int(wd.get("spawned", -1)) != 5 or String(wd.get("event", "")) != "meteor" \\
			or not is_equal_approx(float(wd.get("damage_taken", 0.0)), 40.0) \\
			or not is_equal_approx(float(wd.get("heal", 0.0)), 7.0):
		_fail("BalanceLog: 出怪数 / 事件波 / 受击 / 回复未记录 %s" % str(wd))
	# ---- ③ 玩家快照：全量属性 + 武器清单（含实战冷却，取 try_fire 的同一算法）----
	var snap: Dictionary = latest.get("player", {})
	var stats_snap: Dictionary = snap.get("stats", {})
	if not stats_snap.has("dmg_mult") or not stats_snap.has("as_mult"):
		_fail("BalanceLog: 玩家快照缺少全量 stats")
		return
	var wl: Array = snap.get("weapons", [])
	if wl.is_empty() or not (wl[0] as Dictionary).has("reach"):
		_fail("BalanceLog: 玩家快照缺少武器清单 / 射程")
		return
	for we in wl:
		var we_d: Dictionary = we
		if not is_equal_approx(float(we_d.get("cd_effective", -1.0)),
				float(we_d.get("cd", 0.0)) / maxf(0.01, float(p.stats.as_mult))):
			_fail("BalanceLog: 实战冷却未按 面板cd÷攻速 折算（%s）" % str(we_d))
			break
	# ---- ④ 射程口径：与开火同源，且**投掷物不吃弹速/射程类加成**（第 8 轮修复点）----
	var gcfg: Dictionary = Registry.weapons.get("thunder_gong", {})
	if gcfg.is_empty():
		_fail("BalanceLog: Registry 缺少 thunder_gong")
		return
	var r_base := p.weapon_reach(gcfg)
	if not is_equal_approx(r_base, float(gcfg.bspeed) * float(gcfg.bullet_life) + 26.0
			+ float(gcfg.splash)):
		_fail("BalanceLog: 投掷物射程口径应为 弹速×存活+26+splash，实际 %.1f" % r_base)
	var keep_bullet := float(p.stats.get("bullet_range_bonus", 0.0))
	var keep_throw := float(p.stats.get("throw_range_bonus", 0.0))
	var keep_melee := float(p.stats.get("melee_range_bonus", 0.0))
	p.stats.bullet_range_bonus = 0.5
	if not is_equal_approx(p.weapon_reach(gcfg), r_base):
		_fail("BalanceLog: 投掷物不该吃「射程」类加成（第 8 轮修复点）")
	p.stats.bullet_range_bonus = keep_bullet
	p.stats.throw_range_bonus = 0.5
	if p.weapon_reach(gcfg) <= r_base:
		_fail("BalanceLog: 投掷物应吃「投掷距离」类加成")
	p.stats.throw_range_bonus = keep_throw
	# 近战：射程 = range ×(1+近战范围加成)，且不吃投掷 / 弹道加成
	var mcfg: Dictionary = Registry.weapons.get("knife", {})
	var m_base := p.weapon_reach(mcfg)
	if not is_equal_approx(m_base, float(mcfg.range)):
		_fail("BalanceLog: 近战射程应等于 range（%.1f vs %.1f）" % [m_base, float(mcfg.range)])
	p.stats.melee_range_bonus = 0.5
	if not is_equal_approx(p.weapon_reach(mcfg), float(mcfg.range) * 1.5):
		_fail("BalanceLog: 近战射程未吃「近战范围」加成")
	p.stats.melee_range_bonus = keep_melee
	# ---- ⑤ 进化体识别：期望集**从被测数据算**，并配反向对照 ----
	var evolved_ids: Array = []
	for base_id in Config.WEAPONS:
		for br in Config.WEAPONS[base_id].get("evolve_branches", []):
			evolved_ids.append(String(br))
	if evolved_ids.is_empty():
		_fail("BalanceLog: Config.WEAPONS 里一条 evolve_branches 都没有，本断言已失去意义")
		return
	for eid in evolved_ids:
		if not p._is_evolved_form(eid):
			_fail("BalanceLog: 进化体 %s 未被识别" % eid)
			break
	for wid in Config.WEAPONS:
		if String(wid) in evolved_ids:
			continue
		if p._is_evolved_form(String(wid)):
			_fail("BalanceLog: 基础武器 %s 被误判为进化体" % wid)
			break
	# ---- ⑥ 波次隔离：第二笔 commit 必须追加历史，且本波计数归零 ----
	BalanceLog.begin_wave(3)
	if not BalanceLog.commit(3, p, "shop"):
		_fail("BalanceLog: 第二波落盘失败")
		return
	var parsed2: Variant = JSON.parse_string(FileAccess.open(log_path, FileAccess.READ).get_as_text())
	if typeof(parsed2) != TYPE_DICTIONARY:
		_fail("BalanceLog: 第二波后日志不是合法 JSON")
		return
	var d2: Dictionary = parsed2
	var waves: Array = d2.get("waves", [])
	if waves.size() != 2:
		_fail("BalanceLog: 逐波历史应为 2 条（追加而非覆盖），实际 %d" % waves.size())
		return
	if int((waves[0] as Dictionary).get("wave", 0)) != 2 \\
			or int((waves[1] as Dictionary).get("wave", 0)) != 3:
		_fail("BalanceLog: 逐波历史顺序/波号错误 %s" % str(waves))
	var wd2: Dictionary = (d2.get("latest", {}) as Dictionary).get("wave_data", {})
	if float(wd2.get("damage_dealt", -1.0)) != 0.0 or int(wd2.get("spawned", -1)) != 0:
		_fail("BalanceLog: 波次之间未清零累计（第 2 波的数字滚进了第 3 波）%s" % str(wd2))
	# 还原：日志根目录交回正式路径（后续用例若触发真实落盘，也只该落在测试目录之外）
	BalanceLog.close_run()
	BalanceLog.reset_storage_root_after_tests()
	print("SMOKE: balance_log OK (waves=%d)" % waves.size())

'''

JOBS = [
    (P, [
        ('func _ready() -> void:\n\tSaveRun.set_storage_root_for_tests(TEST_SAVE_ROOT)\n',
         'func _ready() -> void:\n\tSaveRun.set_storage_root_for_tests(TEST_SAVE_ROOT)\n'
         '\t# 逐波平衡日志（第 8 轮）同款隔离：用例会真的写 user:// 日志，绝不能落到正式档上\n'
         '\tBalanceLog.set_storage_root_for_tests(TEST_SAVE_ROOT)\n',
         "storage.root"),
        ('\t_check_reach_safety()\n',
         '\t_check_reach_safety()\n\t_check_balance_log()\n',
         "register"),
        ('func _cleanup_test_storage(reset_root: bool) -> void:\n',
         CHECK + 'func _cleanup_test_storage(reset_root: bool) -> void:\n',
         "func"),
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
        print("-- %s 未写" % path.rsplit("/", 1)[-1])
        continue
    if src != orig:
        io.open(path, "w", encoding="utf-8", newline="").write(src)
        print("OK %s %d 处已写入" % (path.rsplit("/", 1)[-1], len(repls)))

if fail:
    print("!! 有替换没命中：")
    for f in fail:
        print("   - " + f)
    sys.exit(1)
print("全部完成")
