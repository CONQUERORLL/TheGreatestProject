# -*- coding: utf-8 -*-
"""修 2026-09-18.md 里被 bash 命令替换吃掉的「提交入库」段。

事故原因：上一轮把含**反引号**的内容塞进 `python -c "..."`，bash 把反引号当命令替换、
把内层双引号当字符串结束 → 标识符（pc / 4ff3794 / .gitignore …）全被剥掉。
教训：**含反引号的文本绝不走 `-c` 双引号字符串**，写成 .py 文件再跑。
"""
import io

P = r"D:\code\firstProject-ai\TheGreatestProject\.workbuddy\memory\2026-09-18.md"
MARK = "## 提交入库 + 推送（01:26）"

FIXED = """## 提交入库 + 推送（01:26）
- 分支 `pc`，提交 **`4ff3794`**：**97 个文件，+21,321 / −1,821**，已 `git push origin pc`
  （`14ebed7..4ff3794`，6.7s）。覆盖第 7~9 轮全部改动（数值减半 / 唯一件 / 内容冻结 /
  交互入口 / 投掷通道 / 逐波日志 / 需求 1~4 / 中间 BOSS 血量 P0 修复）+ 施工图 §12.13/§12.13b
  + docs + 工具链；同时删除已废弃的 `obstacle.gd` / `systems/obstacles.gd`（含 .uid，共 4 个）。
- `.gitignore` 补 **`game/tools/_*.log`** —— 原先只列了 3 个具体日志名，`_import_gate.log` /
  `_pre.log` 漏网（会以 untracked 形式一直挂在 status 里）。
- ⚠️ **`.workbuddy/` 本就已忽略** → 记忆与技能快照**不进版本库**（预期行为，别去「修」）。
- 用户选择**全量提交**：`game/tools/_apply_*.py` / `_sync_*.py` 一次性留痕脚本也入版
  （历史上从未提交过，本轮起成为常规）。
- ✅ 推送可靠性做法：`GIT_TERMINAL_PROMPT=0` + `GIT_SSH_COMMAND='ssh -o BatchMode=yes'`
  把「交互式凭据挂死」变成快速失败；本机 SSH key 有效。提交信息用
  `git commit -F <.\\.git 下的临时文件>` 规避 shell 引号/换行问题，提交后立刻删该临时文件。
- ⚠️ **遗留安全项（未处理 · 属既有状态）**：`game/export_presets.cfg` 已跟踪、历史里就有明文
  Android keystore 口令（`keystore/release_password`）。本轮提交**未新增**泄露，但真要消除
  得清历史（git filter-repo）或改成环境变量 —— 属独立任务，别顺手改（会打断 Android 导出）。
"""

text = io.open(P, encoding="utf-8", newline="").read()
i = text.find(MARK)
if i < 0:
    raise SystemExit("FAIL: 找不到待修复的段落标记")
nl = "\r\n" if "\r\n" in text else "\n"
head = text[:i].rstrip("\r\n")
out = head + nl + nl + FIXED.replace("\n", nl)
io.open(P, "w", encoding="utf-8", newline="").write(out)
print("修复完成: %d -> %d chars" % (len(text), len(out)))

# 复核：反引号标识符必须都在
chk = io.open(P, encoding="utf-8").read()
for k in ["4ff3794", "orphan_placeholder_never", "`pc`", "`game/tools/_*.log`",
          "`GIT_TERMINAL_PROMPT=0`", "`keystore/release_password`"]:
    print("  %-30s -> %d" % (k, chk.count(k)))
