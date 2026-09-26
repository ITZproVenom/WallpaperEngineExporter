#!/usr/bin/env python3
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

APP_ID = "431960"
HOST = os.getenv("HOST", "0.0.0.0")
PORT = int(os.getenv("PORT", "8080"))
PUBLIC_BASE_URL = os.getenv("PUBLIC_BASE_URL", "").rstrip("/")
API_KEY = os.getenv("API_KEY", "")
STEAMCMD = os.getenv("STEAMCMD", "/opt/steamcmd/steamcmd.sh")
ROOT = Path(os.getenv("DOWNLOAD_ROOT", "/tmp/lumaforge"))
MAX_AGE = int(os.getenv("DOWNLOAD_MAX_AGE", "3600"))
LOCK = threading.Lock()
ID_RE = re.compile(r"^\d{6,20}$")

ROOT.mkdir(parents=True, exist_ok=True)


def run_steamcmd(workshop_id: str, target: Path) -> None:
    cmd = [
        STEAMCMD,
        "+@ShutdownOnFailedCommand", "1",
        "+@NoPromptForPassword", "1",
        "+login", "anonymous",
        "+force_install_dir", str(target),
        "+workshop_download_item", APP_ID, workshop_id, "validate",
        "+quit",
    ]
    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=300,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError("SteamCMD failed: " + result.stdout[-3000:])


def package_result(workshop_id: str, target: Path) -> Path:
    content = target / "steamapps" / "workshop" / "content" / APP_ID / workshop_id
    if not content.is_dir():
        raise RuntimeError("SteamCMD completed but returned no Workshop content")

    # Keep the original package when there is exactly one useful file.
    files = [p for p in content.rglob("*") if p.is_file()]
    if len(files) == 1 and files[0].suffix.lower() in {".pkg", ".zip", ".mp4", ".webm", ".mov", ".m4v"}:
        destination = ROOT / f"{uuid.uuid4().hex}-{files[0].name}"
        shutil.copy2(files[0], destination)
        return destination

    destination = ROOT / f"{uuid.uuid4().hex}-{workshop_id}.zip"
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        for file in files:
            archive.write(file, file.relative_to(content))
    return destination


def resolve(workshop_id: str) -> Path:
    if not ID_RE.fullmatch(workshop_id):
        raise ValueError("Invalid Workshop ID")

    with LOCK:
        work = Path(tempfile.mkdtemp(prefix="steamcmd-", dir=ROOT))
        try:
            run_steamcmd(workshop_id, work)
            return package_result(workshop_id, work)
        finally:
            shutil.rmtree(work, ignore_errors=True)


def cleanup() -> None:
    now = time.time()
    for path in ROOT.iterdir():
        try:
            if path.is_file() and now - path.stat().st_mtime > MAX_AGE:
                path.unlink()
        except OSError:
            pass


class Handler(BaseHTTPRequestHandler):
    server_version = "LumaForgeSteamCMD/1.0"

    def send_json(self, status: int, payload: dict) -> None:
        import json
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorized(self) -> bool:
        if not API_KEY:
            return True
        return self.headers.get("Authorization") == f"Bearer {API_KEY}"

    def do_GET(self) -> None:
        cleanup()
        parsed = urlparse(self.path)

        if parsed.path == "/health":
            self.send_json(200, {"ok": True, "provider": "steamcmd", "appid": APP_ID})
            return

        if parsed.path == "/workshop":
            if not self.authorized():
                self.send_json(401, {"error": "Unauthorized"})
                return

            values = parse_qs(parsed.query).get("id", [])
            workshop_id = values[0] if values else ""
            try:
                result = resolve(workshop_id)
                filename = result.name
                base = PUBLIC_BASE_URL or f"http://{self.headers.get('Host', 'localhost')}"
                self.send_json(200, {
                    "download_url": f"{base}/files/{filename}",
                    "provider": "steamcmd",
                    "workshop_id": workshop_id,
                })
            except subprocess.TimeoutExpired:
                self.send_json(504, {"error": "SteamCMD timed out"})
            except Exception as exc:
                self.send_json(502, {"error": str(exc)})
            return

        if parsed.path.startswith("/files/"):
            name = Path(parsed.path.removeprefix("/files/")).name
            file = ROOT / name
            if not file.is_file():
                self.send_json(404, {"error": "File not found"})
                return
            try:
                size = file.stat().st_size
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(size))
                self.send_header("Content-Disposition", f'attachment; filename="{name}"')
                self.end_headers()
                with file.open("rb") as stream:
                    shutil.copyfileobj(stream, self.wfile)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return

        self.send_json(404, {"error": "Not found"})

    def log_message(self, fmt: str, *args) -> None:
        print(f"[steamcmd] {self.address_string()} {fmt % args}")


if __name__ == "__main__":
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
