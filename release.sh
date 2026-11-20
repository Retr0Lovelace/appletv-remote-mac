#!/bin/bash
# Fabrique une archive autonome (Python 3.12 + pyatv embarqués) : dist/Telecommande-AppleTV-<version>-macOS-arm64.zip
set -euo pipefail
cd "$(dirname "$0")"
PROJECT="$PWD"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
NAME="Télécommande Apple TV.app"
ZIP="Telecommande-AppleTV-${VERSION}-macOS-arm64.zip"

# 1. compilation puis copie dans dist/
./build.sh
rm -rf dist
mkdir -p dist
cp -R "build/$NAME" "dist/$NAME"
APP="$PROJECT/dist/$NAME"
RES="$APP/Contents/Resources"

# 2. CPython 3.12 relocatable (python-build-standalone via uv), cherché hors du projet pour ne pas tomber sur .venv
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
uv python install 3.12
PYBIN=$(cd /tmp && uv python find --no-project --managed-python 3.12)
PYROOT=$(cd "$(dirname "$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$PYBIN")")/.." && pwd)
echo "Python embarqué : $PYROOT"
ditto "$PYROOT" "$RES/python"
rm -f "$RES/python/lib/python3.12/EXTERNALLY-MANAGED"

# 3. dépendances
EMB="$RES/python/bin/python3"
uv pip install --python "$EMB" --break-system-packages --no-cache pyatv "srptools<2"

# 4. assistant
mkdir -p "$RES/helper"
cp helper/atv_helper.py "$RES/helper/"

# 5. allègement
PY="$RES/python"
find "$PY" -name "__pycache__" -type d -prune -exec rm -rf {} +
find "$PY" \( -name test -o -name tests \) -type d -prune -exec rm -rf {} +
rm -rf "$PY"/lib/python3.12/{idlelib,tkinter,turtledemo,ensurepip,lib2to3} \
       "$PY"/lib/python3.12/lib-dynload/_tkinter*.so "$PY"/include "$PY"/share
find "$PY" -name "*.a" -type f -delete
find "$PY" -name "*.pyc" -delete 2>/dev/null || true
find "$PY" -name "libtcl*" -o -name "libtk*" | xargs rm -rf 2>/dev/null || true

# 6. signature ad hoc de tous les binaires Mach-O, puis de l'app
find "$APP" -type f -not -path "*/_CodeSignature/*" | while IFS= read -r f; do
  if file -b "$f" | grep -q "Mach-O"; then codesign -f -s - "$f" 2>/dev/null || echo "signature impossible : $f"; fi
done
codesign --force -s - "$APP"
codesign --verify --deep "$APP" && echo "signature OK"

# 7. archive
(cd dist && ditto -c -k --keepParent "$NAME" "$ZIP")
du -h "dist/$ZIP"
echo "OK : dist/$ZIP"
