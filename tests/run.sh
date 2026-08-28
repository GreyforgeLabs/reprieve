#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
node tests/test_undo_model.js
python3 tests/test_media.py
omarchy plugin validate .
echo "ok"
