#!/bin/bash
# Prépare l'environnement Python (venv + pyatv) pour la télécommande Apple TV.
set -euo pipefail
cd "$(dirname "$0")"
UV="$(command -v uv || true)"
[ -z "$UV" ] && [ -x "$HOME/.local/bin/uv" ] && UV="$HOME/.local/bin/uv"
if [ -z "$UV" ]; then
  echo "Installation de uv (dans ~/.local/bin)…"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  UV="$HOME/.local/bin/uv"
fi
[ -x .venv/bin/python ] || "$UV" venv --python 3.12 .venv
# srptools 2.x casse pyatv 0.18 (SRPClientSession.__init__ a changé)
"$UV" pip install --python .venv/bin/python --upgrade pyatv "srptools<2"
.venv/bin/python -c "from importlib.metadata import version; print('pyatv', version('pyatv'))"
echo "OK : environnement prêt (.venv)"
