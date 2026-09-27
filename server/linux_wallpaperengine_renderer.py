#!/usr/bin/env python3
"""Headless Wallpaper Engine scene renderer using linux-wallpaperengine.

The renderer runs the native Linux Wallpaper Engine implementation inside an
Xvfb display and captures the rendered window with FFmpeg. It intentionally
does not acquire Workshop content or authenticate with Steam.
"""
from __future__ import annotations

import os
import signal
import subprocess
import tempfile
import time
from pathlib import Path


class LinuxWallpaperEngineError(RuntimeError):
    pass


def _run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, text=True, **kwargs)


def render_scene(
    wallpaper_path: str | Path,
    output_path: str | Path,
    *,
    assets_dir: str | Path,
    width: int = 1280,
    height: int = 720,
    seconds: float = 6,
    fps: int = 30,
) -> Path:
    engine = Path(os.environ.get("LWE_RENDERER", "/opt/linux-wallpaperengine/linux-wallpaperengine"))
    wallpaper = Path(wallpaper_path)
    assets = Path(assets_dir)
    output = Path(output_path)

    if not engine.is_file():
        raise LinuxWallpaperEngineError(f"linux-wallpaperengine binary not found: {engine}")
    if not assets.is_dir():
        raise LinuxWallpaperEngineError(f"Wallpaper Engine assets directory not found: {assets}")
    if not wallpaper.exists():
        raise LinuxWallpaperEngineError(f"Wallpaper project not found: {wallpaper}")

    output.parent.mkdir(parents=True, exist_ok=True)
    display = os.environ.get("LWE_DISPLAY", ":99")

    xvfb = subprocess.Popen(
        [
            "Xvfb",
            display,
            "-screen", "0", f"{width}x{height}x24",
            "-ac",
            "-nolisten", "tcp",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )

    engine_proc = None
    ffmpeg_proc = None
    try:
        time.sleep(0.5)
        if xvfb.poll() is not None:
            raise LinuxWallpaperEngineError("Xvfb failed to start")

        env = os.environ.copy()
        env.update({
            "DISPLAY": display,
            "LIBGL_ALWAYS_SOFTWARE": os.environ.get("LIBGL_ALWAYS_SOFTWARE", "1"),
            "WALLPAPER_ENGINE_PATH": str(assets.parent),
        })

        # The renderer's --window option creates a normal X11 window that can
        # be captured without requiring a desktop/compositor.
        engine_proc = subprocess.Popen(
            [
                str(engine),
                "--assets-dir", str(assets),
                "--window", f"{width}x{height}+0+0",
                "--silent",
                "--fps", str(fps),
                str(wallpaper),
            ],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )

        # Give the renderer a moment to create its X11 window before capture.
        time.sleep(2.0)
        if engine_proc.poll() is not None:
            logs = engine_proc.stdout.read()[-12000:] if engine_proc.stdout else ""
            raise LinuxWallpaperEngineError(
                f"linux-wallpaperengine exited early ({engine_proc.returncode}):\n{logs}"
            )

        duration = max(0.5, float(seconds))
        ffmpeg_proc = subprocess.Popen(
            [
                "ffmpeg", "-y",
                "-f", "x11grab",
                "-video_size", f"{width}x{height}",
                "-framerate", str(fps),
                "-draw_mouse", "0",
                "-i", f"{display}+0,0",
                "-t", str(duration),
                "-an",
                "-c:v", "libx264",
                "-preset", "veryfast",
                "-crf", "18",
                "-pix_fmt", "yuv420p",
                "-movflags", "+faststart",
                str(output),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        ffmpeg_logs = ffmpeg_proc.communicate(timeout=duration + 30)[1]
        if ffmpeg_proc.returncode != 0:
            raise LinuxWallpaperEngineError(f"FFmpeg capture failed:\n{ffmpeg_logs[-12000:]}")

        if not output.is_file() or output.stat().st_size < 10 * 1024:
            raise LinuxWallpaperEngineError("Renderer produced an empty or suspiciously small MP4")

        return output
    finally:
        for proc in (ffmpeg_proc, engine_proc, xvfb):
            if proc is not None and proc.poll() is None:
                try:
                    proc.terminate()
                    proc.wait(timeout=3)
                except Exception:
                    try:
                        proc.kill()
                    except Exception:
                        pass
