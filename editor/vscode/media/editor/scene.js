import { element, setAttributes, svgElement } from "./dom.js";
import {
  anchorSegment,
  constraintGeometry,
  frameByNode,
  signed,
} from "./geometry.js";
import { renderPdfItems } from "./pdf.js";

const templates = new WeakMap();

export function renderScene(snapshot, pageId, thumbnail = false) {
  const scene = element("div", thumbnail ? "thumbnail-scene" : "scene");
  if (thumbnail) scene.setAttribute("aria-hidden", "true");
  const page = pageTemplate(snapshot, pageId);
  if (!page) return scene;
  const clone = page.cloneNode(true);
  clone.classList.add("scene-page");
  if (thumbnail) {
    clone.querySelectorAll(".ss-semantic-layer, .ss-link, .ss-destination").forEach((node) => node.remove());
    const layout = snapshot.layout.pages.find((candidate) =>
      candidate.id === pageId
    );
    if (layout) scene.style.setProperty("--scene-scale", String(64 / layout.width));
  }
  scene.append(clone);
  void renderPdfItems(scene).catch((error) => {
    scene.dataset.error = error instanceof Error ? error.message : String(error);
  });
  return scene;
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

export function renderConstraints(snapshot, page, objectId) {
  const group = svgElement("g", "constraint-layer");
  for (
    const relation of snapshot.layout.relations.filter((item) =>
      item.target?.node_id === objectId
    )
  ) {
    const sourceFrame = relation.source.type === "page"
      ? { x: 0, y: 0, width: page.width, height: page.height }
      : frameByNode(snapshot, page, relation.source.node_id);
    const targetFrame = frameByNode(snapshot, page, relation.target.node_id);
    if (!sourceFrame || !targetFrame) continue;
    const sourceSegment = anchorSegment(sourceFrame, relation.source.anchor);
    const targetSegment = anchorSegment(targetFrame, relation.target.anchor);
    const geometry = constraintGeometry(
      sourceSegment,
      targetSegment,
      relation.axis,
    );
    const sourceKind = relation.source.type === "page" ? "page" : "object";
    const relationGroup = svgElement(
      "g",
      `constraint constraint--${sourceKind}${
        relation.kind === "fallback" ? " constraint--fallback" : ""
      }`,
    );
    relationGroup.append(
      segmentLine(
        geometry.source,
        "constraint-anchor constraint-anchor--source",
      ),
    );
    relationGroup.append(
      segmentLine(
        geometry.target,
        "constraint-anchor constraint-anchor--target",
      ),
    );
    const connector = svgElement("line", "constraint-connector");
    setAttributes(connector, {
      x1: geometry.connector.x1,
      y1: geometry.connector.y1,
      x2: geometry.connector.x2,
      y2: geometry.connector.y2,
    });
    relationGroup.append(connector);
    const label = svgElement("text", "constraint-offset");
    setAttributes(label, {
      x: geometry.label.x,
      y: geometry.label.y,
    });
    label.textContent = signed(relation.offset);
    relationGroup.append(label);
    group.append(relationGroup);
  }
  return group;
}

function segmentLine(value, className) {
  const line = svgElement("line", className);
  setAttributes(line, value);
  return line;
}
