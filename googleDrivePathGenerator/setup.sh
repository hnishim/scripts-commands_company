#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"

if [ -n "${PYTHON_BIN:-}" ]; then
    python_candidates=("$PYTHON_BIN")
else
    python_candidates=()
    path_python="$(command -v python3 || true)"
    if [ -n "$path_python" ]; then
        python_candidates+=("$path_python")
    fi

    brew_prefix="$(brew --prefix 2>/dev/null || true)"
    if [ -n "$brew_prefix" ]; then
        for candidate in "$brew_prefix"/bin/python3* "$brew_prefix"/opt/python@*/bin/python3*; do
            if [ -x "$candidate" ]; then
                python_candidates+=("$candidate")
            fi
        done
    fi
fi

python_bin=""
for candidate in "${python_candidates[@]}"; do
    if "$candidate" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))' 2>/dev/null; then
        python_bin="$candidate"
        break
    fi
done

if [ -z "$python_bin" ]; then
    echo "Python 3.10以上が必要です。" >&2
    exit 1
fi

if [ ! -x "$VENV_DIR/bin/python" ] || ! "$VENV_DIR/bin/python" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))' 2>/dev/null; then
    "$python_bin" -m venv --clear "$VENV_DIR"
fi

"$VENV_DIR/bin/python" -m pip install -r "$SCRIPT_DIR/requirements.txt"
