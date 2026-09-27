import importlib.util
import tempfile
import unittest
import urllib.request
import zipfile
from pathlib import Path
from unittest.mock import patch

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

    def test_redirect_handler_rejects_private_destination(self):
        handler = SERVER.SafeRedirectHandler()
        request = urllib.request.Request("https://example.com/file")
        with self.assertRaisesRegex(RuntimeError, "unsafe URL"):
            handler.redirect_request(
                request, None, 302, "Found", {}, "https://127.0.0.1/private"
            )

    def test_workshop_id_validation(self):
        self.assertTrue(SERVER.ID_RE.fullmatch("3714599577"))
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
                (target / "wallpaper" / "video.mp4").read_bytes(), b"not-real-video"
            )

    def test_placeholder_image_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "content"
            root.mkdir()
            image = root / "workshop.png"
            image.write_bytes(b"placeholder")
            with patch.object(SERVER, "image_dimensions", return_value=(16, 16)):
                with self.assertRaisesRegex(RuntimeError, "no usable"):
                    SERVER.validate_workshop_content(root)

    def test_preview_only_download_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "content"
            root.mkdir()
            (root / "preview.jpg").write_bytes(b"preview")
            with self.assertRaisesRegex(RuntimeError, "preview-only"):
                SERVER.validate_workshop_content(root)

    def test_valid_image_is_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "content"
            root.mkdir()
            image = root / "wallpaper.jpg"
            image.write_bytes(b"wallpaper")
            with patch.object(SERVER, "image_dimensions", return_value=(1920, 1080)):
                result = SERVER.validate_workshop_content(root)
            self.assertEqual(result["kind"], "image")
            self.assertEqual(result["path"].name, "wallpaper.jpg")

    def test_depotdownloader_builds_anonymous_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            content = target / "steamapps" / "workshop" / "content" / SERVER.APP_ID / "3714599577"
            content.mkdir(parents=True)
            with patch.dict("os.environ", {"STEAM_USERNAME": "", "STEAM_PASSWORD": ""}, clear=False),                  patch.object(SERVER, "DEPOT_DOWNLOADER", "/opt/depotdownloader/DepotDownloader"),                  patch.object(SERVER, "run", return_value="downloaded") as run_mock:
                result = SERVER.depotdownloader_download("3714599577", target)
            self.assertEqual(result, content)
            command = run_mock.call_args.args[0]
            self.assertIn("-pubfile", command)
            self.assertIn("3714599577", command)
            self.assertNotIn("-username", command)
            self.assertNotIn("-password", command)

    def test_scene_pkg_is_preferred_over_preview(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "content"
            root.mkdir()
            (root / "scene.pkg").write_bytes(b"x" * 4096)
            (root / "preview.jpg").write_bytes(b"preview")
            result = SERVER.validate_workshop_content(root)
            self.assertEqual(result["kind"], "scene")
            self.assertEqual(result["path"].name, "scene.pkg")

    def test_preview_only_error_is_explicit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "content"
            root.mkdir()
            (root / "preview.jpg").write_bytes(b"preview")
            with self.assertRaisesRegex(RuntimeError, "preview-only media"):
                SERVER.validate_workshop_content(root)


if __name__ == "__main__":
    unittest.main()
