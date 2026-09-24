#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/WallpaperEngineExporter.xcodeproj/project.pbxproj"
# Prefer multi-part base64 (avoids single-file push limits)
if ls "$ROOT"/scripts/pbx.b64.part* >/dev/null 2>&1; then
  cat "$ROOT"/scripts/pbx.b64.part* | base64 -d > "$OUT"
elif [ -f "$ROOT/scripts/project.pbxproj.b64" ]; then
  base64 -d < "$ROOT/scripts/project.pbxproj.b64" > "$OUT"
else
  echo "No pbxproj base64 sources found"
  exit 1
fi
BYTES=$(wc -c < "$OUT" | tr -d ' ')
echo "Restored project.pbxproj ($BYTES bytes)"
grep -q "PBXNativeTarget" "$OUT"
grep -q "SteamLoginWebView" "$OUT"
grep -q "PRODUCT_BUNDLE_IDENTIFIER" "$OUT"
echo "project.pbxproj validation OK"
