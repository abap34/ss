import { element } from "./dom.js";
import { renderPdfItems } from "./pdf.js";

const templates = new WeakMap();

export function renderPage(snapshot, pageId, thumbnail = false) {
  const preview = element("div", thumbnail ? "thumbnail-preview" : "preview");
  if (thumbnail) preview.setAttribute("aria-hidden", "true");
  const page = pageTemplate(snapshot, pageId);
  if (!page) return preview;
  const clone = page.cloneNode(true);
  clone.classList.add("preview-page");
  if (thumbnail) {
    clone.querySelectorAll(".ss-semantic-layer, .ss-link, .ss-destination").forEach((node) => node.remove());
    const layout = snapshot.layout.pages.find((candidate) =>
      candidate.id === pageId
    );
    if (layout) preview.style.setProperty("--preview-scale", String(64 / layout.width));
  }
  preview.append(clone);
  void renderPdfItems(preview).catch((error) => {
    preview.dataset.error = error instanceof Error ? error.message : String(error);
  });
  return preview;
}

function pageTemplate(snapshot, pageId) {
  if (!snapshot?.display?.html) return null;
  let template = templates.get(snapshot);
  if (!template) {
    template = document.createElement("template");
    template.innerHTML = snapshot.display.html;
    templates.set(snapshot, template);
  }
  return [...template.content.querySelectorAll(".ss-page")].find((page) =>
    Number(page.dataset.ssPageId) === pageId
  ) || null;
}
