import { element } from "./dom.js";
import { disposePdfItems, renderPdfItems } from "./pdf.js";

const templates = new WeakMap();
const previews = new WeakMap();

export function renderPage(snapshot, pageId, thumbnail = false) {
  const display = snapshot.display;
  let cached = previews.get(display);
  if (!cached) {
    cached = new Map();
    previews.set(display, cached);
  }
  const key = String(pageId) + ":" + String(thumbnail);
  const existing = cached.get(key);
  if (existing) return existing;

  const preview = element("div", thumbnail ? "thumbnail-preview" : "preview");
  if (thumbnail) preview.setAttribute("aria-hidden", "true");
  const page = pageTemplate(snapshot, pageId);
  if (!page) {
    cached.set(key, preview);
    return preview;
  }
  const clone = page.cloneNode(true);
  clone.classList.add("preview-page");
  applyDisplayTranslations(clone, snapshot.display.translations || []);
  if (thumbnail) {
    clone.querySelectorAll(".ss-semantic-layer, .ss-link, .ss-destination").forEach((node) => node.remove());
    const layout = snapshot.layout.pages.find((candidate) =>
      candidate.id === pageId
    );
    if (layout) preview.style.setProperty("--preview-scale", String(64 / layout.width));
  }
  preview.append(clone);
  cached.set(key, preview);
  void renderPdfItems(preview, {
    thumbnail,
    textLayer: false,
    annotationLayer: false,
  }).catch((error) => {
    preview.dataset.error = error instanceof Error ? error.message : String(error);
  });
  return preview;
}

function applyDisplayTranslations(root, translations) {
  for (const translation of translations) {
    for (
      const item of root.querySelectorAll(
        `[data-ss-node-id="${translation.node_id}"]`,
      )
    ) {
      item.style.translate = `${translation.x}pt ${translation.y}pt`;
      item.dataset.ssBaseTranslationX = String(translation.x);
      item.dataset.ssBaseTranslationY = String(translation.y);
    }
  }
}

export function disposePages(snapshot) {
  const display = snapshot.display;
  const cached = previews.get(display);
  if (cached) {
    for (const preview of cached.values()) disposePdfItems(preview);
    previews.delete(display);
  }
  templates.delete(display);
}

function pageTemplate(snapshot, pageId) {
  if (!snapshot?.display?.html) return null;
  const display = snapshot.display;
  let template = templates.get(display);
  if (!template) {
    template = document.createElement("template");
    template.innerHTML = snapshot.display.html;
    templates.set(display, template);
  }
  return [...template.content.querySelectorAll(".ss-page")].find((page) =>
    Number(page.dataset.ssPageId) === pageId
  ) || null;
}
