@echo off
setlocal EnableExtensions

set "SCRIPT=%~dp0Switch-CodexMode.ps1"

if not exist "%SCRIPT%" (
  echo Switch-CodexMode.ps1 not found next to this BAT.
  pause
  exit /b 1
)

if /I "%~1"=="normal" goto normal
if /I "%~1"=="cockpit" goto cockpit
if /I "%~1"=="ccswitch" goto ccswitch
if /I "%~1"=="cc" goto ccswitch
if /I "%~1"=="status" goto status

:menu
cls
echo Codex Mode Switcher
echo.
echo  1. Normal    - OpenAI login provider
echo  2. Cockpit   - Cockpit local API provider
echo  3. CCSwitch  - CC Switch custom provider
echo  4. Status    - Show current provider/session index
echo  Q. Quit
echo.
set /p "choice=Choose mode: "

if /I "%choice%"=="1" goto normal
if /I "%choice%"=="normal" goto normal
if /I "%choice%"=="2" goto cockpit
if /I "%choice%"=="cockpit" goto cockpit
if /I "%choice%"=="3" goto ccswitch
if /I "%choice%"=="ccswitch" goto ccswitch
if /I "%choice%"=="cc" goto ccswitch
if /I "%choice%"=="4" goto status
if /I "%choice%"=="status" goto status
if /I "%choice%"=="q" exit /b 0
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
echo.
if /I not "%MODE%"=="Status" echo Close and reopen Codex Desktop after switching mode.
pause
exit /b %ERRORLEVEL%
