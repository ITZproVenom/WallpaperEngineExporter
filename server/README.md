# LumaForge SteamCMD Resolver

Server-side Workshop acquisition for LumaForge.

The iPhone does not run SteamCMD. The server runs SteamCMD with Wallpaper Engine App ID 431960 and the requested Workshop ID, then returns a URL for the downloaded package.

## Endpoints

- GET /health
- GET /workshop?id=WORKSHOP_ID
- GET /files/GENERATED_FILE

## Environment

- PORT=8080
- PUBLIC_BASE_URL=https://your-server.example
- API_KEY=optional bearer token
- DOWNLOAD_ROOT=/tmp/lumaforge
- DOWNLOAD_MAX_AGE=3600

## Docker

Build:

    docker build -t lumaforge-steamcmd .

Run:

    docker run --rm -p 8080:8080 -e PUBLIC_BASE_URL=https://your-server.example lumaforge-steamcmd

Keep the resolver behind HTTPS. If API_KEY is set, requests to /workshop require Authorization: Bearer API_KEY.
