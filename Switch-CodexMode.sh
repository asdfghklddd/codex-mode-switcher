#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/Switch-CodexMode.ps1"

if [[ ! -f "$script" ]]; then
  echo "Switch-CodexMode.ps1 not found next to this script."
  exit 1
fi

if command -v pwsh >/dev/null 2>&1; then
  powershell_bin="pwsh"
elif command -v powershell >/dev/null 2>&1; then
  powershell_bin="powershell"
else
  echo "PowerShell 7 is required. Install it with: brew install --cask powershell"
  exit 1
fi

mode="${1:-}"
mode_key="$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
case "$mode_key" in
  normal) mode="Normal" ;;
  cockpit) mode="Cockpit" ;;
  ccswitch|cc) mode="CCSwitch" ;;
  status) mode="Status" ;;
  "")
    echo "Codex Mode Switcher"
    echo
    echo "  1. Normal    - OpenAI login provider"
    echo "  2. Cockpit   - Cockpit local API provider"
    echo "  3. CCSwitch  - CC Switch custom provider"
    echo "  4. Status    - Show current provider/session index"
    echo
    read -r -p "Choose mode: " choice
    choice_key="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"
    case "$choice_key" in
      1|normal) mode="Normal" ;;
      2|cockpit) mode="Cockpit" ;;
      3|ccswitch|cc) mode="CCSwitch" ;;
      4|status) mode="Status" ;;
      *) echo "Invalid choice."; exit 1 ;;
    esac
    ;;
  *) echo "Usage: $0 [normal|cockpit|ccswitch|status]"; exit 1 ;;
esac

"$powershell_bin" -NoProfile -ExecutionPolicy Bypass -File "$script" -Mode "$mode"
if [[ "$mode" != "Status" ]]; then
  echo
  echo "Close and reopen Codex Desktop after switching mode."
fi
