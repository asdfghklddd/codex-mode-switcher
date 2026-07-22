#!/usr/bin/env bash
set -u

cd -- "$(dirname -- "$0")" || exit 1
bash ./Switch-CodexMode.sh "$@"
status=$?

if [[ -t 0 && $# -eq 0 ]]; then
  echo
  read -r -p "Press Return to close..."
fi

exit "$status"
