@echo off
setlocal EnableExtensions

set "SCRIPT=%~dp0Switch-CodexMode.ps1"

if not exist "%SCRIPT%" (
  echo Switch-CodexMode.ps1 not found next to this BAT.
  pause
  exit /b 1
)

if "%~1"=="1" goto normal
if "%~1"=="2" goto cockpit
if "%~1"=="3" goto ccswitch
if "%~1"=="4" goto status

:menu
cls
echo ========================================
echo          Codex Mode Switcher
echo ========================================
echo.
echo   1  Normal     Plus/OpenAI login mode
echo   2  Cockpit    Cockpit mode
echo   3  CCSwitch   CC Switch mode
echo   4  Status     Show detailed current status
echo   0  Quit
echo.
set /p "choice=Input number: "

if "%choice%"=="1" goto normal
if "%choice%"=="2" goto cockpit
if "%choice%"=="3" goto ccswitch
if "%choice%"=="4" goto status
if "%choice%"=="0" exit /b 0
goto menu

:normal
set "MODE=Normal"
goto run

:cockpit
set "MODE=Cockpit"
goto run

:ccswitch
set "MODE=CCSwitch"
goto run

:status
set "MODE=Status"
goto run

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Mode %MODE%
set "RUN_ERROR=%ERRORLEVEL%"
echo.
if not "%RUN_ERROR%"=="0" goto finish
if /I "%MODE%"=="Status" goto finish
echo ========================================
echo          Current Status Review
echo ========================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Mode Status
echo.
echo Switch complete. Close and reopen every Codex app so it reloads config.toml.

:finish
pause
exit /b %RUN_ERROR%
