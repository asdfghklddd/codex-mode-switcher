#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/Switch-CodexMode.ps1"
host_os="$(uname -s)"
host_arch="$(uname -m)"

if [[ ! -f "$script" ]]; then
  echo "Switch-CodexMode.ps1 not found next to this script."
  exit 1
fi

if ! command -v pwsh >/dev/null 2>&1; then
  if [[ "$host_os" == "Darwin" ]]; then
    echo "Native PowerShell 7 is required for macOS. Install it with: brew install --cask powershell"
  else
    echo "PowerShell 7 (pwsh) is required to run this launcher."
  fi
  exit 1
fi

powershell_bin="pwsh"

if [[ "$host_os" == "Darwin" && "$host_arch" == "arm64" ]] && command -v file >/dev/null 2>&1; then
  pwsh_path="$(command -v pwsh)"
  pwsh_arch="$(file -Lb "$pwsh_path" 2>/dev/null || true)"
  if [[ "$pwsh_arch" != *"arm64"* ]]; then
    echo "Warning: pwsh does not appear to be an arm64 build and may run through Rosetta."
    echo "For Apple Silicon (including M4), install native PowerShell 7: brew install --cask powershell"
  fi
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
    echo "  4. Status    - Show current configuration only"
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

"$powershell_bin" -NoLogo -NoProfile -File "$script" -Mode "$mode"
if [[ "$mode" != "Status" ]]; then
  echo
  echo "Close and reopen every Codex app after switching mode."
fi
