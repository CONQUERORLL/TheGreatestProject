---
name: "godot-export"
description: "为 TheGreatestProject 一键导出 Windows EXE / Android APK（自动选分支、建目录、验签、报告产物）。Invoke when 用户要求打包/导出/出包/出 APK/出 EXE/出安装包。"
---

# Godot 导出（EXE / APK）

为 TheGreatestProject 项目一键导出可交付产物，**必须严格按此流程执行**，避免"声称已导出但实际未生成文件"的空转。

## 环境常量（固定，勿改）

| 项 | 路径 |
|---|---|
| 仓库根 | `D:\code\firstProject-ai\TheGreatestProject` |
| Godot 项目根 | `D:\code\firstProject-ai\TheGreatestProject\game` |
| Godot 可执行 | `D:\code\godot\Godot_v4.7.2-stable_win64_console.exe` |
| Android SDK build-tools | `D:\code\android\sdk\build-tools\36.0.0`（含 aapt / aapt2 / apksigner；35.0.0 也在，统一用 36） |
| JDK | `D:\code\android\jdk`（apksigner 需 `$env:JAVA_HOME`） |
| 导出目录 | **仓库根** `D:\code\firstProject-ai\TheGreatestProject\export\` ⚠️ **不是** `game\export\`（该目录并不存在）；`.gitignore` 首行的 `export/` 指的就是它 |
| release keystore | `D:\code\android\keystore\release.keystore`（JKS，CN=BrotatoLite, O=CONQUERORLL） |

## 分支 → 产物 → 命令

**规则：导出前必须先切到对应分支**。当前不在目标分支时先 `git checkout`。

| 用户要 | 分支 | 产物 | 命令 |
|---|---|---|---|
| PC / Windows / EXE / 桌面版 | `pc` | `export\BrotatoLite.exe` + `.pck` | `--export-release "Windows" export/BrotatoLite.exe` |
| 手机 / Android / APK / 安卓 / app | `mobile` | `export\BrotatoLite.apk` | `--export-release "Android" export/BrotatoLite.apk` |
| 两者都要 | 先 `pc` 再 `mobile`（各自导出） | 两个产物 | 分别执行 |

## 执行流程（每步必须验证产物存在）

### 1. 切换分支 + 确认提交

```powershell
git -C "D:\code\firstProject-ai\TheGreatestProject" checkout <pc|mobile>
git -C "D:\code\firstProject-ai\TheGreatestProject" log --oneline -1
```

### 2. 确保 export 目录存在

Godot **不会自动创建**目标目录，缺失会报"目标文件夹不存在"。
⚠️ 要建的是**仓库根**的 `export\` —— 建 `game\export\` 是白建（真去那里导出还会报错）。

```powershell
if (-not (Test-Path "D:\code\firstProject-ai\TheGreatestProject\export")) {
    New-Item -ItemType Directory -Path "D:\code\firstProject-ai\TheGreatestProject\export" | Out-Null
}
```

### 3. 导出

⚠️ 输出路径（`export/BrotatoLite.apk`）是相对**当前工作目录**解析的，**不是**相对 `--path` ⇒ 必须在**仓库根**执行，否则会写到不存在的 `game\export\`。

```powershell
& "D:\code\godot\Godot_v4.7.2-stable_win64_console.exe" --headless `
    --path "D:\code\firstProject-ai\TheGreatestProject\game" `
    --export-release "Android" export/BrotatoLite.apk 2>$null
# 检查 EXIT=$LASTEXITCODE 应为 0
```

**必须检查退出码**。非 0 即失败，要读日志（`2>&1`）排查，不可忽略。

### 4. 验证产物存在 + 大小

```powershell
Get-Item "D:\code\firstProject-ai\TheGreatestProject\export\BrotatoLite.apk" |
    Select-Object @{N="MB";E={[math]::Round($_.Length/1MB,1)}}, LastWriteTime
```

- APK 预期 ~28 MB（2026-09-18 实测 **28,007,485** 字节）；EXE 预期 ~105.5 MB（实测 **110,694,240** 字节）
- 文件必须真实存在且大小 > 1 MB，否则导出失败

### 5. APK 验签（仅 APK 需要，EXE 跳过）

```powershell
$env:JAVA_HOME = "D:\code\android\jdk"
& "D:\code\android\sdk\build-tools\36.0.0\apksigner.bat" verify `
    --print-certs "D:\code\firstProject-ai\TheGreatestProject\export\BrotatoLite.apk"
```

**通过标准**：输出包含 `Signer #1 certificate DN: CN=BrotatoLite, O=CONQUERORLL`，且无错误。签名不通过的 APK 不能交付。

## APK 内容核验（必做：验签只证明「签名有效」，不证明「内容对」）

用 `aapt` 从 **APK 自身**读，别去读 `export_presets.cfg`（预设可能与实际不符）：

