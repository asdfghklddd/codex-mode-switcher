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
echo   1  Normal     OpenAI login provider
echo   2  Cockpit    Cockpit local API provider
echo   3  CCSwitch   CC Switch custom provider
echo   4  Status     Show current state only
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
echo.
if /I not "%MODE%"=="Status" echo Close and reopen Codex Desktop after switching mode.
pause
exit /b %ERRORLEVEL%
