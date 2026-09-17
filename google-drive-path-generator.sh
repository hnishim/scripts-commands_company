#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Google Drive Path Generator
# @raycast.mode compact

# Optional parameters:
# @raycast.icon 💻

# Documentation:
# @raycast.description Google Driveのリンクから、ローカルのファイル/フォルダーを開く

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/googleDrivePathGenerator"
VENV_PYTHON="$PROJECT_DIR/.venv/bin/python"

set -euo pipefail

if [ ! -x "$VENV_PYTHON" ]; then
    "$PROJECT_DIR/setup.sh" >&2
fi

cd "$PROJECT_DIR"
exec "$VENV_PYTHON" "$PROJECT_DIR/googleDrivePathGenerator.py"
