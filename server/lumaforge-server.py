#!/usr/bin/env python3
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import threading
import time
import uuid
import urllib.error
import urllib.request
import urllib.parse
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
MAX_MEMORY_JOBS = int(os.getenv("MAX_MEMORY_JOBS", "100"))
WORKSHOP_PROVIDER = os.getenv(
    "WORKSHOP_PROVIDER", "steamapi,swdl,ggnetwork,supabase,steamcmd"
).strip().lower()
GGNETWORK_ENDPOINT = os.getenv("GGNETWORK_ENDPOINT", "https://api.ggntw.com/steam.request")
SWDL_ENDPOINTS = [
    u.strip().rstrip("/")
    for u in os.getenv(
        "SWDL_ENDPOINTS",
        "https://node03.steamworkshopdownloader.io/prod/api/download,"
        "https://backend-01-prd.steamworkshopdownloader.io/api/download,"
        "https://api.steamworkshopdownloader.io/api/download",
    ).split(",")
    if u.strip()
]
SWDL_TIMEOUT = int(os.getenv("SWDL_TIMEOUT", "900"))
SUPABASE_RESOLVER_URL = os.getenv(
    "SUPABASE_RESOLVER_URL",
    "https://yxyfdxjyxcpitrrllopi.supabase.co/functions/v1/lumaforge-workshop-resolver",
).rstrip("/")
MAX_DOWNLOAD_BYTES = int(os.getenv("MAX_DOWNLOAD_BYTES", str(2 * 1024 * 1024 * 1024)))
MAX_ZIP_ENTRIES = int(os.getenv("MAX_ZIP_ENTRIES", "100000"))
MAX_EXTRACTED_BYTES = int(os.getenv("MAX_EXTRACTED_BYTES", str(4 * 1024 * 1024 * 1024)))
MIN_MEDIA_DIMENSION = int(os.getenv("MIN_MEDIA_DIMENSION", "64"))
ID_RE = re.compile(r"^\d{6,20}$")
VIDEO_EXTS = {".mp4", ".mov", ".m4v", ".webm", ".mkv", ".avi", ".wmv"}
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".webp"}
PREVIEW_NAMES = {
    "preview.jpg", "preview.jpeg", "preview.png", "preview.webp",
    "thumbnail.jpg", "thumbnail.jpeg", "thumbnail.png", "thumbnail.webp",
    "cover.jpg", "cover.jpeg", "cover.png", "cover.webp",
}

jobs = {}
jobs_lock = threading.Lock()
slots = threading.BoundedSemaphore(MAX_JOBS)
ROOT.mkdir(parents=True, exist_ok=True)


def set_job(job_id, **values):
    with jobs_lock:
        if job_id in jobs:
            jobs[job_id].update(values)


def cleanup():
    cutoff = time.time() - MAX_AGE
    active = set()
    with jobs_lock:
        for job_id, job in list(jobs.items()):
            if job.get("status") in {"queued", "downloading", "converting"}:
                active.add(job_id)
            elif job.get("created_at", 0) < cutoff:
                jobs.pop(job_id, None)
    for p in list(ROOT.iterdir()):
        try:
            if p.name.startswith("job-") and p.name[4:] in active:
                continue
            if p.stat().st_mtime < cutoff:
                shutil.rmtree(p, ignore_errors=True) if p.is_dir() else p.unlink()
        except OSError:
            pass


def run(cmd, timeout=600):
    result = subprocess.run(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, timeout=timeout, check=False
    )
    if result.returncode:
        raise RuntimeError(result.stdout[-5000:] or "Command failed")
    return result.stdout


