"""第 8 轮 · 第 2 条：codex 文案收敛 + shop_ui 悬浮/点击接线。"""
import io
import sys

CODEX = r"D:/code/firstProject-ai/TheGreatestProject/game/scripts/ui/codex.gd"
SHOP = r"D:/code/firstProject-ai/TheGreatestProject/game/scripts/ui/shop_ui.gd"

fail = []

# ============ codex.gd：_effect_lines 改为薄封装 ============
src = io.open(CODEX, encoding="utf-8").read()
start_marker = "## effects \u5b57\u5178 \u2192 \u4e2d\u6587\u6548\u679c\u884c\uff08\u56fe\u9274/\u5347\u7ea7/\u9053\u5177\u5171\u7528\uff09\n"
i = src.find(start_marker)
if i < 0:
    fail.append("codex.gd: 找不到 _effect_lines 抬头注释")
else:
    fn = src.find("func _effect_lines(effects: Dictionary) -> Array:\n", i)
    if fn < 0:
        fail.append("codex.gd: 找不到 _effect_lines 函数头")
    else:
        end = src.find("\n\treturn out\n", fn)
        if end < 0:
            fail.append("codex.gd: 找不到 _effect_lines 结尾")
        else:
            new_fn = (
                "## effects \u5b57\u5178 \u2192 \u4e2d\u6587\u6548\u679c\u884c\n"
                "## \u26a0\ufe0f 2026-09-17\uff08\u7b2c 8 \u8f6e\uff09\u5b9e\u73b0**\u642c\u5230 `EntryText.effect_lines`**\uff1a\u5546\u5e97\u4e0e\u6682\u505c\u9762\u677f\u7684\n"
                "##    \u300c\u70b9\u51fb\u770b\u52a0\u6210\u300d\u8981\u7528\u540c\u4e00\u4efd\u6587\u6848\uff0c\u4e09\u5904\u5404\u5199\u4e00\u4efd\u5fc5\u7136\u4f1a\u6f0f\u6539\uff08\u65b0\u589e\u6548\u679c\u952e\u53ea\u6539\u4e00\u5904\uff09\u3002\n"
                "##    \u8fd9\u91cc\u4fdd\u7559\u540c\u540d\u8584\u5c01\u88c5 \u2014\u2014 codex.gd \u5185\u90e8\u7684\u8c03\u7528\u70b9\u4e00\u884c\u90fd\u4e0d\u7528\u6539\u3002\n"
                "func _effect_lines(effects: Dictionary) -> Array:\n"
                "\treturn EntryText.effect_lines(effects)\n"
            )
            src = src[:i] + new_fn + src[end + 1:]
            io.open(CODEX, "w", encoding="utf-8", newline="").write(src)
            print("OK codex.gd    _effect_lines 已改为薄封装")

# ============ shop_ui.gd ============
src = io.open(SHOP, encoding="utf-8").read()
orig = src
REPL = []

# ---- ① 属性行挂悬浮说明 ----
REPL.append((
    '\tvar l := Label.new()\n'
    '\tl.text = name_text\n'
    '\tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL\n'
    '\tl.add_theme_font_size_override("font_size", 13)\n'
    '\tl.add_theme_color_override("font_color", Color("9aa3b2"))\n'
    '\tl.mouse_filter = Control.MOUSE_FILTER_IGNORE\n'
    '\trow.add_child(l)\n',
    '\tvar l := Label.new()\n'
    '\tl.text = name_text\n'
    '\tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL\n'
    '\tl.add_theme_font_size_override("font_size", 13)\n'
    '\tl.add_theme_color_override("font_color", Color("9aa3b2"))\n'
    '\tl.mouse_filter = Control.MOUSE_FILTER_IGNORE\n'
    '\t# \u60ac\u6d6e\u770b\u8be5\u5c5e\u6027\u7684\u5177\u4f53\u542b\u4e49\uff08\u7b2c 8 \u8f6e\uff09\u3002`attach_hover` \u4f1a\u628a\u8fd9**\u4e00\u4e2a Label**\n'
    '\t# \u7f6e\u4e3a STOP\uff0c\u6574\u884c\u4ecd\u662f IGNORE \u2014\u2014 \u6240\u4ee5\u4e0d\u4f1a\u6321\u4f4f\u53f3\u4fa7\u6570\u503c\u6216\u4e0b\u65b9\u6309\u94ae\u3002\n'
    '\tHintBubble.attach_hover(l, name_text, EntryText.stat_help(name_text), self)\n'
    '\trow.add_child(l)\n',
    "\u5c5e\u6027\u884c hover",
))

# ---- ② 商品卡物品名：点击看详情 ----
REPL.append((
    '\tname_l.mouse_filter = Control.MOUSE_FILTER_IGNORE\n\tbox.add_child(name_l)\n',
    '\tname_l.mouse_filter = Control.MOUSE_FILTER_IGNORE\n'
    '\tbox.add_child(name_l)\n'
    '\t# \u70b9\u51fb\u7269\u54c1\u540d \u2192 \u5f39\u51fa\u300c\u52a0\u6210 + \u63cf\u8ff0\u300d\u8be6\u60c5\uff08\u7b2c 8 \u8f6e\uff09\u3002\n'
    '\t# provider \u5728**\u70b9\u51fb\u90a3\u4e00\u523b**\u624d\u6c42\u503c\uff0c\u6240\u4ee5\u62ff\u5230\u7684\u4e00\u5b9a\u662f\u5f53\u573a\u6570\u636e\uff08\u4e0d\u662f\u6302\u8f7d\u65f6\u7684\u65e7\u503c\uff09\u3002\n'
    '\tHintBubble.attach_click(name_l, _good_detail_provider(i), self)\n',
    "\u5546\u54c1\u540d\u70b9\u51fb",
))

