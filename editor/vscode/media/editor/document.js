import { element } from "./dom.js";
import { disposePdfItems, renderPdfItems } from "./pdf.js";

const templates = new WeakMap();
const previews = new WeakMap();
const displayNodes = new WeakMap();
const translationTolerance = 0.0001;

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
  indexDisplayNodes(display, clone);
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

export function applyDisplayTranslationPatch(display, patches) {
  const touched = new Set();
  if (!display || !Array.isArray(patches) || patches.length === 0) {
    return touched;
  }
  display.translations = composeDisplayTranslations(
    display.translations,
    patches,
  );
  const translations = new Map(
    display.translations.map((item) => [item.node_id, item]),
  );
  for (const patch of patches) {
    touched.add(patch.node_id);
  }

  const indexed = displayNodes.get(display);
  if (!indexed) return touched;
  for (const nodeId of touched) {
    const translation = translations.get(nodeId);
    for (const item of indexed.get(String(nodeId)) || []) {
      setDisplayTranslation(item, translation);
    }
  }
  return touched;
}

export function composeDisplayTranslations(base = [], patches = []) {
  const translations = new Map(
    (Array.isArray(base) ? base : []).map((item) => [
      item.node_id,
      { ...item },
    ]),
  );
  for (const patch of Array.isArray(patches) ? patches : []) {
    const current = translations.get(patch.node_id) || {
      node_id: patch.node_id,
      x: 0,
      y: 0,
    };
    current.x += patch.x;
    current.y += patch.y;
    translations.set(patch.node_id, current);
  }
  return [...translations.values()].filter(hasTranslation);
}

function applyDisplayTranslations(root, translations) {
  const indexed = new Map(
    translations.map((translation) => [
      String(translation.node_id),
      translation,
    ]),
  );
  for (const item of root.querySelectorAll("[data-ss-node-id]")) {
    const translation = indexed.get(item.dataset.ssNodeId);
    if (translation) setDisplayTranslation(item, translation);
  }
}

function setDisplayTranslation(item, translation) {
  if (!hasTranslation(translation)) {
    item.style.removeProperty("translate");
    delete item.dataset.ssBaseTranslationX;
    delete item.dataset.ssBaseTranslationY;
    return;
  }
  item.style.translate = `${translation.x}pt ${translation.y}pt`;
  item.dataset.ssBaseTranslationX = String(translation.x);
  item.dataset.ssBaseTranslationY = String(translation.y);
}

function hasTranslation(item) {
  return item != null &&
    (Math.abs(item.x) >= translationTolerance ||
      Math.abs(item.y) >= translationTolerance);
}

export function disposePages(snapshot) {
  const display = snapshot.display;
  const cached = previews.get(display);
  if (cached) {
    for (const preview of cached.values()) disposePdfItems(preview);
    previews.delete(display);
  }
  templates.delete(display);
  displayNodes.delete(display);
}

function indexDisplayNodes(display, root) {
  let indexed = displayNodes.get(display);
  if (!indexed) {
    indexed = new Map();
    displayNodes.set(display, indexed);
  }
  for (const item of root.querySelectorAll("[data-ss-node-id]")) {
    const nodeId = item.dataset.ssNodeId;
    if (nodeId == null) continue;
    let matches = indexed.get(nodeId);
    if (!matches) {
      matches = new Set();
      indexed.set(nodeId, matches);
    }
    matches.add(item);
  }
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
