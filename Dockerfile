FROM mcr.microsoft.com/dotnet/sdk:9.0-bookworm-slim AS depotbuilder

WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
 && git clone --depth 1 --branch DepotDownloader_3.4.0 https://github.com/SteamRE/DepotDownloader.git /src/DepotDownloader \
 && dotnet publish /src/DepotDownloader/DepotDownloader.sln -c Release -o /out --self-contained false \
 && test -f /out/DepotDownloader.dll

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV STEAMCMD=/opt/steamcmd/steamcmd.sh
ENV DEPOT_DOWNLOADER=/opt/depotdownloader/DepotDownloader
ENV PORT=8080
ENV WORK_ROOT=/tmp/lumaforge
ENV MAX_JOBS=1
ENV WORKSHOP_PROVIDER=steamapi,depotdownloader,swdl,ggnetwork,supabase,steamcmd
ENV MIN_MEDIA_DIMENSION=64
ENV SCENE_RENDER_WIDTH=1280
ENV SCENE_RENDER_HEIGHT=720
ENV SCENE_RENDER_SECONDS=6
ENV SCENE_RENDER_FPS=30
ENV CHROMIUM_PATH=/usr/bin/chromium
ENV WEBWALLGL_MODULE=/opt/lumaforge-renderer/webwallgl.min.mjs

RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl ffmpeg python3 python3-pil nodejs npm chromium \
      libc6:i386 lib32gcc-s1 \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /opt/steamcmd /opt/depotdownloader /opt/lumaforge-renderer \
 && curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar -xz -C /opt/steamcmd \
 && chmod +x /opt/steamcmd/steamcmd.sh \
 && curl -fsSL https://cdn.jsdelivr.net/npm/webwallgl@1.4.2/webwallgl.min.mjs -o /opt/lumaforge-renderer/webwallgl.min.mjs \
 && curl -fsSL https://cdn.jsdelivr.net/npm/webwallgl@1.4.2/LICENSE -o /opt/lumaforge-renderer/WEBWALLGL-LICENSE \
 && cd /opt/lumaforge-renderer \
 && npm init -y >/dev/null 2>&1 \
 && npm install --omit=dev --no-audit --no-fund puppeteer-core@24.20.0 \
 && rm -f package.json package-lock.json

COPY --from=depotbuilder /out/ /opt/depotdownloader/
COPY --from=depotbuilder /usr/share/dotnet /usr/share/dotnet
RUN printf '#!/bin/sh\nexec /usr/share/dotnet/dotnet /opt/depotdownloader/DepotDownloader.dll "$@"\n' > /opt/depotdownloader/DepotDownloader \
 && chmod +x /opt/depotdownloader/DepotDownloader

WORKDIR /app
COPY server/lumaforge-server.py /app/lumaforge-server.py
COPY server/scene_renderer.mjs /app/scene_renderer.mjs
EXPOSE 8080
CMD ["python3", "/app/lumaforge-server.py"]
