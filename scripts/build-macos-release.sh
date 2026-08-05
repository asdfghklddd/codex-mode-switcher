#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "用法：$0 <版本，例如 v1.0.0> <输出目录>"
  exit 2
fi

version_input="$1"
version="${version_input#v}"
version_tag="v$version"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
output_dir="$2"
archive_path="$output_dir/codex-mode-switcher-$version_tag-macos.zip"
stage_root="$(mktemp -d)"
app_path="$stage_root/Codex Mode Switcher.app"

cleanup() {
  rm -rf -- "$stage_root"
}
trap cleanup EXIT

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$output_dir"
sed "s/__VERSION__/$version/g" "$repo_root/packaging/macos/Info.plist" > "$app_path/Contents/Info.plist"
cp "$repo_root/packaging/macos/CodexModeSwitcher" "$app_path/Contents/MacOS/CodexModeSwitcher"
cp \
  "$repo_root/CodexModeSwitcher.html" \
  "$repo_root/session_provider_sync.py" \
  "$repo_root/Start-CodexModeSwitcher.ps1" \
  "$repo_root/Switch-CodexMode.ps1" \
  "$repo_root/Switch-CodexMode.sh" \
  "$app_path/Contents/Resources/"
chmod 755 "$app_path/Contents/MacOS/CodexModeSwitcher" "$app_path/Contents/Resources/Switch-CodexMode.sh"

rm -f -- "$archive_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
echo "$archive_path"