# ---- ③ 右侧已购：法宝名 / 道具名 点击看详情 ----
REPL.append((
    '\t\t\tanm.mouse_filter = Control.MOUSE_FILTER_IGNORE\n\t\t\tarow.add_child(anm)\n',
    '\t\t\tanm.mouse_filter = Control.MOUSE_FILTER_IGNORE\n'
    '\t\t\tarow.add_child(anm)\n'
    '\t\t\tHintBubble.attach_click(anm, _entry_detail_provider("artifact", aid), self)\n',
    "法宝名点击",
))
REPL.append((
    '\t\tnm.mouse_filter = Control.MOUSE_FILTER_IGNORE\n\t\trow.add_child(nm)\n',
    '\t\tnm.mouse_filter = Control.MOUSE_FILTER_IGNORE\n'
    '\t\trow.add_child(nm)\n'
    '\t\tHintBubble.attach_click(nm, _entry_detail_provider("item", id), self)\n',
    "道具名点击",
))

# ---- ④ 新增三个详情 helper（挂在 _group_label 之前）----
REPL.append((
    '## \u5206\u7ec4\u5c0f\u6807\u9898\uff08\u6cd5\u5b9d / \u9053\u5177\uff09\uff1a',
    '## ---- \u70b9\u51fb\u8be6\u60c5\uff08\u7b2c 8 \u8f6e\uff09----\n'
    '## \u628a\u6761\u76ee id \u89e3\u6790\u6210 `{title, body}`\u3002\u5b9e\u73b0\u5168\u5728 `EntryText`\uff0c\u8fd9\u91cc\u53ea\u505a\u300c\u54ea\u4e2a\u8868\u53bb\u67e5\u300d\u3002\n'
    'func _entry_detail_by(kind: String, id: String) -> Dictionary:\n'
    '\tmatch kind:\n'
    '\t\t"artifact":\n'
    '\t\t\treturn EntryText.entry_detail(Registry.get_artifact(id), "\u6cd5\u5b9d")\n'
    '\t\t"weapon":\n'
    '\t\t\treturn EntryText.entry_detail(Registry.weapons.get(id, {}), "\u6b66\u5668")\n'
    '\t\t"upgrade":\n'
    '\t\t\treturn EntryText.entry_detail(Registry.upgrades.get(id, {}), "\u5347\u7ea7")\n'
    '\t\t_:\n'
    '\t\t\treturn EntryText.entry_detail(Registry.items.get(id, {}), "\u9053\u5177")\n'
    '\n'
    'func _entry_detail_provider(kind: String, id: String) -> Callable:\n'
    '\treturn func() -> Dictionary:\n'
    '\t\treturn _entry_detail_by(kind, id)\n'
    '\n'
    '## \u5546\u54c1\u5361\u70b9\u51fb\u8be6\u60c5\uff1a\u56de Registry \u53d6**\u539f\u59cb**\u6761\u76ee\u3002\n'
    '## \u26a0\ufe0f `goods[i].desc` \u4f1a\u88ab\u8fdb\u5316\u63d0\u793a\u6539\u5199\uff08\u300c\u8fdb\u5316 1/3 \u2192 \u5e9a\u91d1\u5251\u57df\u300d\uff09\uff0c\n'
    '##    \u76f4\u63a5\u62ff\u5b83\u5f53\u63cf\u8ff0\u4f1a\u8ba9\u73a9\u5bb6\u70b9\u5f00\u770b\u5230\u7684\u662f\u8fdb\u5ea6\u6761\u800c\u4e0d\u662f\u6b66\u5668\u8bf4\u660e\u3002\n'
    'func _good_detail(i: int) -> Dictionary:\n'
    '\tif i < 0 or i >= goods.size():\n'
    '\t\treturn { "title": "", "body": "" }\n'
    '\tvar g: Dictionary = goods[i]\n'
    '\tvar kind := String(g.get("kind", ""))\n'
    '\tif kind == "weapon":\n'
    '\t\treturn _entry_detail_by("weapon", String(g.get("wtype", "")))\n'
    '\treturn _entry_detail_by(kind, String(g.get("id", "")))\n'
    '\n'
    'func _good_detail_provider(i: int) -> Callable:\n'
    '\treturn func() -> Dictionary:\n'
    '\t\treturn _good_detail(i)\n'
    '\n'
    '## \u5206\u7ec4\u5c0f\u6807\u9898\uff08\u6cd5\u5b9d / \u9053\u5177\uff09\uff1a',
    "\u8be6\u60c5 helper",
))

# ---- ⑤ 商店重开时收起气泡（否则会留一张上一家店的卡）----
REPL.append((
    'func open(shop_wave: int) -> void:\n',
    'func open(shop_wave: int) -> void:\n'
    '\tHintBubble.hide_for(self)   # \u91cd\u5f00\u65f6\u6536\u8d77\u4e0a\u4e00\u5bb6\u5e97\u6b8b\u7559\u7684\u8be6\u60c5\u5361\n',
    "open \u6536\u6c14\u6ce1",
))

for old, new, tag in REPL:
    n = src.count(old)
    if n != 1:
        fail.append("shop_ui.gd / %s -> 命中 %d 次" % (tag, n))
        continue
    src = src.replace(old, new)

if src != orig and not any("shop_ui" in f for f in fail):
    io.open(SHOP, "w", encoding="utf-8", newline="").write(src)
    print("OK shop_ui.gd  已写入 %d 处" % len(REPL))

if fail:
    print("!! 有问题：")
    for f in fail:
        print("   - " + f)
    sys.exit(1)
print("完成")
