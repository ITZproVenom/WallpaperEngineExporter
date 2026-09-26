# LumaForge

A focused iOS Wallpaper Engine exporter.

## Server-side workflow

LumaForge is a thin iOS client. The iPhone never receives the raw Wallpaper Engine Workshop package.

1. Enter a Steam Workshop URL or Workshop ID.
2. LumaForge creates a server job.
3. The worker uses SteamCMD to acquire the Workshop item.
4. The worker extracts ZIP/PKG content and decodes supported TEX assets.
5. FFmpeg converts the selected media to MP4.
6. The iPhone downloads only the finished MP4.
7. The finished MP4 is saved locally for sharing.

Temporary server files are cleaned automatically.

### API

- `POST /v1/jobs` with `{"workshop_id":"123456789"}`
- `GET /v1/jobs/{job_id}`
- `GET /v1/files/{job_id}.mp4`
- `DELETE /v1/jobs/{job_id}`
- `GET /health`

The production worker is deployed from the repository root `Dockerfile`. The iOS client targets the worker API and does not run AVFoundation conversion, ZIP/PKG extraction, or TEX decoding.

## Build

Xcode 26, iOS 18+, unsigned IPA in CI.

The CI pipeline validates the Python worker and builds the Docker image in addition to building the iOS archive.
