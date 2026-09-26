# LumaForge Server

All Workshop acquisition and conversion happens on the server.

The iPhone only:
1. Sends a Workshop ID.
2. Polls the server job status.
3. Downloads the finished MP4.

The iPhone never downloads a Workshop package, extracts PKG/ZIP contents, decodes TEX data, or runs video conversion.

## Pipeline

`iPhone -> /v1/jobs -> acquisition cascade -> Workshop content -> media extraction -> FFmpeg -> MP4 -> /v1/files -> iPhone`

Wallpaper Engine App ID: `431960`.

## Endpoints

- `GET /health`
- `POST /v1/jobs` with `{"workshop_id":"123456789" }`
- `GET /v1/jobs/{job_id}`
- `GET /v1/files/{filename}`
- `DELETE /v1/jobs/{job_id}`

Jobs are temporary. Generated files are automatically removed after `WORK_MAX_AGE`.

## Environment

- `PORT=8080`
- `PUBLIC_BASE_URL=https://your-server.example`
- `API_KEY=optional bearer token`
- `WORK_ROOT=/tmp/lumaforge`
- `WORK_MAX_AGE=3600`
- `MAX_JOBS=1`
- `MAX_MEMORY_JOBS=100`
- `WORKSHOP_PROVIDER=supabase,swdl,ggnetwork,steamcmd`
- `SUPABASE_RESOLVER_URL=https://yxyfdxjyxcpitrrllopi.supabase.co/functions/v1/lumaforge-workshop-resolver`
- `GGNETWORK_ENDPOINT=https://api.ggntw.com/steam.request`
- `MAX_DOWNLOAD_BYTES=2147483648`
- `MAX_ZIP_ENTRIES=100000`
- `MAX_EXTRACTED_BYTES=4294967296`

## Docker

```sh
docker build -t lumaforge-server ./server
docker run --rm -p 8080:8080 \
  -e PUBLIC_BASE_URL=https://your-server.example \
  -e API_KEY=change-me \
  lumaforge-server
```

The image includes SteamCMD, FFmpeg, Python and Pillow. The primary Workshop acquisition path is the server-side GGNetwork API, so the iPhone and the Wallpaper Engine app are not required. SteamCMD is retained as a server-side fallback. Keep the service behind HTTPS.


## Conversion behavior

Native video wallpapers and standalone GIF/image media are converted directly with FFmpeg. A native
Wallpaper Engine `scene.pkg` is **not** replaced by `preview.jpg` when the server cannot render its
scene assets. In that case the job fails with an explicit unsupported-scene error instead of producing
a misleading three-second preview video.

Full scene rendering requires a Wallpaper Engine runtime/assets renderer. The worker does not bundle
the proprietary Wallpaper Engine runtime assets.
