# Codex Mode Switcher

Small Windows/macOS launcher for selecting the top-level Codex provider in one shared `CODEX_HOME`.

## What it changes

The switcher changes only the top-level `model_provider` in `config.toml`:

- `Normal`: removes the managed top-level provider and uses the normal OpenAI default.
- `Cockpit`: selects `codex_local_access`.
- `CCSwitch`: selects `custom`.
- `Status`: reads configuration only.

It never reads, copies, rewrites, indexes, archives, migrates, or deletes:

- `sessions/` or `archived_sessions/`
- SQLite databases or global state
- authentication files
- backup directories

Historical conversation metadata is private implementation data. Changing a runtime provider must not rewrite it. To share the same local conversations across Codex launchers, make every launcher use the same `CODEX_HOME` (normally `~/.codex`).

## Files

- `Switch-CodexMode.bat`: Windows interactive menu.
- `Switch-CodexMode.ps1`: main implementation.
- `Switch-CodexMode.sh`: macOS/Linux command-line wrapper.
- `Switch-CodexMode.command`: macOS Finder wrapper.
- `tests/Invoke-SwitcherSelfTest.ps1`: isolated no-session-mutation test.

## Usage

Close every Codex app, then choose a provider and reopen the apps so they reload `config.toml`.

```powershell
.\Switch-CodexMode.bat 1  # Normal
.\Switch-CodexMode.bat 2  # Cockpit
.\Switch-CodexMode.bat 3  # CCSwitch
.\Switch-CodexMode.bat 4  # Status
```

On macOS/Linux, install PowerShell 7 and run:

```bash
bash ./Switch-CodexMode.sh status
bash ./Switch-CodexMode.sh normal
bash ./Switch-CodexMode.sh cockpit
bash ./Switch-CodexMode.sh ccswitch
```

## Self-test

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-SwitcherSelfTest.ps1
```

The test confirms all modes work and verifies that fixture session JSONL, archived JSONL, SQLite, global state, and backup directories are unchanged.
