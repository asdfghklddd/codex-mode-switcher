@echo off
setlocal EnableExtensions
chcp 65001 >nul

set "SCRIPT=%~dp0Switch-CodexMode.ps1"
set "PANEL=%~dp0Start-CodexModeSwitcher.ps1"

if not exist "%SCRIPT%" (
  echo 找不到 Switch-CodexMode.ps1，请确认它与此 BAT 文件位于同一目录。
  pause
  exit /b 1
)

if not exist "%PANEL%" (
  echo 找不到 Start-CodexModeSwitcher.ps1，请确认它与此 BAT 文件位于同一目录。
  pause
  exit /b 1
)

if "%~1"=="" goto panel
if /I "%~1"=="ui" goto panel
if "%~1"=="1" goto normal
if "%~1"=="2" goto cockpit
if "%~1"=="3" goto ccswitch
if "%~1"=="4" goto status

:panel
powershell -NoProfile -ExecutionPolicy Bypass -File "%PANEL%"
exit /b %ERRORLEVEL%

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
echo                 当前状态复核
echo ========================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Mode Status
echo.
echo 切换完成。请关闭并重新打开所有 Codex 应用，让它们重新加载 config.toml。

:finish
pause
exit /b %RUN_ERROR%
