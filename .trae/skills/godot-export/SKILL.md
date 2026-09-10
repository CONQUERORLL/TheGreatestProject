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
| Android SDK build-tools | `D:\code\android\sdk\build-tools\35.0.0` |
| JDK | `D:\code\android\jdk`（apksigner 需 `$env:JAVA_HOME`） |
| 导出目录 | `game\export\` |
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

```powershell
if (-not (Test-Path "D:\code\firstProject-ai\TheGreatestProject\game\export")) {
    New-Item -ItemType Directory -Path "D:\code\firstProject-ai\TheGreatestProject\game\export" | Out-Null
}
```

### 3. 导出

```powershell
& "D:\code\godot\Godot_v4.7.2-stable_win64_console.exe" --headless `
    --path "D:\code\firstProject-ai\TheGreatestProject\game" `
    --export-release "Android" export/BrotatoLite.apk 2>$null
# 检查 EXIT=$LASTEXITCODE 应为 0
```

**必须检查退出码**。非 0 即失败，要读日志（`2>&1`）排查，不可忽略。

### 4. 验证产物存在 + 大小

```powershell
Get-Item "D:\code\firstProject-ai\TheGreatestProject\game\export\BrotatoLite.apk" |
    Select-Object @{N="MB";E={[math]::Round($_.Length/1MB,1)}}, LastWriteTime
```

- APK 预期 ~25 MB；EXE 预期 ~104 MB（含 .pck）
- 文件必须真实存在且大小 > 1 MB，否则导出失败

### 5. APK 验签（仅 APK 需要，EXE 跳过）

```powershell
$env:JAVA_HOME = "D:\code\android\jdk"
& "D:\code\android\sdk\build-tools\35.0.0\apksigner.bat" verify `
    --print-certs "D:\code\firstProject-ai\TheGreatestProject\game\export\BrotatoLite.apk"
```

**通过标准**：输出包含 `Signer #1 certificate DN: CN=BrotatoLite, O=CONQUERORLL`，且无错误。签名不通过的 APK 不能交付。

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
7. **产物被 .gitignore 忽略**：`game/export/*` 不入库，删除不影响仓库；但 `export_presets.cfg` **入库**，keystore 修复务必提交到 mobile 分支，否则下次合并又丢。
