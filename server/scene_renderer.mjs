#!/usr/bin/env node
import fs from "node:fs";
import fsp from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import puppeteer from "puppeteer-core";

const [, , pkgArg, outputArg, widthArg = "1280", heightArg = "720", secondsArg = "6", fpsArg = "30"] = process.argv;

if (!pkgArg || !outputArg) {
  console.error("usage: render_scene.mjs <scene.pkg> <output.webm> [width] [height] [seconds] [fps]");
  process.exit(2);
}

const pkgPath = path.resolve(pkgArg);
const outputPath = path.resolve(outputArg);
const width = Math.max(320, Math.min(1920, Number(widthArg) || 1280));
const height = Math.max(180, Math.min(1080, Number(heightArg) || 720));
const seconds = Math.max(2, Math.min(12, Number(secondsArg) || 6));
const fps = Math.max(10, Math.min(30, Number(fpsArg) || 30));
const chromium = process.env.CHROMIUM_PATH || "/usr/bin/chromium";
const webwallgl = process.env.WEBWALLGL_MODULE || "/opt/lumaforge-renderer/webwallgl.min.mjs";

const tempDir = await fsp.mkdtemp(path.join(os.tmpdir(), "lumaforge-scene-"));
const servedPkg = path.join(tempDir, "scene.pkg");
const servedProject = path.join(tempDir, "project.json");
const servedModule = path.join(tempDir, "webwallgl.min.mjs");
const html = path.join(tempDir, "index.html");

await fsp.copyFile(pkgPath, servedPkg);
try {
  await fsp.copyFile(path.join(path.dirname(pkgPath), "project.json"), servedProject);
} catch {}

await fsp.copyFile(webwallgl, servedModule);

const htmlBody = `<!doctype html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=${width},height=${height}"></head>
<body style="margin:0;overflow:hidden;background:#000">
<canvas id="wp" width="${width}" height="${height}" style="display:block;width:${width}px;height:${height}px"></canvas>
<script type="module">
import { mount, httpSource } from "/webwallgl.min.mjs";

const canvas = document.getElementById("wp");
const diagnostics = [];
window.__LUMAFORGE_ERROR = null;

try {
  const instance = await mount(canvas, {
    source: httpSource(window.location.origin + "/"),
    fps: ${fps},
    renderDpr: 1,
    volume: 0,
    quality: {
      antiAliasing: "off",
      particles: "medium",
      postProcessing: "medium"
    }
  });
  window.__LUMAFORGE_READY = true;
  window.__LUMAFORGE_INFO = instance.info;
  instance.on("diagnostic", (message, level) => {
    if (level === "error") diagnostics.push(String(message));
  });
  window.__LUMAFORGE_DIAGNOSTICS = diagnostics;
} catch (error) {
  window.__LUMAFORGE_ERROR = String(error?.stack || error);
}

window.__LUMAFORGE_RECORD = async () => {
  if (!window.__LUMAFORGE_READY) throw new Error(window.__LUMAFORGE_ERROR || "scene renderer did not become ready");
  const stream = canvas.captureStream(${fps});
  const mimeTypes = [
    "video/webm;codecs=vp9",
    "video/webm;codecs=vp8",
    "video/webm"
  ];
  const mimeType = mimeTypes.find((x) => MediaRecorder.isTypeSupported(x));
  if (!mimeType) throw new Error("Chromium has no supported WebM MediaRecorder codec");

  const chunks = [];
  const recorder = new MediaRecorder(stream, {
    mimeType,
    videoBitsPerSecond: 12000000
  });
  const stopped = new Promise((resolve, reject) => {
    recorder.onstop = resolve;
    recorder.onerror = () => reject(recorder.error || new Error("MediaRecorder failed"));
  });
  recorder.ondataavailable = (event) => {
    if (event.data && event.data.size) chunks.push(event.data);
  };

  recorder.start(1000);
  await new Promise((resolve) => setTimeout(resolve, ${Math.round(seconds * 1000)}));
  recorder.stop();
  await stopped;
  stream.getTracks().forEach((track) => track.stop());

  const blob = new Blob(chunks, { type: mimeType });
  const response = await fetch("/__lumaforge_upload", {
    method: "POST",
    headers: { "Content-Type": "video/webm" },
    body: blob
  });
  if (!response.ok) throw new Error("Renderer upload failed: HTTP " + response.status);
  return { bytes: blob.size, mimeType };
};
</script>
</body>
</html>`;

