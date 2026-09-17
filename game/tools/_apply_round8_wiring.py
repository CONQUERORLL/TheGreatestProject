"""第 8 轮 · 第 3 条：把 throw_* 两键接进「注册上限 / 存档兜底 / HUD 名」三处。"""
import io
import sys

JOBS = [
    # (文件, [(old, new, tag), ...])
    (r"D:/code/firstProject-ai/TheGreatestProject/game/scripts/core/registry.gd", [
        ('\t"bullet_speed_bonus": Vector2(0.0, 10.0), "bullet_range_bonus": Vector2(0.0, 10.0),\n',
         '\t"bullet_speed_bonus": Vector2(0.0, 10.0), "bullet_range_bonus": Vector2(0.0, 10.0),\n'
         '\t"throw_speed_bonus": Vector2(0.0, 10.0), "throw_range_bonus": Vector2(0.0, 10.0),\n',
         "STAT_LIMITS"),
        ('\t"bullet_speed_bonus": 10.0, "bullet_range_bonus": 10.0, "melee_range_bonus": 10.0,\n',
         '\t"bullet_speed_bonus": 10.0, "bullet_range_bonus": 10.0, "melee_range_bonus": 10.0,\n'
         '\t"throw_speed_bonus": 10.0, "throw_range_bonus": 10.0,\n',
         "EFFECT_LIMITS"),
    ]),
    (r"D:/code/firstProject-ai/TheGreatestProject/game/scripts/core/save_run.gd", [
        ('\tstats.status_spread = clampf(float(stats.status_spread), 0.0, 1.0)\n',
         '\tstats.status_spread = clampf(float(stats.status_spread), 0.0, 1.0)\n'
         '\t# \u6295\u63b7\u7c7b\u52a0\u6210\uff08\u7b2c 8 \u8f6e\uff09\uff1a\u4e0e player._sanitize_stats \u4fdd\u6301\u4e00\u81f4\u3002\n'
         '\t# \u26a0\ufe0f \u4e0d\u52a0\u8fd9\u884c\u4e5f\u4e0d\u4f1a\u62a5\u9519\uff08\u8fd9\u4e24\u952e\u4e0d\u5728\u4e0a\u9762\u7684 stat_limits \u6821\u9a8c\u8868\u91cc\uff09\uff0c\n'
         '\t#    \u4f46\u8bfb\u6863\u540e\u4f1a\u628a\u8d1f\u6570\u539f\u6837\u6062\u590d \u2014\u2014 \u90a3\u7b49\u4e8e\u300c\u7a7f\u7532\u6b63\u6570\u53d8\u8d1f\u6570\u300d\u7684\u540c\u7c7b\u9759\u9ed8\u5751\u3002\n'
         '\tstats.throw_speed_bonus = maxf(0.0, float(stats.throw_speed_bonus))\n'
         '\tstats.throw_range_bonus = maxf(0.0, float(stats.throw_range_bonus))\n',
         "_sanitize_stats"),
    ]),
    (r"D:/code/firstProject-ai/TheGreatestProject/game/scripts/ui/hud.gd", [
        ('\t"bullet_speed_bonus": "\u5f39\u901f", "bullet_range_bonus": "\u5c04\u7a0b",\n',
         '\t"bullet_speed_bonus": "\u5f39\u901f", "bullet_range_bonus": "\u5c04\u7a0b",\n'
         '\t"throw_speed_bonus": "\u6295\u63b7\u901f\u5ea6", "throw_range_bonus": "\u6295\u63b7\u8ddd\u79bb",\n',
         "HUD \u540d\u8868"),
    ]),
]

fail = []
for path, repls in JOBS:
    src = io.open(path, encoding="utf-8").read()
    orig = src
    for old, new, tag in repls:
        n = src.count(old)
        if n != 1:
            fail.append("%s / %s -> 命中 %d 次" % (path.rsplit("/", 1)[-1], tag, n))
            continue
        src = src.replace(old, new)
    if src != orig and not any(path.rsplit("/", 1)[-1] in f for f in fail):
        io.open(path, "w", encoding="utf-8", newline="").write(src)
        print("OK %-14s %s" % (path.rsplit("/", 1)[-1], "已写入"))
    else:
        print("-- %-14s 未写" % path.rsplit("/", 1)[-1])

if fail:
    print("!! 有替换没命中：")
    for f in fail:
        print("   - " + f)
    sys.exit(1)
print("全部完成")
