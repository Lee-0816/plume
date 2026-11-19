#!/bin/bash
# Assemble the web editor (our sources + the Vditor runtime) into a folder.
# Usage: scripts/assemble-editor.sh <output-dir>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?output dir required}"
VD="$ROOT/web/node_modules/vditor"
if [ ! -d "$VD/dist" ]; then
  echo "Installing editor dependencies…"
  (cd "$ROOT/web" && npm install --no-audit --no-fund)
fi
rm -rf "$OUT"
mkdir -p "$OUT/vditor/dist"
cp -R "$ROOT/web/src/." "$OUT/"
# Vditor runtime: skip TypeScript sources, typings and MathJax (KaTeX is used).
cp "$VD/dist/index.min.js" "$VD/dist/index.css" "$OUT/vditor/dist/"
cp -R "$VD/dist/css" "$VD/dist/images" "$OUT/vditor/dist/"
mkdir -p "$OUT/vditor/dist/js"
for d in "$VD/dist/js/"*; do
  name="$(basename "$d")"
  [ "$name" = "mathjax" ] && continue
  cp -R "$d" "$OUT/vditor/dist/js/"
done
cp "$VD/LICENSE" "$OUT/vditor/LICENSE"
echo "Editor assembled at $OUT ($(du -sh "$OUT" | cut -f1))"
