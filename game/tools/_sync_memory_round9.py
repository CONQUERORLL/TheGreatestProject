# -*- coding: utf-8 -*-
"""第 9 轮记忆归档（对齐 _sync_memory_round8.py 的做法）。

做两件事：
  1. 往 `.workbuddy/memory/2026-09-17.md` **追加**第 9 轮工作日志（append-only，裸追加）
  2. 就地改 `.workbuddy/memory/MEMORY.md`：§12.10→§12.13、插第 9 轮长期条目、补 4 条静默陷阱

改完各自打印字符数；MEMORY.md 的改动可 grep 复核。
"""
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _edit_util import load, save, to_eol, apply_edits  # noqa: E402


ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MEM_DIR = os.path.join(ROOT, ".workbuddy", "memory")
DAILY = os.path.join(MEM_DIR, "2026-09-17.md")
LONG = os.path.join(MEM_DIR, "MEMORY.md")


# ---------------------------------------------------------------- 1) 日日志追加
DAILY_TAIL = r"  实机日志落在 `%APPDATA%\Godot\app_userdata\BrotatoLite\balance_log.json`，用 `balance_report.py` 读。"

ROUND9 = """

### 第 9 轮（需求驱动 4 条 · ✅ SMOKE: PASS · 已重导 exe）
用户给的 4 条需求（都不是五行主线）：浮动布局 / 连升合并 / 商店刷新倾向 / 每 4 波 BOSS + 场景属性地形区域。

**需求 1 · UI 浮动布局**
- `main_menu.gd`：「桌面一列装不下」时首页按钮宿主 单列 → `GridContainer columns=2`；
  判据与按钮尺寸读同一组常量（`HOME_BTN_H` / `HOME_BTN_GAP` / `HOME_RESERVE_H`）。
- `shop_ui.gd`：`_goods_box` 由 `HBoxContainer` → `GridContainer`；按可用宽度算**最大列数**再**平均**反推列数
  （6 格 → **3+3**，不留孤卡）；卡尺寸由行列反推，不再固定 150×238（旧版硬溢出的根源）。
- 商店左栏 / 暂停页左栏各包一层 `ScrollContainer`（原先超出只会被**裁掉**、看不到最后几行且无提示）；
  `hint_bubble.show_docked()`（宽度固定 `DOCK_W` + 右侧垂直居中）供「点击详情」用，悬浮提示仍随鼠标。

**需求 2 · 开局反复弹升级卡（根因：一波能跨 2~3 级，旧逻辑每级各弹一次且每次重抽三张）**
- 修法：连升 N 级**合并成一次**选择，选中那张**生效 N 次**（收益不减、点击 N→1）。
  `Config.LEVEL_MERGE_CAP = 3`（叠 N 次对 `dmg_mult` 这类**乘法**是复利，故封顶 3）、
  `LEVEL_MERGE_OVERFLOW_MAT = 12`（溢出级数折材料）；`level_up_ui._choose()` 末尾一次清零 `level_queue`。
- 冒烟：原「单次跨两级要重抽」断言 → 「合并成一次、收益 ×2」，钉 `merged_count()==2`。

**需求 3 · 商店刷新三倾向（全在 `shop_ui` 抽取路径，不动任何结算）**
1. 倾向已有武器：同名权重 ×`SHOP_OWNED_WEAPON_MULT`(3.0)。**只在商店侧加权**，不动 `Registry.shop_weapon_pool()`（事件卡送武器也走它）。
2. 同化度保底：整店没出同化度 → 下次权重 ×`(1+0.35×连续落空店数)`（封顶 3 档）；落空 ≥`SHOP_ASSIM_FORCE_AT`(3) 硬塞一格；刷到即归零。
3. 武器侧饱和：满槽（买了会被 `buy()` 拦） / 武器侧全进化 → 武器概率降 `WEAPON_CHANCE_SLOTS_FULL` / `WEAPON_CHANCE_SATURATED`；
   ⚠️ **关键不在降到多少，而在让出的份额去哪**：腾出的比例**全部并进升级池**（`_roll_one` 的 `wch`/`uch`）—— 这才是「道具挤占核心构筑件」的根治点。
- ⚠️ 同化度唯一稳定判据 = `Config.is_assim_entry()`（认 `effects` 里的 `assim_*` 键，**不认 id 前缀** ——
  同化度横跨 `i-assim-*`（道具）与 `wu_*`（升级）两套命名，按前缀判会**静默漏掉升级那一支**）。
- ⚠️ 同化度保底与亲和保底**互斥**（都抢「最后一格」，后跑的会换掉前一个刚塞进去的）→ 顺序：同化度保底优先。

**需求 4 · 每 4 波一个 BOSS + 场景属性地形区域**
- `Config.is_boss_wave`：标准/每日/自定义 → `w >= wave_total or w % BLOCK_WAVES == 0` = **W4/8/12/16/20**
  （刻意**复用 `BLOCK_WAVES`** 而非写死 4：区块划分与 BOSS 节奏同一处真值）；**无尽仍 `w % 10 == 0`**。
  ⚠️ `w < 1` 必须挡最前（`0 % 4 == 0` → 不挡的话 `is_boss_wave(0)` 会变成 true）。
- 新增三态：`is_final_boss_wave` / `is_mid_boss_wave`。
  ⚠️ `main._on_boss_killed` 与 `wave_manager._on_boss_killed` **必须读同一个函数** ——
  一边按「最终」、一边按「中间」会同时踩「通关面板底下又开商店」与「中间 BOSS 打完直接通关」两个相反坑。
- 中间 BOSS **限时** `midboss_duration = wave_duration × MIDBOSS_TIME_MULT`(2.5)；到时未击杀 → BOSS+干扰怪退场、**不掉落**、照常收波进商店
  （用户原话：「如果时间结束没有击杀则不掉落」）。**最终 BOSS / 无尽 BOSS 不限时**。
- 血量 `Config.boss_hp_scale`：最终波锚点 **1.0**（W20 既有平衡一字未动）；中间查 `MIDBOSS_HP_FRAC=[0.03,0.07,0.14,0.25]`；
  无尽沿用既有 `1+0.30×(w−10)`。⚠️ 中间 BOSS 血量**不能**按最终 BOSS 比例缩（56~90 万是**无限时消耗战**标定，中间 BOSS 必须能在限时内打完）。
- 掉宝：无尽前的中间 BOSS **只掉「法宝盒子」**（`GameState.boss_boxes`），波末开盒**三选一**
  （`scenes/ui/boss_box.tscn` + `scripts/ui/boss_box.gd`，池空折材料不弹空盒）；**最终/无尽 BOSS 保持直掉法宝**。
- 地形：`Config.terrain_zone_for_wave(player_element, wave)` 返回圆形区 —— 属性=本区区域元素；
  圆心 = `(玩家元素, 区块号)` 的**哈希纯函数**（不用 `GameRng` → 读档 / 每日挑战全服一致）；同区块四波**固定**（换区才挪）；距出生点 ≥ 半径。
  `fx/terrain_zone.gd` 以 0.35s 低频扫描：玩家进区 `player.set_zone_assim()`、区内**同元素**怪 `enemy.set_zone_bonus()`，**离区即撤**。
- 上限：怪侧并入 `Config.mob_resist` 的**加法项** `zone` → 天然被 `_resist_cap()`（0.75 / 0.90）吃掉；
  玩家侧受 `_sanitize_stats` 的 assim ≤ 2.0 与逐关系 cap 约束。

**⚠️⚠️ 需求 4 的三个静默陷阱（本轮全部写进注释 + 冒烟断言）**
1. **信号顺序**：`boss_killed` 的监听里 `wave_manager` **先于** `main`（子节点 `_ready` 早于父节点），
   而 `wave_manager._on_boss_killed` 紧接着 `emit wave_ended` → 商店 + 进化流程 + **写存档**。
   盒子若发在 `main` 那侧就**晚一整波**（本波末不开盒、要等下一波末才弹，横幅还会盖在商店上）。
   → 发放点移到 `wave_manager._on_boss_killed`，并用探针断言「wave_ended 触发**那一刻**盒子已存在」。
2. **临时加成必须可逆**：`player.set_zone_assim` 记的是**实际生效量**（`after − before`）而不是「想要写的量」
   —— 同化度有 2.0 上限，若按想要量撤会把玩家**固有**的同化度吃掉（不报错，只是变少）。
   且必须在**所有「本波结束 / 即将写档」的路径**上 `clear()`（`_on_wave_ended` / `_on_boss_killed` / `_on_player_died`）——
   少一处就把那片地的加成**永久烙进存档**（`SaveRun.save()` 会把 stats 原样写走）。
3. `queue_free()` 的 `_exit_tree` 要等**本帧末**才跑 → 换波时旧区迟到的撤销会把新区的加成一起抹掉（表现为「站进区里没加成」）。
   → 销毁前**同步** `clear()`，并用 `_cleared` 标志防重复撤销。

**冒烟新增 `_check_round9_boss_terrain()`**：三态 BOSS 判定（标准 / 自定义 18 波 / 无尽）· 中间 vs 最终分流 ·
血量锚点与单调 · 限时宽于普通波 · 圆的纯函数性与「不覆盖出生点」· 同区块不漂移 / 跨区块必变 ·
临时同化度**可逆**（含「已到上限时不许吃固有值」这一反向对照）· 怪侧加成进 `mob_resist` 且被 cap 吃掉 ·
直调两个处理函数验证「盒子早于 wave_ended」与「中间 BOSS 不进 VICTORY」（**现场全部还原**，并临时摘掉 `wave_ended` 监听以免把假进度写进真实存档槽）。

**跑红三次（全是真问题，不是脚本错）**
- ①`grid.alignment` —— `GridContainer` **没有** `alignment`，是**运行期**错误且会**中断整个 `_build()`**
  （reroll/heal/next 三个按钮全 null、商店整体不可用）；BGM 期望表含 W4/W8 但它们已成 BOSS 波 →
  修：改用 `SIZE_SHRINK_CENTER`；期望表只放非 BOSS 波 + 全部 BOSS 波统一查 `boss`。
- ②「换区后地形未变」= **我自己的测试 bug**（比的 W5 与 W7 同属 block 2，本就该相同）→ 改比 W4(block1) vs W6(block2)。
- ③「中间 BOSS 未发盒 0→0」= 测试只调了 `main._on_boss_killed`，而发放点已移到 wave_manager → 改直调 `wm_b._on_boss_killed()`。

**工具链**：`_apply_round9_boss_{cfg,code,fix,main,smoke}.py` / `_apply_round9_{ui,ui_menu,levelup,shop,doc,redfix_a,redfix_b}.py`；
本轮新增 **`game/tools/_edit_util.py`** —— CRLF/LF 感知的批量替换器（`load` 用 `newline=""` 不折叠换行、
每处断言命中**恰好 1 次**、**全过才写盘**、写回保持原换行）。适用于本项目「同目录混着 CRLF 与 LF」的现状。

**✅ 重导 exe**：`export/BrotatoLite.exe` = **110,692,624 字节**（旧 110,672,048，**+20,576**）·
md5 `f5d33e420662601f982d68a97aab329f` · mtime 2026-09-18 00:20；
打包清单含 `terrain_zone.gdc` / `boss_box.gdc` / `boss_box.tscn.remap`（第 9 轮新文件**确已进包**）；
启动自检 `--quit-after 90` 退出码 **0**、`Registry: 已加载 3 条自定义内容`（与第 8 轮一致，mod 数未变）。
⚠️ 启动自检多出 `2 ObjectDB instances were leaked at exit` —— verbose 定位是 `AudioStreamWAV` + `AudioStreamPlaybackWAV`
（`Music` autoload，**本轮 diff 未触碰任何音频**）→ 是 `--quit-after` 强制退出时不释放播放流的引擎侧收尾现象，**非本轮回归**。

**⚠️ 未闭环（留给实测，别当成已完成）**
- `MIDBOSS_HP_FRAC` / `MIDBOSS_TIME_MULT` 是**首次落地估价**（限时战不能照搬「无限时消耗战」的 56~90 万标定）。
  偏肉症状很好认：**「时间到 BOSS 还剩一大半血」** → 修法是先降 `MIDBOSS_HP_FRAC`，**不要去拉长限时**
  （拉长会让「没击杀就不掉落」这条规则失去意义）。
- 中间 BOSS 波不跑 `Registry.wave_composition`（沿用写死的干扰怪列表）→ 那 4 波**没有区块元素加权**。
- **20 波墙钟仍未重跑**（第 8 轮遗留 + 本轮多出 4 场 BOSS 战，半小时预算需要重新核算）。
- 文档：`docs/plans/五行体系重设计_规划.md` 已追加 **§12.13**（含被推翻的正文章节对照表：§8.2 / §8.3 / §8.5-B / §13 BGM / §附二 / §12.12）。
"""


