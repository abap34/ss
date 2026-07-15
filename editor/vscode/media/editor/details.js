import { element } from "./dom.js";
import { formatNumber, previewFrame } from "./geometry.js";

export function renderObjectSheet(state, object, actions) {
  const page = state.snapshot.layout.pages.find((candidate) =>
    candidate.id === object.page_id
  );
  const frame = previewFrame(page, object);
  const sheet = element("section", "object-sheet");
  sheet.setAttribute("aria-label", "Object details");
  sheet.append(
    heading(object, actions.close),
    bounds(frame),
    relations(state, object),
    actionArea(state, object, actions.revealSource),
  );
  return sheet;
}

function heading(object, closeSheet) {
  const container = element("div", "sheet-heading");
  const title = element("div");
  const eyebrow = element("small");
  eyebrow.textContent = "Selected object";
  const name = element("strong");
  name.textContent = object.role || object.name || `Object ${object.id}`;
  title.append(eyebrow, name);
  const close = element("button");
  close.type = "button";
  close.textContent = "×";
  close.setAttribute("aria-label", "Close details");
  close.addEventListener("click", closeSheet);
  container.append(title, close);
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

function actionArea(state, object, revealSource) {
  const actions = element("div", "sheet-actions");
  const editable = isMovable(state, object.id);
  const moveState = element("span", editable ? "movable" : "locked");
  moveState.textContent = editable
    ? "Drag to edit · Shift keeps relations"
    : "Generated position";
  actions.append(moveState);
  if (object.location?.path) {
    const source = element("button");
    source.type = "button";
    source.textContent = "Reveal source";
    source.addEventListener("click", () => revealSource(object));
    actions.append(source);
  }
  return actions;
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
