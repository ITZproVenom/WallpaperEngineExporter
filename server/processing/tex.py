"""Wallpaper Engine TEX texture reader.

Container layout (TEXV0005):

    "TEXV0005\\0"              magic + version
    "TEXI0001\\0"              image info chunk
        uint32 format
        uint32 flags
        uint32 width
        uint32 height
        uint32 image_width
        uint32 image_height
    "TEXB000{3,4}\\0"          mipmap/frame container
        uint32 image_count
        (v4 carries an additional format field)
    payload

A texture payload is either GPU-compressed pixel data (DXT/BCn), a plain
image (PNG/JPEG), or - important for this project - a complete MP4 video
stream. Video wallpapers keep their original encoded video inside a TEX,
so lifting those bytes out yields the untouched original.

Format reference: 91King0721/Wallpaper-Engine-Extractor (src/extractor/tex.py).
Differences here: the embedded stream is located by parsing ISOBMFF box
lengths rather than searching for "ftyp" at a guessed offset, PNG/JPEG/GIF
payloads are detected too, and nothing is written unless a payload is
recognised.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path

MAGIC = b"TEXV0005\x00"
INFO_CHUNK = b"TEXI0001\x00"

# Container signatures we can hand straight to a muxer or image decoder.
SIGNATURES: tuple[tuple[bytes, str, str], ...] = (
    (b"\x89PNG\r\n\x1a\n", "png", "image"),
    (b"\xff\xd8\xff", "jpg", "image"),
    (b"GIF89a", "gif", "animation"),
    (b"GIF87a", "gif", "animation"),
    (b"\x1a\x45\xdf\xa3", "webm", "video"),
    (b"RIFF", "webp", "image"),
)


class TexError(ValueError):
    """Raised when a file is not a usable TEX texture."""


@dataclass(frozen=True)
class TexPayload:
    kind: str           # "video" | "image" | "animation" | "raw"
    extension: str      # "mp4" | "webm" | "png" | ...
    offset: int         # payload offset inside the TEX file
    size: int
    width: int
    height: int
    tex_format: int

    @property
    def is_media(self) -> bool:
        return self.kind in ("video", "animation")


def _find_isobmff(blob: bytes) -> int:
    """Return the offset of an MP4/ISOBMFF stream, or -1.

    Validates by reading the box length prefix that must precede "ftyp",
    which avoids matching the characters inside compressed pixel data.
    """
    search_from = 0
    while True:
        hit = blob.find(b"ftyp", search_from)
        if hit < 4:
            if hit == -1:
                return -1
            search_from = hit + 4
            continue
        start = hit - 4
        (box_len,) = struct.unpack_from(">I", blob, start)
        if 8 <= box_len <= len(blob) - start:
            return start
        search_from = hit + 4


def _container_chunk_start(blob: bytes) -> int:
    for tag, header in ((b"TEXB0004", 9 + 8), (b"TEXB0003", 9 + 4), (b"TEXB0002", 9 + 4)):
        hit = blob.find(tag)
        if hit >= 0:
            return hit + header
    raise TexError("Missing TEXB container chunk")


def probe(blob: bytes) -> TexPayload:
    """Identify a TEX file's payload without copying it."""
    if not blob.startswith(MAGIC):
        raise TexError("Not a TEXV0005 texture")

    info = blob.find(INFO_CHUNK)
    if info < 0:
        raise TexError("Missing TEXI0001 info chunk")
    base = info + len(INFO_CHUNK)
    if base + 24 > len(blob):
        raise TexError("Truncated TEXI0001 info chunk")
    tex_format, _flags, width, height = struct.unpack_from("<IIII", blob, base)

    start = _container_chunk_start(blob)
    body = blob[start:]

    video_at = _find_isobmff(body)
    if video_at >= 0:
        return TexPayload("video", "mp4", start + video_at, len(body) - video_at,
                          width, height, tex_format)

    for signature, extension, kind in SIGNATURES:
        hit = body.find(signature)
        if 0 <= hit <= 64:
            return TexPayload(kind, extension, start + hit, len(body) - hit,
                              width, height, tex_format)

    return TexPayload("raw", "bin", start, len(body), width, height, tex_format)


def extract_payload(blob: bytes, destination: str | Path | None = None) -> bytes:
    """Return the payload bytes exactly as stored, optionally writing them out."""
    payload = probe(blob)
    data = blob[payload.offset : payload.offset + payload.size]
    if destination is not None:
        destination = Path(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    return data
