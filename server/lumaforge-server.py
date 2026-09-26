#!/usr/bin/env python3
import json
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
from urllib.parse import urlparse

APP_ID = "431960"
HOST = os.getenv("HOST", "0.0.0.0")
PORT = int(os.getenv("PORT", "8080"))
PUBLIC_BASE_URL = os.getenv("PUBLIC_BASE_URL", "").rstrip("/")
API_KEY = os.getenv("API_KEY", "")
STEAMCMD = os.getenv("STEAMCMD", "/opt/steamcmd/steamcmd.sh")
ROOT = Path(os.getenv("WORK_ROOT", "/tmp/lumaforge"))
MAX_AGE = int(os.getenv("WORK_MAX_AGE", "3600"))
MAX_JOBS = int(os.getenv("MAX_JOBS", "1"))
ID_RE = re.compile(r"^\d{6,20}$")
jobs = {}
jobs_lock = threading.Lock()
slots = threading.BoundedSemaphore(MAX_JOBS)
ROOT.mkdir(parents=True, exist_ok=True)


def set_job(job_id, **values):
    with jobs_lock:
        jobs[job_id].update(values)


def cleanup():
    cutoff = time.time() - MAX_AGE
    for p in list(ROOT.iterdir()):
        try:
            if p.stat().st_mtime < cutoff:
                if p.is_dir():
                    shutil.rmtree(p, ignore_errors=True)
                else:
                    p.unlink()
        except OSError:
            pass


def run(cmd, timeout=600):
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=timeout, check=False)
    if result.returncode:
        raise RuntimeError(result.stdout[-4000:] or "Command failed")
    return result.stdout


def steamcmd_download(workshop_id, target):
    output = run([
        STEAMCMD, "+@ShutdownOnFailedCommand", "1",
        "+@NoPromptForPassword", "1", "+login", "anonymous",
        "+force_install_dir", str(target),
        "+workshop_download_item", APP_ID, workshop_id, "validate", "+quit"
    ], timeout=600)
    content = target / "steamapps" / "workshop" / "content" / APP_ID / workshop_id
    if not content.is_dir():
        logs = []
        for log_name in ("stderr.txt", "stdout.txt"):
            log_path = Path.home() / "Steam" / "logs" / log_name
            try:
                logs.append(f"--- {log_name} ---\\n{log_path.read_text(errors=\"replace\")[-4000:]}")
            except OSError:
                pass
        detail = "\\n".join(logs)
        print(f"[lumaforge] SteamCMD produced no Workshop content for {workshop_id}: {detail or output[-4000:]}", flush=True)
        raise RuntimeError("SteamCMD returned no Workshop content")
    return content


def ffmpeg_image_to_mp4(image, output):
    run([
        "ffmpeg", "-y", "-loop", "1", "-i", str(image),
        "-t", "3", "-r", "30", "-vf", "format=yuv420p",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
        "-movflags", "+faststart", str(output)
    ], timeout=180)


def ffmpeg_video_to_mp4(source, output):
    run([
        "ffmpeg", "-y", "-i", str(source),
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart",
        "-an", str(output)
    ], timeout=900)


def find_signature(data, sig, start=0):
    return data.find(sig, start)


def rle_decode(data, expected):
    out = bytearray()
    i = 0
    while i < len(data) and len(out) < expected:
        control = data[i]
        i += 1
        if control & 0x80:
            count = (control & 0x7f) + 1
            if i >= len(data):
                break
            out.extend(bytes([data[i]]) * min(count, expected - len(out)))
            i += 1
        else:
            count = control + 1
            out.extend(data[i:i + min(count, expected - len(out))])
            i += count
    return bytes(out)


