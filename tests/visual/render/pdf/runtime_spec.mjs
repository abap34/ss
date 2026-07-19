#!/usr/bin/env node
import assert from "node:assert/strict";
import { cp, mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { withBrowser } from "../../render/capture.mjs";

const repository = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../../..",
);
const output = path.join(repository, ".ss-cache/pdf-runtime-test");

await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
await cp(
  path.join(repository, "src/render/html/pdf"),
  path.join(output, "pdf"),
  { recursive: true },
);
await writeFile(
  path.join(output, "index.html"),
  `<!doctype html><meta charset="utf-8">
<script type="importmap">{"imports":{
  "@ss/pdf/controller":"./pdf/controller.js",
  "@ss/pdf/geometry":"./pdf/geometry.js",
  "@ss/pdf/placement":"./pdf/placement.js",
  "@ss/pdf/queue":"./pdf/queue.js",
  "@ss/pdf/service":"./pdf/service.js"
}}</script><main id="root"></main>`,
  "utf8",
);

await withBrowser(output, async (browser, baseUrl) => {
  const page = await browser.newPage({
    deviceScaleFactor: 2,
    viewport: { width: 800, height: 600 },
  });
  try {
    await page.goto(baseUrl + "/index.html", { waitUntil: "networkidle" });
    const result = await page.evaluate(async () => {
      const runtime = await import("./pdf/index.js");
      const { PdfService } = await import("./pdf/service.js");
      const { RenderQueue } = await import("./pdf/queue.js");
      const { visiblePixelSize } = await import("./pdf/geometry.js");
      const displaySizes = {
        fourK: displayPixelSize(3840, 2160),
        fiveKRetina: displayPixelSize(2560, 1440, 2),
        sixK: displayPixelSize(6016, 3384),
      };
      const workerPorts = { created: 0, terminated: 0 };
      const NativeWorker = globalThis.Worker;
      globalThis.Worker = class {
        constructor() {
          workerPorts.created += 1;
          this.terminated = false;
        }

        terminate() {
          if (this.terminated) return;
          this.terminated = true;
          workerPorts.terminated += 1;
        }
      };
      const counters = {
        documents: 0,
        pages: 0,
        renders: 0,
        active: 0,
        maximumActive: 0,
        text: 0,
        annotations: 0,
        workers: 0,
      };
      const pdfjs = fakePdfjs(counters, false);
      const root = document.querySelector("#root");
      const pageBoxes = ["10,5,90,45", "20,10,80,40", "0,0,100,50"];
      for (let index = 0; index < pageBoxes.length; index += 1) {
        root.append(pdfPlacement(
          "shared.pdf",
          10 + index * 70,
          pageBoxes[index],
        ));
      }
      root.append(pdfPlacement(
        "shared.pdf",
        10,
        pageBoxes[0],
        1200,
        900,
      ));
      const placeholderCanvasCount = root.querySelectorAll(".ss-pdf > canvas").length;
      const controller = await runtime.renderPdfPages(
        root,
        pdfjs,
        "worker-a",
        { textLayer: false, annotationLayer: false },
      );
      const canvasSizes = [...root.querySelectorAll(".ss-pdf > canvas")]
        .map((canvas) => ({ width: canvas.width, height: canvas.height }));

      const hiddenRoot = document.createElement("section");
      hiddenRoot.style.display = "none";
      hiddenRoot.append(pdfPlacement("hidden.pdf", 250));
      document.body.append(hiddenRoot);
      const hidden = runtime.mountPdfPages(
        hiddenRoot,
        pdfjs,
        "worker-a",
        { textLayer: false, annotationLayer: false },
      );
      await hidden.ready;
      const documentsBeforeReveal = counters.documents;
      hiddenRoot.style.display = "block";
      hidden.refreshVisible();
      await waitFor(() =>
        hiddenRoot.querySelector(".ss-pdf").dataset.ssPdfRendered === "true"
      );

      const cancellation = { renders: 0, cancelled: 0, workers: 0 };
      const slowRoot = document.createElement("section");
      slowRoot.append(pdfPlacement("slow.pdf", 330));
      document.body.append(slowRoot);
      const slow = runtime.mountPdfPages(
        slowRoot,
        fakePdfjs(cancellation, true),
        "worker-b",
        { textLayer: false, annotationLayer: false },
      );
      await waitFor(() => cancellation.renders === 1);
      slow.destroy();
      await slow.ready;

      const forced = { renders: 0, cancelled: 0, workers: 0 };
      const forcedRoot = document.createElement("section");
      forcedRoot.append(pdfPlacement("print.pdf", 2000));
      document.body.append(forcedRoot);
      const forcedController = runtime.mountPdfPages(
        forcedRoot,
        fakePdfjs(forced, false),
        "worker-print",
        { textLayer: false, annotationLayer: false },
      );
      await forcedController.ready;
      const forcedRender = forcedController.renderAll();
      await waitFor(() => forced.renders === 1);
      forcedController.refreshVisible();
      await forcedRender;
      forcedController.restoreAfterPrint();
      const forcedCanvasCountAfterRestore = forcedRoot.querySelectorAll(
        ".ss-pdf > canvas",
      ).length;

      let blockedStarted = false;
      const blockedRoot = document.createElement("section");
      blockedRoot.append(pdfPlacement("blocked.pdf", 400));
      document.body.append(blockedRoot);
      const blocked = runtime.mountPdfPages(
        blockedRoot,
        fakePdfjs({}, false),
        "worker-c",
        {
          textLayer: false,
          annotationLayer: false,
          resolveSource() {
            blockedStarted = true;
            return new Promise(() => {});
          },
        },
      );
      await waitFor(() => blockedStarted);
      blocked.destroy();
      const blockedReady = await Promise.race([
        blocked.ready.then(() => true),
        new Promise((resolve) => setTimeout(() => resolve(false), 250)),
      ]);

      const failedRoot = document.createElement("section");
      failedRoot.append(pdfPlacement("broken.pdf", 470));
      document.body.append(failedRoot);
      let reportedError = null;
      let rejectedError = null;
      try {
        await runtime.renderPdfPages(
          failedRoot,
          fakePdfjs({}, false),
          "worker-d",
          {
            textLayer: false,
            annotationLayer: false,
            resolveSource() {
              throw new Error("broken PDF resource");
            },
            onError(error) {
              reportedError = error.message;
            },
          },
        );
      } catch (error) {
        rejectedError = error.message;
      }

      const priority = { order: [], workers: 0 };
      const priorityPdfjs = fakePdfjs(priority, false);
      const thumbnailRoot = document.createElement("section");
      thumbnailRoot.append(pdfPlacement("thumbnail.pdf", 10));
      document.body.append(thumbnailRoot);
      const mainRoot = document.createElement("section");
      mainRoot.append(pdfPlacement("main.pdf", 80));
      document.body.append(mainRoot);
      const thumbnail = runtime.mountPdfPages(
        thumbnailRoot,
        priorityPdfjs,
        "worker-e",
        { thumbnail: true, textLayer: false, annotationLayer: false },
      );
      const main = runtime.mountPdfPages(
        mainRoot,
        priorityPdfjs,
        "worker-e",
        { textLayer: false, annotationLayer: false },
      );
      await Promise.all([thumbnail.ready, main.ready]);

      const loading = { documents: 0, destroys: 0, workers: 0 };
      const loadingService = new PdfService(
        pendingPdfjs(loading),
        "worker-f",
      );
      const loadingAbort = new AbortController();
      let loadingBodyCalled = false;
      const loadingUse = loadingService.usePage(
        "pending.pdf",
        1,
        () => {
          loadingBodyCalled = true;
        },
        loadingAbort.signal,
      );
      await waitFor(() => loading.documents === 1);
      loadingAbort.abort();
      const loadingCancelled = await Promise.race([
        loadingUse.then(() => true),
        new Promise((resolve) => setTimeout(() => resolve(false), 250)),
      ]);
      const loadingUsers = loadingService.documents.get("pending.pdf")?.users;
      await loadingService.destroy();

      const pendingProvider = new PdfService(
        () => new Promise(() => {}),
        "worker-g",
      );
      void pendingProvider.pdfjs();
      const providerDestroyed = await Promise.race([
        pendingProvider.destroy().then(() => true),
        new Promise((resolve) => setTimeout(() => resolve(false), 250)),
      ]);

      const queueLifecycle = {
        started: false,
        abortObserved: false,
        bodyFinished: false,
        closeResolved: false,
      };
      let releaseQueueCleanup;
      const queue = new RenderQueue(1);
      const queueWork = queue.enqueue(100, async (signal) => {
        queueLifecycle.started = true;
        await observeAbort(signal, () => {
          queueLifecycle.abortObserved = true;
        });
        await new Promise((resolve) => {
          releaseQueueCleanup = resolve;
        });
        queueLifecycle.bodyFinished = true;
      });
      await waitFor(() => queueLifecycle.started);
      const queueClose = queue.close().then(() => {
        queueLifecycle.closeResolved = true;
      });
      await waitFor(() => typeof releaseQueueCleanup === "function");
      queueLifecycle.closeResolvedBeforeCleanup = queueLifecycle.closeResolved;
      releaseQueueCleanup();
      await Promise.all([queueWork, queueClose]);

      const serviceLifecycle = {
        workers: 0,
        workerDestroys: 0,
        documents: 0,
        documentDestroys: 0,
        bodyStarted: false,
        abortObserved: false,
        bodyFinished: false,
        destroyResolved: false,
      };
      const drainingService = new PdfService(
        lifecyclePdfjs(serviceLifecycle),
        "worker-service-drain",
      );
      let releaseServiceCleanup;
      const serviceWork = drainingService.schedule(100, (signal) =>
        drainingService.usePage(
          "service-drain.pdf",
          1,
          async () => {
            serviceLifecycle.bodyStarted = true;
            await observeAbort(signal, () => {
              serviceLifecycle.abortObserved = true;
            });
            await new Promise((resolve) => {
              releaseServiceCleanup = resolve;
            });
            serviceLifecycle.bodyFinished = true;
          },
          signal,
        )
      );
      await waitFor(() => serviceLifecycle.bodyStarted);
      const servicePortsBefore = workerPorts.terminated;
      const serviceDestroy = drainingService.destroy().then(() => {
        serviceLifecycle.destroyResolved = true;
      });
      await waitFor(() => typeof releaseServiceCleanup === "function");
      serviceLifecycle.beforeCleanup = {
        destroyResolved: serviceLifecycle.destroyResolved,
        documentDestroys: serviceLifecycle.documentDestroys,
        workerDestroys: serviceLifecycle.workerDestroys,
        terminatedPorts: workerPorts.terminated - servicePortsBefore,
      };
      releaseServiceCleanup();
      await Promise.all([serviceWork, serviceDestroy]);

      const retirementLifecycle = {
        workers: 0,
        workerDestroys: 0,
        documents: 0,
        destroyStarted: [],
        destroyFinished: [],
        releases: [],
        destroyResolved: false,
      };
      const retirementService = new PdfService(
        retirementPdfjs(retirementLifecycle),
        "worker-retirement",
      );
      let retirementError = null;
      try {
        await retirementService.usePage("failed.pdf", 1, () => {});
      } catch (error) {
        retirementError = error.message;
      }
      for (let index = 0; index < 9; index += 1) {
        await retirementService.usePage(`retired-${index}.pdf`, 1, () => {});
      }
      await waitFor(() => retirementLifecycle.releases.length === 2);
      const retirementPortsBefore = workerPorts.terminated;
      const retirementDestroy = retirementService.destroy().then(() => {
        retirementLifecycle.destroyResolved = true;
      });
      await new Promise((resolve) => setTimeout(resolve, 10));
      retirementLifecycle.beforeRelease = {
        destroyResolved: retirementLifecycle.destroyResolved,
        destroyStarted: retirementLifecycle.destroyStarted.length,
        destroyFinished: retirementLifecycle.destroyFinished.length,
        workerDestroys: retirementLifecycle.workerDestroys,
        terminatedPorts: workerPorts.terminated - retirementPortsBefore,
      };
      for (const release of retirementLifecycle.releases.splice(0)) release();
      await retirementDestroy;

      const runtimeLifecycle = {
        renders: 0,
        cancelled: 0,
        workers: 0,
      };
      const runtimeDrainRoot = document.createElement("section");
      runtimeDrainRoot.append(pdfPlacement("runtime-drain.pdf", 540));
      document.body.append(runtimeDrainRoot);
      const runtimeDrainController = runtime.mountPdfPages(
        runtimeDrainRoot,
        fakePdfjs(runtimeLifecycle, true, 60),
        "worker-runtime-drain",
        { textLayer: false, annotationLayer: false },
      );
      await waitFor(() => runtimeLifecycle.renders === 1);

      controller.destroy();
      hidden.destroy();
      forcedController.destroy();
      thumbnail.destroy();
      main.destroy();
      let runtimeDisposeResolved = false;
      const runtimeDispose = runtime.disposePdfRuntime().then(() => {
        runtimeDisposeResolved = true;
      });
      await waitFor(() => runtimeLifecycle.cancelRequested === true);
      await new Promise((resolve) => setTimeout(resolve, 10));
      runtimeLifecycle.beforeCancellationFinished = {
        disposeResolved: runtimeDisposeResolved,
        documentDestroys: runtimeLifecycle.documentDestroys || 0,
        workerDestroys: runtimeLifecycle.workerDestroys || 0,
      };
      await runtimeDispose;
      await runtimeDrainController.ready;
      globalThis.Worker = NativeWorker;
      return {
        counters,
        placeholderCanvasCount,
        canvasSizes,
        documentsBeforeReveal,
        cancellation,
        forced,
        forcedCanvasCountAfterRestore,
        workerPorts,
        blockedReady,
        reportedError,
        rejectedError,
        priority,
        loading: {
          ...loading,
          cancelled: loadingCancelled,
          bodyCalled: loadingBodyCalled,
          users: loadingUsers,
        },
        providerDestroyed,
        queueLifecycle,
        serviceLifecycle,
        retirementLifecycle: {
          ...retirementLifecycle,
          retirementError,
        },
        runtimeLifecycle,
        displaySizes,
      };

      function displayPixelSize(width, height, devicePixelRatio = 1) {
        return visiblePixelSize({
          getBoundingClientRect: () => ({ width, height }),
        }, { devicePixelRatio }, 16 * 1024 * 1024);
      }

      function fakePdfjs(values, neverComplete, cancellationDelay = 0) {
        return {
          GlobalWorkerOptions: {},
          AnnotationMode: { DISABLE: 0 },
          PDFWorker: class {
            constructor() {
              values.workers += 1;
            }

            destroy() {
              values.workerDestroys = (values.workerDestroys || 0) + 1;
            }
          },
          getDocument({ url }) {
            values.documents = (values.documents || 0) + 1;
            const page = new Proxy({
              getViewport({ scale }) {
                return {
                  width: 100 * scale,
                  height: 50 * scale,
                  convertToViewportRectangle([left, bottom, right, top]) {
                    return [
                      left * scale,
                      (50 - top) * scale,
                      right * scale,
                      (50 - bottom) * scale,
                    ];
                  },
                };
              },
              render({ transform, annotationMode }) {
                values.order?.push(url);
                values.renders += 1;
                (values.transforms ||= []).push(transform.join(","));
                (values.annotationModes ||= []).push(annotationMode);
                values.active = (values.active || 0) + 1;
                values.maximumActive = Math.max(
                  values.maximumActive || 0,
                  values.active,
                );
                let settled = false;
                let rejectRender;
                let timer;
                const promise = new Promise((resolve, reject) => {
                  rejectRender = reject;
                  if (!neverComplete) {
                    timer = setTimeout(() => {
                      settled = true;
                      values.active -= 1;
                      resolve();
                    }, 20);
                  }
                });
                return {
                  promise,
                  cancel() {
                    if (settled) return;
                    settled = true;
                    clearTimeout(timer);
                    values.cancelled = (values.cancelled || 0) + 1;
                    values.cancelRequested = true;
                    const finish = () => {
                      values.active -= 1;
                      values.cancelFinished = true;
                      const error = new Error("cancelled");
                      error.name = "RenderingCancelledException";
                      rejectRender(error);
                    };
                    if (cancellationDelay > 0) setTimeout(finish, cancellationDelay);
                    else finish();
                  },
                };
              },
              async getTextContent() {
                values.text = (values.text || 0) + 1;
                return { items: [], styles: {} };
              },
              async getAnnotations() {
                values.annotations = (values.annotations || 0) + 1;
                return [];
              },
            }, {
              get(target, property, receiver) {
                if (property === "_pageInfo") {
                  throw new Error("PDF.js private page metadata was accessed");
                }
                return Reflect.get(target, property, receiver);
              },
            });
            return {
              promise: Promise.resolve({
                getPage() {
                  values.pages = (values.pages || 0) + 1;
                  return Promise.resolve(page);
                },
              }),
              async destroy() {
                values.documentDestroys = (values.documentDestroys || 0) + 1;
              },
            };
          },
        };
      }

      function lifecyclePdfjs(values) {
        return {
          GlobalWorkerOptions: {},
          PDFWorker: class {
            constructor() {
              values.workers += 1;
            }

            destroy() {
              values.workerDestroys += 1;
            }
          },
          getDocument() {
            values.documents += 1;
            return {
              promise: Promise.resolve({
                getPage() {
                  return Promise.resolve({});
                },
              }),
              async destroy() {
                values.documentDestroys += 1;
              },
            };
          },
        };
      }

      function pendingPdfjs(values) {
        return {
          GlobalWorkerOptions: {},
          PDFWorker: class {
            constructor() {
              values.workers += 1;
            }

            destroy() {
              values.workerDestroys = (values.workerDestroys || 0) + 1;
            }
          },
          getDocument() {
            values.documents += 1;
            return {
              promise: new Promise(() => {}),
              async destroy() {
                values.destroys += 1;
              },
            };
          },
        };
      }

      function retirementPdfjs(values) {
        return {
          GlobalWorkerOptions: {},
          PDFWorker: class {
            constructor() {
              values.workers += 1;
            }

            destroy() {
              values.workerDestroys += 1;
            }
          },
          getDocument({ url }) {
            values.documents += 1;
            const promise = url === "failed.pdf"
              ? Promise.reject(new Error("retirement failure"))
              : Promise.resolve({
                getPage() {
                  return Promise.resolve({});
                },
              });
            return {
              promise,
              destroy() {
                values.destroyStarted.push(url);
                if (url === "failed.pdf" || url === "retired-0.pdf") {
                  return new Promise((resolve) => {
                    values.releases.push(() => {
                      values.destroyFinished.push(url);
                      resolve();
                    });
                  });
                }
                values.destroyFinished.push(url);
                return Promise.resolve();
              },
            };
          },
        };
      }

      function pdfPlacement(
        source,
        top,
        viewBox = "10,5,90,45",
        width = 100,
        height = 50,
      ) {
        const container = document.createElement("div");
        container.className = "ss-pdf";
        container.dataset.pdfSrc = source;
        container.dataset.page = "1";
        container.dataset.viewBox = viewBox;
        container.dataset.rotation = "0";
        container.dataset.canvasBackground = "transparent";
        container.dataset.copyAnnotations = "false";
        container.style.cssText =
          "position:absolute;left:10px;top:" + top +
          "px;width:" + width + "px;height:" + height + "px;overflow:hidden";
        container.innerHTML =
          "<div class=\"ss-pdf-layer ss-pdf-text\"></div>" +
          "<div class=\"ss-pdf-layer ss-pdf-annotations\"></div>";
        return container;
      }

      async function waitFor(predicate) {
        const deadline = performance.now() + 5000;
        while (!predicate()) {
          if (performance.now() > deadline) throw new Error("timed out");
          await new Promise((resolve) => setTimeout(resolve, 10));
        }
      }

      function observeAbort(signal, body) {
        return new Promise((resolve) => {
          const observe = () => {
            body();
            resolve();
          };
          if (signal.aborted) observe();
          else signal.addEventListener("abort", observe, { once: true });
        });
      }
    });

    assert.equal(result.counters.documents, 2, "PDF documents were not shared by source");
    assert.equal(result.placeholderCanvasCount, 0,
      "PDF placements exposed an empty canvas before rendering");
    assert.equal(result.counters.pages, 2, "PDF pages were not shared by source and page");
    assert.equal(result.counters.workers, 1, "PDF.js worker was not shared");
    assert.equal(result.counters.renders, 5, "a PDF placement was omitted or rendered twice");
    assert.equal(result.counters.maximumActive, 2, "PDF rendering ignored its concurrency limit");
    assert.equal(new Set(result.counters.transforms).size, 4,
      "shared PDF pages reused one placement's crop transform");
    assert(result.counters.annotationModes.every((value) => value === 0),
      "PDF annotations were painted into the canvas layer");
    assert.equal(result.counters.text, 0, "canvas-only rendering created a text layer");
    assert.equal(result.counters.annotations, 0, "canvas-only rendering created annotations");
    assert.equal(result.documentsBeforeReveal, 1, "hidden PDF was loaded before it became visible");
    assert.equal(result.forcedCanvasCountAfterRestore, 0,
      "print cleanup restored an empty PDF canvas");
    assert.deepEqual(
      result.canvasSizes,
      [
        ...Array.from({ length: 3 }, () => ({ width: 200, height: 100 })),
        { width: 2400, height: 1800 },
      ],
      "canvas resolution did not follow visible size and device pixel ratio",
    );
    assert.deepEqual(result.displaySizes, {
      fourK: { width: 3840, height: 2160 },
      fiveKRetina: { width: 5120, height: 2880 },
      sixK: { width: 5461, height: 3072 },
    }, "PDF canvas resolution did not preserve 4K and 5K output before applying its memory limit");
    assert.equal(result.cancellation.cancelled, 1, "disposing a surface did not cancel its render task");
    assert.equal(result.forced.cancelled, 0,
      "offscreen visibility cancelled an explicit all-page render");
    assert.equal(result.forced.renders, 1,
      "explicit all-page rendering omitted an offscreen PDF placement");
    assert.equal(result.forced.workerDestroys, 1,
      "the all-page rendering worker was not disposed");
    assert.equal(result.blockedReady, true,
      "disposing a surface remained blocked on stale resource resolution");
    assert.equal(result.reportedError, "broken PDF resource",
      "PDF rendering errors were not reported to the host UI");
    assert.equal(result.rejectedError, "broken PDF resource",
      "initial PDF rendering errors were silently accepted");
    assert.equal(result.cancellation.workers, 1, "a PDF runtime created redundant workers");
    assert.equal(result.counters.workerDestroys, 1, "the shared PDF.js worker was not disposed");
    assert.equal(result.cancellation.workerDestroys, 1, "a secondary PDF.js worker was not disposed");
    assert.deepEqual(result.priority.order, ["main.pdf", "thumbnail.pdf"],
      "thumbnail work delayed the central preview during the same render batch");
    assert.equal(result.priority.workerDestroys, 1,
      "the priority-test worker was not disposed");
    assert.equal(result.loading.cancelled, true,
      "cancelling a surface remained blocked on PDF document loading");
    assert.equal(result.loading.bodyCalled, false,
      "cancelled document loading invoked the placement body");
    assert.equal(result.loading.users, 0,
      "cancelled document loading retained an active cache user");
    assert.equal(result.loading.destroys, 1,
      "disposing a service did not destroy its pending PDF document");
    assert.equal(result.loading.workerDestroys, 1,
      "disposing a pending document did not destroy its PDF.js worker");
    assert.equal(result.providerDestroyed, true,
      "service disposal remained blocked on PDF.js provider initialization");
    assert.equal(result.queueLifecycle.abortObserved, true,
      "closing the render queue did not cancel an active body");
    assert.equal(result.queueLifecycle.closeResolvedBeforeCleanup, false,
      "the render queue closed before its active body finished cleanup");
    assert.equal(result.queueLifecycle.bodyFinished, true,
      "the render queue omitted active-body cleanup");
    assert.equal(result.serviceLifecycle.abortObserved, true,
      "service disposal did not cancel its active queue body");
    assert.deepEqual(result.serviceLifecycle.beforeCleanup, {
      destroyResolved: false,
      documentDestroys: 1,
      workerDestroys: 0,
      terminatedPorts: 0,
    }, "service disposal released its worker before the active body drained");
    assert.equal(result.serviceLifecycle.bodyFinished, true,
      "service disposal omitted active-body cleanup");
    assert.equal(result.serviceLifecycle.documentDestroys, 1,
      "service disposal did not destroy its document after draining");
    assert.equal(result.serviceLifecycle.workerDestroys, 1,
      "service disposal did not destroy its worker after draining");
    assert.equal(result.retirementLifecycle.retirementError, "retirement failure",
      "failed PDF document loading did not propagate its error");
    assert.deepEqual(result.retirementLifecycle.beforeRelease, {
      destroyResolved: false,
      destroyStarted: 10,
      destroyFinished: 8,
      workerDestroys: 0,
      terminatedPorts: 0,
    }, "service disposal ignored an in-progress failed or evicted document retirement");
    assert.equal(result.retirementLifecycle.destroyFinished.length, 10,
      "service disposal omitted a failed or evicted document retirement");
    assert.equal(result.retirementLifecycle.workerDestroys, 1,
      "service disposal did not wait for retired documents before destroying its worker");
    assert.deepEqual(result.runtimeLifecycle.beforeCancellationFinished, {
      disposeResolved: false,
      documentDestroys: 1,
      workerDestroys: 0,
    }, "runtime disposal released its worker before active rendering stopped");
    assert.equal(result.runtimeLifecycle.cancelFinished, true,
      "runtime disposal returned before PDF render cancellation finished");
    assert.equal(result.runtimeLifecycle.documentDestroys, 1,
      "runtime disposal omitted document destruction after draining");
    assert.equal(result.runtimeLifecycle.workerDestroys, 1,
      "runtime disposal omitted worker destruction after draining");
    assert.deepEqual(result.workerPorts, { created: 8, terminated: 8 },
      "PDF worker ports were not owned and released by the runtime");
  } finally {
    await page.close();
  }
});