await fsp.writeFile(html, htmlBody);

let uploadPromise;
let uploadResolve;
let uploadReject;
uploadPromise = new Promise((resolve, reject) => {
  uploadResolve = resolve;
  uploadReject = reject;
});

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === "POST" && req.url === "/__lumaforge_upload") {
      const stream = fs.createWriteStream(outputPath);
      req.pipe(stream);
      stream.on("finish", () => {
        res.writeHead(200, { "Content-Type": "text/plain" });
        res.end("ok");
        uploadResolve();
      });
      stream.on("error", uploadReject);
      return;
    }

    const pathname = new URL(req.url, "http://127.0.0.1").pathname;
    const safeName = pathname === "/" ? "index.html" : pathname.replace(/^\/+/, "");
    if (!["index.html", "scene.pkg", "project.json", "webwallgl.min.mjs"].includes(safeName)) {
      res.writeHead(404);
      res.end();
      return;
    }

    const filePath = path.join(tempDir, safeName);
    const stat = await fsp.stat(filePath);
    res.writeHead(200, {
      "Content-Length": stat.size,
      "Content-Type":
        safeName.endsWith(".mjs") ? "text/javascript" :
        safeName.endsWith(".json") ? "application/json" :
        safeName.endsWith(".pkg") ? "application/octet-stream" :
        "text/html; charset=utf-8",
      "Cache-Control": "no-store"
    });
    fs.createReadStream(filePath).pipe(res);
  } catch (error) {
    res.writeHead(500);
    res.end(String(error));
  }
});

await new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(0, "127.0.0.1", resolve);
});
const port = server.address().port;

let browser;
try {
  browser = await puppeteer.launch({
    executablePath: chromium,
    headless: "new",
    args: [
      "--no-sandbox",
      "--disable-setuid-sandbox",
      "--disable-dev-shm-usage",
      "--disable-gpu-sandbox",
      "--ignore-gpu-blocklist",
      "--use-gl=angle",
      "--use-angle=swiftshader",
      "--enable-unsafe-swiftshader",
      "--enable-unsafe-swiftshader",
      "--autoplay-policy=no-user-gesture-required",
      "--disable-background-timer-throttling",
      "--disable-backgrounding-occluded-windows",
      "--disable-renderer-backgrounding"
    ]
  });

  const page = await browser.newPage();
  await page.setViewport({ width, height, deviceScaleFactor: 1 });

  page.on("console", (message) => {
    if (message.type() === "error") console.error("[scene-browser]", message.text());
  });
  page.on("pageerror", (error) => console.error("[scene-browser]", error.stack || error));

  await page.goto(`http://127.0.0.1:${port}/`, {
    waitUntil: "domcontentloaded",
    timeout: 30000
  });

  await page.waitForFunction(
    () => window.__LUMAFORGE_READY === true || window.__LUMAFORGE_ERROR,
    { timeout: 60000 }
  );

  const state = await page.evaluate(() => ({
    ready: !!window.__LUMAFORGE_READY,
    error: window.__LUMAFORGE_ERROR,
    info: window.__LUMAFORGE_INFO,
    diagnostics: window.__LUMAFORGE_DIAGNOSTICS || []
  }));

  if (!state.ready) {
    throw new Error("WebWallGL scene render failed: " + (state.error || state.diagnostics.join(" | ") || "unknown error"));
  }

  console.log("[scene-renderer] ready", JSON.stringify(state.info || {}));
  const recording = await page.evaluate(() => window.__LUMAFORGE_RECORD());
  console.log("[scene-renderer] recorded", JSON.stringify(recording));
  await uploadPromise;
} finally {
  if (browser) await browser.close().catch(() => {});
  server.close();
  await fsp.rm(tempDir, { recursive: true, force: true }).catch(() => {});
}

const stat = await fsp.stat(outputPath);
if (stat.size < 1024) {
  throw new Error("Scene renderer produced an invalid WebM");
}
console.log("[scene-renderer] output", outputPath, stat.size);
