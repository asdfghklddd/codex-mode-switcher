# Codex Mode Switcher

Small Windows/macOS launcher for selecting the top-level Codex provider in one shared `CODEX_HOME`.

Double-clicking its launcher opens a dependency-free local HTML control panel. The
page uses only HTML, CSS, and browser JavaScript; a PowerShell bridge listens on
`127.0.0.1` to apply the existing safe switch script. A random per-launch token
is required for every local API request.

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

- `Switch-CodexMode.bat`: Windows panel launcher (with numbered CLI compatibility).
- `Switch-CodexMode.ps1`: main implementation.
- `Start-CodexModeSwitcher.ps1`: loopback-only bridge for the local panel.
- `CodexModeSwitcher.html`: dependency-free panel UI.
- `Switch-CodexMode.sh`: macOS/Linux panel and command-line wrapper.
- `Switch-CodexMode.command`: macOS Finder panel launcher.
- `tests/Invoke-SwitcherSelfTest.ps1`: isolated no-session-mutation test.

## Usage

Close every Codex app, then open the launcher with no arguments. It opens the
local control panel in your default browser. Choose a provider and reopen every
Codex app so it reloads `config.toml`.

```powershell
.\Switch-CodexMode.bat       # Open the local HTML panel
.\Switch-CodexMode.bat 1  # Normal
.\Switch-CodexMode.bat 2  # Cockpit
.\Switch-CodexMode.bat 3  # CCSwitch
.\Switch-CodexMode.bat 4  # Status
```

### macOS Apple Silicon (M1/M2/M3/M4)

The core script is architecture-neutral PowerShell/.NET code. On Apple Silicon,
install the native arm64 PowerShell 7 build; the launcher detects a likely
Rosetta build and warns rather than silently relying on it.

```bash
brew install --cask powershell
pwsh -NoProfile -Command '[System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture'
# Expected: Arm64

chmod +x ./Switch-CodexMode.command
./Switch-CodexMode.command
```

You can also double-click `Switch-CodexMode.command` in Finder. If macOS marks a
downloaded copy as quarantined, remove that attribute only after checking the
repository source:

```bash
xattr -d com.apple.quarantine ./Switch-CodexMode.command
```

On macOS/Linux, no argument opens the HTML panel; explicit command-line use is:

```bash
bash ./Switch-CodexMode.sh ui
bash ./Switch-CodexMode.sh status
bash ./Switch-CodexMode.sh normal
bash ./Switch-CodexMode.sh cockpit
bash ./Switch-CodexMode.sh ccswitch
```

The default shared location on macOS is `~/.codex`. Do not configure individual
Codex launchers with different `CODEX_HOME` values: that would create separate
local state and histories. Check the shell value before launching with
`echo "$CODEX_HOME"`; an empty value means the shared default is used.

## Self-test

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-SwitcherSelfTest.ps1
```

The test confirms all modes work and verifies that fixture session JSONL, archived JSONL, SQLite, global state, and backup directories are unchanged.
Its fixture paths are platform-neutral, so run the same test on macOS with
`pwsh -NoProfile -File ./tests/Invoke-SwitcherSelfTest.ps1` after copying the
repository there.

Run the isolated browser-panel integration test with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-WebPanelSelfTest.ps1
```
