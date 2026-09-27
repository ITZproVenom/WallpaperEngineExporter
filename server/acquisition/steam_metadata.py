"""Steam public metadata lookup.

ISteamRemoteStorage/GetPublishedFileDetails needs no API key and no login, and
it reveals the wallpaper's declared type before anything is downloaded. That
lets the app tell the user "this one exports losslessly" versus "this one needs
a renderer" up front instead of after a long download.

It does not return a download URL for Wallpaper Engine content; `file_url` is
always empty for app 431960 because the files are depot-hosted behind an
ownership check. Verified live, 2026-09.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request

from .base import AcquisitionError, ItemMetadata

ENDPOINT = "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"
WALLPAPER_ENGINE_APP_ID = 431960
TYPE_TAGS = ("Video", "Scene", "Web", "Application")
INTERACTIVE_TAGS = ("Audio responsive", "Interactive", "Clock", "Media Integration")
USER_AGENT = "LumaForge/3.0 (+https://github.com/ITZproVenom/WallpaperEngineExporter)"


def _post(ids: list[str], timeout: int) -> list[dict]:
    fields = {"itemcount": len(ids)}
    fields.update({f"publishedfileids[{i}]": v for i, v in enumerate(ids)})
    request = urllib.request.Request(
        ENDPOINT,
        data=urllib.parse.urlencode(fields).encode(),
        headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8", "replace"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise AcquisitionError(f"Steam metadata lookup failed: {error}") from error
    return (payload.get("response") or {}).get("publishedfiledetails") or []


def _parse(detail: dict) -> ItemMetadata:
    tags = tuple(
        str(t.get("tag", "")) for t in (detail.get("tags") or []) if t.get("tag")
    )
    declared = next((t for t in tags if t in TYPE_TAGS), None)
    resolution = next((t for t in tags if " x " in t), "")
    return ItemMetadata(
        workshop_id=str(detail.get("publishedfileid") or ""),
        title=str(detail.get("title") or ""),
        declared_type=declared,
        file_size=int(detail.get("file_size") or 0),
        tags=tags,
        preview_url=str(detail.get("preview_url") or ""),
        resolution=resolution,
        interactive=any(t in INTERACTIVE_TAGS for t in tags),
    )


def describe(workshop_id: str, timeout: int = 20) -> ItemMetadata:
    details = _post([str(workshop_id)], timeout)
    if not details:
        raise AcquisitionError(f"Workshop item {workshop_id} was not found")
    detail = details[0]
    if int(detail.get("result") or 0) != 1:
        raise AcquisitionError(f"Workshop item {workshop_id} is unavailable")
    consumer = int(detail.get("consumer_app_id") or 0)
    if consumer and consumer != WALLPAPER_ENGINE_APP_ID:
        raise AcquisitionError(
            f"Item {workshop_id} belongs to app {consumer}, not Wallpaper Engine"
        )
    return _parse(detail)


def describe_many(workshop_ids: list[str], timeout: int = 30) -> dict[str, ItemMetadata]:
    """Batch lookup; used when listing a whole subscription list."""
    found: dict[str, ItemMetadata] = {}
    for chunk_start in range(0, len(workshop_ids), 50):
        chunk = [str(i) for i in workshop_ids[chunk_start : chunk_start + 50]]
        for detail in _post(chunk, timeout):
            if int(detail.get("result") or 0) == 1:
                metadata = _parse(detail)
                found[metadata.workshop_id] = metadata
    return found
