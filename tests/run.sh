#!/usr/bin/env bash
# Offline test suite: pure model, recovery journal, bindings editor, media
# parser. Needs node and python3 only. `omarchy plugin validate` runs when
# the CLI is available (it is on Omarchy; CI skips it).
set -euo pipefail
cd "$(dirname "$0")/.."
node tests/test_model.js
python3 tests/test_journal.py
python3 tests/test_binds.py
python3 tests/test_media.py
python3 -m py_compile bin/reprieve-journal bin/reprieve-binds bin/reprieve-doctor bin/reprieve-media
bash -n bin/reprieve
if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin validate .
fi
echo "ok"