def write_tex_as_png(data, output):
    if len(data) < 32 or data[:4] != b"TEXV":
        return False
    texb = data.find(b"TEXB")
    if texb < 0:
        return False
    width = int.from_bytes(data[0x22:0x26], "little")
    height = int.from_bytes(data[0x26:0x2a], "little")
    if not (1 <= width <= 16384 and 1 <= height <= 16384):
        return False

    pos = data.find(width.to_bytes(4, "little") + height.to_bytes(4, "little"), texb)
    if pos < 0:
        return False

    try:
        from PIL import Image
    except ImportError:
        return False

    w, h = width, height
    for _ in range(8):
        if pos + 20 > len(data):
            break
        rw = int.from_bytes(data[pos:pos+4], "little")
        rh = int.from_bytes(data[pos+4:pos+8], "little")
        size = int.from_bytes(data[pos+16:pos+20], "little")
        if rw != w or rh != h or size <= 0 or pos + 20 + size > len(data):
            break
        payload = data[pos+20:pos+20+size]
        if payload.startswith(b"\x89PNG\r\n\x1a\n"):
            output.write_bytes(payload)
            return True
        if payload.startswith(b"\xff\xd8\xff"):
            output.write_bytes(payload)
            return True
        raw = rle_decode(payload, w * h * 4)
        if len(raw) == w * h * 4:
            try:
                Image.frombytes("RGBA", (w, h), raw, "raw", "BGRA").save(output, "PNG")
                return True
            except Exception:
                pass
        pos += 20 + size
        w = max(1, w // 2)
        h = max(1, h // 2)
    return False


def extract_pkg(pkg, out_dir):
    data = pkg.read_bytes()
    if len(data) < 8:
        return []
    cursor = 0

    def u32():
        nonlocal cursor
        if cursor + 4 > len(data):
            raise ValueError("bad package")
        v = int.from_bytes(data[cursor:cursor+4], "little")
        cursor += 4
        return v

    def string():
        nonlocal cursor
        n = u32()
        if n < 0 or cursor + n > len(data):
            raise ValueError("bad package string")
        s = data[cursor:cursor+n].rstrip(b"\0").decode("utf-8", "ignore")
        cursor += n
        return s

    try:
        root = string()
        if not root.startswith("PKGV"):
            return []
        count = u32()
        if count > 1_000_000:
            return []
        entries = []
        for _ in range(count):
            name, offset, length = string(), u32(), u32()
            entries.append((name, offset, length))
        payload = cursor
    except Exception:
        return []

    outputs = []
    for name, offset, length in sorted(entries, key=lambda x: x[2], reverse=True):
        start, end = payload + offset, payload + offset + length
        if start < payload or end > len(data) or end < start:
            continue
        blob = data[start:end]
        lower = name.lower()
        ext = Path(name).suffix.lower()

        if ext in {".mp4", ".mov", ".m4v", ".webm"}:
            p = out_dir / (uuid.uuid4().hex + ext)
            p.write_bytes(blob)
            outputs.append(p)
            return outputs

    for name, offset, length in sorted(entries, key=lambda x: x[2], reverse=True):
        start, end = payload + offset, payload + offset + length
        if start < payload or end > len(data) or end < start:
            continue
        blob = data[start:end]
        lower = name.lower()
        if lower.endswith(".tex"):
            p = out_dir / (uuid.uuid4().hex + ".png")
            if write_tex_as_png(blob, p):
                outputs.append(p)
                return outputs
        if blob.startswith(b"\x89PNG\r\n\x1a\n"):
            p = out_dir / (uuid.uuid4().hex + ".png")
            p.write_bytes(blob)
            outputs.append(p)
            return outputs
        if blob.startswith(b"\xff\xd8\xff"):
            p = out_dir / (uuid.uuid4().hex + ".jpg")
            p.write_bytes(blob)
            outputs.append(p)
            return outputs
    return outputs


def safe_extract_zip(archive, target):
    root = target.resolve()
    for info in archive.infolist():
        destination = (target / info.filename).resolve()
        if destination != root and root not in destination.parents:
            raise RuntimeError("Unsafe ZIP entry")
        archive.extract(info, target)


def locate_source(content, scratch):
    media = {".mp4", ".mov", ".m4v", ".webm", ".png", ".jpg", ".jpeg", ".gif", ".webp"}
    files = [p for p in content.rglob("*") if p.is_file()]
    videos = [p for p in files if p.suffix.lower() in {".mp4", ".mov", ".m4v", ".webm"}]
    if videos:
        return videos[0]

    images = [p for p in files if p.suffix.lower() in media - {".mp4", ".mov", ".m4v", ".webm"}]
    if images:
        return images[0]

    zips = [p for p in files if p.suffix.lower() in {".zip"}]
    for z in zips:
        target = scratch / ("zip-" + uuid.uuid4().hex)
        target.mkdir()
        try:
            with zipfile.ZipFile(z) as archive:
                archive.extractall(target)
            found = locate_source(target, scratch)
            if found:
                return found
        except zipfile.BadZipFile:
            pass

    pkgs = [p for p in files if p.suffix.lower() == ".pkg" or p.name.lower().endswith(".pkg")]
    for pkg in pkgs:
        pkg_dir = scratch / "pkg"
        pkg_dir.mkdir(parents=True, exist_ok=True)
        found = extract_pkg(pkg, pkg_dir)
        if found:
            return found[0]

    raise RuntimeError("No convertible media was found in the Workshop package")


def process_job(job_id, workshop_id):
    with slots:
        work = ROOT / ("job-" + job_id)
        download_dir = work / "steam"
        scratch = work / "scratch"
        output = ROOT / (job_id + ".mp4")
        try:
            work.mkdir(parents=True, exist_ok=True)
            scratch.mkdir(parents=True, exist_ok=True)
            set_job(job_id, status="downloading", progress=15)
            content = steamcmd_download(workshop_id, download_dir)
            set_job(job_id, status="converting", progress=60)
            source = locate_source(content, scratch)
            if source.suffix.lower() in {".mp4", ".mov", ".m4v", ".webm"}:
                ffmpeg_video_to_mp4(source, output)
            else:
                ffmpeg_image_to_mp4(source, output)
            set_job(job_id, status="completed", progress=100,
                    filename=output.name,
                    download_url=f"{PUBLIC_BASE_URL}/v1/files/{output.name}" if PUBLIC_BASE_URL else None)
        except subprocess.TimeoutExpired:
            print(f"[lumaforge] job {job_id} timed out for workshop {workshop_id}", flush=True)
            set_job(job_id, status="failed", progress=100, error="Server conversion timed out")
        except Exception as exc:
            print(f"[lumaforge] job {job_id} failed for workshop {workshop_id}: {exc}", flush=True)
            set_job(job_id, status="failed", progress=100, error=str(exc))
        finally:
            shutil.rmtree(work, ignore_errors=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "LumaForgeServer/2.0"

    def json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        return not API_KEY or self.headers.get("Authorization") == f"Bearer {API_KEY}"

    def do_POST(self):
        if urlparse(self.path).path != "/v1/jobs":
            return self.json(404, {"error": "Not found"})
        if not self.authorized():
            return self.json(401, {"error": "Unauthorized"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length) or b"{}")
            workshop_id = str(body.get("workshop_id", ""))
            if not ID_RE.fullmatch(workshop_id):
                return self.json(400, {"error": "Invalid Workshop ID"})
        except Exception:
            return self.json(400, {"error": "Invalid JSON"})

        job_id = uuid.uuid4().hex
        with jobs_lock:
            jobs[job_id] = {
                "id": job_id, "workshop_id": workshop_id,
                "status": "queued", "progress": 0,
                "created_at": int(time.time())
            }
        threading.Thread(target=process_job, args=(job_id, workshop_id), daemon=True).start()
        return self.json(202, {"job_id": job_id, "status": "queued"})

    def do_GET(self):
        cleanup()
        path = urlparse(self.path).path

        if path == "/health":
            return self.json(200, {"ok": True, "service": "lumaforge", "provider": "steamcmd+ffmpeg"})

        if path.startswith("/v1/jobs/"):
            if not self.authorized():
                return self.json(401, {"error": "Unauthorized"})
            job_id = path.rsplit("/", 1)[-1]
            with jobs_lock:
                job = jobs.get(job_id)
            if not job:
                return self.json(404, {"error": "Job not found"})
            return self.json(200, job)

        if path.startswith("/v1/files/"):
            name = Path(path.rsplit("/", 1)[-1]).name
            file = ROOT / name
            if not file.is_file() or file.suffix.lower() != ".mp4":
                return self.json(404, {"error": "File not found"})
            try:
                size = file.stat().st_size
                self.send_response(200)
                self.send_header("Content-Type", "video/mp4")
                self.send_header("Content-Length", str(size))
                self.send_header("Content-Disposition", f'attachment; filename="{name}"')
                self.end_headers()
                with file.open("rb") as stream:
                    shutil.copyfileobj(stream, self.wfile)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return

        return self.json(404, {"error": "Not found"})

    def do_DELETE(self):
        if not self.authorized():
            return self.json(401, {"error": "Unauthorized"})
        path = urlparse(self.path).path
        if not path.startswith("/v1/jobs/"):
            return self.json(404, {"error": "Not found"})
        job_id = path.rsplit("/", 1)[-1]
        with jobs_lock:
            job = jobs.pop(job_id, None)
        if not job:
            return self.json(404, {"error": "Job not found"})
        filename = job.get("filename")
        if filename:
            try:
                (ROOT / Path(filename).name).unlink(missing_ok=True)
            except OSError:
                pass
        return self.json(200, {"ok": True})

    def log_message(self, fmt, *args):
        print(f"[lumaforge] {self.address_string()} {fmt % args}")


if __name__ == "__main__":
    print(f"[lumaforge] starting on {HOST}:{PORT}; steamcmd={STEAMCMD}; root={ROOT}", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
