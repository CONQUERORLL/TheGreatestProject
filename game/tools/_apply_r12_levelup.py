"""第 12 轮 · 需求 3：连升「改回一级选一次」（撤回第 9 轮的合并）。

⚠️ 关键点：不能只把 `Config.LEVEL_MERGE_CAP` 改成 1 —— 合并版的 `_choose`
会把整个 `level_queue` 清零并把超出部分折成材料，那样「连升 3 级」只会弹 1 次、
白丢 2 级。必须同时把 `_choose` 改回「减 1 后若仍有积压就继续弹」（= e600854 的旧实现）。

本脚本改两处：
  level_up_ui.gd —— 去掉 _merged / merged_count / 标题后缀 / 溢出折材料，_choose 改回逐级
  smoke_test.gd  —— 把「合并成一次选择」的断言换成「一级选一次」的断言
"""
import io, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UI = os.path.join(ROOT, "scripts", "ui", "level_up_ui.gd")
SMOKE = os.path.join(ROOT, "tests", "smoke_test.gd")


def sub1(path, old, new, label):
    """精确替换一次；匹配不到或匹配多次都报错退出（防止静默漂移）。"""
    with io.open(path, "r", encoding="utf-8") as f:
        s = f.read()
    n = s.count(old)
    if n == 0 and (not new or new in s):
        print("SKIP[%s]: 已应用过" % label)   # 幂等：重复执行不报错
        return
    if n != 1:
        print("FAIL[%s]: 期望匹配 1 次，实际 %d 次" % (label, n))
        sys.exit(1)
    s = s.replace(old, new, 1)
    with io.open(path, "w", encoding="utf-8") as f:
        f.write(s)
    print("OK  [%s]: %d -> %d 字符 (%+d)" % (label, len(s) - (len(new) - len(old)), len(s), len(new) - len(old)))


# ---------------- level_up_ui.gd ----------------
# 1) 去掉 _merged 字段
sub1(UI,
     "var _merged := 1            # 本次选择合并了几级收益（连升合并，见 open/_choose）\n",
     "",
     "ui: 删 _merged 字段")

# 2) open() 里去掉合并级数计算
sub1(UI,
     "\t# 连升合并（第 9 轮）：积压的 N 级合并成**一次**选择，选中的那张生效 N 次。\n"
     "\t# 上限对齐 Config.LEVEL_MERGE_CAP，超出的级数在 _choose 里折成材料。\n"
     "\t# ⚠️ 这里只定「这一次代表几级」，**不动 level_queue** —— 队列一律由 _choose 清零。\n"
     "\t_merged = clampi(maxi(GameState.level_queue, 1), 1, Config.LEVEL_MERGE_CAP)\n",
     "",
     "ui: open 去合并计算")

# 3) 去掉标题「连升 N 级」后缀（改回一级一选后 _merged 恒为 1，后缀永远不显示）
sub1(UI,
     "\t_title.text = \"升级！Lv %d\" % GameState.level\n"
     "\tif _merged > 1:\n"
     "\t\t# 必须让玩家看见「为什么只选一次」——否则会以为漏了两次升级\n"
     "\t\t_title.text += \"  ·  连升 %d 级（本次选择生效 ×%d）\" % [_merged, _merged]\n",
     "\t_title.text = \"升级！Lv %d\" % GameState.level\n",
     "ui: 去掉连升标题后缀")

# 4) 去掉 merged_count()（不再有「合并了几级」的概念）
sub1(UI,
     "## 本次选择代表几级收益（连升合并后的级数；冒烟与 UI 文案都读它，不各自算一遍）\n"
     "func merged_count() -> int:\n"
     "\treturn _merged\n\n",
     "",
     "ui: 删 merged_count()")

