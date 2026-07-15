import { color, element, setAttributes, svgElement } from "./dom.js";
import {
  anchorSegment,
  constraintGeometry,
  frameByNode,
  signed,
} from "./geometry.js";

export function renderScene(snapshot, pageId, thumbnail = false) {
  const display = snapshot?.display.pages.find((page) =>
    page.page_id === pageId
  );
  const scene = element("div", thumbnail ? "thumbnail-scene" : "scene");
  if (!display) return scene;
  const canvas = element("div", "scene-canvas");
  canvas.style.width = `${display.width}px`;
  canvas.style.height = `${display.height}px`;
  if (thumbnail) canvas.style.transform = `scale(${64 / display.width})`;
  for (const item of display.items) canvas.append(renderItem(item, thumbnail));
  scene.append(canvas);
  return scene;
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

function renderItem(item, thumbnail) {
  let node;
  if (item.type === "fill_rect") {
    node = element("div", "scene-box");
    styleRect(node, item);
    node.style.backgroundColor = color(item.color);
  } else if (item.type === "stroke_line") {
    node = element("div", "scene-line");
    const dx = item.x2 - item.x1;
    const dy = item.y2 - item.y1;
    node.style.left = `${item.x1}px`;
    node.style.top = `${item.y1}px`;
    node.style.width = `${Math.hypot(dx, dy)}px`;
    node.style.height = `${item.line_width}px`;
    node.style.backgroundColor = color(item.color);
    node.style.transform = `rotate(${Math.atan2(dy, dx)}rad)`;
    if (item.dash_on > 0 && item.dash_off > 0) {
      const stroke = color(item.color);
      node.style.background = `repeating-linear-gradient(to right, ${stroke} 0 ${item.dash_on}px, transparent ${item.dash_on}px ${item.dash_on + item.dash_off}px)`;
    }
  } else if (item.type === "rounded_rect") {
    node = element("div", "scene-box");
    styleRect(node, item);
    node.style.borderRadius = `${item.radius}px`;
    if (item.fill) node.style.backgroundColor = color(item.fill);
    if (item.stroke) {
      node.style.border = `${item.line_width}px solid ${color(item.stroke)}`;
    }
  } else if (item.type === "text") {
    node = element("span", "scene-text");
    node.style.left = `${item.x}px`;
    node.style.top = `${item.baseline_y - item.font_size * 0.875}px`;
    node.style.width = `${item.width}px`;
    node.textContent = item.text;
    node.style.color = color(item.color);
    node.style.fontFamily = item.font_family || "sans-serif";
    node.style.fontSize = `${item.font_size}px`;
    node.style.fontWeight = String(item.font_weight);
    node.style.fontStyle = item.font_style || "normal";
    node.style.fontStretch = item.font_stretch || "normal";
    node.style.lineHeight = `${item.font_size}px`;
  } else if (item.type === "raster" || (item.type === "svg" && !item.tint)) {
    node = element("img", "scene-image");
    styleRect(node, item);
    node.src = item.uri || "";
    node.alt = "";
  } else if (item.type === "svg") {
    node = tintedSvg(item);
  } else if (item.type === "math" || item.type === "pdf_page") {
    node = thumbnail ? pdfThumbnail(item) : pdfObject(item);
  } else {
    node = element("div");
  }
  if (item.node_id == null) return node;
  const group = element("div", "scene-node");
  group.dataset.nodeId = String(item.node_id);
  group.append(node);
  return group;
}

function pdfThumbnail(item) {
  const node = element("div", "scene-pdf-placeholder");
  styleRect(node, item);
  return node;
}

function pdfObject(item) {
  const object = element("object", "pdf-resource");
  styleRect(object, item);
  object.setAttribute("data", pdfPageUri(item));
  object.setAttribute("type", "application/pdf");
  object.setAttribute("aria-label", `Embedded PDF page ${item.page_index + 1}`);
  return object;
}

function tintedSvg(item) {
  const image = element("div", "tinted-svg-resource scene-image");
  styleRect(image, item);
  const uri = `url("${item.uri || ""}")`;
  image.style.backgroundColor = color(item.tint);
  image.style.maskImage = uri;
  image.style.webkitMaskImage = uri;
  return image;
}

function styleRect(node, rect) {
  node.style.left = `${rect.x}px`;
  node.style.top = `${rect.y}px`;
  node.style.width = `${rect.width}px`;
  node.style.height = `${rect.height}px`;
}

function pdfPageUri(item) {
  const uri = item.uri || "";
  if (!uri) return uri;
  const separator = uri.includes("#") ? "&" : "#";
  return `${uri}${separator}page=${
    item.page_index + 1
  }&toolbar=0&navpanes=0&scrollbar=0`;
}

function segmentLine(value, className) {
  const line = svgElement("line", className);
  setAttributes(line, value);
  return line;
}
