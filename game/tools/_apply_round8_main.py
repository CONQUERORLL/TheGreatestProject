"""第 8 轮 · 第 1+2 条：main.gd —— 暂停页补图鉴/退出 + 属性悬浮 + 条目点击详情。"""
import io
import sys

P = r"D:/code/firstProject-ai/TheGreatestProject/game/scripts/main.gd"
src = io.open(P, encoding="utf-8").read()
orig = src
REPL = []

# ---- ① 暂停页属性行：悬浮看说明 ----
REPL.append((
    'func _pause_stat_row(name_text: String, value_text: String) -> HBoxContainer:\n'
    '\tvar row := HBoxContainer.new()\n'
    '\trow.mouse_filter = Control.MOUSE_FILTER_IGNORE\n'
    '\tvar l := Label.new()\n'
    '\tl.text = name_text\n'
    '\tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL\n'
    '\tl.add_theme_font_size_override("font_size", 13)\n'
    '\tl.add_theme_color_override("font_color", Color("9aa3b2"))\n'
    '\tl.mouse_filter = Control.MOUSE_FILTER_IGNORE\n'
    '\trow.add_child(l)\n',
    'func _pause_stat_row(name_text: String, value_text: String) -> HBoxContainer:\n'
    '\tvar row := HBoxContainer.new()\n'
    '\trow.mouse_filter = Control.MOUSE_FILTER_IGNORE\n'
    '\tvar l := Label.new()\n'
    '\tl.text = name_text\n'
    '\tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL\n'
    '\tl.add_theme_font_size_override("font_size", 13)\n'
    '\tl.add_theme_color_override("font_color", Color("9aa3b2"))\n'
    '\tl.mouse_filter = Control.MOUSE_FILTER_IGNORE\n'
    '\t# \u60ac\u6d6e\u770b\u8be5\u5c5e\u6027\u7684\u5177\u4f53\u542b\u4e49\uff08\u7b2c 8 \u8f6e\uff09\u3002\u53ea\u628a**\u8fd9\u4e00\u4e2a Label** \u7f6e\u4e3a STOP\uff0c\n'
    '\t# \u6574\u884c\u4ecd\u662f IGNORE \u2014\u2014 \u4e0d\u4f1a\u6321\u4f4f\u53f3\u4fa7\u6570\u503c\u3002\u5bbf\u4e3b\u7528 `$UI`\uff08\u6c14\u6ce1\u662f Control\uff0c\n'
    '\t# \u6302 CanvasLayer \u4e0b\u624d\u80fd\u5728\u6574\u4e2a\u9178\u76d8\u5c42\u4e4b\u4e0a\u81ea\u7531\u5b9a\u4f4d\uff1b\u6302 Node2D \u4e0a\u4f1a\u8ddf\u7740\u76f8\u673a\u8dd1\uff09\u3002\n'
    '\tHintBubble.attach_hover(l, name_text, EntryText.stat_help(name_text), $UI)\n'
    '\trow.add_child(l)\n',
    "\u6682\u505c\u5c5e\u6027\u884c hover",
))

# ---- ② 暂停页打开时收起上一轮气泡 ----
REPL.append((
    'func _refresh_pause_content() -> void:\n\t# \u5de6\uff1a\u89d2\u8272 + \u5168\u6570\u503c + \u7279\u6027\n',
    'func _refresh_pause_content() -> void:\n'
    '\tHintBubble.hide_for($UI)   # \u91cd\u5efa\u9762\u677f\u524d\u5148\u6536\u8d77\u6c14\u6ce1\uff0c\u5426\u5219\u4f1a\u7559\u4e00\u5f20\u4e0a\u6b21\u7684\u65e7\u5361\n'
    '\t# \u5de6\uff1a\u89d2\u8272 + \u5168\u6570\u503c + \u7279\u6027\n',
    "_refresh_pause_content \u6536\u6c14\u6ce1",
))