def _validate_download_url(url):
    parsed = urlparse(url)
    if parsed.scheme != "https":
        raise RuntimeError("Downloader returned a non-HTTPS URL")
    host = (parsed.hostname or "").lower()
    if not host or host.endswith(".local"):
        raise RuntimeError("Downloader returned an unsafe URL")
    try:
        addresses = {
            item[4][0]
            for item in socket.getaddrinfo(
                host, parsed.port or 443, type=socket.SOCK_STREAM
            )
        }
    except socket.gaierror as exc:
        raise RuntimeError(f"Downloader URL host could not be resolved: {host}") from exc
    for address in addresses:
        ip = ipaddress.ip_address(address)
        if (
            ip.is_private or ip.is_loopback or ip.is_link_local
            or ip.is_multicast or ip.is_reserved or ip.is_unspecified
        ):
            raise RuntimeError("Downloader returned an unsafe URL")
    return parsed


class SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        _validate_download_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


SAFE_OPENER = urllib.request.build_opener(SafeRedirectHandler)


def _download_url_to_file(url, destination, timeout=900):
    _validate_download_url(url)
    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(
        url, headers={"User-Agent": "LumaForge/4.0", "Accept": "*/*"}
    )
    try:
        with SAFE_OPENER.open(request, timeout=timeout) as response:
            _validate_download_url(response.geturl())
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


def safe_extract_zip(archive, target):
    root = target.resolve()
    infos = archive.infolist()
    if len(infos) > MAX_ZIP_ENTRIES:
        raise RuntimeError("Workshop ZIP contains too many entries")
    total = 0
    for info in infos:
        if info.file_size < 0:
            raise RuntimeError("Workshop ZIP contains an invalid entry")
        total += info.file_size
        if total > MAX_EXTRACTED_BYTES:
            raise RuntimeError("Workshop ZIP expands beyond the server extraction limit")
        destination = (target / info.filename).resolve()
        if destination != root and root not in destination.parents:
            raise RuntimeError("Unsafe ZIP entry")
    for info in infos:
        archive.extract(info, target)


def _materialize_provider_file(downloaded, target):
    content = target / "content"
    content.mkdir(parents=True, exist_ok=True)
    if zipfile.is_zipfile(downloaded):
        safe_extract_zip(downloaded, content)
        return content
    data = downloaded.read_bytes()
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        name = "workshop.png"
    elif data.startswith(b"\xff\xd8\xff"):
        name = "workshop.jpg"
    elif len(data) >= 12 and data[4:8] == b"ftyp":
        name = "workshop.mp4"
    else:
        suffix = Path(urlparse(downloaded.name).path).suffix.lower()
        name = "workshop" + (suffix if suffix else ".pkg")
    (content / name).write_bytes(data)
    return content


def steam_api_download(workshop_id, target):
    payload = urllib.parse.urlencode({
        "itemcount": "1",
        "publishedfileids[0]": workshop_id,
    }).encode()
    request = urllib.request.Request(
        "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/",
        data=payload,
        method="POST",
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
            "User-Agent": "LumaForge/4.0",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            data = json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"Steam API returned HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Steam API network error: {exc.reason}") from exc
    except json.JSONDecodeError as exc:
        raise RuntimeError("Steam API returned invalid JSON") from exc
    details = ((data.get("response") or {}).get("publishedfiledetails") or []) if isinstance(data, dict) else []
    if not details:
        raise RuntimeError("Steam API returned no Workshop details")
    item = details[0]
    if str(item.get("result", "")) != "1":
        raise RuntimeError(f"Steam API rejected Workshop item: {item.get('result')}")
    download_url = item.get("file_url")
    if not isinstance(download_url, str) or not download_url:
        raise RuntimeError(
            "Steam API has no direct file URL for this Workshop item; "
            f'title={item.get("title")!r} file_type={item.get("file_type")} '
            f'filename={item.get("filename")!r} hcontent_file={item.get("hcontent_file")} '
            f'youtubevideoid={item.get("youtubevideoid")!r} url={item.get("url")!r}'
        )
    parsed = urlparse(download_url)
    if parsed.scheme == "http":
        download_url = urllib.parse.urlunparse(parsed._replace(scheme="https"))
    downloaded = target / "provider-download"
    _download_url_to_file(download_url, downloaded)
    return _materialize_provider_file(downloaded, target)


