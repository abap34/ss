import { color, element, setAttributes, setRect, svgElement } from "./dom.js";
import { anchorSegment, frameByNode, signed } from "./geometry.js";

export function renderScene(snapshot, pageId, thumbnail = false) {
  const display = snapshot?.display.pages.find((page) =>
    page.page_id === pageId
  );
  const svg = svgElement("svg", thumbnail ? "thumbnail-scene" : "scene");
  if (!display) return svg;
  svg.setAttribute("viewBox", `0 0 ${display.width} ${display.height}`);
  svg.setAttribute("preserveAspectRatio", "xMidYMid meet");
  for (const item of display.items) svg.append(renderItem(item, thumbnail));
  return svg;
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
    const sourceKind = relation.source.type === "page" ? "page" : "object";
    const relationGroup = svgElement(
      "g",
      `constraint constraint--${sourceKind}${
        relation.kind === "fallback" ? " constraint--fallback" : ""
      }`,
    );
    relationGroup.append(
      segmentLine(sourceSegment, "constraint-anchor constraint-anchor--source"),
    );
    relationGroup.append(
      segmentLine(targetSegment, "constraint-anchor constraint-anchor--target"),
    );
    const connector = svgElement("line", "constraint-connector");
    setAttributes(connector, {
      x1: sourceSegment.cx,
      y1: sourceSegment.cy,
      x2: targetSegment.cx,
      y2: targetSegment.cy,
    });
    relationGroup.append(connector);
    const label = svgElement("text", "constraint-offset");
    setAttributes(label, {
      x: (sourceSegment.cx + targetSegment.cx) / 2,
      y: (sourceSegment.cy + targetSegment.cy) / 2 - 7,
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
    node = svgElement("rect");
    setRect(node, item);
    node.setAttribute("fill", color(item.color));
  } else if (item.type === "stroke_line") {
    node = svgElement("line");
    setAttributes(node, { x1: item.x1, y1: item.y1, x2: item.x2, y2: item.y2 });
    node.setAttribute("stroke", color(item.color));
    node.setAttribute("stroke-width", String(item.line_width));
    if (item.dash_on > 0) {
      node.setAttribute("stroke-dasharray", `${item.dash_on} ${item.dash_off}`);
    }
  } else if (item.type === "rounded_rect") {
    node = svgElement("rect");
    setRect(node, item);
    setAttributes(node, { rx: item.radius, ry: item.radius });
    node.setAttribute("fill", item.fill ? color(item.fill) : "none");
    node.setAttribute("stroke", item.stroke ? color(item.stroke) : "none");
    node.setAttribute("stroke-width", String(item.line_width));
  } else if (item.type === "text") {
    node = svgElement("text");
    setAttributes(node, { x: item.x, y: item.baseline_y });
    node.textContent = item.text;
    node.setAttribute("fill", color(item.color));
    node.setAttribute("font-family", item.font_family || "sans-serif");
    node.setAttribute("font-size", String(item.font_size));
    node.setAttribute("font-weight", String(item.font_weight));
    node.setAttribute("font-style", item.font_style || "normal");
    node.setAttribute("font-stretch", item.font_stretch || "normal");
    node.setAttribute("xml:space", "preserve");
  } else if (item.type === "raster" || (item.type === "svg" && !item.tint)) {
    node = svgElement("image");
    setRect(node, item);
    node.setAttribute("href", item.uri || "");
    node.setAttribute("preserveAspectRatio", "none");
  } else if (item.type === "svg") {
    node = tintedSvg(item);
  } else if (item.type === "pdf_page") {
    node = thumbnail ? pdfThumbnail(item) : pdfObject(item);
  } else {
    node = svgElement("g");
  }
  if (item.node_id == null) return node;
  const group = svgElement("g");
  group.dataset.nodeId = String(item.node_id);
  group.append(node);
  return group;
}

function pdfThumbnail(item) {
  const node = svgElement("rect");
  setRect(node, item);
  node.setAttribute("fill", "#eef2ef");
  node.setAttribute("stroke", "#93a59f");
  return node;
}

function pdfObject(item) {
  const node = svgElement("foreignObject");
  setRect(node, item);
  const object = element("object", "pdf-resource");
  object.setAttribute("data", pdfPageUri(item));
  object.setAttribute("type", "application/pdf");
  object.setAttribute("aria-label", `Embedded PDF page ${item.page_index + 1}`);
  node.append(object);
  return node;
}

function tintedSvg(item) {
  const node = svgElement("foreignObject");
  setRect(node, item);
  const image = element("div", "tinted-svg-resource");
  const uri = `url("${item.uri || ""}")`;
  image.style.backgroundColor = color(item.tint);
  image.style.maskImage = uri;
  image.style.webkitMaskImage = uri;
  node.append(image);
  return node;
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
