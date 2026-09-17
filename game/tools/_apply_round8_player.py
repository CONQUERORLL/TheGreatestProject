"""第 8 轮 · 第 3 条：player.gd —— 投掷物通道分流 + 火焰视觉对齐有效射程。"""
import io
import sys

P = r"D:/code/firstProject-ai/TheGreatestProject/game/scripts/characters/player.gd"
src = io.open(P, encoding="utf-8").read()
orig = src
REPL = []

# ---- ① stats 增加两条投掷类加成 ----
REPL.append((
    '\t\t"bullet_speed_bonus": 0.0,   # \u5f39\u4e38\u98de\u884c\u901f\u5ea6\n'
    '\t\t"bullet_range_bonus": 0.0,   # \u5f39\u4e38\u5b58\u6d3b\u65f6\u957f\uff08\u5c04\u7a0b\uff09\n',
    '\t\t"bullet_speed_bonus": 0.0,   # \u5f39\u4e38\u98de\u884c\u901f\u5ea6\uff08\u4ec5**\u5f39\u5e55**\uff1a\u4e0d\u5305\u62ec\u6295\u63b7\u7269\uff09\n'
    '\t\t"bullet_range_bonus": 0.0,   # \u5f39\u4e38\u5b58\u6d3b\u65f6\u957f\uff08\u5f39\u5e55\u5c04\u7a0b\uff09\n'
    '\t\t# \u256d\u2500 2026-09-17\uff08\u7b2c 8 \u8f6e\uff09\u65b0\u589e\u7684\u6295\u63b7\u7c7b\u901a\u9053 \u2500\u256e\n'
    '\t\t# \u7528\u6237\u53cd\u9988\u300c\u571f\u8d28\u70b8\u5f39\u5403\u5f39\u901f\u7c7b\u52a0\u6210\u592a\u9ad8\u300d\uff1a\u5b83\u672c\u662f\u6295\u63b7\u7206\u70b8\u7269\uff0c\n'
    '\t\t# \u5374\u4e00\u76f4\u6309\u666e\u901a\u5f39\u5e55\u516c\u5f0f\uff08reach = bspeed \u00d7 bullet_life + 26\uff09\u88ab\u653e\u5927\u3002\n'
    '\t\t# \u73b0\u5728\u4e24\u65cf\u5404\u8d70\u5404\u7684\u8868\uff08\u89c1 `_weapon_runtime_cfg` \u7684 `proj_kind` \u5206\u6d41\uff09\u3002\n'
    '\t\t"throw_speed_bonus": 0.0,    # \u6295\u63b7\u7269\u98de\u884c\u901f\u5ea6\n'
    '\t\t"throw_range_bonus": 0.0,    # \u6295\u63b7\u7269\u98de\u884c\u8ddd\u79bb\n'
    '\t\t# \u2570\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u256f\n',
    "stats \u65b0\u589e throw_*",
))

