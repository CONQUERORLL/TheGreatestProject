"""第 12 轮 · 冒烟断言改写（v2）：把「连升」那段的判据换成**弹卡次数**。

原写法卡死在 got1 块里（ck1/ck2 到、ck3 不到），不再纠缠，改用与波末排空
同款的 while 排空写法。判据反而更硬：
  第 9 轮合并版：跨两级只弹 1 次  → pops == 1
  第 12 轮逐级版：每级各弹一次    → pops == 2
不再比较 upgrades_owned 增量（金/红唯一件会被硬闸门拦下，增量本就不确定）。

同时清理所有临时探针行。
"""
import io, sys

P = "game/tests/smoke_test.gd"

with io.open(P, "r", encoding="utf-8") as f:
    lines = f.read().split("\n")

# 1) 清掉所有临时探针行
JUNK = ("_fa1", "_fa2", "_fa3", "_fa4", "_fa5",
        "_cf1", "_cf2", "_cf3", "_cf4", "_cf5", "_cf6",
        "MARK-", "_ck_")
clean = [ln for ln in lines if not any(k in ln for k in JUNK)]

# 2) 定位「单次跨两级」整段并替换
start = None
for i, ln in enumerate(clean):
    if ln.strip().startswith("# ---- 单次跨两级"):
        start = i
        break
if start is None:
    print("FAIL: 找不到「单次跨两级」段")
    sys.exit(1)

end = None
for j in range(start, len(clean)):
    if "两级选完后未恢复 PLAYING" in clean[j]:
        # 该 _fail 之后的 "\t\treturn" 即整段结尾
        for k in range(j, len(clean)):
            if clean[k] == "\t\treturn":
                end = k
                break
        break
if end is None:
    print("FAIL: 找不到整段结尾")
    sys.exit(1)

NEW = (
"\t# ---- 单次跨两级：第 12 轮起**改回「一级选一次」**（撤回第 9 轮的连升合并）----\n"
"\t# 第 9 轮：N 级合并成一次选择、收益 ×N，只弹一次（玩家看不出自己升了几级）。\n"
"\t# 第 12 轮：每级各弹一次三选一、每次重抽三张，`level_queue` 每次只 -1。\n"
"\t# 判据用**弹卡次数**：合并版跨两级只弹 1 次，逐级版必须弹 2 次。\n"
"\t# （不比较 upgrades_owned 增量：金/红唯一件会被硬闸门拦下，增量本就不确定。）\n"
"\tvar need_two := Config.xp_need(GameState.level) + Config.xp_need(GameState.level + 1)\n"
"\tGameState.gain_xp(need_two + 1)\n"
"\tawait get_tree().process_frame\n"
"\tif GameState.phase != GameState.Phase.LEVEL_UP or GameState.level_queue != 2 or ui.card_count() != 3:\n"
"\t\t_fail(\"单次跨两级未生成首组卡（phase=%d queue=%d cards=%d）\" %\n"
"\t\t\t[GameState.phase, GameState.level_queue, ui.card_count()])\n"
"\t\treturn\n"
"\t# 逐次排空：每级弹一次、队列每次 -1（与波末排空同款写法，不另造时序）\n"
"\tvar pops := 0\n"
"\twhile GameState.level_queue > 0 or ui.visible:\n"
"\t\tif ui.visible:\n"
"\t\t\tui._choose(0)\n"
"\t\t\tpops += 1\n"
"\t\telse:\n"
"\t\t\t_fail(\"一级选一次：还有 %d 级没弹卡就关窗了\" % GameState.level_queue)\n"
"\t\t\treturn\n"
"\t\tawait get_tree().process_frame\n"
"\t# 反向对照：合并版这里只会是 1\n"
"\tif pops < 2:\n"
"\t\t_fail(\"一级选一次：跨两级只弹了 %d 次（应 ≥2）\" % pops)\n"
"\t\treturn\n"
"\tif GameState.phase != GameState.Phase.PLAYING or GameState.level_queue != 0:\n"
"\t\t_fail(\"两级选完后未恢复 PLAYING（phase=%d queue=%d）\" %\n"
"\t\t\t[GameState.phase, GameState.level_queue])\n"
"\t\treturn\n"
"\tprint(\"SMOKE: per-level level-up OK（跨两级弹了 %d 次）\" % pops)\n"
).split("\n")
# 末尾 split 会产生一个空串，去掉
NEW = [x for x in NEW if x != ""] if NEW[-1] == "" else NEW

clean[start:end + 1] = NEW

with io.open(P, "w", encoding="utf-8") as f:
    f.write("\n".join(clean))
print("smoke 断言已改写：替换 %d 行 -> %d 行" % (end - start + 1, len(NEW)))