# ---- ③ 暂停页「已购道具」名字点击看详情 ----
REPL.append((
    '\t\t\tl2.mouse_filter = Control.MOUSE_FILTER_IGNORE\n\t\t\trow.add_child(l2)\n',
    '\t\t\tl2.mouse_filter = Control.MOUSE_FILTER_IGNORE\n'
    '\t\t\trow.add_child(l2)\n'
    '\t\t\t# \u70b9\u51fb\u9053\u5177\u540d \u2192 \u52a0\u6210 + \u63cf\u8ff0\uff08\u7b2c 8 \u8f6e\uff09\n'
    '\t\t\tHintBubble.attach_click(l2, func() -> Dictionary:\n'
    '\t\t\t\treturn EntryText.entry_detail(Registry.items.get(id, {}), "\u9053\u5177"), $UI)\n',
    "\u6682\u505c\u9053\u5177\u540d\u70b9\u51fb",
))
# ---- ④ 暂停页法宝行点击看详情 ----
REPL.append((
    '\t\tnm.add_theme_color_override("font_color", Config.rarity_color(a.get("rarity", "common")))\n'
    '\t\tnm.mouse_filter = Control.MOUSE_FILTER_IGNORE\n'
    '\t\trow.add_child(nm)\n',
    '\t\tnm.add_theme_color_override("font_color", Config.rarity_color(a.get("rarity", "common")))\n'
    '\t\tnm.mouse_filter = Control.MOUSE_FILTER_IGNORE\n'
    '\t\trow.add_child(nm)\n'
    '\t\tHintBubble.attach_click(nm, func() -> Dictionary:\n'
    '\t\t\treturn EntryText.entry_detail(Registry.get_artifact(aid), "\u6cd5\u5b9d"), $UI)\n',
    "\u6682\u505c\u6cd5\u5b9d\u540d\u70c9\u51fb",
))

# ---- ⑤ 暂停页按钮区补「图鉴」「退出游戏」 ----
REPL.append((
    '\tvar menu_btn := Button.new()\n'
    '\tmenu_btn.text = "\u8fd4\u56de\u4e3b\u83dc\u5355"\n'
    '\tmenu_btn.custom_minimum_size = Vector2(act_w, act_h)\n'
    '\tmenu_btn.pressed.connect(_goto_main_menu)\n'
    '\tcenter.add_child(menu_btn)\n',
    '\tvar menu_btn := Button.new()\n'
    '\tmenu_btn.text = "\u8fd4\u56de\u4e3b\u83dc\u5355"\n'
    '\tmenu_btn.custom_minimum_size = Vector2(act_w, act_h)\n'
    '\tmenu_btn.pressed.connect(_goto_main_menu)\n'
    '\tcenter.add_child(menu_btn)\n'
    '\t# ---- \u7b2c 8 \u8f6e\uff1a\u6682\u505c\u9875\u8865\u300c\u56fe\u9274\u300d\u4e0e\u300c\u9000\u51fa\u6e38\u620f\u300d----\n'
    '\t# \u7528\u6237\u53cd\u9988\u300c\u6e38\u620f\u4e2d\u6682\u505c\u770b\u4e0d\u5230\u9000\u51fa\u300d\u3002\u67e5\u8bc1\uff1a\u8fd9\u4e00\u9875\u539f\u672c**\u53ea\u6709**\n'
    '\t# \u300c\u7ee7\u7eed\u6e38\u620f / \u8fd4\u56de\u4e3b\u83dc\u5355\u300d\u2014\u2014 \u6839\u672c\u6ca1\u6709\u9000\u51fa\u5165\u53e3\uff08\u4e0d\u662f\u88ab\u6321\u4f4f\uff09\u3002\n'
    '\t# \u800c\u56de\u4e3b\u83dc\u5355\u540e\uff0c\u9996\u9875\u7684\u300c\u9000\u51fa\u300d\u5728 16:9 \u5168\u5c4f\u53c8\u4f1a\u88ab\u5207\u6389\n'
    '\t# \uff08\u89c1 `main_menu._build_home`\uff09\u2014\u2014 \u4e24\u4e2a bug \u53e0\u8d77\u6765\u5c31\u662f\u300c\u9000\u4e0d\u51fa\u53bb\u300d\u3002\n'
    '\t# \u56fe\u9274\u6309\u94ae\u540c\u6837\u662f\u7528\u6237\u8981\u6c42\uff1a\u300c\u9700\u8981\u6682\u505c\u65f6\u53ef\u4ee5\u770b\u56fe\u9274\u300d\u3002\n'
    '\tvar codex_btn := Button.new()\n'
    '\tcodex_btn.text = "\u56fe\u9274"\n'
    '\tcodex_btn.custom_minimum_size = Vector2(act_w, act_h)\n'
    '\tcodex_btn.tooltip_text = "\u67e5\u770b\u4e94\u884c / \u6b66\u5668 / \u9053\u5177 / \u6cd5\u5b9d / \u654c\u4eba / \u5947\u9047 / \u6210\u5c31"\n'
    '\tcodex_btn.pressed.connect(_open_codex_from_pause)\n'
    '\tcenter.add_child(codex_btn)\n'
    '\tvar quit_btn := Button.new()\n'
    '\tquit_btn.text = "\u9000\u51fa\u6e38\u620f"\n'
    '\tquit_btn.custom_minimum_size = Vector2(act_w, act_h)\n'
    '\tquit_btn.tooltip_text = "\u76f4\u63a5\u9000\u51fa\u5230\u684c\u9762\uff08\u672c\u6ce2\u8fdb\u5ea6 = \u4e0a\u4e00\u6ce2\u8fdb\u5546\u5e97\u65f6\u7684\u5feb\u7167\uff09"\n'
    '\tquit_btn.pressed.connect(_quit_game)\n'
    '\tcenter.add_child(quit_btn)\n',
    "\u6682\u505c\u9875\u56fe\u9274/\u9000\u51fa\u6309\u94ae",
))

