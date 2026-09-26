FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV STEAMCMD=/opt/steamcmd/steamcmd.sh
ENV PORT=8080
ENV WORK_ROOT=/tmp/lumaforge

RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl ffmpeg python3 python3-pil \
      libc6:i386 lib32gcc-s1 \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /opt/steamcmd \
 && curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar -xz -C /opt/steamcmd \
 && chmod +x /opt/steamcmd/steamcmd.sh

WORKDIR /app
COPY lumaforge-server.py /app/lumaforge-server.py
EXPOSE 8080
CMD ["python3", "/app/lumaforge-server.py"]
