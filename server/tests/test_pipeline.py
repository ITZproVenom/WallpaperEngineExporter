"""Pipeline tests. The passthrough assertions are byte-exact on purpose:
a lossless export must reproduce the original stream, not merely a similar one.
"""
from __future__ import annotations

import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from processing import convert, inspect as inspector, pkg, tex  # noqa: E402
from tests.build_fixtures import make_mp4, make_pkg, make_tex  # noqa: E402


class PkgTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def test_reads_directory_and_honours_offsets(self):
        blob = make_pkg([("a.txt", b"first"), ("nested/b.txt", b"second-entry")])
        path = self.tmp / "a.pkg"
        path.write_bytes(blob)
        archive = pkg.open_archive(path)
        self.assertEqual(archive.version, "0022")
        self.assertEqual([e.name for e in archive.entries], ["a.txt", "nested/b.txt"])
        self.assertEqual(archive.entries[1].offset, 5)
        self.assertEqual(pkg.read_entry(path, archive.entries[1]), b"second-entry")

    def test_rejects_non_pkg(self):
        path = self.tmp / "bad.pkg"
        path.write_bytes(b"NOPE" * 8)
        with self.assertRaises(pkg.PkgError):
            pkg.open_archive(path)

    def test_extract_writes_nested_files_and_manifest(self):
        blob = make_pkg([("materials/x.tex", b"xx"), ("project.json", b"{}")])
        path = self.tmp / "b.pkg"
        path.write_bytes(blob)
        pkg.extract(path, self.tmp / "out")
        self.assertTrue((self.tmp / "out/materials/x.tex").is_file())
        manifest = json.loads((self.tmp / "out/_manifest.json").read_text())
        self.assertEqual(len(manifest["entries"]), 2)

    def test_blocks_path_traversal(self):
        for hostile in ("../escape.txt", "/etc/passwd", "C:/windows/x", "..\\escape"):
            with self.subTest(hostile=hostile), self.assertRaises(pkg.PkgError):
                pkg.safe_relative_path(hostile)

    def test_traversal_entry_is_refused_during_extract(self):
        path = self.tmp / "evil.pkg"
        path.write_bytes(make_pkg([("../escape.txt", b"pwned")]))
        with self.assertRaises(pkg.PkgError):
            pkg.extract(path, self.tmp / "out2")
        self.assertFalse((self.tmp.parent / "escape.txt").exists())


class TexTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def test_detects_embedded_mp4_and_returns_exact_bytes(self):
        mp4 = make_mp4(self.tmp / "s.mp4")
        blob = make_tex(mp4, 1920, 1080)
        payload = tex.probe(blob)
        self.assertEqual(payload.kind, "video")
        self.assertEqual((payload.width, payload.height), (1920, 1080))
        self.assertEqual(tex.extract_payload(blob), mp4)

    def test_handles_texb0003_header_length(self):
        mp4 = make_mp4(self.tmp / "s3.mp4")
        blob = bytearray(b"TEXV0005\x00" + b"TEXI0001\x00")
        blob += struct.pack("<IIIIII", 4, 0, 64, 64, 64, 64)
        blob += b"TEXB0003\x00" + struct.pack("<I", 1) + mp4
        self.assertEqual(tex.extract_payload(bytes(blob)), mp4)

    def test_detects_png_payload(self):
        png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
        payload = tex.probe(make_tex(png, 8, 8))
        self.assertEqual((payload.kind, payload.extension), ("image", "png"))

    def test_ignores_ftyp_inside_pixel_data(self):
        noise = b"\xff\xff\xff\xffftyp" + b"\x11" * 256
        self.assertEqual(tex.probe(make_tex(noise, 8, 8)).kind, "raw")

    def test_rejects_non_tex(self):
        with self.assertRaises(tex.TexError):
            tex.probe(b"not a texture at all")


class InspectorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def _video_pkg(self) -> Path:
        mp4 = make_mp4(self.tmp / "v.mp4")
        path = self.tmp / "scene.pkg"
        path.write_bytes(make_pkg([
            ("materials/video.tex", make_tex(mp4, 1280, 720)),
            ("project.json", b'{"type":"video"}'),
        ]))
        return path

    def test_video_in_tex_is_passthrough(self):
        plan = inspector.inspect(self._video_pkg())
        self.assertEqual(plan.strategy, inspector.PASSTHROUGH)
        self.assertEqual(plan.fidelity, inspector.IDENTICAL)
        self.assertEqual(plan.candidate.source, "tex")

    def test_loose_mp4_beside_project_is_passthrough(self):
        root = self.tmp / "loose"
        root.mkdir()
        make_mp4(root / "wallpaper.mp4")
        (root / "project.json").write_text('{"type":"video"}')
        plan = inspector.inspect(root)
        self.assertEqual(plan.strategy, inspector.PASSTHROUGH)

    def test_scene_without_media_needs_renderer(self):
        root = self.tmp / "scenepkg"
        root.mkdir()
        (root / "scene.pkg").write_bytes(make_pkg([
            ("scene.json", b'{"objects":[]}'),
            ("materials/tex.tex", make_tex(b"\x02" * 4096, 512, 512)),
        ]))
        (root / "project.json").write_text('{"type":"scene"}')
        plan = inspector.inspect(root)
        self.assertEqual(plan.strategy, inspector.RENDER_SCENE)
        self.assertEqual(plan.fidelity, inspector.APPROXIMATE)
        self.assertFalse(plan.ok is False)

    def test_interactive_tags_produce_warning(self):
        plan = inspector.inspect(self._video_pkg(), tags=["Video", "Audio responsive"])
        self.assertTrue(any("Audio responsive" in w for w in plan.warnings))

    def test_empty_package_is_unsupported(self):
        root = self.tmp / "empty"
        root.mkdir()
        plan = inspector.inspect(root)
        self.assertEqual(plan.strategy, inspector.UNSUPPORTED)
        self.assertFalse(plan.ok)

    def test_still_image_only_reports_static(self):
        root = self.tmp / "still"
        root.mkdir()
        (root / "a.png").write_bytes(b"\x89PNG\r\n\x1a\n" + b"\x00" * 128)
        plan = inspector.inspect(root)
        self.assertEqual(plan.fidelity, inspector.STATIC_ONLY)


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def test_passthrough_export_is_byte_identical(self):
        mp4 = make_mp4(self.tmp / "orig.mp4", seconds=2, size="320x180")
        path = self.tmp / "scene.pkg"
        path.write_bytes(make_pkg([("materials/v.tex", make_tex(mp4, 320, 180))]))
        plan = inspector.inspect(path)
        result = convert.export(plan, self.tmp / "out.mp4", self.tmp / "scratch")
        self.assertFalse(result.reencoded)
        self.assertEqual((self.tmp / "out.mp4").read_bytes(), mp4)
        self.assertEqual((result.width, result.height), (320, 180))

    def test_scene_export_fails_with_a_clear_reason(self):
        root = self.tmp / "s"
        root.mkdir()
        (root / "scene.pkg").write_bytes(make_pkg([("scene.json", b"{}")]))
        plan = inspector.inspect(root)
        with self.assertRaises(convert.ConversionError) as caught:
            convert.export(plan, self.tmp / "o.mp4", self.tmp / "sc")
        self.assertIn("real-time scene", str(caught.exception))


if __name__ == "__main__":
    unittest.main(verbosity=2)
