import io
import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "lumaforge_server",
    Path(__file__).with_name("lumaforge-server.py"),
)
SERVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SERVER)


class WorkerTests(unittest.TestCase):
    def test_download_url_rejects_plain_http(self):
        with self.assertRaisesRegex(RuntimeError, "non-HTTPS"):
            SERVER._validate_download_url("http://example.com/file")

    def test_download_url_rejects_private_ip(self):
        with self.assertRaisesRegex(RuntimeError, "unsafe URL"):
            SERVER._validate_download_url("https://127.0.0.1/file")
        with self.assertRaisesRegex(RuntimeError, "unsafe URL"):
            SERVER._validate_download_url("https://169.254.169.254/latest/meta-data")

    def test_workshop_id_validation(self):
        self.assertTrue(SERVER.ID_RE.fullmatch("3803559783"))
        self.assertFalse(SERVER.ID_RE.fullmatch("12345"))
        self.assertFalse(SERVER.ID_RE.fullmatch("abc123456"))
        self.assertFalse(SERVER.ID_RE.fullmatch("1" * 21))

    def test_safe_extract_rejects_path_traversal(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive_path = Path(tmp) / "bad.zip"
            target = Path(tmp) / "out"
            target.mkdir()
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("../escape.txt", "nope")
            with zipfile.ZipFile(archive_path) as archive:
                with self.assertRaises(RuntimeError):
                    SERVER.safe_extract_zip(archive, target)

    def test_safe_extract_accepts_normal_archive(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive_path = Path(tmp) / "ok.zip"
            target = Path(tmp) / "out"
            target.mkdir()
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("wallpaper/video.mp4", b"not-real-video")
            with zipfile.ZipFile(archive_path) as archive:
                SERVER.safe_extract_zip(archive, target)
            self.assertEqual(
                (target / "wallpaper" / "video.mp4").read_bytes(),
                b"not-real-video",
            )

    def test_locate_source_prefers_real_video_over_preview(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "content"
            scratch = Path(tmp) / "scratch"
            root.mkdir()
            scratch.mkdir()
            (root / "preview.jpg").write_bytes(b"preview")
            (root / "wallpaper.mp4").write_bytes(b"video")
            source = SERVER.locate_source(root, scratch)
            self.assertEqual(source.name, "wallpaper.mp4")

    def test_locate_source_does_not_export_preview_as_wallpaper(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "content"
            scratch = Path(tmp) / "scratch"
            root.mkdir()
            scratch.mkdir()
            (root / "preview.jpg").write_bytes(b"preview")
            with self.assertRaisesRegex(RuntimeError, "preview media"):
                SERVER.locate_source(root, scratch)

    def test_locate_source_reports_unsupported_pkg(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "content"
            scratch = Path(tmp) / "scratch"
            root.mkdir()
            scratch.mkdir()
            (root / "scene.pkg").write_bytes(b"not-a-pkg")
            (root / "preview.jpg").write_bytes(b"preview")
            with self.assertRaisesRegex(RuntimeError, "scene.pkg"):
                SERVER.locate_source(root, scratch)

    def test_provider_file_rejects_non_media_without_silent_extension_guess(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "download"
            target = Path(tmp) / "target"
            target.mkdir()
            source.write_bytes(b"PKGV-invalid")
            content = SERVER._materialize_provider_file(source, target)
            self.assertTrue((content / "workshop.pkg").exists())


if __name__ == "__main__":
    unittest.main()
