"""Concrete acquisition sources, best fidelity first.

Ranking rationale:

  10  ImportedFile      user hands over the real package; nothing is lossier
  20  LocalLibrary      Wallpaper Engine's own download folder on this machine
  50  SteamAccount      authenticated Steam client (opt-in, ToS caveats)
  90  PublicMirror      third-party proxies; all known ones are dead or gated

Every source reports its capability at runtime. Nothing is assumed to work
because it worked once.
"""

from __future__ import annotations

import json
import os
import shutil
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from .base import AcquiredContent, AcquisitionError, Capability, ItemMetadata, Source

WALLPAPER_ENGINE_APP_ID = "431960"


def _copy_tree(source: Path, target: Path) -> Path:
    target.mkdir(parents=True, exist_ok=True)
    if source.is_file():
        destination = target / source.name
        shutil.copy2(source, destination)
        return target
    shutil.copytree(source, target, dirs_exist_ok=True)
    return target


@dataclass
class ImportedFile(Source):
    """Content the user supplied directly: a .pkg, a folder, or a ZIP.

    This is the only source that works with no Steam access, no credentials,
    no server, and no Wallpaper Engine licence. It is therefore the default.
    """

    inbox: Path
    name: str = "imported"
    priority: int = 10

    def capability(self) -> Capability:
        exists = self.inbox.is_dir()
        return Capability(
            name=self.name,
            available=exists,
            detail=(
                f"Reads user-supplied packages from {self.inbox}"
                if exists else f"Inbox {self.inbox} does not exist"
            ),
            requires_user_action=True,
        )

    def _candidates(self, workshop_id: str) -> list[Path]:
        if not self.inbox.is_dir():
            return []
        exact = [
            p for p in self.inbox.iterdir()
            if p.stem == workshop_id or p.name == workshop_id
        ]
        if exact:
            return exact
        return [p for p in self.inbox.rglob("*.pkg") if workshop_id in str(p)]

    def acquire(self, workshop_id: str, target: Path,
                metadata: ItemMetadata | None = None) -> AcquiredContent:
        candidates = self._candidates(workshop_id)
        if not candidates:
            raise AcquisitionError(
                f"No imported package found for {workshop_id} in {self.inbox}"
            )
        root = _copy_tree(candidates[0], target)
        return AcquiredContent(
            workshop_id=workshop_id, root=root, source_name=self.name,
            metadata=metadata, notes=(f"Imported from {candidates[0].name}",),
        )


@dataclass
class LocalLibrary(Source):
    """Wallpaper Engine's own Workshop folder, when running on that machine.

    Files here are already decrypted and complete, so exports are lossless and
    no credentials are involved. Requires Wallpaper Engine to be installed.
    """

    library_root: Path | None = None
    name: str = "local-library"
    priority: int = 20

    DEFAULT_PATHS = (
        Path.home() / ".steam/steam/steamapps/workshop/content" / WALLPAPER_ENGINE_APP_ID,
        Path("C:/Program Files (x86)/Steam/steamapps/workshop/content") / WALLPAPER_ENGINE_APP_ID,
        Path.home() / "Library/Application Support/Steam/steamapps/workshop/content" / WALLPAPER_ENGINE_APP_ID,
    )

    def _root(self) -> Path | None:
        if self.library_root is not None:
            return self.library_root if self.library_root.is_dir() else None
        override = os.getenv("WE_WORKSHOP_DIR")
        if override and Path(override).is_dir():
            return Path(override)
        return next((p for p in self.DEFAULT_PATHS if p.is_dir()), None)

    def capability(self) -> Capability:
        root = self._root()
        return Capability(
            name=self.name,
            available=root is not None,
            detail=(
                f"Wallpaper Engine library found at {root}" if root
                else "No local Wallpaper Engine Workshop folder on this machine"
            ),
        )

    def acquire(self, workshop_id: str, target: Path,
                metadata: ItemMetadata | None = None) -> AcquiredContent:
        root = self._root()
        if root is None:
            raise AcquisitionError("No local Wallpaper Engine library")
        item = root / workshop_id
        if not item.is_dir():
            raise AcquisitionError(f"{workshop_id} is not subscribed in {root}")
        return AcquiredContent(
            workshop_id=workshop_id, root=_copy_tree(item, target),
            source_name=self.name, metadata=metadata,
            notes=("Original files from the local Wallpaper Engine library",),
        )


