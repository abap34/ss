import { element, setAttributes, svgElement } from "./dom.js";
import { formatNumber, previewFrame } from "./geometry.js";
import { strokeStyleSelect } from "./shape-style.js";

export function renderObjectSheet(state, object, actions) {
  const page = state.snapshot.layout.pages.find((candidate) =>
    candidate.id === object.page_id
  );
  const frame = previewFrame(page, object);
  const shapeTarget = actions.shape?.styleTarget(object.id);
  const locked = actions.objectLocks?.isLocked(object.id) || false;
  const sheet = element(
    "section",
    `object-sheet${shapeTarget ? " object-sheet--shape" : ""}`,
  );
  sheet.setAttribute("aria-label", "Object details");
  sheet.append(
    closeButton(actions.close),
    heading(object, actions),
    bounds(frame),
    relations(state, object),
  );
  if (shapeTarget) {
    sheet.append(shapeStyleEditor(shapeTarget, actions.shape, locked));
  }
  return sheet;
}

function shapeStyleEditor(target, shape, locked) {
  const disabled = !shape.canEdit(target) || locked;
  const line = target.kind === "line";
  const container = element("div", "shape-style-editor");
  const title = element("h2");
  title.textContent = line ? "Line style" : "Shape style";
  container.append(title);
  const controls = element("div", "shape-style-fields");
  const fields = [];
  const editLine = (stroke, arrowStart = target.arrow_start, arrowEnd = target.arrow_end) =>
    shape.editStyle(target, { stroke, arrowStart, arrowEnd });
  if (!line) {
    fields.push(
      styleCheckbox("Fill", target.fill.enabled, (enabled) => {
        if (!enabled && !target.stroke.enabled) return;
        shape.editStyle(target, {
          fill: { ...target.fill, enabled },
          stroke: { ...target.stroke },
        });
      }),
      styleColor("Fill color", target.fill.color, (color) => {
        shape.editStyle(target, {
          fill: { ...target.fill, color },
          stroke: { ...target.stroke },
        });
      }),
      styleNumber("Opacity", target.fill.opacity, 0, 1, 0.05, (opacity) => {
        shape.editStyle(target, {
          fill: { ...target.fill, opacity },
          stroke: { ...target.stroke },
        });
      }),
      styleCheckbox("Stroke", target.stroke.enabled, (enabled) => {
        if (!enabled && !target.fill.enabled) return;
        shape.editStyle(target, {
          fill: { ...target.fill },
          stroke: { ...target.stroke, enabled },
        });
      }),
    );
  }
  fields.push(
    styleColor(line ? "Line color" : "Stroke color", target.stroke.color, (color) => {
      if (line) editLine({ ...target.stroke, color });
      else shape.editStyle(target, {
        fill: { ...target.fill },
        stroke: { ...target.stroke, color },
      });
    }),
    strokeStyleSelect(target.stroke.style, {
      label: line ? "Style" : "Line",
      ariaLabel: line ? "Line style" : "Shape stroke style",
      disabled,
      change: (style) => {
        if (line) editLine({ ...target.stroke, style });
        else shape.editStyle(target, {
          fill: { ...target.fill },
          stroke: { ...target.stroke, style },
        });
      },
    }),
    styleNumber(line ? "Weight" : "Width", target.stroke.width, 0.1, 24, 0.1, (width) => {
      if (line) editLine({ ...target.stroke, width });
      else shape.editStyle(target, {
        fill: { ...target.fill },
        stroke: { ...target.stroke, width },
      });
    }),
  );
  if (line) {
    fields.push(
      styleCheckbox("Start arrow", target.arrow_start, (enabled) => {
        editLine({ ...target.stroke }, enabled, target.arrow_end);
      }),
      styleCheckbox("End arrow", target.arrow_end, (enabled) => {
        editLine({ ...target.stroke }, target.arrow_start, enabled);
      }),
    );
  }
  controls.append(...fields);
  for (const input of controls.querySelectorAll("input")) {
    input.disabled = disabled;
  }
  if (locked) {
    const notice = element("small", "shape-style-locked");
    notice.textContent = "Unlock the object to edit its style.";
    container.append(notice);
  }
  container.append(controls);
  return container;
}

function styleCheckbox(label, checked, change) {
  const control = element("label", "shape-style-checkbox");
  const input = element("input");
  input.type = "checkbox";
  input.checked = checked;
  input.setAttribute("aria-label", label);
  input.addEventListener("change", () => change(input.checked));
  control.append(input, document.createTextNode(label));
  return control;
}

