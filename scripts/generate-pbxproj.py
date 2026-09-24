#!/usr/bin/env python3
"""Restore complete project.pbxproj from base64 parts (known-good device archive settings)."""
from __future__ import annotations
import base64
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "WallpaperEngineExporter.xcodeproj" / "project.pbxproj"
SCRIPTS = ROOT / "scripts"

def main() -> None:
    parts = sorted(SCRIPTS.glob("pbx.b64.part*"))
    if not parts:
        raise SystemExit("No pbx.b64.part* found")
    data = "".join(p.read_text().strip() for p in parts)
    raw = base64.b64decode(data)
    text = raw.decode("utf-8")
    required = (
        "PBXNativeTarget",
        "SteamLoginWebView",
        "PRODUCT_BUNDLE_IDENTIFIER",
        "DEVELOPMENT_TEAM",
        "A60000000000000000000001",
    )
    missing = [r for r in required if r not in text]
    if missing:
        raise SystemExit(f"pbxproj missing: {missing}")
    if len(text.splitlines()) < 400:
        raise SystemExit(f"pbxproj too short: {len(text.splitlines())} lines")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(raw)
    print(f"Wrote {OUT} ({len(raw)} bytes, {len(text.splitlines())} lines)")
    for r in required:
        print(f"  OK: {r}")
    scheme = ROOT / "WallpaperEngineExporter.xcodeproj/xcshareddata/xcschemes/WallpaperEngineExporter.xcscheme"
    if scheme.is_file():
        s = scheme.read_text()
        s2 = s.replace("A500000000000001", "A60000000000000000000001")
        s2 = s2.replace("A500000000000002", "A60000000000000000000002")
        if s2 != s:
            scheme.write_text(s2)
            print("  OK: scheme synced to A600...")

if __name__ == "__main__":
    main()
