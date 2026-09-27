"""Turn an export Plan into a finished MP4.

Rule: never re-encode video that is already H.264/HEVC in an MP4 container.
The bytes Wallpaper Engine plays are the bytes the user gets.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from . import inspect as inspector
from . import pkg, tex

FFMPEG = shutil.which("ffmpeg") or "ffmpeg"
FFPROBE = shutil.which("ffprobe") or "ffprobe"


class ConversionError(RuntimeError):
    pass


@dataclass(frozen=True)
class ExportResult:
    path: Path
    strategy: str
    fidelity: str
    reencoded: bool
    width: int = 0
    height: int = 0
    duration: float = 0.0
    warnings: tuple[str, ...] = ()


def _run(args: list[str], timeout: int = 900) -> subprocess.CompletedProcess:
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if result.returncode != 0:
        tail = (result.stderr or "").strip().splitlines()[-3:]
        raise ConversionError(" / ".join(tail) or f"{args[0]} failed")
    return result


def probe_media(path: str | Path) -> tuple[int, int, float, str]:
    result = subprocess.run(
        [FFPROBE, "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=width,height,codec_name:format=duration", "-of", "json", str(path)],
        capture_output=True, text=True, timeout=120,
    )
    if result.returncode != 0:
        raise ConversionError("Exported file is not readable media")
    payload = json.loads(result.stdout or "{}")
    streams = payload.get("streams") or []
    if not streams:
        raise ConversionError("Exported file has no video stream")
    stream = streams[0]
    duration = float((payload.get("format") or {}).get("duration") or 0.0)
    return (
        int(stream.get("width") or 0),
        int(stream.get("height") or 0),
        duration,
        str(stream.get("codec_name") or ""),
    )


def materialise(candidate: inspector.MediaCandidate, scratch: Path) -> Path:
    """Put the candidate's original bytes on disk, untouched."""
    scratch.mkdir(parents=True, exist_ok=True)

    if candidate.source == "file" and candidate.path is not None:
        return candidate.path

    if candidate.entry is None or candidate.archive is None:
        raise ConversionError("Media candidate has no source data")

    if candidate.source == "pkg":
        target = scratch / Path(candidate.entry.name).name
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("wb") as out:
            for chunk in pkg.iter_entry_data(candidate.archive, candidate.entry):
                out.write(chunk)
        return target

    if candidate.source == "tex":
        blob = pkg.read_entry(candidate.archive, candidate.entry)
        target = scratch / (Path(candidate.entry.name).stem + "." + candidate.extension)
        tex.extract_payload(blob, target)
        return target

    raise ConversionError(f"Unknown media source: {candidate.source}")


def export(plan: inspector.Plan, output: str | Path, scratch: str | Path) -> ExportResult:
    output, scratch = Path(output), Path(scratch)
    output.parent.mkdir(parents=True, exist_ok=True)
    scratch.mkdir(parents=True, exist_ok=True)

    if plan.strategy == inspector.UNSUPPORTED:
        raise ConversionError(plan.reason)
    if plan.strategy == inspector.RENDER_SCENE:
        raise ConversionError(
            "This is a real-time scene wallpaper. It contains no finished video, so "
            "it must be recorded by a Wallpaper Engine renderer."
        )
    if plan.candidate is None:
        raise ConversionError("Nothing to export")

    source = materialise(plan.candidate, scratch)
    reencoded = True

    if plan.strategy == inspector.PASSTHROUGH:
        # Already MP4: copy the file verbatim. No muxer, no metadata rewrite.
        shutil.copy2(source, output)
        reencoded = False
    elif plan.strategy == inspector.REMUX:
        # Change container only; both streams are copied bit-exactly.
        _run([FFMPEG, "-y", "-i", str(source), "-c", "copy",
              "-movflags", "+faststart", str(output)])
        reencoded = False
    elif plan.strategy == inspector.ENCODE_ANIMATION:
        _run([FFMPEG, "-y", "-i", str(source),
              "-movflags", "+faststart", "-pix_fmt", "yuv420p",
              "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
              "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", str(output)])
    elif plan.strategy == inspector.ENCODE_STILL:
        _run([FFMPEG, "-y", "-loop", "1", "-i", str(source), "-t", "5",
              "-movflags", "+faststart", "-pix_fmt", "yuv420p",
              "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
              "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", str(output)])
    else:
        raise ConversionError(f"Unknown strategy: {plan.strategy}")

    if not output.is_file() or output.stat().st_size < 1024:
        raise ConversionError("Export produced no usable file")

    width, height, duration, _codec = probe_media(output)
    return ExportResult(
        path=output, strategy=plan.strategy, fidelity=plan.fidelity,
        reencoded=reencoded, width=width, height=height, duration=duration,
        warnings=tuple(plan.warnings),
    )
