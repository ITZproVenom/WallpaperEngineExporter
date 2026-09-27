"""Decide how a Wallpaper Engine package should be exported.

The inspector never guesses from Workshop tags alone. Tags say what the author
claimed; the package says what is actually inside. Tags are used only to
explain a result and to warn about wallpapers that cannot be a faithful video
(audio responsive, interactive, clock driven).
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from . import pkg, tex

VIDEO_SUFFIXES = {".mp4", ".webm", ".m4v", ".mov", ".mkv"}
ANIMATION_SUFFIXES = {".gif", ".apng"}
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".bmp"}

# Strategies, ordered best to worst.
PASSTHROUGH = "passthrough"        # original stream copied, zero quality loss
REMUX = "remux"                    # container change only, stream untouched
ENCODE_ANIMATION = "encode_animation"
ENCODE_STILL = "encode_still"
RENDER_SCENE = "render_scene"      # needs a real renderer
UNSUPPORTED = "unsupported"

# Fidelity, reported to the user before they commit to an export.
IDENTICAL = "identical"
NEAR_IDENTICAL = "near_identical"
APPROXIMATE = "approximate"
STATIC_ONLY = "static_only"
NONE = "none"

INTERACTIVE_TAGS = {"Audio responsive", "Interactive", "Clock", "Media Integration"}


@dataclass
class MediaCandidate:
    """A concrete piece of media found inside the package."""
    source: str                    # "file" or "tex"
    path: Path | None = None       # loose file on disk
    entry: pkg.PkgEntry | None = None
    archive: Path | None = None
    kind: str = "video"
    extension: str = "mp4"
    size: int = 0
    width: int = 0
    height: int = 0

    @property
    def pixels(self) -> int:
        return self.width * self.height


@dataclass
class Plan:
    strategy: str
    fidelity: str
    reason: str
    declared_type: str | None = None          # "Video" | "Scene" | "Web" | None
    candidate: MediaCandidate | None = None
    scene_root: Path | None = None
    warnings: list[str] = field(default_factory=list)
    project: dict = field(default_factory=dict)

    @property
    def ok(self) -> bool:
        return self.strategy != UNSUPPORTED

    def describe(self) -> str:
        return f"{self.strategy} ({self.fidelity}): {self.reason}"


def _load_project(root: Path) -> dict:
    for name in ("project.json", "Project.json"):
        candidate = next(root.rglob(name), None)
        if candidate is None:
            continue
        try:
            return json.loads(candidate.read_text(encoding="utf-8", errors="replace"))
        except (OSError, json.JSONDecodeError):
            continue
    return {}


def _declared_type(project: dict, tags: list[str] | None) -> str | None:
    raw = str(project.get("type") or "").strip().lower()
    if raw in ("video", "scene", "web", "application"):
        return raw.capitalize()
    for tag in tags or ():
        if tag in ("Video", "Scene", "Web", "Application"):
            return tag
    return None


def _loose_media(root: Path) -> list[MediaCandidate]:
    found: list[MediaCandidate] = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        suffix = path.suffix.lower()
        if suffix in VIDEO_SUFFIXES:
            kind = "video"
        elif suffix in ANIMATION_SUFFIXES:
            kind = "animation"
        elif suffix in IMAGE_SUFFIXES:
            kind = "image"
        else:
            continue
        found.append(
            MediaCandidate(
                source="file", path=path, kind=kind,
                extension=suffix.lstrip("."), size=path.stat().st_size,
            )
        )
    return found


def _packaged_media(archive_path: Path) -> list[MediaCandidate]:
    """Look inside a .pkg for media, including video hidden in .tex textures."""
    try:
        archive = pkg.open_archive(archive_path)
    except pkg.PkgError:
        return []

    found: list[MediaCandidate] = []

    for entry in archive.entries:
        if entry.suffix in VIDEO_SUFFIXES:
            found.append(
                MediaCandidate(
                    source="pkg", entry=entry, archive=archive_path, kind="video",
                    extension=entry.suffix.lstrip("."), size=entry.size,
                )
            )
        elif entry.suffix in ANIMATION_SUFFIXES:
            found.append(
                MediaCandidate(
                    source="pkg", entry=entry, archive=archive_path, kind="animation",
                    extension=entry.suffix.lstrip("."), size=entry.size,
                )
            )

    # Video wallpapers store the encoded stream inside a texture.
    for entry in archive.find(".tex"):
        if entry.size < 1024:
            continue
        try:
            blob = pkg.read_entry(archive_path, entry)
            payload = tex.probe(blob)
        except (pkg.PkgError, tex.TexError):
            continue
        if not payload.is_media:
            continue
        found.append(
            MediaCandidate(
                source="tex", entry=entry, archive=archive_path,
                kind=payload.kind, extension=payload.extension,
                size=payload.size, width=payload.width, height=payload.height,
            )
        )

    return found


def _best(candidates: list[MediaCandidate]) -> MediaCandidate | None:
    if not candidates:
        return None
    rank = {"video": 0, "animation": 1, "image": 2}
    return sorted(candidates, key=lambda c: (rank.get(c.kind, 9), -c.pixels, -c.size))[0]


def inspect(root: str | Path, tags: list[str] | None = None) -> Plan:
    """Inspect extracted Workshop content and return an export plan."""
    root = Path(root)
    if not root.exists():
        return Plan(UNSUPPORTED, NONE, "Content directory does not exist")

    if root.is_file():
        if root.suffix.lower() == ".pkg":
            archives = [root]
            root = root.parent
        else:
            archives = []
    else:
        archives = sorted(root.rglob("*.pkg"), key=lambda p: -p.stat().st_size)

    project = _load_project(root)
    declared = _declared_type(project, tags)
    warnings: list[str] = []

    for tag in tags or ():
        if tag in INTERACTIVE_TAGS:
            warnings.append(
                f"Tagged '{tag}': this wallpaper reacts at runtime, so a video "
                f"cannot reproduce that behaviour."
            )

    candidates = _loose_media(root)
    for archive in archives:
        candidates.extend(_packaged_media(archive))

    playable = [c for c in candidates if c.kind in ("video", "animation")]
    best = _best(playable)

    if best is not None and best.kind == "video":
        return Plan(
            strategy=PASSTHROUGH if best.extension == "mp4" else REMUX,
            fidelity=IDENTICAL,
            reason=(
                "Package contains the original encoded video"
                + (" inside a .tex texture" if best.source == "tex" else "")
                + "; exporting it without re-encoding."
            ),
            declared_type=declared, candidate=best, warnings=warnings, project=project,
        )

    if best is not None and best.kind == "animation":
        return Plan(
            ENCODE_ANIMATION, NEAR_IDENTICAL,
            "Package contains an animation; encoding it to MP4 at its native rate.",
            declared_type=declared, candidate=best, warnings=warnings, project=project,
        )

    scene = next((a for a in archives if pkg_has_scene(a)), None)
    if scene is not None or declared in ("Scene", "Web", "Application"):
        return Plan(
            RENDER_SCENE, APPROXIMATE,
            (
                "No finished video inside the package: this wallpaper is rendered "
                "in real time, so a renderer must record it."
            ),
            declared_type=declared, scene_root=scene.parent if scene else root,
            warnings=warnings, project=project,
        )

    still = _best([c for c in candidates if c.kind == "image"])
    if still is not None:
        return Plan(
            ENCODE_STILL, STATIC_ONLY,
            "Package contains only a still image; the export will not move.",
            declared_type=declared, candidate=still, warnings=warnings, project=project,
        )

    return Plan(
        UNSUPPORTED, NONE,
        "No video, animation, image, or scene data was found in this package.",
        declared_type=declared, warnings=warnings, project=project,
    )


def pkg_has_scene(archive_path: Path) -> bool:
    try:
        archive = pkg.open_archive(archive_path)
    except pkg.PkgError:
        return False
    names = {Path(e.name).name.lower() for e in archive.entries}
    return bool(names & {"scene.json", "project.json"}) or bool(archive.find(".json"))
