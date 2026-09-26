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
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse
import urllib.parse

APP_ID = "431960"
HOST = os.getenv("HOST", "0.0.0.0")
PORT = int(os.getenv("PORT", "8080"))
PUBLIC_BASE_URL = os.getenv("PUBLIC_BASE_URL", "").rstrip("/")
API_KEY = os.getenv("API_KEY", "")
STEAMCMD = os.getenv("STEAMCMD", "/opt/steamcmd/steamcmd.sh")
ROOT = Path(os.getenv("WORK_ROOT", "/tmp/lumaforge"))
MAX_AGE = int(os.getenv("WORK_MAX_AGE", "3600"))
MAX_JOBS = int(os.getenv("MAX_JOBS", "1"))
WORKSHOP_PROVIDER = os.getenv("WORKSHOP_PROVIDER", "supabase,swdl,ggnetwork,steamcmd").strip().lower()
GGNETWORK_ENDPOINT = os.getenv("GGNETWORK_ENDPOINT", "https://api.ggntw.com/steam.request")
SWDL_ENDPOINTS = [u.strip().rstrip("/") for u in os.getenv("SWDL_ENDPOINTS", "https://node03.steamworkshopdownloader.io/prod/api/download,https://backend-01-prd.steamworkshopdownloader.io/api/download,https://api.steamworkshopdownloader.io/api/download").split(",") if u.strip()]
SWDL_TIMEOUT = int(os.getenv("SWDL_TIMEOUT", "900"))
SUPABASE_RESOLVER_URL = os.getenv("SUPABASE_RESOLVER_URL", "https://yxyfdxjyxcpitrrllopi.supabase.co/functions/v1/lumaforge-workshop-resolver").rstrip("/")
MAX_DOWNLOAD_BYTES = int(os.getenv("MAX_DOWNLOAD_BYTES", str(2 * 1024 * 1024 * 1024)))
MAX_ZIP_ENTRIES = int(os.getenv("MAX_ZIP_ENTRIES", "100000"))
MAX_EXTRACTED_BYTES = int(os.getenv("MAX_EXTRACTED_BYTES", str(4 * 1024 * 1024 * 1024)))
ID_RE = re.compile(r"^\d{6,20}$")
jobs = {}
jobs_lock = threading.Lock()
slots = threading.BoundedSemaphore(MAX_JOBS)
ROOT.mkdir(parents=True, exist_ok=True)


def set_job(job_id, **values):
    with jobs_lock:
        job = jobs.get(job_id)
        if job is not None:
            job.update(values)


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


def _download_url_to_file(url, destination, timeout=900):
    parsed = urlparse(url)
    if parsed.scheme != "https":
        raise RuntimeError("Downloader returned a non-HTTPS URL")
    host = (parsed.hostname or "").lower()
    if not host or host in {"localhost", "127.0.0.1", "::1"} or host.endswith(".local"):
        raise RuntimeError("Downloader returned an unsafe URL")

    request = urllib.request.Request(url, headers={
        "User-Agent": "LumaForge/3.0",
        "Accept": "*/*",
    })
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            length = response.headers.get("Content-Length")
            if length and int(length) > MAX_DOWNLOAD_BYTES:
                raise RuntimeError("Workshop download exceeds server size limit")
            written = 0
            with destination.open("wb") as output:
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    written += len(chunk)
                    if written > MAX_DOWNLOAD_BYTES:
                        raise RuntimeError("Workshop download exceeds server size limit")
                    output.write(chunk)
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"Workshop provider returned HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Workshop provider network error: {exc.reason}") from exc
    return destination


def _materialize_provider_file(downloaded, target):
    content = target / "content"
    content.mkdir(parents=True, exist_ok=True)

    if zipfile.is_zipfile(downloaded):
        safe_extract_zip(downloaded, content)
        return content

    data = downloaded.read_bytes()
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        destination = content / "workshop.png"
    elif data.startswith(b"\xff\xd8\xff"):
        destination = content / "workshop.jpg"
    elif len(data) >= 12 and data[4:8] == b"ftyp":
        destination = content / "workshop.mp4"
    else:
        suffix = Path(urlparse(downloaded.name).path).suffix.lower()
        destination = content / ("workshop" + suffix if suffix else "workshop.pkg")
    destination.write_bytes(data)
    return content