def ggnetwork_download(workshop_id, target):
    payload = json.dumps({
        "url": f"https://steamcommunity.com/sharedfiles/filedetails/?id={workshop_id}"
    }).encode()
    request = urllib.request.Request(
        GGNETWORK_ENDPOINT, data=payload, method="POST",
        headers={
            "Content-Type": "application/json", "Accept": "application/json",
            "Origin": "https://ggntw.com", "Referer": "https://ggntw.com/",
            "User-Agent": "LumaForge/4.0",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            if response.status != 200:
                raise RuntimeError(f"GGNetwork returned HTTP {response.status}")
            data = json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"GGNetwork returned HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"GGNetwork network error: {exc.reason}") from exc
    except json.JSONDecodeError as exc:
        raise RuntimeError("GGNetwork returned invalid JSON") from exc
    nested = data.get("data") if isinstance(data, dict) and isinstance(data.get("data"), dict) else data
    download_url = next(
        (nested.get(k) for k in ("download_url", "url", "link", "file", "download")
         if isinstance(nested, dict) and isinstance(nested.get(k), str)),
        None,
    )
    if not download_url:
        raise RuntimeError("GGNetwork returned no download URL")
    downloaded = target / "provider-download"
    _download_url_to_file(download_url, downloaded)
    return _materialize_provider_file(downloaded, target)


def supabase_resolver_download(workshop_id, target):
    url = SUPABASE_RESOLVER_URL + "?id=" + urllib.parse.quote(workshop_id, safe="")
    request = urllib.request.Request(
        url, headers={"Accept": "application/json", "User-Agent": "LumaForge/4.0"}
    )
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            data = json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"LumaForge resolver returned HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"LumaForge resolver network error: {exc.reason}") from exc
    except json.JSONDecodeError as exc:
        raise RuntimeError("LumaForge resolver returned invalid JSON") from exc
    if not isinstance(data, dict):
        raise RuntimeError("LumaForge resolver returned an invalid response")
    download_url = data.get("download_url")
    if not isinstance(download_url, str) or not download_url:
        raise RuntimeError(str(data.get("error") or "LumaForge resolver returned no download URL"))
    downloaded = target / "provider-download"
    _download_url_to_file(download_url, downloaded)
    return _materialize_provider_file(downloaded, target)


def steamworkshopdownloader_download(workshop_id, target):
    errors = []
    for endpoint in SWDL_ENDPOINTS:
        try:
            payload = json.dumps({
                "publishedFileId": int(workshop_id),
                "collectionId": None, "extract": True,
                "hidden": False, "direct": False, "autodownload": False,
            }).encode()
            request = urllib.request.Request(
                endpoint + "/request", data=payload, method="POST",
                headers={
                    "Content-Type": "application/json",
                    "Accept": "application/json, text/plain, */*",
                    "User-Agent": "LumaForge/4.0",
                    "Referer": "https://steamworkshopdownloader.io/",
                },
            )
            with urllib.request.urlopen(request, timeout=90) as response:
                data = json.loads(response.read().decode())
            request_id = data.get("uuid") if isinstance(data, dict) else None
            if not request_id:
                raise RuntimeError("no request ID")
            deadline = time.time() + SWDL_TIMEOUT
            while time.time() < deadline:
                status_request = urllib.request.Request(
                    endpoint + "/status",
                    data=json.dumps({"uuids": [request_id]}).encode(),
                    method="POST",
                    headers={"Content-Type": "application/json", "Accept": "application/json"},
                )
                with urllib.request.urlopen(status_request, timeout=30) as response:
                    status_data = json.loads(response.read().decode())
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
            _download_url_to_file(
                endpoint + "/transmit?uuid=" + request_id, downloaded, timeout=900
            )
            return _materialize_provider_file(downloaded, target)
        except Exception as exc:
            errors.append(f"{endpoint}: {exc}")
    raise RuntimeError("all Steam Workshop Downloader endpoints failed: " + " | ".join(errors))


def steamcmd_download(workshop_id, target):
    run_output = run([
        STEAMCMD, "+@ShutdownOnFailedCommand", "1",
        "+@NoPromptForPassword", "1", "+force_install_dir", str(target),
        "+login", "anonymous", "+workshop_download_item", APP_ID, workshop_id,
        "+quit",
    ], timeout=600)
    content = target / "steamapps" / "workshop" / "content" / APP_ID / workshop_id
    if not content.is_dir():
        raise RuntimeError("SteamCMD returned no Workshop content; output=" + run_output[-2500:])
    return content


def ffprobe_media(path):
    result = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height,duration",
            "-of", "json", str(path),
        ],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
    )
    if result.returncode:
        raise RuntimeError("FFprobe could not read media")
    streams = json.loads(result.stdout).get("streams", [])
    if not streams:
        raise RuntimeError("Media contains no video stream")
    stream = streams[0]
    width, height = int(stream.get("width") or 0), int(stream.get("height") or 0)
    duration = float(stream.get("duration") or 0)
    if width < MIN_MEDIA_DIMENSION or height < MIN_MEDIA_DIMENSION:
        raise RuntimeError(f"Media is only {width}x{height}; refusing placeholder media")
    if duration <= 0:
        raise RuntimeError("Media has no usable duration")
    return width, height, duration


