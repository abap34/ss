import { element, setAttributes, svgElement } from "./dom.js";
import { formatNumber, previewFrame } from "./geometry.js";

export function renderObjectSheet(state, object, actions) {
  const page = state.snapshot.layout.pages.find((candidate) =>
    candidate.id === object.page_id
  );
  const frame = previewFrame(page, object);
  const sheet = element("section", "object-sheet");
  sheet.setAttribute("aria-label", "Object details");
  sheet.append(
    heading(object, actions),
    bounds(frame),
    relations(state, object),
    actionArea(state, object),
  );
  return sheet;
}

function heading(object, actions) {
  const container = element("div", "sheet-heading");
  const title = element("div");
  const eyebrow = element("small");
  eyebrow.textContent = "Selected object";
  const name = element("strong");
  name.textContent = object.role || object.name || `Object ${object.id}`;
  title.append(eyebrow, name);
  const close = element("button", "close-button");
  close.type = "button";
  close.textContent = "×";
  close.setAttribute("aria-label", "Close details");
  close.addEventListener("click", actions.close);
  container.append(title, close);
  if (object.location?.path) {
    container.append(sourceButton(object, actions.revealSource));
  }
  return container;
}

function bounds(frame) {
  const container = element("div", "bounds");
  container.append(
    bound("X", frame.x),
    bound("Y", frame.y),
    bound("W", frame.width),
    bound("H", frame.height),
  );
  return container;
}

function relations(state, object) {
  const container = element("div", "relation-details");
  const title = element("h2");
  title.textContent = "Constraints";
  container.append(title);
  const values = state.snapshot.layout.relations.filter((relation) =>
    relation.target?.node_id === object.id
  );
  if (values.length === 0) {
    const automatic = element("p", "automatic-layout");
    automatic.textContent = "Positioned by automatic layout";
    container.append(automatic);
    return container;
  }
  const page = state.snapshot.layout.pages.find((candidate) =>
    candidate.id === object.page_id
  );
  for (const relation of values) container.append(relationRow(relation, page));
  return container;
}

function relationRow(relation, page) {
  const row = element("div", "relation-row");
  const constraintKind = relation.source.type === "page"
    ? "absolute"
    : "relative";
  const icon = element("i", `relation-icon relation-icon--${constraintKind}`);
  icon.title = constraintKind === "absolute"
    ? "Absolute constraint"
    : "Relative constraint";
  icon.setAttribute("aria-label", icon.title);
  if (constraintKind === "absolute") setPageIconRatio(icon, page);
  const expression = element("code");
  expression.textContent = relation.expression;
  row.append(icon, expression);
  return row;
}

function setPageIconRatio(icon, page) {
  const ratio = page?.width > 0 && page?.height > 0
    ? page.width / page.height
    : 16 / 9;
  const width = Math.min(20, 11 * ratio);
  const height = width / ratio;
  icon.style.setProperty("--page-width", `${width}px`);
  icon.style.setProperty("--page-height", `${height}px`);
  icon.style.setProperty("--page-left", `${(22 - width) / 2}px`);
  icon.style.setProperty(
    "--arrow-width",
    `${Math.min(width, Math.max(1.5, width * 0.74))}px`,
  );
}

function actionArea(state, object) {
  const container = element("div", "sheet-actions");
  const editable = isMovable(state, object.id);
  const moveState = element("span", editable ? "movable" : "locked");
  moveState.textContent = editable
    ? "Drag to edit · Shift keeps relations"
    : "Generated position";
  container.append(moveState);
  return container;
}

function sourceButton(object, revealSource) {
  const source = element("button", "source-button");
  source.type = "button";
  source.append(editorIcon(), document.createTextNode("Open in Editor"));
  source.addEventListener("click", () => revealSource(object));
  return source;
}

function editorIcon() {
  const icon = svgElement("svg", "source-icon");
  setAttributes(icon, {
    viewBox: "0 0 16 16",
    fill: "none",
    "aria-hidden": "true",
  });
  const path = svgElement("path");
  setAttributes(path, {
    d: "M5.25 3.75 2.5 8l2.75 4.25M10.75 3.75 13.5 8l-2.75 4.25M9.25 2.5l-2.5 11",
    stroke: "currentColor",
    "stroke-width": "1.35",
    "stroke-linecap": "round",
    "stroke-linejoin": "round",
  });
  icon.append(path);
  return icon;
}

function bound(label, value) {
  const node = element("span");
  const key = element("small");
  key.textContent = label;
  node.append(key, document.createTextNode(formatNumber(value)));
  return node;
}

function isMovable(state, nodeId) {
  return Boolean(
    !state.snapshot?.stale &&
      state.snapshot?.editing.some((target) => target.node_id === nodeId),
  );
}