def ggnetwork_download(workshop_id, target):
    workshop_url = f"https://steamcommunity.com/sharedfiles/filedetails/?id={workshop_id}"
    payload = json.dumps({"url": workshop_url}).encode()
    request = urllib.request.Request(
        GGNETWORK_ENDPOINT,
        data=payload,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Origin": "https://ggntw.com",
            "Referer": "https://ggntw.com/",
            "User-Agent": "LumaForge/3.0",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            if response.status != 200:
                raise RuntimeError(f"GGNetwork returned HTTP {response.status}")
            data = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"GGNetwork returned HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"GGNetwork network error: {exc.reason}") from exc
    except json.JSONDecodeError as exc:
        raise RuntimeError("GGNetwork returned invalid JSON") from exc

    download_url = None
    for key in ("download_url", "url", "link", "file", "download"):
        if isinstance(data, dict) and isinstance(data.get(key), str):
            download_url = data[key]
            break
    if not download_url and isinstance(data, dict) and isinstance(data.get("data"), dict):
        nested = data["data"]
        for key in ("download_url", "url", "link", "file", "download"):
            if isinstance(nested.get(key), str):
                download_url = nested[key]
                break
    if not download_url:
        raise RuntimeError("GGNetwork returned no download URL")

    downloaded = target / "provider-download"
    _download_url_to_file(download_url, downloaded)
    return _materialize_provider_file(downloaded, target)


def supabase_resolver_download(workshop_id, target):
    url = SUPABASE_RESOLVER_URL + "?id=" + urllib.parse.quote(workshop_id, safe="")
    request = urllib.request.Request(url, headers={
        "Accept": "application/json",
        "User-Agent": "LumaForge/3.0",
    })
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            data = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"LumaForge resolver returned HTTP {exc.code}")
    except urllib.error.URLError as exc:
        raise RuntimeError(f"LumaForge resolver network error: {exc.reason}")
    except json.JSONDecodeError as exc:
        raise RuntimeError("LumaForge resolver returned invalid JSON") from exc

    if not isinstance(data, dict):
        raise RuntimeError("LumaForge resolver returned an invalid response")
    download_url = data.get("download_url")
    if not isinstance(download_url, str) or not download_url:
        raise RuntimeError(str(data.get("error") or "LumaForge resolver returned no download URL"))

    downloaded = target / "provider-download"
    _download_url_to_file(download_url, downloaded, timeout=900)
    return _materialize_provider_file(downloaded, target)


def steamworkshopdownloader_download(workshop_id, target):
    errors = []
    for endpoint in SWDL_ENDPOINTS:
        try:
            request_payload = json.dumps({
                "publishedFileId": int(workshop_id),
                "collectionId": None,
                "extract": True,
                "hidden": False,
                "direct": False,
                "autodownload": False,
            }).encode()
            request = urllib.request.Request(
                endpoint + "/request",
                data=request_payload,
                method="POST",
                headers={
                    "Content-Type": "application/json",
                    "Accept": "application/json, text/plain, */*",
                    "User-Agent": "LumaForge/3.0",
                    "Referer": "https://steamworkshopdownloader.io/",
                },
            )
            with urllib.request.urlopen(request, timeout=90) as response:
                data = json.loads(response.read().decode("utf-8"))
            request_id = data.get("uuid") if isinstance(data, dict) else None
            if not isinstance(request_id, str) or not request_id:
                raise RuntimeError("no request ID")

            deadline = time.time() + SWDL_TIMEOUT
            state = None
            while time.time() < deadline:
                status_request = urllib.request.Request(
                    endpoint + "/status",
                    data=json.dumps({"uuids": [request_id]}).encode(),
                    method="POST",
                    headers={
                        "Content-Type": "application/json",
                        "Accept": "application/json",
                        "User-Agent": "LumaForge/3.0",
                        "Referer": "https://steamworkshopdownloader.io/",
                    },
                )
                with urllib.request.urlopen(status_request, timeout=30) as response:
                    status_data = json.loads(response.read().decode("utf-8"))
                state = status_data.get(request_id) if isinstance(status_data, dict) else None
                if isinstance(state, dict):
                    status = str(state.get("status", "")).lower()
                    if status == "prepared":
                        break
                    if status in {"failed", "error"} or state.get("downloadError"):
                        raise RuntimeError(str(state.get("downloadError") or "provider reported failure"))
                time.sleep(1)
            else:
                raise RuntimeError("provider timed out")

            downloaded = target / "provider-download"
            direct_url = endpoint + "/transmit?uuid=" + request_id
            _download_url_to_file(direct_url, downloaded, timeout=900)
            return _materialize_provider_file(downloaded, target)
        except urllib.error.HTTPError as exc:
            errors.append(f"{endpoint}: HTTP {exc.code}")
        except urllib.error.URLError as exc:
            errors.append(f"{endpoint}: network error: {exc.reason}")
        except json.JSONDecodeError:
            errors.append(f"{endpoint}: invalid JSON")
        except Exception as exc:
            errors.append(f"{endpoint}: {exc}")
    raise RuntimeError("all Steam Workshop Downloader endpoints failed: " + " | ".join(errors))

