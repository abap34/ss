#!/usr/bin/env node
import assert from "node:assert/strict";
import { cp, mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { pdfAsset } from "../assets.mjs";
import { withBrowser } from "../capture.mjs";

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../..");
const output = path.join(repository, ".ss-cache/pdf-cache-test");
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
await cp(path.join(repository, "src/render/html/pdf"), path.join(output, "pdf"), { recursive: true });
await cp(path.join(repository, "third_party/pdfjs"), path.join(output, "pdfjs"), { recursive: true });
await writeFile(path.join(output, "asset.pdf"), pdfAsset());
await writeFile(path.join(output, "index.html"), `<!doctype html><meta charset="utf-8">
<style>
  body { margin: 0; }
  .viewport { position: relative; width: 400px; height: 300px; overflow: auto; }
  .content { position: relative; height: 4000px; }
  .ss-pdf { position: absolute; overflow: hidden; }
  .ss-pdf > canvas { width: 100%; height: 100%; }
</style>
<script type="importmap">{"imports":{
  "@ss/pdf/controller":"./pdf/controller.js",
  "@ss/pdf/geometry":"./pdf/geometry.js",
  "@ss/pdf/placement":"./pdf/placement.js",
  "@ss/pdf/queue":"./pdf/queue.js",
  "@ss/pdf/service":"./pdf/service.js"
}}</script>`);

await withBrowser(output, async (browser, baseUrl) => {
  const page = await browser.newPage({ viewport: { width: 800, height: 600 } });
  try {
    await page.goto(baseUrl + "/index.html");
    const result = await page.evaluate(async () => {
      const runtime = await import("./pdf/index.js");
      const nativePdfjs = await import("./pdfjs/pdf.mjs");
      const { PdfService } = await import("./pdf/service.js");
      const { RenderQueue } = await import("./pdf/queue.js");
      const renders = [];
      let renderGate = null;
      const pdfjs = {
        ...nativePdfjs,
        getDocument(parameters) {
          const task = nativePdfjs.getDocument(parameters);
          return {
            promise: task.promise.then((document) => ({
              async getPage(number) {
                const pdfPage = await document.getPage(number);
                return new Proxy(pdfPage, {
                  get(target, property) {
                    if (property === "render") return (options) => {
                      renders.push(parameters.url);
                      const rendering = target.render(options);
                      const gate = renderGate;
                      return {
                        promise: rendering.promise.then(() => gate),
                        cancel: () => rendering.cancel(),
                      };
                    };
                    const value = Reflect.get(target, property, target);
                    return typeof value === "function" ? value.bind(target) : value;
                  },
                });
              },
            })),
            destroy: () => task.destroy(),
          };
        },
      };
      const worker = new URL("./pdfjs/pdf.worker.mjs", location.href).href;
      const viewport = document.createElement("div");
      viewport.className = "viewport";
      document.body.append(viewport);
      const options = {
        cacheRaster: true, textLayer: false, annotationLayer: false,
        visibilityRoot: viewport, prefetchScreens: 2,
      };

      const original = await mount("asset.pdf");
      const originalPixels = pixels(original.container);
      const originalRenders = renders.length;
      const thumbnail = await mount("asset.pdf", { width: 60, height: 40 });
      const thumbnailRenders = renders.length;
      const thumbnailWidth = thumbnail.container.querySelector("canvas").width;
      original.controller.destroy();
      original.container.remove();
      const replacement = await mount("asset.pdf");
      const replacementPixels = pixels(replacement.container);
      const replacementRenders = renders.length;
      await mount("asset.pdf", { box: "0,0,120,160" });
      const cropRenders = renders.length;
      await mount("asset.pdf", { rotation: 90 });
      const rotationRenders = renders.length;
      await mount("asset.pdf?revision=2");
      const revisionRenders = renders.length;

      await mount("asset.pdf?quality", { width: 60, height: 40 });
      let releaseRender;
      renderGate = new Promise((resolve) => { releaseRender = resolve; });
      const beforeRefinement = renders.length;
      const refinement = mount("asset.pdf?quality");
      await waitFor(() => renders.length > beforeRefinement);
      const pendingCanvasCount = viewport.lastElementChild.querySelectorAll("canvas").length;
      releaseRender();
      renderGate = null;
      const refined = await refinement;
      const refinedWidth = refined.container.querySelector("canvas").width;

      const beforeImages = renders.length;
      renderGate = new Promise((resolve) => { releaseRender = resolve; });
      const abandoned = placement("asset.pdf?thumbnail");
      const shared = placement("asset.pdf?thumbnail", { width: 60, height: 40 });
      viewport.append(abandoned, shared);
      const abandonedController = runtime.mountPdfPages(abandoned, pdfjs, worker, { ...options, thumbnail: true });
      const sharedController = runtime.mountPdfPages(shared, pdfjs, worker, { ...options, thumbnail: true });
      await waitFor(() => renders.length > beforeImages);
      abandonedController.destroy();
      releaseRender();
      renderGate = null;
      await Promise.all([abandonedController.ready, sharedController.ready]);
      const image = shared.querySelector("img");
      const imageSource = image.src;
      const imageWidth = image.naturalWidth;
      shared.style.width = "120px";
      shared.style.height = "80px";
      await sharedController.renderAll();
      const retainedImage = shared.querySelector("img") === image;
      const recreated = await mount("asset.pdf?thumbnail", { thumbnail: true, width: 100, height: 40 });
      const sameImage = recreated.container.querySelector("img").src === imageSource;
      const imageRenders = renders.length - beforeImages;
      const abandonedImageCount = abandoned.querySelectorAll("img").length;
      await mount("asset.pdf?thumbnail", { thumbnail: true, rotation: 90 });
      const rotatedImageRenders = renders.length - beforeImages;
      await mount("asset.pdf?thumbnail", { thumbnail: true, box: "0,0,120,160" });
      const croppedImageRenders = renders.length - beforeImages;
      const sharpSource = "asset.pdf?sharp";
      await mount(sharpSource, { width: 480, height: 320 });
      const beforeSharpImage = renders.length;
      await mount(sharpSource, { thumbnail: true, width: 60, height: 40 });
      const sharpImageRenders = renders.length - beforeSharpImage;

      await runtime.disposePdfRuntime();
      viewport.replaceChildren();
      const content = document.createElement("div");
      content.className = "content";
      viewport.append(content);
      const visible = placement("asset.pdf?visible", { top: 10 });
      const near = placement("asset.pdf?near", { top: 700 });
      const far = placement("asset.pdf?far", { top: 1600 });
      content.append(near, far, visible);
      const beforePrefetch = renders.length;
      const prefetch = runtime.mountPdfPages(content, pdfjs, worker, options);
      await prefetch.ready;
      const initialPrefetch = renders.slice(beforePrefetch);
      const nearReadyBeforeScroll = near.dataset.ssPdfRendered === "true";
      const farReadyBeforeScroll = far.dataset.ssPdfRendered === "true";
      viewport.scrollTop = 1500;
      await waitFor(() => far.dataset.ssPdfRendered === "true");
      const afterScroll = renders.slice(beforePrefetch);
      await runtime.disposePdfRuntime();

      const cache = new PdfService(null, "unused");
      const large = { width: 4096, height: 4096 };
      cache.rememberRaster("first", large);
      cache.rememberRaster("second", large);
      cache.cachedRaster("first");
      cache.rememberRaster("third", large);
      const cacheKeys = [...cache.rasters.keys()];
      const cacheBytes = cache.rasterBytes;
      cache.rememberRaster("first", { width: 32, height: 32 });
      const retainedWidth = cache.cachedRaster("first").width;
      let imageCreations = 0;
      const firstImage = cache.thumbnail("same", () => {
        imageCreations += 1;
        return "same-image";
      });
      const pendingImageShared = firstImage === cache.thumbnail("same", () => {
        imageCreations += 1;
        return "unexpected-image";
      });
      await firstImage;
      const imagePayload = "x".repeat(3 * 1024 * 1024);
      for (const key of ["image-first", "image-second", "image-third"]) {
        await cache.thumbnail(key, () => imagePayload);
      }
      const imageCacheKeys = [...cache.thumbnails.keys()];
      const imageCacheBytes = cache.thumbnailBytes;
      let releaseImage;
      const pendingImage = cache.thumbnail("late", () => new Promise((resolve) => {
        releaseImage = resolve;
      }));
      await waitFor(() => releaseImage);
      await cache.destroy();
      releaseImage("late-image");
      await pendingImage;

      const queue = new RenderQueue(1);
      const priorityOrder = [];
      let releaseBlocker;
      const blocker = queue.enqueue(1000, () => new Promise((resolve) => {
        releaseBlocker = resolve;
      }));
      await waitFor(() => releaseBlocker);
      let firstPriority = 100;
      const first = queue.enqueue(() => firstPriority, () => priorityOrder.push("first"));
      const second = queue.enqueue(50, () => priorityOrder.push("second"));
      firstPriority = 0;
      releaseBlocker();
      await Promise.all([blocker, first, second]);
      await queue.close();

      return {
        originalRenders, thumbnailRenders, thumbnailWidth, replacementRenders,
        identicalPixels: originalPixels === replacementPixels,
        cropRenders, rotationRenders, revisionRenders, pendingCanvasCount, refinedWidth,
        imageWidth, imageSource, retainedImage, sameImage, imageRenders, abandonedImageCount,
        rotatedImageRenders, croppedImageRenders, sharpImageRenders,
        initialPrefetch, nearReadyBeforeScroll, farReadyBeforeScroll, afterScroll,
        cacheKeys, cacheBytes, retainedWidth,
        imageCreations, pendingImageShared, imageCacheKeys, imageCacheBytes,
        disposedImageBytes: cache.thumbnailBytes, disposedImageCount: cache.thumbnails.size,
        disposedCacheBytes: cache.rasterBytes, disposedCacheCount: cache.rasters.size,
        priorityOrder,
      };

      async function mount(source, extra = {}) {
        const container = placement(source, extra);
        viewport.append(container);
        const controller = runtime.mountPdfPages(container, pdfjs, worker, { ...options, ...extra });
        await controller.ready;
        return { controller, container };
      }

      function placement(source, { width = 240, height = 160, top = 10,
        box = "0,0,240,160", rotation = 0 } = {}) {
        const container = document.createElement("div");
        container.className = "ss-pdf";
        Object.assign(container.dataset, {
          pdfSrc: source, page: "1", viewBox: box, rotation: String(rotation),
          canvasBackground: "transparent", copyAnnotations: "false",
        });
        container.style.cssText = `left:10px;top:${top}px;width:${width}px;height:${height}px`;
        container.innerHTML = '<div class="ss-pdf-text"></div><div class="ss-pdf-annotations"></div>';
        return container;
      }

      function pixels(container) {
        const canvas = container.querySelector("canvas");
        const data = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height).data;
        let checksum = 0;
        for (const value of data) checksum = (checksum * 31 + value) | 0;
        return checksum;
      }

      async function waitFor(predicate) {
        const deadline = performance.now() + 5000;
        while (!predicate()) {
          if (performance.now() > deadline) throw new Error("timed out");
          await new Promise((resolve) => setTimeout(resolve, 10));
        }
      }
    });
    assert.equal(result.originalRenders, 1);
    assert.equal(result.thumbnailRenders, 1, "thumbnail rasterized a PDF already drawn in the editor");
    assert.equal(result.thumbnailWidth, 60);
    assert.equal(result.replacementRenders, 1, "replacing the display discarded the PDF raster cache");
    assert.equal(result.identicalPixels, true, "cached PDF pixels changed during display replacement");
    assert.equal(result.cropRenders, 2, "different PDF crops shared an incorrect raster");
    assert.equal(result.rotationRenders, 3, "different PDF rotations shared an incorrect raster");
    assert.equal(result.revisionRenders, 4, "changed PDF contents reused stale pixels");
    assert.equal(result.pendingCanvasCount, 0, "a low-resolution cached image appeared while rendering");
    assert.equal(result.refinedWidth, 240, "a small cached image prevented full-resolution rendering");
    assert.match(result.imageSource, /^data:image\/png;base64,/);
    assert.equal(result.imageWidth, 256, "PDF image dimensions depended on its display size");
    assert.equal(result.imageRenders, 1, "identical PDF images were generated more than once");
    assert.equal(result.abandonedImageCount, 0, "a disposed placement received a late PDF image");
    assert.equal(result.retainedImage, true, "resizing recreated a fixed PDF image");
    assert.equal(result.sameImage, true, "recreating a preview discarded its fixed PDF image");
    assert.equal(result.rotatedImageRenders, 2, "different rotations shared a PDF image");
    assert.equal(result.croppedImageRenders, 3, "different crops shared a PDF image");
    assert.equal(result.sharpImageRenders, 0, "fixed image generation ignored an available sharp raster");
    assert.deepEqual(result.initialPrefetch.map((source) => source.split("?")[1]), ["visible", "near"],
      "prefetching did not prioritize the visible PDF within the scroll viewport");
    assert.equal(result.nearReadyBeforeScroll, true, "nearby PDF was not prepared outside the clipped viewport");
    assert.equal(result.farReadyBeforeScroll, false, "prefetching loaded a distant PDF");
    assert.equal(result.afterScroll.length, 3, "scrolling omitted a PDF or repeated a completed render");
    assert.deepEqual(result.cacheKeys, ["first", "third"], "raster eviction ignored recent use");
    assert.equal(result.cacheBytes, 128 * 1024 * 1024, "raster cache exceeded its byte budget");
    assert.equal(result.retainedWidth, 4096, "a thumbnail replaced a sharper cached raster");
    assert.equal(result.imageCreations, 1);
    assert.equal(result.pendingImageShared, true, "concurrent requests generated duplicate PDF images");
    assert.deepEqual(result.imageCacheKeys, ["image-second", "image-third"]);
    assert.equal(result.imageCacheBytes, 12 * 1024 * 1024, "PDF image cache ignored its memory budget");
    assert.equal(result.disposedImageBytes, 0, "a late image repopulated the disposed cache");
    assert.equal(result.disposedImageCount, 0);
    assert.equal(result.disposedCacheBytes, 0);
    assert.equal(result.disposedCacheCount, 0);
    assert.deepEqual(result.priorityOrder, ["second", "first"], "queued PDF work ignored updated priorities");
    console.log("PDF raster cache and viewport prefetch passed");
  } finally {
    await page.close();
  }
});