function styleColor(label, value, change) {
  const control = element("label", "shape-style-color");
  const caption = element("span");
  caption.textContent = label;
  const input = element("input");
  input.type = "color";
  input.value = value;
  input.setAttribute("aria-label", label);
  input.addEventListener("change", () => change(input.value));
  control.append(caption, input);
  return control;
}

function styleNumber(label, value, min, max, step, change) {
  const control = element("label", "shape-style-number");
  const caption = element("span");
  caption.textContent = label;
  const input = element("input");
  input.type = "number";
  input.value = String(value);
  input.min = String(min);
  input.max = String(max);
  input.step = String(step);
  input.setAttribute("aria-label", label);
  input.addEventListener("change", () => {
    const next = Number(input.value);
    if (Number.isFinite(next)) change(Math.min(max, Math.max(min, next)));
  });
  control.append(caption, input);
  return control;
}

function heading(object, actions) {
  const container = element("div", "sheet-heading");
  const title = element("div");
  const eyebrow = element("small");
  eyebrow.textContent = "Selected object";
  const name = element("strong");
  name.textContent = object.role || object.name || `Object ${object.id}`;
  title.append(eyebrow, name);
  container.append(title);
  const actionsContainer = element("div", "sheet-heading-actions");
  if (actions.objectLocks?.canLock(object.id)) {
    actionsContainer.append(objectLockButton(object, actions.objectLocks));
  }
  if (object.location?.path) {
    actionsContainer.append(sourceButton(object, actions.revealSource));
  }
  if (actionsContainer.childElementCount > 0) container.append(actionsContainer);
  return container;
}

function objectLockButton(object, objectLocks) {
  const locked = objectLocks.isLocked(object.id);
  const button = element(
    "button",
    `object-lock-button${locked ? " is-locked" : ""}`,
  );
  button.type = "button";
  button.setAttribute("aria-pressed", String(locked));
  button.setAttribute("aria-label", locked ? "Unlock object" : "Lock object");
  button.append(element("span", "object-lock-icon"));
  const label = element("span");
  label.textContent = locked ? "Unlock" : "Lock";
  button.append(label);
  button.addEventListener("click", () => objectLocks.toggle(object.id));
  return button;
}

function closeButton(closeDetails) {
  const close = element("button", "close-button");
  close.type = "button";
  close.textContent = "×";
  close.setAttribute("aria-label", "Close details");
  close.addEventListener("click", closeDetails);
  return close;
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
  for (const relation of values) {
    container.append(relationRow(relation, page, state.snapshot.entry_path));
  }
  return container;
}

function relationRow(relation, page, entryPath) {
  const fallback = relation.kind === "fallback";
  const row = element(
    "div",
    `relation-row${fallback ? " relation-row--fallback" : ""}`,
  );
  const constraintKind = relation.source.type === "page"
    ? "absolute"
    : "relative";
  const icon = element("i", `relation-icon relation-icon--${constraintKind}`);
  icon.title = constraintKind === "absolute"
    ? "Absolute constraint"
    : "Relative constraint";
  icon.setAttribute("aria-label", icon.title);
  if (constraintKind === "absolute") setPageIconRatio(icon, page);
  const copy = element("div", "relation-copy");
  const expression = element("code");
  expression.textContent = relation.expression;
  copy.append(expression);
  if (relation.location?.path) {
    const source = element("small", "relation-source");
    source.textContent = sourceLabel(relation.location, entryPath);
    source.title = `${relation.location.path}:${relation.location.line}:${relation.location.column}`;
    copy.append(source);
  }
  row.append(icon, copy);
  if (fallback) {
    const badge = element("small", "relation-kind");
    badge.textContent = "Fallback";
    row.append(badge);
  }
  return row;
}

function sourceLabel(location, entryPath) {
  const normalizedPath = location.path.replaceAll("\\", "/");
  const normalizedEntry = (entryPath || "").replaceAll("\\", "/");
  const directoryEnd = normalizedEntry.lastIndexOf("/");
  const directory = directoryEnd >= 0
    ? normalizedEntry.slice(0, directoryEnd + 1)
    : "";
  const displayPath = directory && normalizedPath.startsWith(directory)
    ? normalizedPath.slice(directory.length)
    : normalizedPath.split("/").pop() || normalizedPath;
  return `${displayPath}:${location.line}`;
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

export function sourceButton(object, revealSource) {
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
