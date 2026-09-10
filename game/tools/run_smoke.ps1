# 冒烟测试运行器（Godot headless）
#
# 为什么需要这个脚本，而不是直接 godot --headless res://tests/smoke_test.tscn：
# 测试会往 user://（即 %APPDATA%\Godot\app_userdata\<项目名>）落盘存档/图鉴/成就队列。
# 若命令被包在只放开工作区的沙箱里，这些写入会全部失败，导致「落盘类断言」假失败
# （典型症状：SMOKE: FAIL - 平台成就离线队列未落盘，而 stderr 里只有 无法写入 user:// 警告、
# 没有任何 Parse Error）。本脚本再套一层沙箱，把 %APPDATA%\Godot 也登记为可写根。
#
# 用法（任意工作目录）：
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File game\tools\run_smoke.ps1
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File game\tools\run_smoke.ps1 -Times 3
#
# 判定：看 stdout 是否出现 SMOKE: PASS。
# 不要依赖退出码 —— Godot Windows 版是 GUI 子系统 exe，经 Start-Process 拉起时拿不到 $LASTEXITCODE。

param(
	[int]$Times = 1,
	[string]$Godot = 'C:\Users\CONQUEROR\AppData\Local\Temp\dsh-godot-4.7.2\Godot_v4.7.2-stable_win64.exe'
)

$ErrorActionPreference = 'Continue'

# 路径全部由脚本自身位置推导，便于换机/换目录
$game = Split-Path -Parent $PSScriptRoot          # .../game
$root = Split-Path -Parent $game                  # 仓库根
$userDir = Join-Path $env:APPDATA 'Godot'         # user:// 的真实落点

$sb = 'c:\Program Files\Qoder CN IDE\resources\app\resources\bin\x86_64_windows\sandbox.exe'
if (-not (Test-Path $sb)) {
	# 不在沙箱环境里（例如直接在普通终端跑）：直接调 Godot 即可
	$sb = $null
}

for ($i = 1; $i -le $Times; $i++) {
	if ($Times -gt 1) { Write-Output "===== RUN $i / $Times =====" }

	$out = Join-Path $game 'smoke_out.txt'
	$err = Join-Path $game 'smoke_err.txt'
	Remove-Item $out, $err -Force -ErrorAction SilentlyContinue

	$godotArgs = @('--headless', '--path', '.', 'res://tests/smoke_test.tscn')
	if ($sb) {
		$file = $sb
		# --workspace-root 可多次指定，每指定一次就放开一个可写根
		# 注意 $Godot 必须夹在 sandbox 参数与 Godot 参数之间：
		# 漏了它 sandbox 会把 --headless 当成要启动的程序，报 CreateProcessAsUserW 失败: 2
		$all = @('--policy', 'workspace-write',
			'--workspace-root', $root,
			'--workspace-root', $userDir,
			'--timeout', '280000',
			'--cwd', $game,
			$Godot) + $godotArgs
	} else {
		$file = $Godot
		$all = $godotArgs
	}

	$p = Start-Process -FilePath $file -ArgumentList $all -WorkingDirectory $game `
		-RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
	Wait-Process -Id $p.Id -Timeout 280 -ErrorAction SilentlyContinue

	Write-Output '=== stdout (SMOKE 行) ==='
	Select-String -Path $out -Pattern 'SMOKE:' -ErrorAction SilentlyContinue |
		ForEach-Object { $_.Line }
	Write-Output '=== stderr (脚本错误) ==='
	Select-String -Path $err -Pattern 'SCRIPT ERROR|Parse Error|Failed to load script' `
		-ErrorAction SilentlyContinue | Select-Object -First 20 | ForEach-Object { $_.Line }
}
