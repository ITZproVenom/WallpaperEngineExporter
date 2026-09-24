#!/usr/bin/env python3
"""Restore a complete Xcode project.pbxproj from base64 parts (CI-safe).

The checked-in project.pbxproj is often truncated by git/push limits.
This script reconstructs the full 525-line project that includes all
sources (SteamLoginWebView, tests, targets, build settings).
"""
from __future__ import annotations

import base64
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "WallpaperEngineExporter.xcodeproj" / "project.pbxproj"
SCRIPTS = ROOT / "scripts"


def load_b64() -> bytes:
    parts = sorted(SCRIPTS.glob("pbx.b64.part*"))
    if parts:
        data = "".join(p.read_text().strip() for p in parts)
        return base64.b64decode(data)
    single = SCRIPTS / "project.pbxproj.b64"
    if single.is_file():
        return base64.b64decode(single.read_text().strip())
    raise SystemExit("No pbx.b64.part* or project.pbxproj.b64 found under scripts/")


def main() -> None:
    raw = load_b64()
    text = raw.decode("utf-8")
    required = (
        "PBXNativeTarget",
        "SteamLoginWebView",
        "PRODUCT_BUNDLE_IDENTIFIER",
        "PBXSourcesBuildPhase",
        "XCBuildConfiguration",
        "WallpaperEngineExporterApp.swift",
    )
    missing = [r for r in required if r not in text]
    if missing:
        raise SystemExit(f"Restored pbxproj missing required markers: {missing}")
    if len(text.splitlines()) < 400:
        raise SystemExit(f"Restored pbxproj too short: {len(text.splitlines())} lines")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(raw)
    print(f"Wrote {OUT} ({len(raw)} bytes, {len(text.splitlines())} lines)")
    for r in required:
        print(f"  OK: {r}")


if __name__ == "__main__":
    main()
