"""Build synthetic PKG/TEX fixtures that mirror the real container layouts."""
from __future__ import annotations
import struct, subprocess, sys
from pathlib import Path


def make_mp4(path: Path, seconds: int = 1, size: str = "128x72") -> bytes:
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
         "-i", f"testsrc=size={size}:rate=10:duration={seconds}",
         "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(path)],
        check=True, timeout=120,
    )
    return path.read_bytes()


def make_tex(payload: bytes, width: int, height: int, texb: bytes = b"TEXB0004") -> bytes:
    out = bytearray(b"TEXV0005\x00")
    out += b"TEXI0001\x00"
    out += struct.pack("<IIIIII", 4, 0, width, height, width, height)
    out += texb + b"\x00"
    out += struct.pack("<II", 1, 0)  # image count + v4 extra field
    out += payload
    return bytes(out)


def make_pkg(entries: list[tuple[str, bytes]], version: bytes = b"0022") -> bytes:
    directory = bytearray()
    offset = 0
    for name, blob in entries:
        encoded = name.encode("utf-8")
        directory += struct.pack("<I", len(encoded)) + encoded
        directory += struct.pack("<II", offset, len(blob))
        offset += len(blob)
    header = struct.pack("<I", 8) + b"PKGV" + version + struct.pack("<I", len(entries))
    return bytes(header + directory + b"".join(blob for _, blob in entries))


if __name__ == "__main__":
    target = Path(sys.argv[1] if len(sys.argv) > 1 else "fixtures")
    target.mkdir(parents=True, exist_ok=True)
    mp4 = make_mp4(target / "source.mp4")
    (target / "video_scene.pkg").write_bytes(
        make_pkg([("materials/video.tex", make_tex(mp4, 128, 72)),
                  ("project.json", b'{"type":"video","title":"fixture"}')])
    )
    print("fixtures written to", target)
