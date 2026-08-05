#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/Switch-CodexMode.ps1"
panel="$script_dir/Start-CodexModeSwitcher.ps1"
sync_helper="$script_dir/session_provider_sync.py"
host_os="$(uname -s)"
host_arch="$(uname -m)"

# Finder-launched .command files may not inherit Homebrew's shell PATH.
if [[ "$host_os" == "Darwin" && -x /usr/libexec/path_helper ]]; then
  eval "$(/usr/libexec/path_helper -s)"
fi

usage() {
  cat <<EOF
用法：$0 [--codex-home <目录>] [ui|normal|cockpit|ccswitch|status]

CODEX_HOME 选择顺序：
  1. --codex-home 参数
  2. CODEX_HOME 环境变量
  3. \${XDG_CONFIG_HOME:-\$HOME/.config}/codex-mode-switcher/codex-home
  4. \$HOME/.codex
EOF
}

mode="ui"
mode_set=0
explicit_codex_home=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --codex-home)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "--codex-home 需要一个目录参数。"
        exit 2
      fi
      explicit_codex_home="$2"
      shift 2
      ;;
    --codex-home=*)
      explicit_codex_home="${1#*=}"
      if [[ -z "$explicit_codex_home" ]]; then
        echo "--codex-home 需要一个目录参数。"
        exit 2
      fi
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ $mode_set -eq 1 ]]; then
        echo "只能指定一个模式。"
        usage
        exit 2
      fi
      mode="$1"
      mode_set=1
      shift
      ;;
  esac
done

settings_root="${XDG_CONFIG_HOME:-$HOME/.config}"
codex_home_file="$settings_root/codex-mode-switcher/codex-home"
if [[ -n "$explicit_codex_home" ]]; then
  codex_home="$explicit_codex_home"
  codex_home_source="--codex-home"
elif [[ -n "${CODEX_HOME:-}" ]]; then
  codex_home="$CODEX_HOME"
  codex_home_source="CODEX_HOME"
elif [[ -f "$codex_home_file" ]]; then
  IFS= read -r codex_home < "$codex_home_file" || true
  codex_home="${codex_home%$'\r'}"
  if [[ -z "$codex_home" ]]; then
    echo "CodexHome 配置文件为空：$codex_home_file"
    exit 1
  fi
  codex_home_source="$codex_home_file"
else
  codex_home="$HOME/.codex"
  codex_home_source="默认目录"
fi

case "$codex_home" in
  "~") codex_home="$HOME" ;;
  "~/"*) codex_home="$HOME/${codex_home#~/}" ;;
esac

if [[ "$codex_home" != /* ]]; then
  echo "CODEX_HOME 必须是绝对路径：$codex_home"
  exit 1
fi
if [[ ! -d "$codex_home" ]]; then
  echo "找不到 CODEX_HOME 目录：$codex_home"
  exit 1
fi
if [[ ! -f "$codex_home/config.toml" ]]; then
  echo "找不到 config.toml：$codex_home/config.toml"
  exit 1
fi

export CODEX_HOME="$(cd -- "$codex_home" && pwd -P)"
echo "CODEX_HOME（${codex_home_source}）：$CODEX_HOME"

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

mode_key="$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
case "$mode_key" in
  normal) mode="Normal" ;;
  cockpit) mode="Cockpit" ;;
  ccswitch|cc) mode="CCSwitch" ;;
  status) mode="Status" ;;
  ui|panel) mode="UI" ;;
  *) usage; exit 2 ;;
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