def steamcmd_download(workshop_id, target):
    output = run([
        STEAMCMD, "+@ShutdownOnFailedCommand", "1",
        "+@NoPromptForPassword", "1",
        "+force_install_dir", str(target),
        "+login", "anonymous",
        "+workshop_download_item", APP_ID, workshop_id, "validate", "+quit"
    ], timeout=600)
    content = target / "steamapps" / "workshop" / "content" / APP_ID / workshop_id
    if content.is_dir():
        return content
    raise RuntimeError("SteamCMD returned no Workshop content")


def acquire_workshop(workshop_id, target):
    providers = [p.strip() for p in WORKSHOP_PROVIDER.split(",") if p.strip()]
    errors = []
    for provider in providers:
        try:
            if provider == "supabase":
                return supabase_resolver_download(workshop_id, target)
            if provider == "swdl":
                return steamworkshopdownloader_download(workshop_id, target)
            if provider == "ggnetwork":
                return ggnetwork_download(workshop_id, target)
            if provider == "steamcmd":
                return steamcmd_download(workshop_id, target)
            errors.append(f"{provider}: unknown provider")
        except Exception as exc:
            errors.append(f"{provider}: {exc}")
    raise RuntimeError("All Workshop acquisition providers failed: " + " | ".join(errors))
def ffmpeg_image_to_mp4(image, output):
    run([
        "ffmpeg", "-y", "-loop", "1", "-i", str(image),
        "-t", "3", "-r", "30", "-vf", "format=yuv420p",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
        "-movflags", "+faststart", str(output)
    ], timeout=180)


def ffmpeg_gif_to_mp4(source, output):
    run([
        "ffmpeg", "-y", "-i", str(source),
        "-vf", "fps=30,format=yuv420p",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
        "-movflags", "+faststart", str(output)
    ], timeout=900)


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
    infos = archive.infolist()
    if len(infos) > MAX_ZIP_ENTRIES:
        raise RuntimeError("Workshop ZIP contains too many entries")
    total_size = 0
    for info in infos:
        if info.file_size < 0:
            raise RuntimeError("Workshop ZIP contains an invalid entry")
        total_size += info.file_size
        if total_size > MAX_EXTRACTED_BYTES:
            raise RuntimeError("Workshop ZIP expands beyond the server extraction limit")
        destination = (target / info.filename).resolve()
        if destination != root and root not in destination.parents:
            raise RuntimeError("Unsafe ZIP entry")
    for info in infos:
        archive.extract(info, target)