def image_dimensions(path):
    try:
        from PIL import Image
        with Image.open(path) as image:
            return image.size
    except Exception as exc:
        raise RuntimeError(f"Invalid image: {exc}") from exc


def validate_workshop_content(content):
    files = [p for p in content.rglob("*") if p.is_file()]
    scene_pkgs = [
        p for p in files
        if p.name.lower() == "scene.pkg" and p.stat().st_size >= 1024
    ]
    if scene_pkgs:
        return {"kind": "scene", "path": max(scene_pkgs, key=lambda p: p.stat().st_size)}

    videos = [p for p in files if p.suffix.lower() in VIDEO_EXTS]
    valid_videos = []
    video_errors = []
    for path in videos:
        try:
            ffprobe_media(path)
            valid_videos.append(path)
        except Exception as exc:
            video_errors.append(str(exc))
    if valid_videos:
        return {"kind": "video", "path": max(valid_videos, key=lambda p: p.stat().st_size)}

    gifs = [p for p in files if p.suffix.lower() == ".gif" and p.name.lower() not in PREVIEW_NAMES]
    if gifs:
        return {"kind": "gif", "path": max(gifs, key=lambda p: p.stat().st_size)}

    valid_images = []
    for path in files:
        if path.suffix.lower() not in IMAGE_EXTS or path.name.lower() in PREVIEW_NAMES:
            continue
        try:
            width, height = image_dimensions(path)
            if width >= MIN_MEDIA_DIMENSION and height >= MIN_MEDIA_DIMENSION:
                valid_images.append(path)
        except Exception:
            continue
    if valid_images:
        return {"kind": "image", "path": max(valid_images, key=lambda p: p.stat().st_size)}

    names = ", ".join(p.name for p in files[:12])
    if files and all(p.name.lower() in PREVIEW_NAMES for p in files):
        raise RuntimeError("Provider returned preview-only media, not the Workshop wallpaper")
    if video_errors:
        raise RuntimeError("Provider returned invalid video media: " + video_errors[0])
    raise RuntimeError("Provider returned no usable Wallpaper Engine content: " + names)


def acquire_workshop(workshop_id, target):
    providers = [p.strip() for p in WORKSHOP_PROVIDER.split(",") if p.strip()]
    errors = []
    for index, provider in enumerate(providers):
        provider_target = target / f"provider-{index}-{provider}"
        try:
            provider_target.mkdir(parents=True, exist_ok=True)
            if provider == "steamapi":
                content = steam_api_download(workshop_id, provider_target)
            elif provider == "supabase":
                content = supabase_resolver_download(workshop_id, provider_target)
            elif provider == "swdl":
                content = steamworkshopdownloader_download(workshop_id, provider_target)
            elif provider == "ggnetwork":
                content = ggnetwork_download(workshop_id, provider_target)
            elif provider == "steamcmd":
                content = steamcmd_download(workshop_id, provider_target)
            else:
                raise RuntimeError("unknown provider")
            validated = validate_workshop_content(content)
            print(
                f"[lumaforge] provider={provider} accepted kind={validated['kind']} "
                f"path={validated['path']}",
                flush=True,
            )
            return content, validated
        except Exception as exc:
            print(f"[lumaforge] provider={provider} rejected: {exc}", flush=True)
            errors.append(f"{provider}: {exc}")
    raise RuntimeError("All Workshop acquisition providers failed: " + " | ".join(errors))


