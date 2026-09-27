FROM debian:bookworm-slim AS lwebuilder

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git cmake build-essential pkg-config \
      libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev \
      libgl1-mesa-dev libglew-dev freeglut3-dev libsdl2-dev liblz4-dev \
      libavcodec-dev libavformat-dev libavutil-dev libswscale-dev \
      libmpv-dev libpulse-dev libfreetype6-dev libdbus-1-dev \
      libwayland-dev wayland-protocols libegl1-mesa-dev libglfw3-dev libfftw3-dev libglm-dev libgmp-dev \
 && rm -rf /var/lib/apt/lists/* \
 && git clone --depth 1 --recurse-submodules https://github.com/Almamu/linux-wallpaperengine.git /src/linux-wallpaperengine \
 && sed -i '/#include <map>/a #include <memory>\n#include <optional>' /src/linux-wallpaperengine/src/WallpaperEngine/Media/MediaSource.h \
 && cmake -S /src/linux-wallpaperengine -B /src/linux-wallpaperengine/build -DCMAKE_BUILD_TYPE=Release \
 && cmake --build /src/linux-wallpaperengine/build --parallel 2 \
 && cmake --install /src/linux-wallpaperengine/build

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
ENV LWE_RENDERER=/opt/linux-wallpaperengine/linux-wallpaperengine
ENV LWE_ASSETS_DIR=/opt/wallpaper-engine/assets
ENV LWE_RENDERER_ENABLED=1
ENV LIBGL_ALWAYS_SOFTWARE=1

RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl ffmpeg python3 python3-pil nodejs npm chromium xvfb \
      mesa-utils libgl1-mesa-dri libgl1-mesa-glx libglu1-mesa libglew2.2 libglfw3 \
      libmpv2 libpulse0 libfftw3-double3 libfreetype6 libdbus-1-3 libx11-6 libxrandr2 libxinerama1 \
      libxcursor1 libxi6 libwayland-client0 libegl1 libgl1 \
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

COPY --from=lwebuilder /opt/linux-wallpaperengine /opt/linux-wallpaperengine

COPY --from=depotbuilder /out/ /opt/depotdownloader/
COPY --from=depotbuilder /usr/share/dotnet /usr/share/dotnet
RUN printf '#!/bin/sh\nexec /usr/share/dotnet/dotnet /opt/depotdownloader/DepotDownloader.dll "$@"\n' > /opt/depotdownloader/DepotDownloader \
 && chmod +x /opt/depotdownloader/DepotDownloader

WORKDIR /app
COPY server/lumaforge-server.py /app/lumaforge-server.py
COPY server/scene_renderer.mjs /app/scene_renderer.mjs
COPY server/patch_lwe_sources.py /app/patch_lwe_sources.py
COPY server/linux_wallpaperengine_renderer.py /app/linux_wallpaperengine_renderer.py
EXPOSE 8080
CMD ["python3", "/app/lumaforge-server.py"]