def append_daily():
    text, crlf = load(DAILY)
    tail = to_eol(DAILY_TAIL, crlf)
    # ⚠️ 文件以换行结尾，比较前必须剥掉尾部换行 —— 拿不含换行的 tail 直接 endswith 必失败
    # （第 9 轮首次跑就踩到：日志"尾部与预期不符"其实是判据写错，锚点本身没错）
    body = text.rstrip("\r\n")
    if not body.endswith(tail):
        print("FAIL 日日志尾部与预期不符，放弃追加")
        print("   实际尾部=%r" % (body[-160:],))
        return False
    out = body + to_eol(ROUND9, crlf)
    save(DAILY, out)
    print("日日志追加: %d -> %d chars (%s)" % (len(text), len(out), "CRLF" if crlf else "LF"))
    return True


# ---------------------------------------------------------------- 2) 长期备忘
LONG_EDITS = [
    # 文档索引：§12.13 已存在
    (
        "**§12.1~§12.10 的回填清单比正文可信**。",
        "**§12.1~§12.13 的回填清单比正文可信**（§12.13 = 第 9 轮，结论优先于正文）。",
    ),
    # 插第 9 轮长期条目（放在「五行进化形态」之前）
    (
        "## ⭐ 五行进化形态（S8 第 4 轮补做 · 见体检表 §10）",
        """## ⭐ 第 9 轮（2026-09-17）：浮动布局 / 连升合并 / 商店刷新倾向 / 每 4 波 BOSS + 地形
需求驱动、非五行主线；需求 4 动了 BOSS 波根本判定 → **详见施工图 §12.13**（含被推翻正文章节对照表）。
- ⭐ **BOSS 节奏变了**：标准 / 每日 / 自定义局 = **每 4 波 + 最后一波**（W4/8/12/16/20），**无尽仍 `w%10==0`**。
  ⚠️ **三态 `is_boss_wave` / `is_final_boss_wave` / `is_mid_boss_wave` 必须被 `main` 与 `wave_manager` 读同一个** ——
  一边判「最终」一边判「中间」会同时踩两个相反的坑。
- 中间 BOSS **限时**（`wave_duration×2.5`），到时未击杀 = **不掉落、照常收波进商店**；且**只掉法宝盒子**
  （`GameState.boss_boxes`，波末三选一 `boss_box.tscn`）。**最终 / 无尽 BOSS 不限时、保持直掉法宝**。
- 血量 `boss_hp_scale`：最终波锚点 **1.0**（W20 既有平衡不动）；中间 `MIDBOSS_HP_FRAC=[0.03,0.07,0.14,0.25]`（**估价**）。
- 地形区域 `Config.terrain_zone_for_wave`：圆 + 圆心用 `(玩家元素, 区块号)` **哈希纯函数**（不用 `GameRng` → 读档 / 每日全服一致）、
  同区块四波固定、距出生点 ≥ 半径；`fx/terrain_zone.gd` 0.35s 扫描 → 玩家同化度 / 区内同元素怪抗性，**离区即撤**（受各自 cap）。
- 其余三需求：UI 浮动布局（`GridContainer` 换行 / `ScrollContainer` / `hint_bubble.show_docked`）、
  连升合并（`LEVEL_MERGE_CAP=3`、溢出折材料 12）、商店三倾向（已有武器 ×3.0 / 同化度保底 / 武器侧饱和把份额让给升级池）。
- ✅ 冒烟 `SMOKE: PASS`；已重导 `export/BrotatoLite.exe`（110,692,624 字节 / md5 `f5d33e42…`）。
- ⚠️ 未闭环：`MIDBOSS_HP_FRAC` 是估价（偏肉先降此表、**别拉长限时**）；中间 BOSS 波无区块元素加权；20 波墙钟仍未重跑。

## ⭐ 五行进化形态（S8 第 4 轮补做 · 见体检表 §10）""",
    ),
    # 补 4 条静默陷阱（接在 12 之后、断言纪律之前）
    (
        "会被**隐式当成 `bullet`** 吃满弹速加成 —— **不报错**，只是射程 / AOE 悄悄膨胀。\n\n## ⚠️ 断言纪律",
        """会被**隐式当成 `bullet`** 吃满弹速加成 —— **不报错**，只是射程 / AOE 悄悄膨胀。
13. **信号监听顺序**（第 9 轮）：子节点 `_ready()` **先于**父节点 → 同一信号 `boss_killed` 的监听里
    `wave_manager` **先于** `main`。而 `wave_manager._on_boss_killed` 紧接着 `emit wave_ended`
    （→ 商店 + 进化 + **写档**）。任何「波末必须有」的状态（如中间 BOSS 的法宝盒子）**必须写在
    wave_manager 侧、且在 emit 之前** —— 写在 `main` 那侧会**晚一整波**（盒子要等下一波末才弹，横幅还盖在商店上）。
14. **临时加成必须可逆、且按「实际生效量」撤**（第 9 轮地形区域）：记 `after − before` 而不是「想写的量」——
    属性有上限（assim ≤ 2.0），按想写量撤会把玩家**固有**值吃掉（**不报错**，只是变少）。
    且要在**所有「本波结束 / 即将写档」路径**上清（`_on_wave_ended` / `_on_boss_killed` / `_on_player_died`）——
    少一处就把加成**永久烙进存档**（`SaveRun.save()` 把 stats 原样写走）。
15. **`queue_free()` 的 `_exit_tree` 要等本帧末才跑**（第 9 轮）：换波时旧区迟到的撤销会把新区的加成
    一起抹掉（表现「站进区里没加成」）→ 销毁前**同步** `clear()`，并用 `_cleared` 标志防重复撤销。
16. **`GridContainer` 没有 `alignment`**（那是 `BoxContainer` 的）（第 9 轮）→ 写成 `grid.alignment = ...`
    是**运行期** `Invalid assignment of property`，且会**中断整个 `_build()`**（同函数后面所有控件全 null，
    商店整体不可用）。`--import` 解析门禁**抓不到**，只有跑冒烟才暴露。居中只能用 `SIZE_SHRINK_CENTER`。

## ⚠️ 断言纪律""",
    ),
]


def edit_long():
    text, crlf = load(LONG)
    out = apply_edits(text, LONG_EDITS, "MEMORY", crlf)
    if out is None:
        print("MEMORY NOT WRITTEN（文件保持原样）")
        return False
    save(LONG, out)
    print("MEMORY: %d -> %d chars (已写盘, %s)" % (len(text), len(out), "CRLF" if crlf else "LF"))
    return True


if __name__ == "__main__":
    ok1 = append_daily()
    ok2 = edit_long()
    print("RESULT:", "OK" if (ok1 and ok2) else "FAILED")
    sys.exit(0 if (ok1 and ok2) else 1)
