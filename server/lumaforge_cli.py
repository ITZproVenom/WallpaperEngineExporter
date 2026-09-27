#!/usr/bin/env python3
"""LumaForge command line: acquire -> inspect -> export.

    lumaforge_cli.py capabilities
    lumaforge_cli.py describe 3807719502
    lumaforge_cli.py inspect  /path/to/scene.pkg
    lumaforge_cli.py export   /path/to/scene.pkg -o out.mp4
    lumaforge_cli.py run      3807719502 -o out.mp4
"""
from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from acquisition import AcquisitionError  # noqa: E402
from acquisition import steam_metadata  # noqa: E402
from acquisition.sources import default_registry  # noqa: E402
from processing import convert, inspect as inspector  # noqa: E402


def _plan_json(plan: inspector.Plan) -> dict:
    return {
        "strategy": plan.strategy,
        "fidelity": plan.fidelity,
        "reason": plan.reason,
        "declared_type": plan.declared_type,
        "lossless": plan.strategy in (inspector.PASSTHROUGH, inspector.REMUX),
        "needs_renderer": plan.strategy == inspector.RENDER_SCENE,
        "media": (
            None if plan.candidate is None else {
                "source": plan.candidate.source,
                "kind": plan.candidate.kind,
                "extension": plan.candidate.extension,
                "size": plan.candidate.size,
                "width": plan.candidate.width,
                "height": plan.candidate.height,
            }
        ),
        "warnings": plan.warnings,
    }


def cmd_capabilities(_args) -> int:
    for capability in default_registry().capabilities():
        mark = "available" if capability.available else "unavailable"
        print(f"[{mark:>11}] {capability.name}: {capability.detail}")
    return 0


def cmd_describe(args) -> int:
    metadata = steam_metadata.describe(args.workshop_id)
    print(json.dumps({
        "workshop_id": metadata.workshop_id,
        "title": metadata.title,
        "declared_type": metadata.declared_type,
        "file_size": metadata.file_size,
        "resolution": metadata.resolution,
        "interactive": metadata.interactive,
        "likely_passthrough": metadata.likely_passthrough,
        "tags": list(metadata.tags),
    }, indent=2, ensure_ascii=False))
    return 0


def cmd_inspect(args) -> int:
    plan = inspector.inspect(args.path, tags=args.tag or None)
    print(json.dumps(_plan_json(plan), indent=2, ensure_ascii=False))
    return 0 if plan.ok else 2


def cmd_export(args) -> int:
    plan = inspector.inspect(args.path, tags=args.tag or None)
    if not plan.ok:
        print(f"Cannot export: {plan.reason}", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory() as scratch:
        try:
            result = convert.export(plan, args.output, Path(scratch))
        except convert.ConversionError as error:
            print(f"Export failed: {error}", file=sys.stderr)
            return 3
    print(json.dumps({
        "output": str(result.path),
        "strategy": result.strategy,
        "fidelity": result.fidelity,
        "reencoded": result.reencoded,
        "width": result.width,
        "height": result.height,
        "duration": round(result.duration, 3),
        "warnings": list(result.warnings),
    }, indent=2, ensure_ascii=False))
    return 0


def cmd_run(args) -> int:
    try:
        metadata = steam_metadata.describe(args.workshop_id)
    except AcquisitionError as error:
        print(f"Metadata lookup failed: {error}", file=sys.stderr)
        metadata = None

    with tempfile.TemporaryDirectory() as work:
        try:
            content = default_registry().acquire(
                args.workshop_id, Path(work) / "content", metadata
            )
        except AcquisitionError as error:
            print(f"Acquisition failed:\n{error}", file=sys.stderr)
            return 4
        plan = inspector.inspect(
            content.root, tags=list(metadata.tags) if metadata else None
        )
        if not plan.ok:
            print(f"Cannot export: {plan.reason}", file=sys.stderr)
            return 2
        try:
            result = convert.export(plan, args.output, Path(work) / "scratch")
        except convert.ConversionError as error:
            print(f"Export failed: {error}", file=sys.stderr)
            return 3
    print(json.dumps({
        "output": str(result.path), "source": content.source_name,
        "strategy": result.strategy, "fidelity": result.fidelity,
        "reencoded": result.reencoded,
    }, indent=2, ensure_ascii=False))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="lumaforge", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("capabilities", help="Report which acquisition sources work now")

    describe = sub.add_parser("describe", help="Look up public Workshop metadata")
    describe.add_argument("workshop_id")

    for name, handler in (("inspect", cmd_inspect), ("export", cmd_export)):
        command = sub.add_parser(name, help=f"{name} a local package or folder")
        command.add_argument("path")
        command.add_argument("--tag", action="append", default=[])
        if name == "export":
            command.add_argument("-o", "--output", required=True)
        command.set_defaults(func=handler)

    run = sub.add_parser("run", help="Acquire, inspect, and export in one step")
    run.add_argument("workshop_id")
    run.add_argument("-o", "--output", required=True)
    run.set_defaults(func=cmd_run)

    args = parser.parse_args(argv)
    handlers = {"capabilities": cmd_capabilities, "describe": cmd_describe}
    handler = handlers.get(args.command) or args.func
    return handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
