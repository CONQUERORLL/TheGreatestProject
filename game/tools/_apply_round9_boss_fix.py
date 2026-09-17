# -*- coding: utf-8 -*-
"""第 9 轮 · 需求 4 修正：法宝盒子的发放点必须早于 `wave_ended`。

【为什么】
  `EventBus.boss_killed` 的监听顺序 = connect 顺序。子节点的 `_ready()` 先于父节点，
  而 `WaveManager` 是 main 的子节点 → **wave_manager._on_boss_killed 先跑**，它在里面
  立刻 `EventBus.wave_ended.emit()` → main._on_wave_ended（开商店 + 存档 + 进化流程）。
  盒子若在 main._on_boss_killed 里发，就落在整条波末流程**之后**：
    · 本波末不会开盒（`_finish_evolve_flow` 已经跑完并写档了），要拖到下一波末才弹；
    · 横幅也会盖在商店界面上。
  这类"看起来只是慢了一拍"的问题极难从现象反推，所以改成：
  盒子 + 横幅一律由 **wave_manager** 在 emit wave_ended **之前**发放（它天然更早）。

跑法：
    python.exe game/tools/_apply_round9_boss_fix.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import apply_file, game_path  # noqa: E402

WAVE = game_path("scripts", "systems", "wave_manager.gd")
MAIN = game_path("scripts", "main.gd")

W_OLD = """\tboss_dead = true
\tending_started = true
\tif GameState.endless:
\t\tGameState.add_score(Config.boss_kill_score(wave))
\tfor e in get_tree().get_nodes_in_group("enemies"):
"""

W_NEW = """\tboss_dead = true
\tending_started = true
\tif GameState.endless:
\t\tGameState.add_score(Config.boss_kill_score(wave))
\telse:
\t\t# 中间 BOSS：法宝盒子 +1（波末开盒三选一，见 main._open_boss_box）。
\t\t#
\t\t# ⚠️ **必须在这里发，不能在 main._on_boss_killed 里发** ——
\t\t#    `boss_killed` 的监听顺序里 wave_manager 先于 main（子节点 _ready 早于父节点），
\t\t#    而本函数紧接着就要 emit wave_ended（→ 商店 → 存档 → 进化流程）。
\t\t#    放在 main 那侧等于"波末流程全跑完之后才拿到盒子"：本波末不会开盒，
\t\t#    要等到下一波末才弹，而且横幅会盖在商店上。
\t\tGameState.boss_boxes += 1
\t\tEventBus.banner_requested.emit("BOSS 击破！",
\t\t\t"获得法宝盒子 ×1 · 波末开箱三选一", 2.6)
\tfor e in get_tree().get_nodes_in_group("enemies"):
"""

M_OLD = """\t# 中间 BOSS（W4/8/12/16）：只给法宝盒子，波末开盒三选一。
\t# ⚠️ 必须排在这里（无尽之后、每日/通关之前）—— 它是阻止"第 4 波 BOSS 一死就通关"
\t#    的唯一闸门。少了这一步，标准局会在 W4 直接进 VICTORY。
\tif Config.is_mid_boss_wave(wave_manager.wave):
\t\tGameState.boss_boxes += 1
\t\tHaptics.rumble(0.4, 0.15, 0.2)
\t\tSfx.play("victory")
\t\tEventBus.banner_requested.emit("BOSS 击破！",
\t\t\t"获得法宝盒子 ×1 · 波末开箱三选一", 2.6)
\t\treturn
"""

M_NEW = """\t# 中间 BOSS（W4/8/12/16）：不通关，也不在这里发奖励。
\t# ⚠️ 这个 `return` 是阻止"第 4 波 BOSS 一死就通关"的唯一闸门 —— 少了它，
\t#    标准局会在 W4 直接进 VICTORY。
\t# ⚠️ 盒子的发放**不在这里**：本函数在 `boss_killed` 的监听顺序里晚于 wave_manager，
\t#    而后者已 emit 过 wave_ended（波末流程含存档）→ 在这里发会晚一整波。
\t#    真正的发放点是 `wave_manager._on_boss_killed`，见那里的注释。
\tif Config.is_mid_boss_wave(wave_manager.wave):
\t\treturn
"""


def main():
    ok = True
    ok = apply_file(WAVE, [(W_OLD, W_NEW)], "r9-fix-wave") and ok
    ok = apply_file(MAIN, [(M_OLD, M_NEW)], "r9-fix-main") and ok
    if not ok:
        sys.exit(1)
    print("ALL OK")


if __name__ == "__main__":
    main()