# ---- ② 火焰喷射：画到「有效射程」 ----
REPL.append((
    '\tvar wc := _weapon_runtime_cfg(c)\n'
    '\tvar reach := float(wc.get("bspeed", 300.0)) * float(wc.get("bullet_life", 0.3)) + 26.0\n'
    '\t_ensure_flame_jet().ignite(ang, reach, 26.0)',
    '\tvar wc := _weapon_runtime_cfg(c)\n'
    '\tvar reach := float(wc.get("bspeed", 300.0)) * float(wc.get("bullet_life", 0.3)) + 26.0\n'
    '\t# \u26a0\ufe0f 2026-09-17\uff08\u7b2c 8 \u8f6e\uff09\uff1a\u706b\u7130\u6539\u753b\u5230\u300c**\u6709\u6548**\u5c04\u7a0b\u300d\uff08\u5f39\u4f53\u5c04\u7a0b + \u6e85\u5c04\u534a\u5f84\uff09\u3002\n'
    '\t#   \u65e7\u7248\u53ea\u753b\u5f39\u4f53\u5c04\u7a0b\uff08110px\uff09\uff0c\u800c\u5b9e\u9645\u80fd\u6253\u5230 110 + splash\uff08\u65e7 75 \u2192 185px\uff09\uff0c\n'
    '\t#   \u73a9\u5bb6\u770b\u5230\u7684\u6bd4\u6253\u5230\u7684\u8fd1 75px \u2014\u2014 \u5c31\u662f\u7528\u6237\u53cd\u9988\u7684\u300c\u55b7\u706b\u5668\u8303\u56f4\u597d\u50cf\u6709\u95ee\u9898\u300d\u3002\n'
    '\t#   \u73b0\u5728\u300c\u770b\u5230\u7684 = \u6253\u5230\u7684\u300d\u3002\n'
    '\t#   \u51cf 18 \u662f\u62b5\u6d88 `flame_jet.gd` \u628a\u9525\u4f53\u8d77\u70b9\u753b\u5728\u67aa\u53e3 `d * 18` \u5904\u7684\u504f\u79fb\uff0c\n'
    '\t#   \u5426\u5219\u706b\u7130\u5c16\u7aef\u4f1a\u591a\u51fa 18px\uff08\u90a3\u6837\u53c8\u53d8\u6210\u300c\u770b\u5230\u7684\u6bd4\u6253\u5230\u7684\u8fdc\u300d\uff09\u3002\n'
    '\tvar eff := reach + float(wc.get("splash", 0.0))\n'
    '\t_ensure_flame_jet().ignite(ang, maxf(20.0, eff - 18.0), 26.0)',
    "\u706b\u7130\u89c6\u89c9\u5bf9\u9f50\u6709\u6548\u5c04\u7a0b",
))

# ---- ③ 特性强调色：按弹体类别判 ----
REPL.append((
    '\tif float(stats.bullet_speed_bonus) > 0.0 or float(stats.bullet_range_bonus) > 0.0:\n'
    '\t\treturn trait_color()',
    '\t# \u7b2c 8 \u8f6e\uff1a\u6295\u63b7\u7269\u53ea\u8ba4\u6295\u63b7\u7c7b\u52a0\u6210\uff0c\u5f39\u5e55\u53ea\u8ba4\u5f39\u901f/\u5c04\u7a0b\u7c7b \u2014\u2014 \u5426\u5219\u571f\u70b8\u5f39\u4f1a\u88ab\u5f39\u901f\u9053\u5177\u70b9\u4eae\uff08\u5b83\u6839\u672c\u4e0d\u5403\uff09\n'
    '\tif String(wcfg.get("proj_kind", "bullet")) == "thrown":\n'
    '\t\tif float(stats.throw_speed_bonus) > 0.0 or float(stats.throw_range_bonus) > 0.0:\n'
    '\t\t\treturn trait_color()\n'
    '\telif float(stats.bullet_speed_bonus) > 0.0 or float(stats.bullet_range_bonus) > 0.0:\n'
    '\t\treturn trait_color()',
    "\u7279\u6027\u5f3a\u8c03\u8272\u5206\u6d41",
))

