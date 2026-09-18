import io

P = r"D:\code\firstProject-ai\TheGreatestProject\.trae\skills\godot-export\SKILL.md"

raw = open(P, "rb").read()
crlf = raw.count(b"\r\n") > 0
s = raw.decode("utf-8").replace("\r\n", "\n")

B = chr(96) * 3  # 三反引号

edits = []

edits.append((
    "| Android SDK build-tools | " + B.join(["`D:\\code\\android\\sdk\\build-tools\\35.0.0` |\n| JDK ", ""]) ,
    None,
))

# -------- R1: 环境常量表 --------
edits = []
edits.append((
    "| Android SDK build-tools | `D:\\code\\android\\sdk\\build-tools\\35.0.0` |\n"
    "| JDK | `D:\\code\\android\\jdk`（apksigner 需 `$env:JAVA_HOME`） |\n"
    "| 导出目录 | `game\\export\\` |",
    "| Android SDK build-tools | `D:\\code\\android\\sdk\\build-tools\\36.0.0`（含 aapt / aapt2 / apksigner；35.0.0 也在，统一用 36） |\n"
    "| JDK | `D:\\code\\android\\jdk`（apksigner 需 `$env:JAVA_HOME`） |\n"
    "| 导出目录 | **仓库根** `D:\\code\\firstProject-ai\\TheGreatestProject\\export\\` ⚠️ **不是** `game\\export\\`（该目录并不存在）；`.gitignore` 首行的 `export/` 指的就是它 |"
))

# -------- R2: step2 建目录 --------
edits.append((
    'Godot **不会自动创建**目标目录，缺失会报"目标文件夹不存在"。\n\n'
    + B + 'powershell\n'
    'if (-not (Test-Path "D:\\code\\firstProject-ai\\TheGreatestProject\\game\\export")) {\n'
    '    New-Item -ItemType Directory -Path "D:\\code\\firstProject-ai\\TheGreatestProject\\game\\export" | Out-Null\n'
    '}\n'
    + B,
    'Godot **不会自动创建**目标目录，缺失会报"目标文件夹不存在"。\n'
    '⚠️ 要建的是**仓库根**的 `export\\` —— 建 `game\\export\\` 是白建（真去那里导出还会报错）。\n\n'
    + B + 'powershell\n'
    'if (-not (Test-Path "D:\\code\\firstProject-ai\\TheGreatestProject\\export")) {\n'
    '    New-Item -ItemType Directory -Path "D:\\code\\firstProject-ai\\TheGreatestProject\\export" | Out-Null\n'
    '}\n'
    + B
))

# -------- R3: step3 导出命令前后加 CWD 说明 --------
edits.append((
    "### 3. 导出\n\n" + B + "powershell\n",
    "### 3. 导出\n\n"
    "⚠️ 输出路径（`export/BrotatoLite.apk`）是相对**当前工作目录**解析的，**不是**相对 `--path` ⇒ "
    "必须在**仓库根**执行，否则会写到不存在的 `game\\export\\`。\n\n"
    + B + "powershell\n"
))

# -------- R4: step4 校验路径 --------
edits.append((
    'Get-Item "D:\\code\\firstProject-ai\\TheGreatestProject\\game\\export\\BrotatoLite.apk" |',
    'Get-Item "D:\\code\\firstProject-ai\\TheGreatestProject\\export\\BrotatoLite.apk" |'
))
edits.append((
    "- APK 预期 ~25 MB；EXE 预期 ~104 MB（含 .pck）",
    "- APK 预期 ~28 MB（2026-09-18 实测 **28,007,485** 字节）；EXE 预期 ~105.5 MB（实测 **110,694,240** 字节）"
))

# -------- R5: step5 验签路径与版本 --------
edits.append((
    '& "D:\\code\\android\\sdk\\build-tools\\35.0.0\\apksigner.bat" verify `\n'
    '    --print-certs "D:\\code\\firstProject-ai\\TheGreatestProject\\game\\export\\BrotatoLite.apk"',
    '& "D:\\code\\android\\sdk\\build-tools\\36.0.0\\apksigner.bat" verify `\n'
    '    --print-certs "D:\\code\\firstProject-ai\\TheGreatestProject\\export\\BrotatoLite.apk"'
))