# 5) _choose 改回「一级选一次」：队列 -1，仍有积压就重新抽三张继续弹
sub1(UI,
     "\t# 连升合并（第 9 轮）：一次点击兑现 _merged 级的收益。\n"
     "\t# ⚠️ 金/红「唯一件」的第二、三次会被 `player.apply_upgrade` 的硬闸门拒绝 ——\n"
     "\t#    这是对的（唯一件本就不该叠加），所以这里不做任何补救，收益自然少算。\n"
     "\tvar times := maxi(1, _merged)\n"
     "\tif player and uid != \"\":\n"
     "\t\tfor _t in times:\n"
     "\t\t\tplayer.apply_upgrade(uid)\n"
     "\t# 超出合并上限的级数折成材料 —— 避免「一次升 8 级」被一张卡白白吃掉\n"
     "\tvar overflow := GameState.level_queue - times\n"
     "\tif overflow > 0:\n"
     "\t\tGameState.add_materials(overflow * Config.LEVEL_MERGE_OVERFLOW_MAT)\n"
     "\tHaptics.rumble(0.25, 0.0, 0.08)   # 手柄确认轻震\n"
     "\t# 队列一次清零：合并后不存在「还剩几级要补弹」，这是玩家少点几次的全部来源\n"
     "\tGameState.level_queue = 0\n"
     "\t_merged = 1\n"
     "\t_choices = []\n"
     "\tvisible = false\n"
     "\tGameState.set_phase(GameState.Phase.PLAYING)\n",
     "\t# 第 12 轮：改回「一级选一次」—— 本次只兑现 1 级（不再有 ×N 的合并收益）。\n"
     "\tif player and uid != \"\":\n"
     "\t\tplayer.apply_upgrade(uid)\n"
     "\tHaptics.rumble(0.25, 0.0, 0.08)   # 手柄确认轻震\n"
     "\tGameState.level_queue = maxi(0, GameState.level_queue - 1)\n"
     "\t_choices = []\n"
     "\tif GameState.level_queue > 0:\n"
     "\t\t# 还有积压的级数：为下一次升级重新抽三张（不复用同一组卡，避免空卡锁死）\n"
     "\t\topen()\n"
     "\telse:\n"
     "\t\tvisible = false\n"
     "\t\tGameState.set_phase(GameState.Phase.PLAYING)\n",
     "ui: _choose 改回逐级")

