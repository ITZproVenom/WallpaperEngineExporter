FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV STEAMCMD=/opt/steamcmd/steamcmd.sh
ENV PORT=8080
ENV WORK_ROOT=/tmp/lumaforge
ENV MAX_JOBS=1
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
 && mkdir -p /opt/steamcmd /opt/lumaforge-renderer \
 && curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar -xz -C /opt/steamcmd \
 && chmod +x /opt/steamcmd/steamcmd.sh \
 && curl -fsSL https://cdn.jsdelivr.net/npm/webwallgl@1.4.2/webwallgl.min.mjs -o /opt/lumaforge-renderer/webwallgl.min.mjs \
 && cd /opt/lumaforge-renderer \
 && npm init -y >/dev/null 2>&1 \
 && npm install --omit=dev --no-audit --no-fund puppeteer-core@24.20.0 \
 && rm -f package.json package-lock.json

WORKDIR /app
COPY server/lumaforge-server.py /app/lumaforge-server.py
COPY server/scene_renderer.mjs /app/scene_renderer.mjs
EXPOSE 8080
CMD ["python3", "/app/lumaforge-server.py"]
