let rendererModule;
let rendererApi;
let pdfjsModule;
const mounts = new WeakMap();
const activeMounts = new Set();

export async function renderPdfItems(root, options = {}) {
  disposeRoot(root);
  if (!root.querySelector(".ss-pdf")) return;
  const mount = { root, thumbnail: Boolean(options.thumbnail), cancelled: false, controller: null };
  mounts.set(root, mount);
  activeMounts.add(mount);
  root.dataset.ssPdfRenderRoot = "true";

  let reported = false;
  const reportError = (error) => {
    reported = true;
    root.dispatchEvent(new CustomEvent("ss-pdf-error", {
      bubbles: true,
      detail: {
        message: error instanceof Error ? error.message : String(error),
      },
    }));
  };
  try {
    rendererModule ??= import("../../out/render/pdf.js");
    const renderer = await rendererModule;
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
