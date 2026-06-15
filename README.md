# Codex Mode Switcher

Windows desktop switcher for keeping Codex Desktop sessions visible across three provider modes:

- `Normal`: direct OpenAI login provider.
- `Cockpit`: Cockpit local API provider, default `http://localhost:55939/v1`.
- `CCSwitch`: CC Switch custom provider, default `https://anyrouter.top/v1`.

## Files

- `Switch-CodexMode.bat`: single interactive menu for all modes.
- `Switch-CodexMode.ps1`: main switch logic.
- `legacy-Switch-CodexMode-*.bat`: old one-click wrappers kept for compatibility.

## Usage

Double-click `Switch-CodexMode.bat`, choose a mode, then close and reopen Codex Desktop after switching.

Command-line shortcuts are also supported:

```powershell
.\Switch-CodexMode.bat normal
.\Switch-CodexMode.bat cockpit
.\Switch-CodexMode.bat ccswitch
.\Switch-CodexMode.bat status
```

## Safety

The switcher creates a timestamped backup in `%USERPROFILE%\.codex` before every non-status switch. It backs up config/state files and rewrites session provider metadata so historical threads remain visible under the selected provider.
