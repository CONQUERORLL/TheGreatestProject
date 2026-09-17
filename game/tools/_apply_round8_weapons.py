"""第 8 轮 · 第 3 条：土炸弹改投掷物通道 + 喷火枪削溅射。
每处替换都断言「命中恰好 1 次」，任何一处没命中就整体不写盘（避免半截改动）。
"""
import io
import sys

P = r"D:/code/firstProject-ai/TheGreatestProject/game/scripts/core/config.gd"
src = io.open(P, encoding="utf-8").read()
orig = src

REPL = []

# ---- ① 厚土雷：同步投掷物类别 + 显式 bullet_life ----
REPL.append((
    '"thunder_gong_ex": { "name": "厚土雷", "ico": "\U0001f30b", "attack_type": "projectile", "sfx": "shoot_rocket", "cd": 1.35, "dmg": 30.0, "bspeed": 340.0, "splash": 115.0,',
    '"thunder_gong_ex": { "name": "厚土雷", "ico": "\U0001f30b", "attack_type": "projectile", "proj_kind": "thrown", "sfx": "shoot_rocket", "cd": 1.35, "dmg": 30.0, "bspeed": 340.0, "bullet_life": 1.1, "splash": 115.0,',
    "厚土雷 proj_kind=thrown + 显式 bullet_life",
))
REPL.append((
    '"desc": "土炸弹\u00b7进化\uff1a115px \u6e85\u5c04\uff08\u9762\u79ef 1.47\u00d7\uff09\uff0c\u5355\u4f53 DPS 2.0\u00d7\uff0c\u7729\u6655 45%", "price": 162, "shop_weight": 0 },',
    '"desc": "\u571f\u70b8\u5f39\u00b7\u8fdb\u5316\uff1a\u6295\u63b7\u7206\u70b8\u7269\uff0c\u9762\u79ef 1.47\u00d7\uff0c\u5355\u4f53 DPS 2.0\u00d7\uff0c\u7729\u6655 45%\uff08\u4ec5\u5403\u6295\u63b7\u7c7b\u52a0\u6210\uff09", "price": 162, "shop_weight": 0 },',
    "厚土雷 desc",
))

