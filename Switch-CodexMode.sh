#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/Switch-CodexMode.ps1"
panel="$script_dir/Start-CodexModeSwitcher.ps1"
host_os="$(uname -s)"
host_arch="$(uname -m)"

for required_file in "$script" "$panel"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Required launcher file not found: $required_file"
    exit 1
  fi
done

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

mode="${1:-ui}"
mode_key="$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
case "$mode_key" in
  normal) mode="Normal" ;;
  cockpit) mode="Cockpit" ;;
  ccswitch|cc) mode="CCSwitch" ;;
  status) mode="Status" ;;
  ui|panel) mode="UI" ;;
  *) echo "Usage: $0 [ui|normal|cockpit|ccswitch|status]"; exit 1 ;;
esac

if [[ "$mode" == "UI" ]]; then
  "$powershell_bin" -NoLogo -NoProfile -File "$panel"
  exit $?
fi

"$powershell_bin" -NoLogo -NoProfile -File "$script" -Mode "$mode"
if [[ "$mode" != "Status" ]]; then
  echo
  echo "Close and reopen every Codex app after switching mode."
fi
