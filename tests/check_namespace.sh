#!/usr/bin/env bash
# Runtime identity must be Reprieve only.
set -euo pipefail
cd "$(dirname "$0")/.."
runtime=(manifest.json Service.qml Panel.qml BarWidget.qml BarIcons.js ReprieveModel.js bin/reprieve bin/reprieve-journal bin/reprieve-media)
fail=0
for f in "${runtime[@]}"; do
  if grep -n -E "desktop-undo|forge""undo" "$f"; then
    echo "stale namespace in $f" >&2
    fail=1
  fi
done
if grep -rn -E "special:desktop-undo|desktop-undo\.json" --exclude-dir=.git --exclude-dir=tests --exclude=CHANGELOG.md --exclude=README.md . ; then
  echo "stale runtime namespace found" >&2
  fail=1
fi
if grep -rn -i "forge""undo" --exclude-dir=.git --exclude=check_namespace.sh . ; then
  echo "pre-rename product name found" >&2
  fail=1
fi
exit $fail