def locate_source(content, scratch):
    media = {".mp4", ".mov", ".m4v", ".webm", ".png", ".jpg", ".jpeg", ".gif", ".webp"}
    files = [p for p in content.rglob("*") if p.is_file()]

    # Never choose preview.jpg/thumbnail assets before the actual wallpaper.
    # Workshop scene wallpapers commonly contain a preview image next to scene.pkg.
    # Prefer native video, then an animated preview, then the package, and only
    # use a loose still image as the final fallback.
    videos = [p for p in files if p.suffix.lower() in {".mp4", ".mov", ".m4v", ".webm"}]
    if videos:
        return videos[0]

    gifs = [p for p in files if p.suffix.lower() == ".gif"]
    if gifs:
        return gifs[0]

    zips = [p for p in files if p.suffix.lower() == ".zip"]
    for z in zips:
        target = scratch / ("zip-" + uuid.uuid4().hex)
        target.mkdir()
        try:
            with zipfile.ZipFile(z) as archive:
                safe_extract_zip(archive, target)
            found = locate_source(target, scratch)
            if found:
                return found
        except zipfile.BadZipFile:
            pass

    pkgs = [p for p in files if p.suffix.lower() == ".pkg" or p.name.lower().endswith(".pkg")]
    for pkg in pkgs:
        pkg_dir = scratch / ("pkg-" + uuid.uuid4().hex)
        pkg_dir.mkdir(parents=True, exist_ok=True)
        found = extract_pkg(pkg, pkg_dir)
        if found:
            return found[0]

    images = [
        p for p in files
        if p.suffix.lower() in media - {".mp4", ".mov", ".m4v", ".webm", ".gif"}
        and p.name.lower() not in {"preview.jpg", "preview.jpeg", "thumbnail.jpg", "thumbnail.jpeg", "cover.jpg", "cover.png"}
    ]
    if images:
        return images[0]

    # A preview is still preferable to a hard failure when the Workshop item
    # only ships its preview image alongside an unsupported package.
    previews = [
        p for p in files
        if p.name.lower() in {"preview.jpg", "preview.jpeg", "thumbnail.jpg", "thumbnail.jpeg", "cover.jpg", "cover.png"}
    ]
    if previews:
        return previews[0]

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
            content = acquire_workshop(workshop_id, download_dir)
            set_job(job_id, status="converting", progress=60)
            source = locate_source(content, scratch)
            if source.suffix.lower() in {".mp4", ".mov", ".m4v", ".webm"}:
                ffmpeg_video_to_mp4(source, output)
            elif source.suffix.lower() == ".gif":
                ffmpeg_gif_to_mp4(source, output)
            else:
                ffmpeg_image_to_mp4(source, output)
            if not output.is_file() or output.stat().st_size < 1024:
                raise RuntimeError("FFmpeg produced an invalid MP4")
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
                "job_id": job_id, "id": job_id, "workshop_id": workshop_id,
                "status": "queued", "progress": 0,
                "created_at": int(time.time())
            }
        threading.Thread(target=process_job, args=(job_id, workshop_id), daemon=True).start()
        return self.json(202, {"job_id": job_id, "status": "queued"})

    def do_GET(self):
        cleanup()
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/v1/auth/steam/callback":
            query = parsed.query
            if not query:
                return self.json(400, {"error": "Missing Steam OpenID callback parameters"})
            location = "lumaforge://steam-callback?" + query
            self.send_response(302)
            self.send_header("Location", location)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return

        if path == "/health":
            return self.json(200, {"ok": True, "service": "lumaforge", "providers": WORKSHOP_PROVIDER, "converter": "ffmpeg", "git_commit": os.getenv("RENDER_GIT_COMMIT", "")})

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
        if job.get("status") in {"queued", "downloading", "converting"}:
            return self.json(409, {"error": "Job is still running"})
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
    errors = []
    for endpoint in SWDL_ENDPOINTS:
        try:
            request_payload = json.dumps({
                "publishedFileId": int(workshop_id),
                "collectionId": None,
                "extract": True,
                "hidden": False,
                "direct": False,
                "autodownload": False,
            }).encode()
            request = urllib.request.Request(
                endpoint + "/request",
                data=request_payload,
                method="POST",
                headers={
                    "Content-Type": "application/json",
                    "Accept": "application/json, text/plain, */*",
                    "User-Agent": "LumaForge/3.0",
                    "Referer": "https://steamworkshopdownloader.io/",
                },
            )
            with urllib.request.urlopen(request, timeout=90) as response:
                data = json.loads(response.read().decode("utf-8"))
            request_id = data.get("uuid") if isinstance(data, dict) else None
            if not isinstance(request_id, str) or not request_id:
                raise RuntimeError("no request ID")

            deadline = time.time() + SWDL_TIMEOUT
            state = None
            while time.time() < deadline:
                status_request = urllib.request.Request(
                    endpoint + "/status",
                    data=json.dumps({"uuids": [request_id]}).encode(),
                    method="POST",
                    headers={
                        "Content-Type": "application/json",
                        "Accept": "application/json",
                        "User-Agent": "LumaForge/3.0",
                        "Referer": "https://steamworkshopdownloader.io/",
                    },
                )
                with urllib.request.urlopen(status_request, timeout=30) as response:
                    status_data = json.loads(response.read().decode("utf-8"))
                state = status_data.get(request_id) if isinstance(status_data, dict) else None
                if isinstance(state, dict):
                    status = str(state.get("status", "")).lower()
                    if status == "prepared":
                        break
                    if status in {"failed", "error"} or state.get("downloadError"):
                        raise RuntimeError(str(state.get("downloadError") or "provider reported failure"))
                time.sleep(1)
            else:
                raise RuntimeError("provider timed out")

            downloaded = target / "provider-download"
            direct_url = endpoint + "/transmit?uuid=" + request_id
            _download_url_to_file(direct_url, downloaded, timeout=900)
            return _materialize_provider_file(downloaded, target)
        except urllib.error.HTTPError as exc:
            errors.append(f"{endpoint}: HTTP {exc.code}")
        except urllib.error.URLError as exc:
            errors.append(f"{endpoint}: network error: {exc.reason}")
        except json.JSONDecodeError:
            errors.append(f"{endpoint}: invalid JSON")
        except Exception as exc:
            errors.append(f"{endpoint}: {exc}")
    raise RuntimeError("all Steam Workshop Downloader endpoints failed: " + " | ".join(errors))