# ---- ④ 运行参数：proj_kind 分流 ----
REPL.append((
    '## \u6b66\u5668\u8fd0\u884c\u53c2\u6570\uff1a\u53e0\u52a0\u89d2\u8272\u7684\u5f39\u9053\u7c7b\u7279\u6027\uff08\u5f39\u901f / \u5c04\u7a0b / \u7206\u70b8\u534a\u5f84\uff09\u3002\n'
    '## \u65e0\u52a0\u6210\u65f6\u76f4\u63a5\u590d\u7528\u539f\u5b57\u5178 \u2014\u2014 \u9ad8\u653b\u901f\u6b66\u5668\u6bcf\u79d2\u5f00\u706b\u5341\u4f59\u6b21\uff0c\u6ca1\u5fc5\u8981\u6bcf\u6b21\u90fd duplicate\n'
    'func _weapon_runtime_cfg(c: Dictionary) -> Dictionary:\n'
    '\tvar sb := float(stats.bullet_speed_bonus)\n'
    '\tvar rb := float(stats.bullet_range_bonus)\n'
    '\tvar ab := float(stats.aoe_radius_bonus)',
    '## \u6b66\u5668\u8fd0\u884c\u53c2\u6570\uff1a\u53e0\u52a0\u89d2\u8272\u7684\u5f39\u9053\u7c7b\u7279\u6027\uff08\u5f39\u901f / \u5c04\u7a0b / \u7206\u70b8\u534a\u5f84\uff09\u3002\n'
    '## \u65e0\u52a0\u6210\u65f6\u76f4\u63a5\u590d\u7528\u539f\u5b57\u5178 \u2014\u2014 \u9ad8\u653b\u901f\u6b66\u5668\u6bcf\u79d2\u5f00\u706b\u5341\u4f59\u6b21\uff0c\u6ca1\u5fc5\u8981\u6bcf\u6b21\u90fd duplicate\n'
    '##\n'
    '## \u26a0\ufe0f 2026-09-17\uff08\u7b2c 8 \u8f6e\uff09**\u6309 `proj_kind` \u5206\u6d41**\uff1a\n'
    '##   `bullet`\uff08\u9ed8\u8ba4\uff09\u2192 \u5403 `bullet_speed_bonus` / `bullet_range_bonus`\uff08\u884c\u4e3a\u4e0e\u6539\u52a8\u524d\u4e00\u81f4\uff09\n'
    '##   `thrown`\uff08\u571f\u8d28\u70b8\u5f39 / \u539a\u571f\u96f7\uff09\u2192 \u6539\u5403 `throw_speed_bonus` / `throw_range_bonus`\n'
    '##   \u4e24\u8005**\u90fd\u5403** `aoe_radius_bonus`\uff08\u5b83\u7ba1\u300c\u7206\u591a\u5927\u300d\uff0c\u4e0e\u300c\u98de\u591a\u8fdc\u300d\u6b63\u4ea4\uff09\n'
    '## \u52a8\u673a\uff1a\u571f\u70b8\u5f39\u539f\u672c\u6ca1\u5199 `bullet_life`\uff0c\u8ddf\u666e\u901a\u5f39\u5e55\u5403\u540c\u4e00\u5957\u516c\u5f0f\uff0c\u4e00\u4e2a\u5f39\u901f +38%\n'
    '## \u5c31\u80fd\u628a\u5b83\u7684\u5927\u8303\u56f4 AOE \u5c04\u7a0b\u4ece 400 \u62c9\u5230 542\uff08\u518d\u53e0\u5c04\u7a0b\u9053\u5177\u5230 731\uff09\u3002\n'
    'func _weapon_runtime_cfg(c: Dictionary) -> Dictionary:\n'
    '\tvar thrown := String(c.get("proj_kind", "bullet")) == "thrown"\n'
    '\tvar sb := float(stats.throw_speed_bonus) if thrown else float(stats.bullet_speed_bonus)\n'
    '\tvar rb := float(stats.throw_range_bonus) if thrown else float(stats.bullet_range_bonus)\n'
    '\tvar ab := float(stats.aoe_radius_bonus)',
    "\u8fd0\u884c\u53c2\u6570\u5206\u6d41",
))

# ---- ⑤ _sanitize_stats 兜住新增两键 ----
REPL.append((
    '\tstats.bullet_speed_bonus = maxf(0.0, float(stats.bullet_speed_bonus))',
    '\tstats.bullet_speed_bonus = maxf(0.0, float(stats.bullet_speed_bonus))\n'
    '\tstats.throw_speed_bonus = maxf(0.0, float(stats.throw_speed_bonus))\n'
    '\tstats.throw_range_bonus = maxf(0.0, float(stats.throw_range_bonus))',
    "_sanitize_stats \u65b0\u589e\u4e24\u884c",
))

failed = []
for old, new, tag in REPL:
    n = src.count(old)
    if n != 1:
        failed.append("%s -> 命中 %d 次" % (tag, n))
        continue
    src = src.replace(old, new)

if failed:
    print("!! 未写盘：")
    for f in failed:
        print("   - " + f)
    sys.exit(1)

io.open(P, "w", encoding="utf-8", newline="").write(src)
print("OK player.gd 已写入，%d 处替换全部命中 1 次；行数 %d -> %d"
      % (len(REPL), orig.count("\n"), src.count("\n")))
