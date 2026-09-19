@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion

rem ============================================================
rem  Double-click this file to build the Android APK.
rem  Output : export\BrotatoLite.apk
rem  Log    : export\_apk_build_log.txt  (overwritten each run)
rem  NOTE   : needs Android SDK + keystore (already configured
rem           in game\export_presets.cfg). Takes ~16-30s.
rem ============================================================

set "PROJ=D:\code\firstProject-ai\TheGreatestProject"
set "GODOT=D:\code\godot\Godot_v4.7.2-stable_win64_console.exe"
set "OUT=%PROJ%\export\BrotatoLite.apk"
set "LOG=%PROJ%\export\_apk_build_log.txt"

title BrotatoLite Build APK

echo.
echo ============================================
echo   BrotatoLite  -  Build Android APK
echo ============================================
echo.

if not exist "%GODOT%" (
    echo [ERROR] Godot not found: %GODOT%
    echo         Edit the GODOT variable at the top of this script.
    echo.
    pause
    exit /b 1
)

if not exist "%PROJ%\game\project.godot" (
    echo [ERROR] Project not found: %PROJ%\game\project.godot
    echo.
    pause
    exit /b 1
)

set "OLD_SIZE=0"
if exist "%OUT%" (
    for %%F in ("%OUT%") do set "OLD_SIZE=%%~zF"
    echo [old] already exists : !OLD_SIZE! bytes
) else (
    echo [old] not present ^(first build^)
)
echo.

echo [1/3] Building APK... please wait ^(16~40s, do not close^)
echo.

cd /d "%PROJ%"

"%GODOT%" --headless --path game --export-release "Android" "%OUT%" > "%LOG%" 2>&1
set "RC=!errorlevel!"

echo [2/3] Checking result...
echo.

if not "!RC!"=="0" (
    echo [FAILED] Godot exit code = !RC!
    echo.
    echo -------- last 30 log lines --------
    powershell -NoProfile -Command "if (Test-Path '%LOG%') { Get-Content '%LOG%' -Tail 30 }"
    echo -----------------------------------
    echo.
    echo Full log: %LOG%
    echo.
    pause
    exit /b 1
)

if not exist "%OUT%" (
    echo [FAILED] exit code 0 but artifact missing.
    echo.
    powershell -NoProfile -Command "if (Test-Path '%LOG%') { Get-Content '%LOG%' -Tail 30 }"
    echo.
    pause
    exit /b 1
)

for %%F in ("%OUT%") do set "NEW_SIZE=%%~zF" & set "NEW_TIME=%%~tF"
set /a MB=!NEW_SIZE!/1048576

echo [3/3] Done.
echo.
echo ============================================
echo   SUCCESS
echo ============================================
echo   file : %OUT%
echo   size : !NEW_SIZE! bytes  ^(~!MB! MB^)
echo   time : !NEW_TIME!
if not "!OLD_SIZE!"=="0" (
    if not "!OLD_SIZE!"=="!NEW_SIZE!" (
        echo   diff : !OLD_SIZE! -^> !NEW_SIZE! bytes
    ) else (
        echo   NOTE : byte size identical to the previous build - did the code change?
    )
)
echo ============================================
echo.
echo log: %LOG%
echo.
echo closing in 3s...
timeout /t 3 >nul
exit /b 0