# ---- ② 喷火枪：splash 75 -> 40，并补第 8 轮说明块 ----
FLAME_COMMENT = (
    "\t# \u26a0\ufe0f\u26a0\ufe0f 2026-09-17\uff08\u7b2c 8 \u8f6e\uff09\u7528\u6237\u53cd\u9988\u300c\u55b7\u706b\u5668\u8303\u56f4\u597d\u50cf\u4e5f\u6709\u95ee\u9898\uff0c\u592a\u8fdc\u4e86\u300d\u3002\n"
    "\t#   \u67e5\u8bc1\uff1a\u5b83\u81ea\u79f0\u300c\u5c04\u7a0b\u2248110px\u300d\uff0c\u4f46**\u771f\u5b9e\u4f24\u5bb3\u534a\u5f84 = 110 + splash 75 = 185px**\n"
    "\t#   \uff08`smoke_test.gd:6781` \u65e9\u5c31\u5199\u660e\uff1a\u65e7\u53e3\u5f84\u628a\u5b83\u8bfb\u77ed\u4e86\u6574\u6574 75px\uff09\uff0c\u800c**\u706b\u7130\u89c6\u89c9\u53ea\u753b\u5230 110px**\n"
    "\t#   \uff08`flame_jet.gd` \u7684 `reach`\uff09\u2192 \u770b\u5230\u7684\u6bd4\u6253\u5230\u7684\u8fd1 75px\u3002\u7528\u6237\u770b\u5230\u7684\u5c31\u662f\u8fd9\u4e2a\u9519\u4f4d\u3002\n"
    "\t#   \u2705 \u4fee\u6cd5\uff08\u7528\u6237\u62cd\u677f\uff1a\u300c\u524a\u6e85\u5c04 + \u89c6\u89c9\u5bf9\u9f50\u300d\uff09\uff1a\n"
    "\t#     1. `splash` 75 \u2192 **40**\uff1a\u6709\u6548\u5c04\u7a0b 185 \u2192 **150px**\uff0c\u56de\u5230\u300c\u8d34\u8138\u70e7\u300d\u7684\u5b9a\u4f4d\u3002\n"
    "\t#     2. \u706b\u7130\u9525\u6539\u753b\u5230**\u6709\u6548\u5c04\u7a0b**\uff08\u89c1 `_ignite_flame_jet`\uff09\u2192 \u4ece\u6b64\u300c\u770b\u5230\u7684 = \u6253\u5230\u7684\u300d\u3002\n"
    "\t#     \u8fdb\u5316\u4f53 `flamethrower_ex` \u540c\u6b65 105 \u2192 **56**\uff08\u4fdd\u6301\u539f 1.4\u00d7 \u6bd4\u4f8b\uff09\u3002\n"
    "\t#   \u26a0\ufe0f \u4ee3\u4ef7\uff1aAOE \u9762\u79ef 17,671 \u2192 **5,027**\uff08\u221271%\uff09\uff0c\u8fdb\u5316\u4f53 34,636 \u2192 9,852\u3002\n"
    "\t#     \u5b83\u672c\u6765\u5c31\u662f\u5168\u573a\u7b2c\u4e8c\u5927 AOE\uff08\u4ec5\u6b21\u4e8e\u571f\u70b8\u5f39\uff09\uff0c\u73b0\u5728\u56de\u5230\u300c\u9ad8\u9891\u5355\u4f53 + \u5c0f\u8303\u56f4\u6e85\u5c04\u300d\u3002\n"
    "\t#     \u26a0\ufe0f \u8fd9\u662f**\u7528\u6237\u660e\u786e\u8981\u6c42\u7684\u524a\u5f31**\uff0c\u4e0d\u662f\u5931\u8861\u4fee\u6b63 \u2014\u2014 \u4e0d\u8981\u56e0\u4e3a\u300c\u91d1\u5251\u53cd\u800c\u66f4\u5f3a\u300d\u518d\u628a\u5b83\u52a0\u56de\u53bb\u3002\n"
)
anchor_flame = '\t"flamethrower": { "name": "喷火枪",'
REPL.append((anchor_flame, FLAME_COMMENT + anchor_flame, "喷火枪第 8 轮说明块"))
REPL.append((
    '"cd": 0.10, "dmg": 1.5, "bspeed": 300.0, "spread": 0.34, "bullet_life": 0.28, "splash": 75.0,',
    '"cd": 0.10, "dmg": 1.5, "bspeed": 300.0, "spread": 0.34, "bullet_life": 0.28, "splash": 40.0,',
    "喷火枪 splash 75->40",
))
REPL.append((
    '\u9ad8\u9891\u53e0\u71c3\u70e7\u5e76\u5e26 75px \u6e85\u5c04\uff0c\u6210\u7fa4\u65f6\u6536\u76ca\u7ffb\u500d", "price": 42',
    '\u9ad8\u9891\u53e0\u71c3\u70e7\u5e76\u5e26 40px \u6e85\u5c04\uff08\u6709\u6548\u5c04\u7a0b\u2248150px\uff09", "price": 42',
    "喷火枪 desc",
))
REPL.append((
    '"cd": 0.10, "dmg": 3.0, "bspeed": 300.0, "spread": 0.34, "bullet_life": 0.28, "splash": 105.0,',
    '"cd": 0.10, "dmg": 3.0, "bspeed": 300.0, "spread": 0.34, "bullet_life": 0.28, "splash": 56.0,',
    "焚天焰 splash 105->56",
))
REPL.append((
    '"desc": "\u55b7\u706b\u67aa\u00b7\u8fdb\u5316\uff1a105px \u6e85\u5c04\uff08\u9762\u79ef 1.96\u00d7\uff09\uff0c\u5355\u4f53 DPS 2.0\u00d7\uff0c\u71c3\u70e7 90%", "price": 126',
    '"desc": "\u55b7\u706b\u67aa\u00b7\u8fdb\u5316\uff1a56px \u6e85\u5c04\uff08\u6709\u6548\u5c04\u7a0b\u2248166px\uff09\uff0c\u5355\u4f53 DPS 2.0\u00d7\uff0c\u71c3\u70e7 90%", "price": 126',
    "焚天焰 desc",
))

# ---- ③ 新增两件「投掷类」道具（放进道具表 ITEMS，紧跟铳匠长管之后）----
SPEAR_ANCHOR = '\t{ "id": "i-frostcore",'
NEW_ITEMS = (
    "\t# \u6295\u63b7\u7c7b\u4e13\u5c5e\u901a\u9053\uff08\u7b2c 8 \u8f6e\uff09\uff1a\u4e0e\u5f39\u5e55\u7c7b\u7684 `bullet_speed_bonus` / `bullet_range_bonus`\n"
    "\t# \u4e92\u4e0d\u4e32\u5473\uff08\u89c1 `player._weapon_runtime_cfg` \u7684 `proj_kind` \u5206\u6d41\uff09\u3002\n"
    "\t# \u4e4b\u524d\u571f\u70b8\u5f39\u88ab\u5f39\u901f\u7c7b\u9053\u5177\u6309\u5f39\u5e55\u516c\u5f0f\u653e\u5927\uff0c\u5c04\u7a0b\u80fd\u88ab\u62c9\u5230 731px \u2014\u2014 \u8fd9\u4e24\u4ef6\u628a\u90a3\u4efd\u6536\u76ca\u6536\u56de\u5230\u300c\u4e3b\u52a8\u9009\u6295\u63b7\u6784\u7b51\u300d\u624d\u80fd\u62ff\u5230\u3002\n"
    "\t{ \"id\": \"i-fuse\", \"ico\": \"\U0001f9e8\", \"name\": \"\u706b\u7ef3\u5f15\u4fe1\", \"desc\": \"\u6295\u63b7\u7269\u98de\u884c\u901f\u5ea6 +20%\uff08\u571f\u8d28\u70b8\u5f39 / \u539a\u571f\u96f7\uff09\", \"price\": 46, \"rarity\": \"rare\", \"effects\": { \"throw_speed_bonus\": 0.20 } },\n"
    "\t{ \"id\": \"i-powder\", \"ico\": \"\u2697\", \"name\": \"\u91cd\u88c5\u836f\u7f50\", \"desc\": \"\u6295\u63b7\u7269\u98de\u884c\u8ddd\u79bb +20%\uff08\u571f\u8d28\u70b8\u5f39 / \u539a\u571f\u96f7\uff09\", \"price\": 64, \"rarity\": \"epic\", \"effects\": { \"throw_range_bonus\": 0.20 } },\n"
    "\t# \u26a0\ufe0f \u9ad8\u7206\u88c5\u8357\uff08`warhead`\uff09/ \u971c\u6838\uff08`i-frostcore`\uff09\u7b49 `aoe_radius_bonus` \u9053\u5177**\u56e0\u679c\u4e0d\u53d8**\uff1a\u5b83\u7ba1\u300c\u7206\u591a\u5927\u300d\uff0c\u4e0e\u300c\u98de\u591a\u8fdc\u300d\u6b63\u4ea4\uff0c\u4e24\u7c7b\u6295\u5c04\u7269\u90fd\u5403\u3002\n"
)
REPL.append((SPEAR_ANCHOR, NEW_ITEMS + SPEAR_ANCHOR, "新增投掷类道具 x2"))

