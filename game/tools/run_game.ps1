# 游戏启动器（带窗口运行）
#
# 为什么需要这个脚本，而不是直接 godot --path .：
# 游戏运行时会往 user://（即 %APPDATA%\Godot\app_userdata\<项目名>）落盘
# 存档 / 图鉴解锁 / 元进度 / 排行榜 / 设置。若命令被包在只放开工作区的沙箱里，
# 这些写入会全部失败（存档存不下、解锁不生效、成就队列丢失）。
# 本脚本再套一层沙箱，把 %APPDATA%\Godot 也登记为可写根。
#
# 用法（任意工作目录）：
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File game\tools\run_game.ps1
# 直接进某个场景（跳过主菜单）：
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File game\tools\run_game.ps1 -Scene res://scenes/main.tscn
# 换 Godot 版本：
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File game\tools\run_game.ps1 -Godot <exe路径>
#
# 与 run_smoke.ps1 的三点区别：
#   1. 不加 --headless —— 需要真实窗口与 GL 上下文
#   2. 不加 --timeout  —— 游戏要长期运行，不能被沙箱超时杀掉
#   3. 不 Wait-Process —— 拉起后立即返回，由玩家自己关窗口
#
# 排错：窗口起不来时先看 run_game_err.log 里有没有 SCRIPT ERROR / Parse Error。
#
# 自动化调用的坑：Godot 窗口进程会继承控制台句柄，把本脚本输出管道化
# （如 `... run_game.ps1 | Out-String`）会让调用方一直等到超时才返回——但游戏其实
# 已经起来了。所以要么不管超时、直接查进程与日志，要么把本脚本放到后台跑。
# 确认启动成功的三个依据：Get-Process 拿到 Godot 且 MainWindowTitle 非空、
# Responding=True、run_game_err.log 为 0 字节。不要依赖退出码。

param(
	[string]$Godot = 'C:\Users\CONQUEROR\AppData\Local\Temp\dsh-godot-4.7.2\Godot_v4.7.2-stable_win64.exe',
	[string]$Scene = ''
)

$ErrorActionPreference = 'Continue'

# 路径全部由脚本自身位置推导，便于换机/换目录
$game = Split-Path -Parent $PSScriptRoot          # .../game
$root = Split-Path -Parent $game                  # 仓库根
$userDir = Join-Path $env:APPDATA 'Godot'         # user:// 的真实落点

if (-not (Test-Path $Godot)) {
	Write-Output "NOT FOUND: $Godot"
	Write-Output 'Pass -Godot <path> or edit the param default in this script.'
	exit 1
}

$out = Join-Path $game 'run_game.log'
$err = Join-Path $game 'run_game_err.log'
Remove-Item $out, $err -Force -ErrorAction SilentlyContinue

# 不传场景时 Godot 会跑 project.godot 里的 run/main_scene（主菜单）
$godotArgs = @('--path', '.')
if ($Scene) { $godotArgs += $Scene }

$sb = 'c:\Program Files\Qoder CN IDE\resources\app\resources\bin\x86_64_windows\sandbox.exe'
if (-not (Test-Path $sb)) {
	# 不在沙箱环境里（例如直接在普通终端跑）：直接调 Godot 即可
	$sb = $null
}

if ($sb) {
	$file = $sb
	# --workspace-root 可多次指定，每指定一次就放开一个可写根
	# 注意 $Godot 必须夹在 sandbox 参数与 Godot 参数之间：
	# 漏了它 sandbox 会把 --path 当成要启动的程序，报 CreateProcessAsUserW 失败: 2
	$all = @('--policy', 'workspace-write',
		'--workspace-root', $root,
		'--workspace-root', $userDir,
		'--cwd', $game,
		$Godot) + $godotArgs
} else {
	$file = $Godot
	$all = $godotArgs
}

$p = Start-Process -FilePath $file -ArgumentList $all -WorkingDirectory $game `
	-RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow

Start-Sleep -Seconds 3
$alive = -not $p.HasExited
Write-Output "PID=$($p.Id) ALIVE=$alive"
Write-Output "stdout -> $out"
Write-Output "stderr -> $err"
