@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion

rem ============================================================
rem  Double-click this file to build the Windows exe.
rem  Output : export\BrotatoLite.exe
rem  Log    : export\_build_log.txt  (overwritten each run)
rem ============================================================

rem ---- Paths: change here if the project moves ----
set "PROJ=D:\code\firstProject-ai\TheGreatestProject"
set "GODOT=D:\code\godot\Godot_v4.7.2-stable_win64_console.exe"
set "OUT=%PROJ%\export\BrotatoLite.exe"
set "LOG=%PROJ%\export\_build_log.txt"

title BrotatoLite Build

echo.
echo ============================================
echo   BrotatoLite  -  Build Windows exe
echo ============================================
echo.

rem ---- 1. Godot present? ----
if not exist "%GODOT%" (
    echo [ERROR] Godot not found:
    echo         %GODOT%
    echo         Edit the GODOT variable at the top of this script.
    echo.
    pause
    exit /b 1
)

rem ---- 2. Project present? ----
if not exist "%PROJ%\game\project.godot" (
    echo [ERROR] Project not found:
    echo         %PROJ%\game\project.godot
    echo         Edit the PROJ variable at the top of this script.
    echo.
    pause
    exit /b 1
)

rem ---- 3. Record the old artifact ----
set "OLD_SIZE=0"
if exist "%OUT%" (
    for %%F in ("%OUT%") do set "OLD_SIZE=%%~zF"
    echo [old] already exists : !OLD_SIZE! bytes
) else (
    echo [old] not present ^(first build^)
)
echo.

rem ---- 4. Build ----
echo [1/3] Building... please wait ^(8~30s, do not close^)
echo.

cd /d "%PROJ%"

rem Godot writes progress to stderr, so merge 2>&1 into the log
"%GODOT%" --headless --path game --export-release "Windows" "%OUT%" > "%LOG%" 2>&1
set "RC=!errorlevel!"

rem ---- 5. Check result ----
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
    echo [FAILED] exit code 0 but artifact missing - export did not really succeed.
    echo.
    powershell -NoProfile -Command "if (Test-Path '%LOG%') { Get-Content '%LOG%' -Tail 30 }"
    echo.
    pause
    exit /b 1
)

for %%F in ("%OUT%") do set "NEW_SIZE=%%~zF" & set "NEW_TIME=%%~tF"
set /a MB=!NEW_SIZE!/1048576

rem ---- 6. Success ----
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

choice /c YN /n /t 15 /d N /m "Launch the game now? (Y/N, auto-N in 15s) "
if !errorlevel!==1 (
    echo Launching...
    start "" "%OUT%"
)

echo.
echo log: %LOG%
echo.
timeout /t 3 >nul
exit /b 0