def steamcmd_download(workshop_id, target):
    output = run([
        STEAMCMD, "+@ShutdownOnFailedCommand", "1",
        "+@NoPromptForPassword", "1",
        "+force_install_dir", str(target),
        "+login", "anonymous",
        "+workshop_download_item", APP_ID, workshop_id, "validate", "+quit"
    ], timeout=600)
    content = target / "steamapps" / "workshop" / "content" / APP_ID / workshop_id
    if content.is_dir():
        return content
    raise RuntimeError("SteamCMD returned no Workshop content")


def acquire_workshop(workshop_id, target):
    providers = [p.strip() for p in WORKSHOP_PROVIDER.split(",") if p.strip()]
    errors = []
    for provider in providers:
        try:
            if provider == "swdl":
                return steamworkshopdownloader_download(workshop_id, target)
            if provider == "ggnetwork":
                return ggnetwork_download(workshop_id, target)
            if provider == "steamcmd":
                return steamcmd_download(workshop_id, target)
            errors.append(f"{provider}: unknown provider")
        except Exception as exc:
            errors.append(f"{provider}: {exc}")
    raise RuntimeError("All Workshop acquisition providers failed: " + " | ".join(errors))
def ffmpeg_image_to_mp4(image, output):
    run([
        "ffmpeg", "-y", "-loop", "1", "-i", str(image),
        "-t", "3", "-r", "30", "-vf", "format=yuv420p",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
        "-movflags", "+faststart", str(output)
    ], timeout=180)


def ffmpeg_gif_to_mp4(source, output):
    run([
        "ffmpeg", "-y", "-i", str(source),
        "-vf", "fps=30,format=yuv420p",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
        "-movflags", "+faststart", str(output)
    ], timeout=900)


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
    infos = archive.infolist()
    if len(infos) > MAX_ZIP_ENTRIES:
        raise RuntimeError("Workshop ZIP contains too many entries")
    total_size = 0
    for info in infos:
        if info.file_size < 0:
            raise RuntimeError("Workshop ZIP contains an invalid entry")
        total_size += info.file_size
        if total_size > MAX_EXTRACTED_BYTES:
            raise RuntimeError("Workshop ZIP expands beyond the server extraction limit")
        destination = (target / info.filename).resolve()
        if destination != root and root not in destination.parents:
            raise RuntimeError("Unsafe ZIP entry")
    for info in infos:
        archive.extract(info, target)