def ffmpeg_image_to_mp4(image, output):
    run([
        "ffmpeg", "-y", "-loop", "1", "-i", str(image),
        "-t", "3", "-r", "30",
        "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
        "-movflags", "+faststart", str(output),
    ], timeout=180)


def ffmpeg_gif_to_mp4(source, output):
    run([
        "ffmpeg", "-y", "-i", str(source),
        "-vf", "fps=30,scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
        "-movflags", "+faststart", str(output),
    ], timeout=900)


def ffmpeg_video_to_mp4(source, output):
    run([
        "ffmpeg", "-y", "-i", str(source),
        "-map", "0:v:0", "-map", "0:a?",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
        "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
        "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k",
        "-movflags", "+faststart", str(output),
    ], timeout=900)


def validate_output(path):
    if not path.is_file() or path.stat().st_size < 1024 * 10:
        raise RuntimeError("FFmpeg produced an implausibly small MP4")
    width, height, duration = ffprobe_media(path)
    if width < MIN_MEDIA_DIMENSION or height < MIN_MEDIA_DIMENSION:
        raise RuntimeError(f"Rendered MP4 is only {width}x{height}")
    if duration < 0.5:
        raise RuntimeError("Rendered MP4 is too short")
    return width, height, duration


SCENE_RENDERER = os.getenv("SCENE_RENDERER", "/app/scene_renderer.mjs")
SCENE_RENDER_WIDTH = int(os.getenv("SCENE_RENDER_WIDTH", "1280"))
SCENE_RENDER_HEIGHT = int(os.getenv("SCENE_RENDER_HEIGHT", "720"))
SCENE_RENDER_SECONDS = int(os.getenv("SCENE_RENDER_SECONDS", "6"))
SCENE_RENDER_FPS = int(os.getenv("SCENE_RENDER_FPS", "30"))


def find_scene_pkg(content):
    candidates = [
        p for p in content.rglob("scene.pkg")
        if p.is_file() and p.stat().st_size >= 1024
    ]
    return max(candidates, key=lambda p: p.stat().st_size) if candidates else None


def stage_scene_project(pkg, scratch):
    project = next(pkg.parent.rglob("project.json"), None)
    staged_pkg = scratch / "scene.pkg"
    shutil.copy2(pkg, staged_pkg)
    if project:
        shutil.copy2(project, scratch / "project.json")
    return staged_pkg


def render_scene_pkg_to_mp4(pkg, output, scratch):
    if not Path(SCENE_RENDERER).is_file():
        raise RuntimeError("Server scene renderer is not installed")
    if shutil.which("node") is None:
        raise RuntimeError("Server scene renderer requires Node.js")
    staged = stage_scene_project(pkg, scratch)
    webm = scratch / ("scene-" + uuid.uuid4().hex + ".webm")
    run([
        "node", SCENE_RENDERER, str(staged), str(webm),
        str(SCENE_RENDER_WIDTH), str(SCENE_RENDER_HEIGHT),
        str(SCENE_RENDER_SECONDS), str(SCENE_RENDER_FPS),
    ], timeout=max(600, SCENE_RENDER_SECONDS * 120))
    if not webm.is_file() or webm.stat().st_size < 1024:
        raise RuntimeError("Scene renderer produced no usable video")
    ffmpeg_video_to_mp4(webm, output)