# ---------------- smoke_test.gd ----------------
sub1(SMOKE,
     "\t# ---- 单次跨两级：第 9 轮起**合并成一次选择**，收益 ×2 ----\n"
     "\t# 旧行为：每个等级各弹一次、每次重抽三张 → 连升 N 级要点 N 次（用户反馈次数太多）。\n"
     "\t# 本段钉两件事：① 只弹一次（仍是三选一）  ② 收益真的按级数兑现。\n"
     "\t# ⚠️ 第 3 条「第二组卡有焦点」的断言已随本次行为变更删除 —— 不再有第二组卡。\n"
     "\tvar need_two := Config.xp_need(GameState.level) + Config.xp_need(GameState.level + 1)\n"
     "\tGameState.gain_xp(need_two + 1)\n"
     "\tawait get_tree().process_frame\n"
     "\tif GameState.phase != GameState.Phase.LEVEL_UP or GameState.level_queue != 2 or ui.card_count() != 3:\n"
     "\t\t_fail(\"单次跨两级未生成首组卡（phase=%d queue=%d cards=%d）\" %\n"
     "\t\t\t[GameState.phase, GameState.level_queue, ui.card_count()])\n"
     "\t\treturn\n"
     "\tif ui.merged_count() != 2:\n"
     "\t\t_fail(\"连升两级未合并成一次选择（merged=%d）\" % ui.merged_count())\n"
     "\t\treturn\n"
     "\tvar pick_rarity := \"common\"\n"
     "\tvar pick_id := \"\"\n"
     "\tif typeof(ui._choices[0]) == TYPE_DICTIONARY:\n"
     "\t\tpick_rarity = String(ui._choices[0].get(\"rarity\", \"common\"))\n"
     "\t\tpick_id = String(ui._choices[0].get(\"id\", \"\"))\n"
     "\t# 期望次数从**被测数据**算：金/红唯一件的第二次会被硬闸门拒绝 → 只 +1；\n"
     "\t# 其余强化吃满 merged 次。不写死 2，否则一抽到神话卡就假红。\n"
     "\tvar want_times := 1 if Config.is_unique_rarity(pick_rarity) else 2\n"
     "\tvar own_before := int(player.upgrades_owned.get(pick_id, 0))\n"
     "\tui._choose(0)\n"
     "\tawait get_tree().process_frame\n"
     "\tif GameState.phase != GameState.Phase.PLAYING or GameState.level_queue != 0:\n"
     "\t\t_fail(\"连升完成后未恢复 PLAYING（phase=%d queue=%d）\" %\n"
     "\t\t\t[GameState.phase, GameState.level_queue])\n"
     "\t\treturn\n"
     "\tif pick_id != \"\":\n"
     "\t\tvar got := int(player.upgrades_owned.get(pick_id, 0)) - own_before\n"
     "\t\tprint(\"SMOKE: merge pick=%s rarity=%s applied=%d want=%d\" %\n"
     "\t\t\t[pick_id, pick_rarity, got, want_times])\n"
     "\t\tif got != want_times:\n"
     "\t\t\t_fail(\"连升收益未按级数兑现（%s 期望 +%d，实际 +%d）\" % [pick_id, want_times, got])\n"
     "\t\t\treturn\n",
     "\t# ---- 单次跨两级：第 12 轮起**改回「一级选一次」**（撤回第 9 轮的连升合并）----\n"
     "\t# 第 9 轮：N 级合并成一次选择、收益 ×N，只弹一次（玩家看不出自己升了几级）。\n"
     "\t# 现在：每级各弹一次三选一、每次重抽三张；`level_queue` 每次只 -1。\n"
     "\t# 本段钉三件事：① 首组卡正常  ② 选完一级队列 -1 且**继续弹下一组**（不是直接回 PLAYING）\n"
     "\t#                ③ 两级都选完才回 PLAYING，且单级收益**不得被 ×N 重复兑现**。\n"
     "\tvar need_two := Config.xp_need(GameState.level) + Config.xp_need(GameState.level + 1)\n"
     "\tGameState.gain_xp(need_two + 1)\n"
     "\tawait get_tree().process_frame\n"
     "\tif GameState.phase != GameState.Phase.LEVEL_UP or GameState.level_queue != 2 or ui.card_count() != 3:\n"
     "\t\t_fail(\"单次跨两级未生成首组卡（phase=%d queue=%d cards=%d）\" %\n"
     "\t\t\t[GameState.phase, GameState.level_queue, ui.card_count()])\n"
     "\t\treturn\n"
     "\t# 第一级：只兑现 1 级 → 队列 2→1，且必须继续弹第二组卡\n"
     "\tvar pick_id := \"\"\n"
     "\tif typeof(ui._choices[0]) == TYPE_DICTIONARY:\n"
     "\t\tpick_id = String(ui._choices[0].get(\"id\", \"\"))\n"
     "\tvar own_before := int(player.upgrades_owned.get(pick_id, 0))\n"
     "\tui._choose(0)\n"
     "\tawait get_tree().process_frame\n"
     "\tif GameState.level_queue != 1:\n"
     "\t\t_fail(\"一级选一次：选完第一级队列应为 1（实际 queue=%d）\" % GameState.level_queue)\n"
     "\t\treturn\n"
     "\tif GameState.phase != GameState.Phase.LEVEL_UP or ui.card_count() != 3:\n"
     "\t\t_fail(\"一级选一次：选完第一级未继续弹第二组卡（phase=%d cards=%d）\" %\n"
     "\t\t\t[GameState.phase, ui.card_count()])\n"
     "\t\treturn\n"
     "\tif pick_id != \"\":\n"
     "\t\t# 反向对照：合并版会在这里兑现 2 次。单级只允许 +1（唯一件被硬闸门拦下时 +0）。\n"
     "\t\tvar got1 := int(player.upgrades_owned.get(pick_id, 0)) - own_before\n"
     "\t\tprint(\"SMOKE: per-level pick=%s applied=%d (want <=1)\" % [pick_id, got1])\n"
     "\t\tif got1 > 1:\n"
     "\t\t\t_fail(\"一级选一次：单级收益被重复兑现（%s 实际 +%d）\" % [pick_id, got1])\n"
     "\t\treturn\n"
     "\t# 第二级：选完队列归零、回到 PLAYING\n"
     "\tui._choose(0)\n"
     "\tawait get_tree().process_frame\n"
     "\tif GameState.phase != GameState.Phase.PLAYING or GameState.level_queue != 0:\n"
     "\t\t_fail(\"两级选完后未恢复 PLAYING（phase=%d queue=%d）\" %\n"
     "\t\t\t[GameState.phase, GameState.level_queue])\n"
     "\t\treturn\n",
     "smoke: 连升断言改回逐级")

print("ALL OK")
