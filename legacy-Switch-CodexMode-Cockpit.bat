@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Switch-CodexMode.ps1" -Mode Cockpit
echo.
echo Close and reopen Codex Desktop after switching mode.
pause