# ---- ④ effect_tags：新键打标（亲和加权 / 相关性过滤都靠它）----
REPL.append((
    '\t\t"aoe_radius_bonus":\n\t\t\tout.append("aoe")',
    '\t\t"throw_speed_bonus":\n\t\t\tout.append("speed")\n'
    '\t\t"throw_range_bonus":\n\t\t\tout.append("range")\n'
    '\t\t"aoe_radius_bonus":\n\t\t\tout.append("aoe")',
    "effect_tags 新键",
))

# ---- ⑤ effect_sigil：新键归属印记 ----
REPL.append((
    '\t\t"aoe_radius_bonus": "blast",',
    '\t\t"throw_speed_bonus": "blast",\n\t\t"throw_range_bonus": "blast",\n\t\t"aoe_radius_bonus": "blast",',
    "effect_sigil 新键",
))

# ---- ⑥ entry_weapon_relevant：弹幕类只认「真弹幕」，投掷类只认「投掷武器」----
REPL.append((
    '##   - bullet_speed_bonus / bullet_range_bonus 需要至少一把投射（ranged）武器\n',
    '##   - bullet_speed_bonus / bullet_range_bonus 需要至少一把**弹幕**武器\n'
    '##     （投射且 `proj_kind != "thrown"` —— 土质炸弹是投掷物，不吃这一族，见 WEAPONS 抬头注释）\n'
    '##   - throw_speed_bonus / throw_range_bonus 需要至少一把**投掷**武器\n',
    "entry_weapon_relevant 注释",
))
REPL.append((
    '\tvar has_melee := false\n\tvar has_ranged := false\n\tvar has_aoe := false',
    '\tvar has_melee := false\n\tvar has_ranged := false\n\tvar has_aoe := false\n\tvar has_bullet := false\n\tvar has_thrown := false',
    "entry_weapon_relevant 变量",
))
REPL.append((
    '\t\tif String(wcfg.get("attack_type", "")) == "melee":\n'
    '\t\t\thas_melee = true\n'
    '\t\telse:\n'
    '\t\t\thas_ranged = true\n',
    '\t\tif String(wcfg.get("attack_type", "")) == "melee":\n'
    '\t\t\thas_melee = true\n'
    '\t\telse:\n'
    '\t\t\thas_ranged = true\n'
    '\t\t\tif String(wcfg.get("proj_kind", "bullet")) == "thrown":\n'
    '\t\t\t\thas_thrown = true\n'
    '\t\t\telse:\n'
    '\t\t\t\thas_bullet = true\n',
    "entry_weapon_relevant 分流",
))
REPL.append((
    '\t\t\t"bullet_speed_bonus", "bullet_range_bonus":\n\t\t\t\tif not has_ranged:\n\t\t\t\t\treturn false',
    '\t\t\t"bullet_speed_bonus", "bullet_range_bonus":\n\t\t\t\tif not has_bullet:\n\t\t\t\t\treturn false\n'
    '\t\t\t"throw_speed_bonus", "throw_range_bonus":\n\t\t\t\tif not has_thrown:\n\t\t\t\t\treturn false',
    "entry_weapon_relevant 过滤",
))

failed = []
for old, new, tag in REPL:
    n = src.count(old)
    if n != 1:
        failed.append("%s -> 命中 %d 次" % (tag, n))
        continue
    src = src.replace(old, new)

if failed:
    print("!! 未写盘，以下替换不满足「恰好 1 次」：")
    for f in failed:
        print("   - " + f)
    sys.exit(1)

io.open(P, "w", encoding="utf-8", newline="").write(src)
print("OK config.gd 已写入，%d 处替换全部命中 1 次；行数 %d -> %d"
      % (len(REPL), orig.count("\n"), src.count("\n")))
