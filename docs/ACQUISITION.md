# Workshop acquisition: what actually works

Acquisition is the hard part of this project, not conversion. This document
records what was tested, when, and what the result was, so nobody re-litigates
it from stale README claims.

## The constraint

Wallpaper Engine (app `431960`) is a **paid** app. Steam serves Workshop
content for paid apps only to accounts that own them, enforced when the client
requests UGC details. Anonymous access is refused at the protocol level, which
is why generic "Steam Workshop downloader" services work for free-to-play
games and fail for this one.

## Live test results (2026-09)

| Source | How it was tested | Result |
| --- | --- | --- |
| `api.ggntw.com/steam.request` | Live POST with a real item URL | `{"result":10,"status":3,"error":"need login to account"}` |
| `backend-0{1,2}-prd.steamworkshopdownloader.io`, `node03…`, `api.…` | DNS + HTTP | Hosts do not resolve; the domain was sold |
| `steamworkshopdownloader.net/api/download` | Live POST, correct key `workshopUrl` | `200 OK`, `downloadUrl: ""` |
| `steamworkshopapi.spidereeb632.workers.dev/api/extract` | Live POST | Metadata only, `downloadUrl: ""` |
| `steamworkshopdownloader.cc`, `.app`, `steamworkshopdl.com`, `steam-workshop-downloader.org` | Live POST to `/api/download`, `/api/resolve` | No file URL returned |
| `ISteamRemoteStorage/GetPublishedFileDetails` | Live API | Works for metadata; `file_url` always empty for `431960` |
| Anonymous Steam client (`steamctl --anonymous ugc download`) | Real login, real `hcontent_file` | `(16) Failed getting UGC details` |
| SteamCMD `workshop_download_item 431960` anonymous | Attempted | Requires ownership |
| DepotDownloader | Documentation and source | Requires an account that owns the app |

Conclusion: no anonymous public route to Wallpaper Engine Workshop files
exists. Services that advertise otherwise return metadata and no file.

## Rejected approach: shared credentials

Several GitHub projects claim "no Steam account needed". They ship stolen or
shared logins:

- `ChadKevin/WallpaperEngineWorkshopDownloader` embeds six base64-encoded Steam
  account passwords in its source.
- `NethercraftMC5608/NetherWorkshopDownloader` advertises "a database full of
  accounts scraped from public account websites".

This project does not use that approach. It is credential abuse, it bypasses
paying the wallpaper platform's authors, and those accounts are banned
continuously, so it breaks anyway.

## Supported sources, best fidelity first

| Priority | Source | Needs | Fidelity |
| --- | --- | --- | --- |
| 10 | `imported` | User supplies the `.pkg`/folder | Original files, lossless |
| 20 | `local-library` | Wallpaper Engine installed on the same machine | Original files, lossless |
| 50 | `steam-account` (not implemented) | The user's own Steam login; ToS caveats | Original files |
| 90 | `public-mirror` | A working third-party endpoint | Unknown; none currently exist |

`Registry.acquire()` tries sources in priority order and reports why each one
declined, so a failure explains itself instead of saying "download failed".

## Adding a source later

Implement `acquisition.base.Source`: `capability()` reports whether the source
can work **right now**, and `acquire()` places files in a target directory.
Nothing in `processing/` needs to change — that separation is the point.

Set `LUMAFORGE_MIRRORS` to a comma-separated list of endpoints to enable the
mirror source if a working service appears. A mirror that returns only the
Workshop page URL, or an empty download URL, is treated as failed.
