let rendererModule;
let rendererApi;
let pdfjsModule;
const mounts = new WeakMap();
const activeMounts = new Set();

export async function renderPdfItems(root, options = {}, origin = {}) {
  disposeRoot(root);
  if (!root.querySelector(".ss-pdf")) return;
  const mount = { root, thumbnail: Boolean(options.thumbnail), cancelled: false, controller: null };
  mounts.set(root, mount);
  activeMounts.add(mount);
  root.dataset.ssPdfRenderRoot = "true";
  const initialStructure = pdfStructure(root);
  const templateStructure = origin.template ? pdfStructure(origin.template) : null;
  let rendererSource = new URL("../../out/render/pdf.js", import.meta.url).href;

  let reported = false;
  const reportError = (error, container) => {
    if (mount.cancelled || mounts.get(root) !== mount) return;
    reported = true;
    root.dispatchEvent(new CustomEvent("ss-pdf-error", {
      bubbles: true,
      detail: {
        message: error instanceof Error ? error.message : String(error),
        diagnostics: {
          snapshotId: origin.snapshotId ?? null,
          thumbnail: mount.thumbnail,
          textLayer: options.textLayer ?? true,
          annotationLayer: options.annotationLayer ?? true,
          rendererSource,
          stack: error instanceof Error ? error.stack : null,
          template: templateStructure,
          beforeMount: initialStructure,
          atError: pdfStructure(container || root),
          rootContainsPlacement: container ? root.contains(container) : null,
        },
      },
    }));
  };
  try {
    rendererModule ??= import("../../out/render/pdf.js");
    const renderer = await rendererModule;
    rendererSource = renderer.pdfRuntimeSource ?? rendererSource;
    if (mount.cancelled) return;
    rendererApi = renderer;
    const worker = new URL("../../out/pdfjs/pdf.worker.mjs", import.meta.url).href;
    const loadPdfjs = () => {
      pdfjsModule ??= import("../../out/pdfjs/pdf.mjs");
      return pdfjsModule;
    };
    mount.controller = renderer.mountPdfPages(root, loadPdfjs, worker, {
      cacheRaster: true,
      visibilityRoot: root.closest(options.thumbnail ? ".sidebar" : ".viewport"),
      prefetchScreens: options.thumbnail ? 0 : 2,
      ...options,
      onError: reportError,
    });
    await mount.controller.ready;
  } catch (error) {
    if (mount.cancelled) return;
    if (!reported) reportError(error);
    disposeRoot(root);
    throw error;
  }
}

function pdfStructure(root) {
  const placements = root.matches?.(".ss-pdf")
    ? [root] : [...root.querySelectorAll(".ss-pdf")];
  return placements.map((container) => ({
    tag: container.localName,
    classes: container.getAttribute("class") || "",
    pageId: container.closest(".ss-page")?.dataset.ssPageId ?? null,
    itemId: container.dataset.ssItemId ?? null,
    nodeId: container.dataset.ssNodeId ?? null,
    pdfPage: container.dataset.page ?? null,
    connected: container.isConnected,
    children: [...container.children].map((child) => ({
      tag: child.localName,
      classes: child.getAttribute("class") || "",
    })),
    textLayers: container.querySelectorAll(":scope > .ss-pdf-text").length,
    annotationLayers: container.querySelectorAll(":scope > .ss-pdf-annotations").length,
  }));
}

// Cached previews can move into a replacement viewport during a UI update.
export function refreshPdfItems(root) {
  queueMicrotask(() => {
    const mount = mounts.get(root);
    if (!mount?.controller || mount.cancelled || !root.isConnected) return;
    mount.controller.setVisibilityRoot(root.closest(mount.thumbnail ? ".sidebar" : ".viewport"));
  });
}

export function disposePdfItems(root) {
  disposeRoot(root);
  for (const candidate of root.querySelectorAll?.("[data-ss-pdf-render-root='true']") || []) {
    disposeRoot(candidate);
  }
}

export async function disposePdfRuntime() {
  for (const mount of [...activeMounts]) disposeRoot(mount.root);
  const retiring = rendererApi;
  rendererApi = undefined;
  rendererModule = undefined;
  pdfjsModule = undefined;
  await retiring?.disposePdfRuntime();
}

function disposeRoot(root) {
  const mount = mounts.get(root);
  if (!mount) return;
  mount.cancelled = true;
  mount.controller?.destroy();
  mounts.delete(root);
  activeMounts.delete(mount);
  delete root.dataset.ssPdfRenderRoot;
}
