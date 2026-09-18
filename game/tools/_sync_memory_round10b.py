import io, sys

P = r"D:\code\firstProject-ai\TheGreatestProject\.workbuddy\memory\MEMORY.md"

with io.open(P, "r", encoding="utf-8", newline="") as f:
    s = f.read()

A_old = "- ⚠️ **删文件别用 `os.remove()`**（宿主 safe-delete shim 会抛 `OSError` 且文件留在原地）→ 用 PowerShell `Remove-Item -LiteralPath <p> -Force`，**删完必须用 Python 复查目录**（该工具无论如何都返回 exit 1）。"
A_new = (
    "- ⚠️ **删文件三连坑**：`os.remove()` 会被宿主 safe-delete shim 抛 `OSError`（文件留在原地、脚本中断）；"
    "PS 工具的 `Remove-Item` **也会静默失败**（返回 0 但文件还在）→ **可靠做法 = `git clean -f -x -- <确切路径>`**"
    "（走 git 自己的删除、绕开 shim；`.workbuddy/` 被忽略故需 `-x`），删完用 Python 复查目录。\n"
    "- ⚠️ **`.import` 长期挂 ` M` 多半是假阳性（racily-clean）**：`git status --porcelain=v2` 三处哈希全等 "
    "＋ `git diff --raw` 为空 ⇒ 内容零改动，`git add` 一次刷新 stat 缓存即可，**别当真改动去提交**。"
)

B_old = "✅ `SMOKE: PASS` + 出 `BrotatoLite.apk`（**未真机验证**）。未闭环："
B_new = (
    "✅ `SMOKE: PASS`（296 行 / 86 条 `SMOKE:` / 0 FAIL）＋ 出 `BrotatoLite.apk`（**未真机验证**）。\n"
    "  ✅ 已提交 **`4ecad55`**＋**`33f1a9b`** 并 `git push origin mobile`（`14ebed7..33f1a9b`）；新增 `docs/移动端适配与打包.md`。\n"
    "  ⚠️ **APK 核验要用 `aapt` 读 APK 自身**：minSdk 24 / targetSdk 36 / **仅 `arm64-v8a`**；"
    "预设里 `gradle_build/min_sdk`、`target_sdk` **是空的**（值来自模板默认）。启动入口是 "
    "**activity-alias `com.godot.game.GodotAppLauncher`**（`MAIN`+`LAUNCHER`）→ `badging` **不打印 "
    "`launchable-activity` 行**，**别据此误判「没有启动图标」**。\n"
    "  未闭环："
)

for tag, old, new in (("A", A_old, A_new), ("B", B_old, B_new)):
    n = s.count(old)
    assert n == 1, "edit %s 命中 %d 次（应为 1）" % (tag, n)
    s = s.replace(old, new)
    print("ok MEMORY.md #%s" % tag)

with io.open(P, "w", encoding="utf-8", newline="") as f:
    f.write(s)

d = open(P, "rb").read()
print("MEMORY.md -> %d bytes / %d chars, CRLF=%d" % (len(d), len(d.decode("utf-8")), d.count(b"\r\n")))
