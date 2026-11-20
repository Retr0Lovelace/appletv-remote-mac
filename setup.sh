#!/bin/bash
# Prepares the Python environment (venv + pyatv) for the Apple TV remote.
# Dependencies are pinned with hashes in requirements.lock (generated from requirements.in).
set -euo pipefail
cd "$(dirname "$0")"
UV="$(command -v uv || true)"
[ -z "$UV" ] && [ -x "$HOME/.local/bin/uv" ] && UV="$HOME/.local/bin/uv"
if [ -z "$UV" ]; then
  echo "error: uv is required but was not found." >&2
  echo "Install it with Homebrew:   brew install uv" >&2
  echo "or follow the official instructions: https://docs.astral.sh/uv/getting-started/installation/" >&2
  exit 1
fi
[ -x .venv/bin/python ] || "$UV" venv --python 3.12 .venv
"$UV" pip install --python .venv/bin/python --require-hashes -r requirements.lock
.venv/bin/python -c "from importlib.metadata import version; print('pyatv', version('pyatv'))"
echo "OK: environment ready (.venv)"
