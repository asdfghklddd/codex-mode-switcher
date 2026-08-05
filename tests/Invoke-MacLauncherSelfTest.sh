#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-mode-launch-test.XXXXXX")"

cleanup() {
  rm -rf -- "$temp_root"
}
trap cleanup EXIT

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "断言失败：输出不包含 $needle"
    echo "$haystack"
    exit 1
  fi
}

make_codex_home() {
  local home_path="$1"
  mkdir -p "$home_path"
  printf '%s\n' 'model = "gpt-test"' > "$home_path/config.toml"
}

explicit_home="$temp_root/Explicit Codex Home/.codex"
make_codex_home "$explicit_home"
before_hash="$(shasum -a 256 "$explicit_home/config.toml" | awk '{print $1}')"

explicit_output="$("$repo_root/Switch-CodexMode.sh" --codex-home "$explicit_home" status)"
assert_contains "$explicit_output" "CODEX_HOME（--codex-home）："
assert_contains "$explicit_output" "$(cd -- "$explicit_home" && pwd -P)"
after_hash="$(shasum -a 256 "$explicit_home/config.toml" | awk '{print $1}')"
[[ "$before_hash" == "$after_hash" ]] || { echo "Status 修改了 config.toml。"; exit 1; }
[[ ! -e "$explicit_home/codex-mode-switch-backups" ]] || { echo "Status 创建了备份目录。"; exit 1; }

tool_copy="$temp_root/Tool Folder 工具"
mkdir -p "$tool_copy"
cp \
  "$repo_root/CodexModeSwitcher.html" \
  "$repo_root/session_provider_sync.py" \
  "$repo_root/Start-CodexModeSwitcher.ps1" \
  "$repo_root/Switch-CodexMode.command" \
  "$repo_root/Switch-CodexMode.ps1" \
  "$repo_root/Switch-CodexMode.sh" \
  "$tool_copy/"
chmod 755 "$tool_copy/Switch-CodexMode.command" "$tool_copy/Switch-CodexMode.sh"
command_output="$("$tool_copy/Switch-CodexMode.command" --codex-home "$explicit_home" status)"
assert_contains "$command_output" "仅查看状态"

preference_home="$temp_root/Preference Codex Home/.codex"
preference_root="$temp_root/XDG Config"
make_codex_home "$preference_home"
mkdir -p "$preference_root/codex-mode-switcher"
printf '%s\n' "$preference_home" > "$preference_root/codex-mode-switcher/codex-home"
preference_output="$(CODEX_HOME='' XDG_CONFIG_HOME="$preference_root" "$repo_root/Switch-CodexMode.sh" status)"
assert_contains "$preference_output" "codex-mode-switcher/codex-home"
assert_contains "$preference_output" "$(cd -- "$preference_home" && pwd -P)"

fallback_home="$temp_root/Fallback Home"
make_codex_home "$fallback_home/.codex"
fallback_output="$(HOME="$fallback_home" CODEX_HOME='' XDG_CONFIG_HOME="$fallback_home/no-config" "$repo_root/Switch-CodexMode.sh" status)"
assert_contains "$fallback_output" "CODEX_HOME（默认目录）："
assert_contains "$fallback_output" "$(cd -- "$fallback_home/.codex" && pwd -P)"

app_dist="$temp_root/dist"
app_zip="$(bash "$repo_root/scripts/build-macos-release.sh" v0.0.0 "$app_dist")"
app_extract="$temp_root/app-extract"
mkdir -p "$app_extract"
ditto -x -k "$app_zip" "$app_extract"
app_path="$app_extract/Codex Mode Switcher.app"
plutil -lint "$app_path/Contents/Info.plist" >/dev/null
app_output="$(CODEX_MODE_SWITCHER_MODE=status CODEX_HOME="$explicit_home" "$app_path/Contents/MacOS/CodexModeSwitcher")"
assert_contains "$app_output" "仅查看状态"

echo "macOS 启动器与应用包自测通过。"
