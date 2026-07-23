#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/Switch-CodexMode.ps1"
panel="$script_dir/Start-CodexModeSwitcher.ps1"
sync_helper="$script_dir/session_provider_sync.py"
host_os="$(uname -s)"
host_arch="$(uname -m)"

for required_file in "$script" "$panel" "$sync_helper"; do
  if [[ ! -f "$required_file" ]]; then
    echo "找不到所需启动文件：$required_file"
    exit 1
  fi
done

if ! command -v pwsh >/dev/null 2>&1; then
  if [[ "$host_os" == "Darwin" ]]; then
    echo "macOS 需要原生 PowerShell 7。请运行：brew install --cask powershell"
  else
    echo "运行此启动器需要 PowerShell 7（pwsh）。"
  fi
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
  echo "运行此启动器需要 Python 3.8 或更高版本。"
  exit 1
fi

powershell_bin="pwsh"

if [[ "$host_os" == "Darwin" && "$host_arch" == "arm64" ]] && command -v file >/dev/null 2>&1; then
  pwsh_path="$(command -v pwsh)"
  pwsh_arch="$(file -Lb "$pwsh_path" 2>/dev/null || true)"
  if [[ "$pwsh_arch" != *"arm64"* ]]; then
    echo "警告：pwsh 似乎不是 arm64 原生版本，可能会通过 Rosetta 运行。"
    echo "Apple Silicon（包括 M4）请安装原生 PowerShell 7：brew install --cask powershell"
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
  *) echo "用法：$0 [ui|normal|cockpit|ccswitch|status]"; exit 1 ;;
esac

if [[ "$mode" == "UI" ]]; then
  "$powershell_bin" -NoLogo -NoProfile -File "$panel"
  exit $?
fi

"$powershell_bin" -NoLogo -NoProfile -File "$script" -Mode "$mode"
if [[ "$mode" != "Status" ]]; then
  echo
  echo "切换后请关闭并重新打开所有 Codex 应用。"
fi
