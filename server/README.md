# LumaForge Server

All Workshop acquisition and conversion happens on the server.

The iPhone only:
1. Sends a Workshop ID.
2. Polls the server job status.
3. Downloads the finished MP4.

The iPhone never downloads a Workshop package, extracts PKG/ZIP contents, decodes TEX data, or runs video conversion.

## Pipeline

`iPhone -> /v1/jobs -> SteamCMD -> package extraction -> FFmpeg -> MP4 -> /v1/files -> iPhone`

Wallpaper Engine App ID: `431960`.

## Endpoints

- `GET /health`
- `POST /v1/jobs` with `{"workshop_id":"123456789" }`
- `GET /v1/jobs/{job_id}`
- `GET /v1/files/{job_id}.mp4`
- `DELETE /v1/jobs/{job_id}`

Jobs are temporary. Generated files are automatically removed after `WORK_MAX_AGE`.

## Environment

- `PORT=8080`
- `PUBLIC_BASE_URL=https://your-server.example`
- `API_KEY=optional bearer token`
- `WORK_ROOT=/tmp/lumaforge`
- `WORK_MAX_AGE=3600`
- `MAX_JOBS=1`

## Docker

```sh
docker build -t lumaforge-server ./server
docker run --rm -p 8080:8080 \
  -e PUBLIC_BASE_URL=https://your-server.example \
  -e API_KEY=change-me \
  lumaforge-server
```

The image includes SteamCMD, FFmpeg, Python and Pillow. Keep the service behind HTTPS.
