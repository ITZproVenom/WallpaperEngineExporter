"""Wallpaper Engine PKG archive reader.

Format (PKGV0022), verified against real packages:

    uint32   header_len_or_flag   (typically 8)
    char[4]  "PKGV"
    char[4]  version, e.g. "0022"
    uint32   entry_count
    entry_count x directory entries:
        uint32   name_length
        bytes    name (UTF-8, forward-slash separated)
        uint32   offset   (relative to start of the data section)
        uint32   size
    raw data section

Format reference: 91King0721/Wallpaper-Engine-Extractor (src/extractor/pkg.py).
This implementation differs deliberately: entry offsets are honoured instead of
assuming entries are stored contiguously, names are sanitised against traversal,
and reads are streamed so a 4 GB package never lands in memory.
"""

from __future__ import annotations

import json
import struct
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import BinaryIO, Iterator

MAGIC = b"PKGV"
MAX_NAME_LEN = 512
MAX_ENTRIES = 100_000


class PkgError(ValueError):
    """Raised when a file is not a usable PKG archive."""


@dataclass(frozen=True)
class PkgEntry:
    name: str
    offset: int
    size: int

    @property
    def suffix(self) -> str:
        return Path(self.name).suffix.lower()


@dataclass(frozen=True)
class PkgArchive:
    version: str
    data_start: int
    entries: tuple[PkgEntry, ...]

    def find(self, *suffixes: str) -> tuple[PkgEntry, ...]:
        wanted = {s.lower() for s in suffixes}
        return tuple(e for e in self.entries if e.suffix in wanted)

    def named(self, name: str) -> PkgEntry | None:
        low = name.lower()
        return next((e for e in self.entries if e.name.lower() == low), None)

    def to_manifest(self) -> list[dict]:
        return [asdict(e) for e in self.entries]


def _read_exact(stream: BinaryIO, count: int) -> bytes:
    chunk = stream.read(count)
    if len(chunk) != count:
        raise PkgError("Truncated PKG archive")
    return chunk


def _u32(stream: BinaryIO) -> int:
    return struct.unpack("<I", _read_exact(stream, 4))[0]


def safe_relative_path(name: str) -> Path:
    """Reject absolute paths, drive letters, and ``..`` traversal."""
    cleaned = name.replace("\\", "/").strip()
    if not cleaned or cleaned.startswith("/") or ":" in cleaned.split("/")[0]:
        raise PkgError(f"Unsafe entry name: {name!r}")
    parts = [p for p in cleaned.split("/") if p not in ("", ".")]
    if any(p == ".." for p in parts):
        raise PkgError(f"Unsafe entry name: {name!r}")
    if not parts:
        raise PkgError(f"Unsafe entry name: {name!r}")
    return Path(*parts)


def read_header(stream: BinaryIO) -> PkgArchive:
    """Parse the header and directory. Leaves the stream position undefined."""
    stream.seek(0)
    _ = _u32(stream)
    magic = _read_exact(stream, 4)
    if magic != MAGIC:
        raise PkgError(f"Not a PKG archive (magic {magic!r})")
    version = _read_exact(stream, 4).decode("ascii", "replace")
    entry_count = _u32(stream)
    if not 0 < entry_count <= MAX_ENTRIES:
        raise PkgError(f"Implausible PKG entry count: {entry_count}")

    entries: list[PkgEntry] = []
    for _ in range(entry_count):
        name_len = _u32(stream)
        if not 0 < name_len <= MAX_NAME_LEN:
            raise PkgError(f"Implausible PKG name length: {name_len}")
        name = _read_exact(stream, name_len).decode("utf-8", "replace").rstrip("\x00")
        offset = _u32(stream)
        size = _u32(stream)
        entries.append(PkgEntry(name=name, offset=offset, size=size))

    return PkgArchive(version=version, data_start=stream.tell(), entries=tuple(entries))


def open_archive(path: str | Path) -> PkgArchive:
    with Path(path).open("rb") as stream:
        return read_header(stream)


def iter_entry_data(
    path: str | Path, entry: PkgEntry, chunk_size: int = 1 << 20
) -> Iterator[bytes]:
    """Stream one entry's bytes without loading the whole archive."""
    archive = open_archive(path)
    with Path(path).open("rb") as stream:
        stream.seek(archive.data_start + entry.offset)
        remaining = entry.size
        while remaining > 0:
            chunk = stream.read(min(chunk_size, remaining))
            if not chunk:
                raise PkgError(f"Truncated entry data for {entry.name!r}")
            remaining -= len(chunk)
            yield chunk


def read_entry(path: str | Path, entry: PkgEntry) -> bytes:
    return b"".join(iter_entry_data(path, entry))


def extract(
    path: str | Path, target: str | Path, entries: tuple[PkgEntry, ...] | None = None
) -> list[Path]:
    """Extract entries to ``target``, writing a ``_manifest.json`` alongside."""
    archive = open_archive(path)
    chosen = archive.entries if entries is None else entries
    target = Path(target)
    target.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []

    with Path(path).open("rb") as stream:
        for entry in chosen:
            destination = target / safe_relative_path(entry.name)
            destination.parent.mkdir(parents=True, exist_ok=True)
            stream.seek(archive.data_start + entry.offset)
            remaining = entry.size
            with destination.open("wb") as out:
                while remaining > 0:
                    chunk = stream.read(min(1 << 20, remaining))
                    if not chunk:
                        raise PkgError(f"Truncated entry data for {entry.name!r}")
                    out.write(chunk)
                    remaining -= len(chunk)
            written.append(destination)

    (target / "_manifest.json").write_text(
        json.dumps(
            {"version": archive.version, "entries": archive.to_manifest()},
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    return written