# -------- R6: 新增 aapt 核验章节（插在「交付报告格式」之前） --------
new_sec = (
    "## APK 内容核验（必做：验签只证明「签名有效」，不证明「内容对」）\n\n"
    "用 `aapt` 从 **APK 自身**读，别去读 `export_presets.cfg`（预设可能与实际不符）：\n\n"
    + B + "powershell\n"
    "$aapt = \"D:\\code\\android\\sdk\\build-tools\\36.0.0\\aapt.exe\"\n"
    "$apk  = \"D:\\code\\firstProject-ai\\TheGreatestProject\\export\\BrotatoLite.apk\"\n"
    "& $aapt dump badging $apk\n"
    "& $aapt dump xmltree $apk AndroidManifest.xml\n"
    + B + "\n\n"
    "| 检查项 | 期望（2026-09-18 实测） |\n"
    "|---|---|\n"
    "| `package` | `com.conquerorll.brotatolite` / versionCode `1` / versionName `1.0.0` |\n"
    "| `sdkVersion` | **24**（⚠️ 预设里 `gradle_build/min_sdk` **是空的**，实际值来自模板默认） |\n"
    "| `targetSdkVersion` | **36**（同理，`target_sdk` 也是空） |\n"
    "| `native-code` | **仅 `arm64-v8a`**（见「常见坑 8」） |\n"
    "| `uses-permission` | `android.permission.VIBRATE` |\n"
    "| `uses-feature` | `android.hardware.faketouch`、`android.hardware.screen.landscape` |\n"
    "| 启动入口 | `activity-alias` **`com.godot.game.GodotAppLauncher`**，带 `action.MAIN` + `category.LAUNCHER` + `DEFAULT`，`exported=true` |\n\n"
    "⚠️ **`dump badging` 不会打印 `launchable-activity` 行** —— 因为启动项是 **activity-alias** 而非 activity。"
    "**别据此误判「没有启动图标 / 装上也打不开」**；用 `dump xmltree` 确认 `GodotAppLauncher` 上有 `LAUNCHER` 即可。\n\n"
)

edits.append(("## 交付报告格式", new_sec + "## 交付报告格式"))

# -------- R7: 常见坑新增 8/9 --------
edits.append((
    "7. **产物被 .gitignore 忽略**：`game/export/*` 不入库，删除不影响仓库；但 `export_presets.cfg` **入库**，keystore 修复务必提交到 mobile 分支，否则下次合并又丢。",
    "7. **产物被 .gitignore 忽略**：`export/`（仓库根）不入库，删除不影响仓库；但 `export_presets.cfg` **入库**，keystore 修复务必提交到 mobile 分支，否则下次合并又丢。\n"
    "8. **⚠️ APK 恒为 `arm64-v8a`，预设 `arch/*` 开关无效**（2026-09-18 实测）：预设里 `arch/armeabi-v7a=true`、`arch/arm64-v8a=true`，"
    "但产物 `native-code` 只有 arm64。已排除「模板缺库」（模板四种 ABI 都带）与「预设没被读」（包名/版本/keystore/权限**全都生效**）；"
    "把 `arch/x86_64` 翻成 `true` 重导做对照 → 产物**仍只有 arm64** ⇒ **headless 导出忽略 `arch/*`**。"
    "`game/tools/_abi_probe.py` 可复跑该实验。后果：32 位老机 / x86 模拟器装不上；"
    "Android 7.0+ 的 64 位手机与 Google Play 不受影响。要出 32 位包需走编辑器 GUI。\n"
    "9. **环境坑：删产物别用 `os.remove()`**（宿主 safe-delete shim 会抛 `OSError` 且文件留在原地），"
    "PS 的 `Remove-Item` 也可能**静默失败**（返回 0 但文件还在）→ 用 `git clean -f -x -- <确切路径>`，删完用 Python 复查目录。"
))

for i, (old, new) in enumerate(edits, 1):
    n = s.count(old)
    assert n == 1, "edit #%d 命中 %d 次（应为 1）：%r" % (i, n, old[:60])
    s = s.replace(old, new)
    print("ok godot-export #%d" % i)

out = s.replace("\n", "\r\n") if crlf else s
io.open(P, "w", encoding="utf-8", newline="").write(out)
d = open(P, "rb").read()
print("godot-export/SKILL.md -> %d bytes, CRLF=%d, LF=%d" % (len(d), d.count(b"\r\n"), d.count(b"\n")))
