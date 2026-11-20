#!/bin/bash
# Builds a self-contained archive (Python 3.12 + pyatv embedded): dist/AppleTVRemote-<version>-macOS-arm64.zip
# plus its SHA-256 checksum file.
set -euo pipefail
cd "$(dirname "$0")"
PROJECT="$PWD"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
NAME="Apple TV Remote.app"
ZIP="AppleTVRemote-${VERSION}-macOS-arm64.zip"

# 1. compile, then copy into dist/
./build.sh
rm -rf dist
mkdir -p dist
/usr/bin/ditto "build/$NAME" "dist/$NAME"
APP="$PROJECT/dist/$NAME"
RES="$APP/Contents/Resources"

# 2. relocatable CPython 3.12 (python-build-standalone via uv), looked up outside the project to avoid .venv
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
uv python install 3.12
PYBIN=$(cd /tmp && uv python find --no-project --managed-python 3.12)
PYROOT=$(cd "$(dirname "$(/usr/bin/python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$PYBIN")")/.." && pwd)
echo "Embedded Python: $PYROOT"
/usr/bin/ditto "$PYROOT" "$RES/python"
rm -f "$RES/python/lib/python3.12/EXTERNALLY-MANAGED"

# 3. dependencies (pinned, hash-verified)
EMB="$RES/python/bin/python3"
uv pip install --python "$EMB" --break-system-packages --no-cache --require-hashes -r requirements.lock

# 4. helper
mkdir -p "$RES/helper"
cp helper/atv_helper.py "$RES/helper/"

# 5. slimming and hygiene
PY="$RES/python"
find "$PY" -name "__pycache__" -type d -prune -exec rm -rf {} +
find "$PY" \( -name test -o -name tests \) -type d -prune -exec rm -rf {} +
rm -rf "$PY"/lib/python3.12/{idlelib,tkinter,turtledemo,ensurepip,lib2to3} \
       "$PY"/lib/python3.12/lib-dynload/_tkinter*.so "$PY"/include "$PY"/share
find "$PY" -name "*.a" -type f -delete
find "$PY" -name "*.pyc" -delete 2>/dev/null || true
# tk/tcl data and libraries
rm -rf "$PY"/lib/tcl* "$PY"/lib/tk* "$PY"/lib/itcl* "$PY"/lib/Tix* "$PY"/lib/thread*
find "$PY" \( -name "libtcl*" -o -name "libtk*" \) -exec rm -rf {} + 2>/dev/null || true
# uv-generated scripts in bin/ carry the builder's absolute path in their shebang: keep only the interpreters
find "$PY/bin" -mindepth 1 -maxdepth 1 ! -name python3 ! -name python3.12 ! -name python -exec rm -rf {} +
# build-time sysconfig data embeds the builder's absolute install path; it is not needed at run time
find "$PY" -type f \( -name "_sysconfigdata*.py" -o -name Makefile \) -exec sed -i '' "s|$PYROOT|/python|g" {} +
# nothing from the build machine may leak into the bundle
if LEAKS=$(grep -rIl -- "$HOME" "$APP" 2>/dev/null) && [ -n "$LEAKS" ]; then
  echo "error: the bundle contains the builder's home directory path ($HOME) in:" >&2
  echo "$LEAKS" >&2
  exit 1
fi

# 6. ad-hoc signature of every Mach-O binary, then of the app (any failure aborts the build)
while IFS= read -r f; do
  if /usr/bin/file -b "$f" | grep -q "Mach-O"; then /usr/bin/codesign -f -s - "$f"; fi
done < <(find "$APP" -type f -not -path "*/_CodeSignature/*")
/usr/bin/codesign --force -s - "$APP"
/usr/bin/codesign --verify --deep "$APP" && echo "signature OK"

# 7. archive (no resource forks or extended attributes) and checksum
(cd dist && /usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$NAME" "$ZIP")
(cd dist && /usr/bin/shasum -a 256 "$ZIP" > "$ZIP.sha256")
du -h "dist/$ZIP"
cat "dist/$ZIP.sha256"
echo "OK: dist/$ZIP"