# ---- ⑥ toggle_pause 关闭时也收气泡 ----
REPL.append((
    '\telif GameState.phase == GameState.Phase.PAUSED:\n'
    '\t\tGameState.set_phase(_phase_before_pause)\n'
    '\t\t_pause_overlay.visible = false\n',
    '\telif GameState.phase == GameState.Phase.PAUSED:\n'
    '\t\tGameState.set_phase(_phase_before_pause)\n'
    '\t\t_pause_overlay.visible = false\n'
    '\t\tHintBubble.hide_for($UI)   # \u5173\u6682\u505c\u9875\u65f6\u6536\u8d77\u60ac\u6d6e\u8bf4\u660e\n',
    "toggle_pause \u6536\u6c14\u6ce1",
))

# ---- ⑦ 新增 _open_codex_from_pause / _quit_game（挂在 _on_codex_closed 之前）----
NEW_FUNCS = (
    '## \u6682\u505c\u9875\u7684\u300c\u56fe\u9274\u300d\u6309\u94ae\uff08\u7b2c 8 \u8f6e\uff09\u3002\n'
    '## \u26a0\ufe0f \u76f8\u4f4d\u5df2\u7ecf\u662f PAUSED\u4e86\uff0c**\u4e0d\u8981\u518d\u538b\u4e00\u5c42\u76f8\u4f4d\u6808** \u2014\u2014\n'
    '##    \u76f4\u63a5\u628a\u56fe\u9274\u53e0\u5728\u6682\u505c\u906e\u7f69\u4e4b\u4e0a\uff0c\u5173\u95ed\u540e\u81ea\u7136\u56de\u5230\u6682\u505c\u9875\u3002\n'
    '##    \u90a3\u4e48\u4e3a\u4ec0\u4e48 `_codex_phase_before = -1`\uff1f\u56e0\u4e3a -1 \u7684\u8bed\u4e49\u5c31\u662f\u300c\u5173\u95ed\u65f6\u4e0d\u8fd8\u539f\u76f8\u4f4d\u300d\uff1b\n'
    '##    \u82e5\u7167\u62c4 `_open_toast_target` \u8bb0\u6210 PAUSED\uff0c\u5173\u95ed\u65f6\u4f1a\u53cd\u590d\u5199\u540c\u4e00\u4e2a\u503c\uff08\u65e0\u5bb3\u4f46\u8bef\u5bfc\uff09\u3002\n'
    'func _open_codex_from_pause() -> void:\n'
    '\t_ensure_codex()\n'
    '\tif _codex == null:\n'
    '\t\treturn\n'
    '\t_codex_phase_before = -1\n'
    '\tHintBubble.hide_for($UI)\n'
    '\t_codex.open()\n'
    '\n'
    '## \u9000\u51fa\u6e38\u620f\uff08\u7b2c 8 \u8f6e\uff09\uff1a\u6682\u505c\u9875\u4e0e\u7ed3\u7b97\u9875\u5171\u7528\u3002\n'
    '## \u26a0\ufe0f \u4e0d\u505a\u4efb\u4f55\u5b58\u6863\u52a8\u4f5c\u3002`SaveRun` \u7684\u5b58\u6863\u70b9\u662f\u300c\u6ce2\u672b\u8fdb\u5546\u5e97\u300d\u4e0e\u300c\u6ce2\u5f00\u59cb\u300d\uff0c\n'
    '##    \u6218\u6597\u4e2d\u9000\u51fa\u7528\u7684\u662f\u4e0a\u4e00\u6ce2\u5feb\u7167 \u2014\u2014 \u4e0e\u300c\u8fd4\u56de\u4e3b\u83dc\u5355\u300d\u5b8c\u5168\u4e00\u81f4\uff0c\u4e0d\u4f1a\u4e22\u6574\u5c40\u8fdb\u5ea6\u3002\n'
    'func _quit_game() -> void:\n'
    '\tget_tree().quit()\n'
    '\n'
    'func _on_codex_closed() -> void:\n'
)
REPL.append((
    'func _on_codex_closed() -> void:\n',
    NEW_FUNCS,
    "_open_codex_from_pause / _quit_game",
))