def locate_source(content, scratch):
    media = {".mp4", ".mov", ".m4v", ".webm", ".png", ".jpg", ".jpeg", ".gif", ".webp"}
    files = [p for p in content.rglob("*") if p.is_file()]

    # Never choose preview.jpg/thumbnail assets before the actual wallpaper.
    # Workshop scene wallpapers commonly contain a preview image next to scene.pkg.
    # Prefer native video, then an animated preview, then the package, and only
    # use a loose still image as the final fallback.
    videos = [p for p in files if p.suffix.lower() in {".mp4", ".mov", ".m4v", ".webm"}]
    if videos:
        return videos[0]

    gifs = [p for p in files if p.suffix.lower() == ".gif"]
    if gifs:
        return gifs[0]

    zips = [p for p in files if p.suffix.lower() == ".zip"]
    for z in zips:
        target = scratch / ("zip-" + uuid.uuid4().hex)
        target.mkdir()
        try:
            with zipfile.ZipFile(z) as archive:
                safe_extract_zip(archive, target)
            found = locate_source(target, scratch)
            if found:
                return found
        except zipfile.BadZipFile:
            pass

    pkgs = [p for p in files if p.suffix.lower() == ".pkg" or p.name.lower().endswith(".pkg")]
    for pkg in pkgs:
        pkg_dir = scratch / ("pkg-" + uuid.uuid4().hex)
        pkg_dir.mkdir(parents=True, exist_ok=True)
        found = extract_pkg(pkg, pkg_dir)
        if found:
            return found[0]

    images = [
        p for p in files
        if p.suffix.lower() in media - {".mp4", ".mov", ".m4v", ".webm", ".gif"}
        and p.name.lower() not in {"preview.jpg", "preview.jpeg", "thumbnail.jpg", "thumbnail.jpeg", "cover.jpg", "cover.png"}
    ]
    if images:
        return images[0]

    # A preview is still preferable to a hard failure when the Workshop item
    # only ships its preview image alongside an unsupported package.
    previews = [
        p for p in files
        if p.name.lower() in {"preview.jpg", "preview.jpeg", "thumbnail.jpg", "thumbnail.jpeg", "cover.jpg", "cover.png"}
    ]
    if previews:
        return previews[0]

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
            content = acquire_workshop(workshop_id, download_dir)
            set_job(job_id, status="converting", progress=60)
            source = locate_source(content, scratch)
            if source.suffix.lower() in {".mp4", ".mov", ".m4v", ".webm"}:
                ffmpeg_video_to_mp4(source, output)
            elif source.suffix.lower() == ".gif":
                ffmpeg_gif_to_mp4(source, output)
            else:
                ffmpeg_image_to_mp4(source, output)
            if not output.is_file() or output.stat().st_size < 1024:
                raise RuntimeError("FFmpeg produced an invalid MP4")
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
                "job_id": job_id, "id": job_id, "workshop_id": workshop_id,
                "status": "queued", "progress": 0,
                "created_at": int(time.time())
            }
        threading.Thread(target=process_job, args=(job_id, workshop_id), daemon=True).start()
        return self.json(202, {"job_id": job_id, "status": "queued"})

    def do_GET(self):
        cleanup()
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/v1/auth/steam/callback":
            query = parsed.query
            if not query:
                return self.json(400, {"error": "Missing Steam OpenID callback parameters"})
            location = "lumaforge://steam-callback?" + query
            self.send_response(302)
            self.send_header("Location", location)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return

        if path == "/health":
            return self.json(200, {"ok": True, "service": "lumaforge", "providers": WORKSHOP_PROVIDER, "converter": "ffmpeg", "git_commit": os.getenv("RENDER_GIT_COMMIT", "")})

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
        if job.get("status") in {"queued", "downloading", "converting"}:
            return self.json(409, {"error": "Job is still running"})
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
