FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV STEAMCMD=/opt/steamcmd/steamcmd.sh
ENV PORT=8080

RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl libc6:i386 lib32gcc-s1 python3 \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /opt/steamcmd \
 && curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar -xz -C /opt/steamcmd \
 && chmod +x /opt/steamcmd/steamcmd.sh

WORKDIR /app
COPY steamcmd-resolver.py /app/steamcmd-resolver.py
EXPOSE 8080
CMD ["python3", "/app/steamcmd-resolver.py"]