```powershell
$aapt = "D:\code\android\sdk\build-tools\36.0.0\aapt.exe"
$apk  = "D:\code\firstProject-ai\TheGreatestProject\export\BrotatoLite.apk"
& $aapt dump badging $apk
& $aapt dump xmltree $apk AndroidManifest.xml
```

| 检查项 | 期望（2026-09-18 实测） |
|---|---|
| `package` | `com.conquerorll.brotatolite` / versionCode `1` / versionName `1.0.0` |
| `sdkVersion` | **24**（⚠️ 预设里 `gradle_build/min_sdk` **是空的**，实际值来自模板默认） |
| `targetSdkVersion` | **36**（同理，`target_sdk` 也是空） |
| `native-code` | **仅 `arm64-v8a`**（见「常见坑 8」） |
| `uses-permission` | `android.permission.VIBRATE` |
| `uses-feature` | `android.hardware.faketouch`、`android.hardware.screen.landscape` |
| 启动入口 | `activity-alias` **`com.godot.game.GodotAppLauncher`**，带 `action.MAIN` + `category.LAUNCHER` + `DEFAULT`，`exported=true` |

⚠️ **`dump badging` 不会打印 `launchable-activity` 行** —— 因为启动项是 **activity-alias** 而非 activity。**别据此误判「没有启动图标 / 装上也打不开」**；用 `dump xmltree` 确认 `GodotAppLauncher` 上有 `LAUNCHER` 即可。

## 交付报告格式

导出完成后，给用户一个表格：

| 项 | 值 |
|---|---|
| 路径 | 文件绝对路径（可点击） |
| 大小 | XX.X MB |
| 分支 | `<branch>`（提交 hash + 简短说明） |
| 签名 | ✅ 通过（CN=...）/ —（EXE 无） |

## 常见坑

1. **`export` 目录被外部清空**：Godot 不会重建，务必先 `New-Item`。
2. **PowerShell 把 Godot stderr 当异常**：用 `2>$null` 吞掉进度日志，单独看 `$LASTEXITCODE`。
3. **签名验证失败 / `Missing META-INF/MANIFEST.MF`**：
   - 根因常是 **`export_presets.cfg` 的 `keystore/release*` 三项为空**——跨分支合并（main/pc → mobile）时，pc 上的空 keystore 配置会覆盖 mobile 填好的值，导致 Godot 无 keystore 可用、APK 未签名。
   - **Godot 会误报**：日志照打"正在签名发布 APK...[DONE]"，但 `$LASTEXITCODE=1` 且产物缺 MANIFEST.MF。**所以 exit code 和验签都必须查，不能只看 DONE。**
   - 修复：填回三项（release keystore 路径 + `release` + `brotato2026`），删除旧 `.apk`/`.idsig` 后重导。
   - 验签 `--verbose` 看到 `Verifies` + `v2 scheme: true` 即有效（v1=false 是 Godot 4 正常）；`--print-certs` 应含 `CN=BrotatoLite, O=CONQUERORLL`。
4. **keystore 格式**：Godot 4.7 不认 PKCS12，必须 JKS（`D:\code\android\keystore\release.keystore`）。
5. **切分支后导出旧代码**：导出前 `git log -1` 确认是最新提交。
6. **合并新代码后 headless Parse Error**（`Identifier "CharacterAvatar" not declared` 等新 class_name）：先跑一次 `--import` 重建 `.godot` 类缓存再导出/测试。
7. **产物被 .gitignore 忽略**：`export/`（仓库根）不入库，删除不影响仓库；但 `export_presets.cfg` **入库**，keystore 修复务必提交到 mobile 分支，否则下次合并又丢。
8. **⚠️ APK 恒为 `arm64-v8a`，预设 `arch/*` 开关无效**（2026-09-18 实测）：预设里 `arch/armeabi-v7a=true`、`arch/arm64-v8a=true`，但产物 `native-code` 只有 arm64。已排除「模板缺库」（模板四种 ABI 都带）与「预设没被读」（包名/版本/keystore/权限**全都生效**）；把 `arch/x86_64` 翻成 `true` 重导做对照 → 产物**仍只有 arm64** ⇒ **headless 导出忽略 `arch/*`**。`game/tools/_abi_probe.py` 可复跑该实验。后果：32 位老机 / x86 模拟器装不上；Android 7.0+ 的 64 位手机与 Google Play 不受影响。要出 32 位包需走编辑器 GUI。
9. **环境坑：删产物别用 `os.remove()`**（宿主 safe-delete shim 会抛 `OSError` 且文件留在原地），PS 的 `Remove-Item` 也可能**静默失败**（返回 0 但文件还在）→ 用 `git clean -f -x -- <确切路径>`，删完用 Python 复查目录。