# ---- ⑧ 死亡页 / 胜利页补「退出游戏」 ----
REPL.append((
    '\tback_btn.pressed.connect(_goto_main_menu)\n\tdead_vbox.add_child(back_btn)\n',
    '\tback_btn.pressed.connect(_goto_main_menu)\n'
    '\tdead_vbox.add_child(back_btn)\n'
    '\t# \u7b2c 8 \u8f6e\uff1a\u7ed3\u7b97\u9875\u4e5f\u5f97\u80fd\u9000 \u2014\u2014 \u5426\u5219\u53ea\u80fd\u5148\u56de\u4e3b\u83dc\u5355\u518d\u627e\u90a3\u4e2a\u88ab\u5207\u6389\u7684\u300c\u9000\u51fa\u300d\n'
    '\tvar dead_quit := Button.new()\n'
    '\tdead_quit.text = "\u9000\u51fa\u6e38\u620f"\n'
    '\tdead_quit.custom_minimum_size = Vector2(200.0, 38.0)\n'
    '\tdead_quit.pressed.connect(_quit_game)\n'
    '\tdead_vbox.add_child(dead_quit)\n',
    "死亡页退出按钮",
))

REPL.append((
    '\tvic_vbox.add_child(vic_back)\n\t_victory_menu = vic_vbox\n',
    '\tvic_vbox.add_child(vic_back)\n'
    '\tvar vic_quit := Button.new()\n'
    '\tvic_quit.text = "\u9000\u51fa\u6e38\u620f"\n'
    '\tvic_quit.custom_minimum_size = Vector2(270.0, 38.0)\n'
    '\tvic_quit.pressed.connect(_quit_game)\n'
    '\tvic_vbox.add_child(vic_quit)\n'
    '\t_victory_menu = vic_vbox\n',
    "胜利页退出按钮",
))

failed = []
for old, new, tag in REPL:
    n = src.count(old)
    if n == 0:
        print("!! \u8df3\u8fc7\uff08\u951a\u70b9\u4e0d\u5b58\u5728\uff09: " + tag)
        continue
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
print("OK main.gd 已写入；行数 %d -> %d" % (orig.count("\n"), src.count("\n")))