def process_job(job_id, workshop_id):
    with slots:
        work = ROOT / ("job-" + job_id)
        download_dir = work / "steam"
        scratch = work / "scratch"
        output = ROOT / (job_id + ".mp4")
        try:
            work.mkdir(parents=True, exist_ok=True)
            scratch.mkdir(parents=True, exist_ok=True)
            set_job(job_id, status="downloading", progress=10)
            content, validated = acquire_workshop(workshop_id, download_dir)
            set_job(job_id, status="converting", progress=55, source_kind=validated["kind"])

            if validated["kind"] == "scene":
                render_scene_pkg_to_mp4(validated["path"], output, scratch)
            elif validated["kind"] == "video":
                ffmpeg_video_to_mp4(validated["path"], output)
            elif validated["kind"] == "gif":
                ffmpeg_gif_to_mp4(validated["path"], output)
            else:
                ffmpeg_image_to_mp4(validated["path"], output)

            width, height, duration = validate_output(output)
            set_job(
                job_id, status="completed", progress=100,
                filename=output.name,
                width=width, height=height, duration=duration,
                download_url=f"{PUBLIC_BASE_URL}/v1/files/{output.name}" if PUBLIC_BASE_URL else None,
            )
        except subprocess.TimeoutExpired:
            set_job(job_id, status="failed", progress=100, error="Server conversion timed out")
        except Exception as exc:
            print(f"[lumaforge] job {job_id} failed for workshop {workshop_id}: {exc}", flush=True)
            set_job(job_id, status="failed", progress=100, error=str(exc))
        finally:
            shutil.rmtree(work, ignore_errors=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "LumaForgeServer/4.0"

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

        with jobs_lock:
            live = sum(
                1 for job in jobs.values()
                if job.get("status") in {"queued", "downloading", "converting"}
            )
            if live >= MAX_MEMORY_JOBS:
                return self.json(429, {"error": "Too many jobs are currently queued."})
            job_id = uuid.uuid4().hex
            jobs[job_id] = {
                "job_id": job_id, "id": job_id, "workshop_id": workshop_id,
                "status": "queued", "progress": 0, "created_at": int(time.time()),
            }
        threading.Thread(target=process_job, args=(job_id, workshop_id), daemon=True).start()
        return self.json(202, {"job_id": job_id, "status": "queued"})

    def do_GET(self):
        cleanup()
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/v1/auth/steam/callback":
            if not parsed.query:
                return self.json(400, {"error": "Missing Steam OpenID callback parameters"})
            self.send_response(302)
            self.send_header("Location", "lumaforge://steam-callback?" + parsed.query)
            self.end_headers()
            return
        if path == "/health":
            return self.json(200, {
                "ok": True, "service": "lumaforge", "version": "4.0",
                "providers": WORKSHOP_PROVIDER, "converter": "ffmpeg",
                "scene_renderer": Path(SCENE_RENDERER).is_file(),
                "server_side_only": True,
                "git_commit": os.getenv("RENDER_GIT_COMMIT", ""),
            })
        if path.startswith("/v1/jobs/"):
            if not self.authorized():
                return self.json(401, {"error": "Unauthorized"})
            job_id = path.rsplit("/", 1)[-1]
            with jobs_lock:
                job = jobs.get(job_id)
            return self.json(200, job) if job else self.json(404, {"error": "Job not found"})
        if path.startswith("/v1/files/"):
            if not self.authorized():
                return self.json(401, {"error": "Unauthorized"})
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
            job = jobs.get(job_id)
            if not job:
                return self.json(404, {"error": "Job not found"})
            if job.get("status") in {"queued", "downloading", "converting"}:
                return self.json(409, {"error": "Job is still running"})
            jobs.pop(job_id, None)
        filename = job.get("filename")
        if filename:
            try:
                (ROOT / Path(filename).name).unlink(missing_ok=True)
            except OSError:
                pass
        return self.json(200, {"ok": True})

    def log_message(self, fmt, *args):
        print(f"[lumaforge] {self.address_string()} {fmt % args}", flush=True)


if __name__ == "__main__":
    print(
        f"[lumaforge] starting on {HOST}:{PORT}; providers={WORKSHOP_PROVIDER}; "
        f"root={ROOT}",
        flush=True,
    )
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
