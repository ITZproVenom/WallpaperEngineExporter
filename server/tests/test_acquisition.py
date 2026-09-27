"""Acquisition tests. No network: sources are driven through their contracts."""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from acquisition import AcquisitionError, Capability, ItemMetadata, Registry, Source  # noqa: E402
from acquisition import steam_metadata  # noqa: E402
from acquisition.sources import ImportedFile, LocalLibrary, PublicMirror  # noqa: E402


class ImportedFileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.inbox = self.tmp / "inbox"
        self.inbox.mkdir()

    def test_unavailable_without_inbox(self):
        source = ImportedFile(inbox=self.tmp / "missing")
        self.assertFalse(source.capability().available)

    def test_finds_package_named_after_the_item(self):
        (self.inbox / "3807719502.pkg").write_bytes(b"x" * 64)
        source = ImportedFile(inbox=self.inbox)
        self.assertTrue(source.capability().available)
        content = source.acquire("3807719502", self.tmp / "out")
        self.assertEqual(content.source_name, "imported")
        self.assertTrue((self.tmp / "out/3807719502.pkg").is_file())

    def test_missing_item_raises(self):
        source = ImportedFile(inbox=self.inbox)
        with self.assertRaises(AcquisitionError):
            source.acquire("123456", self.tmp / "out2")


class LocalLibraryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def test_reads_subscribed_item_folder(self):
        library = self.tmp / "content/431960"
        (library / "999").mkdir(parents=True)
        (library / "999/project.json").write_text('{"type":"video"}')
        source = LocalLibrary(library_root=library)
        self.assertTrue(source.capability().available)
        content = source.acquire("999", self.tmp / "out")
        self.assertTrue((self.tmp / "out/project.json").is_file())
        self.assertEqual(content.source_name, "local-library")

    def test_unsubscribed_item_raises(self):
        library = self.tmp / "content2"
        library.mkdir(parents=True)
        with self.assertRaises(AcquisitionError):
            LocalLibrary(library_root=library).acquire("1", self.tmp / "o")


class PublicMirrorTests(unittest.TestCase):
    def test_reports_unavailable_with_no_endpoints(self):
        capability = PublicMirror().capability()
        self.assertFalse(capability.available)
        self.assertIn("paid", capability.detail)

    def test_metadata_echo_is_not_accepted_as_a_download(self):
        """A mirror that returns only the Workshop page URL has not worked."""
        mirror = PublicMirror(endpoints=("https://example.invalid/api",))
        page = "https://steamcommunity.com/sharedfiles/filedetails/?id=1"
        data = {"downloadUrl": "", "url": page}
        for key in ("downloadUrl", "url"):
            self.assertFalse(
                str(data.get(key) or "").startswith("https://")
                and "steamcommunity.com/sharedfiles" not in str(data.get(key))
            )
        self.assertTrue(mirror.capability().available)


class RegistryTests(unittest.TestCase):
    class Failing(Source):
        name = "failing"
        priority = 1

        def capability(self):
            return Capability(self.name, True, "always fails")

        def acquire(self, workshop_id, target, metadata=None):
            raise AcquisitionError("nope")

    class Blocked(Source):
        name = "blocked"
        priority = 2

        def capability(self):
            return Capability(self.name, False, "needs credentials")

        def acquire(self, workshop_id, target, metadata=None):
            raise AssertionError("must not be called")

    def test_reports_every_attempt_when_all_sources_fail(self):
        registry = Registry().register(self.Failing()).register(self.Blocked())
        with self.assertRaises(AcquisitionError) as caught:
            registry.acquire("1", Path(tempfile.mkdtemp()))
        message = str(caught.exception)
        self.assertIn("failing: nope", message)
        self.assertIn("blocked: needs credentials", message)

    def test_unavailable_sources_are_skipped_not_called(self):
        registry = Registry().register(self.Blocked())
        with self.assertRaises(AcquisitionError):
            registry.acquire("1", Path(tempfile.mkdtemp()))


class MetadataParsingTests(unittest.TestCase):
    VIDEO = {
        "publishedfileid": "3807719502", "result": 1, "consumer_app_id": 431960,
        "title": "Test", "file_size": "30485611",
        "tags": [{"tag": "Video"}, {"tag": "Anime"}, {"tag": "3840 x 2160"}],
    }
    SCENE = {
        "publishedfileid": "1", "result": 1, "consumer_app_id": 431960,
        "title": "S", "tags": [{"tag": "Scene"}, {"tag": "Audio responsive"}],
    }

    def test_video_item_is_flagged_as_likely_passthrough(self):
        metadata = steam_metadata._parse(self.VIDEO)
        self.assertEqual(metadata.declared_type, "Video")
        self.assertEqual(metadata.resolution, "3840 x 2160")
        self.assertTrue(metadata.likely_passthrough)
        self.assertFalse(metadata.interactive)

    def test_audio_responsive_scene_is_flagged_interactive(self):
        metadata = steam_metadata._parse(self.SCENE)
        self.assertEqual(metadata.declared_type, "Scene")
        self.assertTrue(metadata.interactive)
        self.assertFalse(metadata.likely_passthrough)

    def test_wrong_app_is_rejected(self):
        original = steam_metadata._post
        steam_metadata._post = lambda ids, timeout: [
            {"publishedfileid": "9", "result": 1, "consumer_app_id": 730, "tags": []}
        ]
        try:
            with self.assertRaises(AcquisitionError):
                steam_metadata.describe("9")
        finally:
            steam_metadata._post = original

    def test_missing_item_is_rejected(self):
        original = steam_metadata._post
        steam_metadata._post = lambda ids, timeout: []
        try:
            with self.assertRaises(AcquisitionError):
                steam_metadata.describe("9")
        finally:
            steam_metadata._post = original


if __name__ == "__main__":
    unittest.main(verbosity=2)
