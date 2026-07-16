import { createReadStream } from "node:fs";
import { cp, mkdir, stat, writeFile } from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { chromium } from "playwright";
import { PNG } from "pngjs";

export async function preparePdfViewer(root, repository) {
  await mkdir(path.join(root, "pdfjs"), { recursive: true });
  await cp(path.join(repository, "third_party/pdfjs/pdf.mjs"), path.join(root, "pdfjs/pdf.mjs"));
  await cp(path.join(repository, "third_party/pdfjs/pdf.worker.mjs"), path.join(root, "pdfjs/pdf.worker.mjs"));
  await writeFile(path.join(root, "pdf-viewer.html"), pdfViewerHtml(), "utf8");
}

export async function withBrowser(root, body) {
  const server = await startServer(root);
  const browser = await chromium.launch({ headless: true });
  try {
    await body(browser, `http://127.0.0.1:${server.address().port}`);
  } finally {
    await browser.close();
    await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
}

export async function captureHtmlPages(browser, baseUrl, relativePath) {
  const page = await browser.newPage({ deviceScaleFactor: 1.5, viewport: { width: 1920, height: 1200 } });
  try {
    await page.goto(`${baseUrl}/${relativePath}/index.html`, { waitUntil: "networkidle" });
    await page.evaluate(() => document.fonts.ready);
    await page.evaluate(() => Promise.all([...document.images].map((image) => image.decode())));
    if (await page.locator(".ss-pdf").count()) {
      await page.waitForFunction(() => document.documentElement.dataset.ssReady === "true", null, { timeout: 120_000 });
    }
    const pages = page.locator(".ss-page");
    const count = await pages.count();
    const images = [];
    for (let index = 0; index < count; index += 1) {
      const item = pages.nth(index);
      const box = await item.boundingBox();
      if (!box || box.width <= 0 || box.height <= 0) throw new Error(`HTML page ${index + 1} has no visible bounds`);
      const size = await item.evaluate((element) => ({
        width: Number.parseFloat(element.style.width),
        height: Number.parseFloat(element.style.height),
      }));
      const targetWidth = Math.round(size.width * 2);
      const targetHeight = Math.round(size.height * 2);
      const screenshot = await page.screenshot({
        clip: {
          x: box.x,
          y: box.y,
          width: (targetWidth + 1) / 1.5,
          height: (targetHeight + 1) / 1.5,
        },
      });
      images.push({
        image: cropPng(screenshot, targetWidth, targetHeight),
        items: await itemRegions(item, box, targetWidth, targetHeight),
      });
    }
    return images;
  } finally {
    await page.close();
  }
}

async function itemRegions(page, pageBox, targetWidth, targetHeight) {
  const scaleX = targetWidth / pageBox.width;
  const scaleY = targetHeight / pageBox.height;
  return await page.locator(":scope > .ss-item").evaluateAll((items, geometry) =>
    items.map((item) => {
      const box = item.getBoundingClientRect();
      return {
        id: item.dataset.ssItemId || "unknown",
        kind: item.classList.contains("ss-line")
          ? "line"
          : item.classList.contains("ss-math")
          ? "math"
          : item.classList.contains("ss-text")
          ? "text"
          : "other",
        x: Math.floor((box.x - geometry.pageX) * geometry.scaleX),
        y: Math.floor((box.y - geometry.pageY) * geometry.scaleY),
        right: Math.ceil((box.right - geometry.pageX) * geometry.scaleX),
        bottom: Math.ceil((box.bottom - geometry.pageY) * geometry.scaleY),
      };
    }), {
      pageX: pageBox.x,
      pageY: pageBox.y,
      scaleX,
      scaleY,
    }
  );
}

function cropPng(source, width, height) {
  const decoded = PNG.sync.read(source, { skipRescale: true });
  if (decoded.width < width || decoded.height < height) {
    throw new Error(`captured image ${decoded.width}x${decoded.height} is smaller than ${width}x${height}`);
  }
  if (decoded.width === width && decoded.height === height) return source;
  const result = new PNG({ width, height });
  PNG.bitblt(decoded, result, 0, 0, width, height, 0, 0);
  return PNG.sync.write(result, { colorType: 6 });
}

export async function capturePdfPages(browser, baseUrl, pdfPath) {
  const page = await browser.newPage({ deviceScaleFactor: 1, viewport: { width: 3000, height: 1800 } });
  try {
    await page.goto(`${baseUrl}/pdf-viewer.html?source=${encodeURIComponent(`/${pdfPath}`)}`, { waitUntil: "networkidle" });
    await page.waitForFunction(() => globalThis.ssPdfReady === true, null, { timeout: 120_000 });
    const error = await page.evaluate(() => globalThis.ssPdfError ?? null);
    if (error) throw new Error(`PDF.js capture failed: ${error}`);
    const pages = page.locator("canvas");
    const count = await pages.count();
    const images = [];
    for (let index = 0; index < count; index += 1) images.push(await pages.nth(index).screenshot());
    return images;
  } finally {
    await page.close();
  }
}

async function startServer(root) {
  const absoluteRoot = path.resolve(root);
  const server = http.createServer(async (request, response) => {
    try {
      const url = new URL(request.url, "http://127.0.0.1");
      const relative = decodeURIComponent(url.pathname).replace(/^\/+/, "");
      const resolved = path.resolve(absoluteRoot, relative || "index.html");
      if (resolved !== absoluteRoot && !resolved.startsWith(`${absoluteRoot}${path.sep}`)) {
        response.writeHead(403).end();
        return;
      }
      const info = await stat(resolved);
      if (!info.isFile()) throw new Error("not a file");
      response.setHeader("Content-Type", contentType(resolved));
      response.setHeader("Cache-Control", "no-store");
      createReadStream(resolved).pipe(response);
    } catch {
      response.writeHead(404).end();
    }
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  return server;
}

function contentType(file) {
  switch (path.extname(file)) {
    case ".html": return "text/html; charset=utf-8";
    case ".js":
    case ".mjs": return "text/javascript; charset=utf-8";
    case ".css": return "text/css; charset=utf-8";
    case ".pdf": return "application/pdf";
    case ".png": return "image/png";
    case ".ttf": return "font/ttf";
    case ".otf": return "font/otf";
    case ".ttc": return "font/collection";
    default: return "application/octet-stream";
  }
}

function pdfViewerHtml() {
  return `<!doctype html>
<meta charset="utf-8">
<style>html,body{margin:0}canvas{display:block}</style>
<main></main>
<script type="module">
import * as pdfjs from "./pdfjs/pdf.mjs";
try {
  pdfjs.GlobalWorkerOptions.workerSrc = "./pdfjs/pdf.worker.mjs";
  const source = new URL(location.href).searchParams.get("source");
  const pdf = await pdfjs.getDocument({url:source,isEvalSupported:false}).promise;
  for (let index=1;index<=pdf.numPages;index++) {
    const page = await pdf.getPage(index);
    const viewport = page.getViewport({scale:2});
    const canvas = document.createElement("canvas");
    canvas.width = Math.floor(viewport.width);
    canvas.height = Math.floor(viewport.height);
    document.querySelector("main").append(canvas);
    await page.render({canvasContext:canvas.getContext("2d"),viewport}).promise;
  }
} catch (error) {
  globalThis.ssPdfError = error instanceof Error ? error.stack : String(error);
} finally {
  globalThis.ssPdfReady = true;
}
</script>`;
}
