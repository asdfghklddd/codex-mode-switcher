# Codex Mode Switcher

Windows desktop switcher for keeping Codex Desktop sessions visible across three provider modes:

- `Normal`: direct OpenAI login provider.
- `Cockpit`: Cockpit local API provider, default `http://localhost:55939/v1`.
- `CCSwitch`: CC Switch custom provider, default `https://anyrouter.top/v1`.

## Files

- `Switch-CodexMode.bat`: single interactive menu for all modes.
- `Switch-CodexMode.sh`: macOS/Linux command-line wrapper.
- `Switch-CodexMode.command`: macOS Finder double-click wrapper.
- `Switch-CodexMode.ps1`: main switch logic.
- `tests/Invoke-SwitcherSelfTest.ps1`: temp-fixture self-test for config, SQLite, JSONL, and POSIX path handling.

## Usage

Double-click `Switch-CodexMode.bat`, choose a mode, then close and reopen Codex Desktop after switching.

Command-line shortcuts are also supported:

```powershell
.\Switch-CodexMode.bat 1
.\Switch-CodexMode.bat 2
.\Switch-CodexMode.bat 3
.\Switch-CodexMode.bat 4
```

## macOS Usage

Install PowerShell 7 and ensure `python3` is available:

```bash
brew install --cask powershell
```

Then run:

```bash
bash ./Switch-CodexMode.sh status
bash ./Switch-CodexMode.sh normal
bash ./Switch-CodexMode.sh cockpit
bash ./Switch-CodexMode.sh ccswitch
```

You can also double-click `Switch-CodexMode.command` from Finder after making it executable:

```bash
chmod +x Switch-CodexMode.command Switch-CodexMode.sh
```

## Self-Test

Run this before changing the switcher:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-SwitcherSelfTest.ps1
```

On macOS:

```bash
pwsh -NoProfile -ExecutionPolicy Bypass -File ./tests/Invoke-SwitcherSelfTest.ps1
```

## Safety

The switcher creates a timestamped backup in `%USERPROFILE%\.codex` before every non-status switch. It backs up config/state files and rewrites session provider metadata so historical threads remain visible under the selected provider.