@dataclass
class PublicMirror(Source):
    """Third-party Workshop proxies.

    Kept pluggable rather than deleted, because a working mirror may appear.
    Every endpoint is probed live and must return a real file URL; a metadata
    echo with an empty download URL counts as unavailable.

    Live check 2026-09: api.ggntw.com requires an account, the four
    steamworkshopdownloader.io hosts no longer resolve, and .net/.top/.cc/.app
    return metadata with an empty download URL for app 431960. Paid-app
    Workshop content is gated on ownership, so anonymous proxies cannot serve it.
    """

    endpoints: tuple[str, ...] = ()
    name: str = "public-mirror"
    priority: int = 90
    timeout: int = 30

    def capability(self) -> Capability:
        if not self.endpoints:
            return Capability(
                name=self.name, available=False,
                detail=(
                    "No working public mirror is known. Wallpaper Engine is a paid "
                    "app, so Steam gates its Workshop files behind ownership."
                ),
            )
        return Capability(
            name=self.name, available=True,
            detail=f"{len(self.endpoints)} configured mirror endpoint(s)",
        )

    def _resolve(self, endpoint: str, workshop_id: str) -> str:
        page = f"https://steamcommunity.com/sharedfiles/filedetails/?id={workshop_id}"
        body = json.dumps({
            "url": page, "workshopUrl": page,
            "publishedFileId": workshop_id, "id": workshop_id,
        }).encode()
        request = urllib.request.Request(
            endpoint, data=body,
            headers={"Content-Type": "application/json", "Accept": "application/json",
                     "User-Agent": "LumaForge/3.0"},
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = json.loads(response.read().decode("utf-8", "replace"))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            raise AcquisitionError(f"{endpoint} unreachable: {error}") from error

        data = payload.get("data") if isinstance(payload.get("data"), dict) else payload
        for key in ("downloadUrl", "download_url", "fileUrl", "file_url", "url"):
            value = str(data.get(key) or "")
            if value.startswith("https://") and "steamcommunity.com/sharedfiles" not in value:
                return value
        raise AcquisitionError(f"{endpoint} returned no download URL")

    def acquire(self, workshop_id: str, target: Path,
                metadata: ItemMetadata | None = None) -> AcquiredContent:
        failures: list[str] = []
        for endpoint in self.endpoints:
            try:
                url = self._resolve(endpoint, workshop_id)
            except AcquisitionError as error:
                failures.append(str(error))
                continue
            target.mkdir(parents=True, exist_ok=True)
            destination = target / f"{workshop_id}.zip"
            try:
                request = urllib.request.Request(
                    url, headers={"User-Agent": "LumaForge/3.0"}
                )
                with urllib.request.urlopen(request, timeout=self.timeout) as response:
                    destination.write_bytes(response.read())
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                failures.append(f"{endpoint} download failed: {error}")
                continue
            if destination.stat().st_size < 1024:
                failures.append(f"{endpoint} served an empty file")
                continue
            shutil.unpack_archive(str(destination), str(target))
            destination.unlink(missing_ok=True)
            return AcquiredContent(
                workshop_id=workshop_id, root=target, source_name=self.name,
                metadata=metadata, notes=(f"Downloaded via {endpoint}",),
            )
        raise AcquisitionError("; ".join(failures) or "no mirror endpoints configured")


def default_registry(inbox: Path | None = None):
    """Build the registry the worker and CLI use."""
    from .base import Registry

    registry = Registry()
    registry.register(ImportedFile(inbox=inbox or Path(os.getenv("LUMAFORGE_INBOX", "/data/inbox"))))
    registry.register(LocalLibrary())
    mirrors = tuple(
        e.strip() for e in os.getenv("LUMAFORGE_MIRRORS", "").split(",") if e.strip()
    )
    registry.register(PublicMirror(endpoints=mirrors))
    return registry
