import { element } from "./dom.js";
import { formatNumber, previewFrame } from "./geometry.js";
import { toolIcon } from "./tool-icons.js";
import { strokeStyleSelect } from "./shape-style.js";

export function renderObjectSheet(state, object, actions) {
  const selectionKey = `${state.snapshot.entry_path}:${object.id}`;
  if (state.objectSheetSelection !== selectionKey) {
    state.objectSheetSelection = selectionKey;
    state.objectSheetSections = {};
  }
  const page = state.snapshot.layout.pages.find((candidate) =>
    candidate.id === object.page_id
  );
  const baseFrame = actions.translation?.frame(page, object) ||
    previewFrame(page, object);
  const frame = actions.componentWidth?.frame(page, object, baseFrame) || baseFrame;
  const shapeTarget = actions.shape?.styleTarget(object.id);
  const locked = actions.objectLocks?.isLocked(object.id) || false;
  const minimumWidth = actions.componentWidth?.minimum(object.id);
  const sheet = element("section", "object-sheet");
  sheet.dataset.objectId = String(object.id);
  sheet.setAttribute("aria-label", `Actions for ${object.name || `Object ${object.id}`}`);
  const widthEdit = !shapeTarget && minimumWidth != null
    ? {
      disabled: locked,
      minimum: minimumWidth,
      maximum: Math.max(
        minimumWidth,
        page.width - frame.x,
      ),
      change: (width) => actions.componentWidth.submit({
        nodeId: object.id,
        pageId: object.page_id,
        fromBounds: frame,
        toBounds: { ...frame, width },
      }),
    }
    : null;
  const sections = [
    detailSection(
      state, object, "bounds", "Position & size",
      bounds(frame, widthEdit), actions.detailsChanged,
    ),
    detailSection(
      state, object, "constraints", "Constraints",
      relations(state, object), actions.detailsChanged,
    ),
  ];
  if (shapeTarget) {
    sections.push(detailSection(
      state, object, "style", "Style",
      shapeStyleEditor(shapeTarget, actions.shape, locked), actions.detailsChanged,
    ));
  }
  sheet.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    const open = sections.find(({ panel }) => !panel.hidden);
    if (!open) return;
    event.preventDefault();
    event.stopPropagation();
    open.button.click();
    open.button.focus();
  });
  sheet.append(
    heading(object, actions, sections.map((section) => section.button)),
    ...sections.map((section) => section.panel),
  );
  return sheet;
}

export function syncObjectSheetLocks(sheet, objectLocks) {
  const locked = objectLocks.isLocked(Number(sheet.dataset.objectId));
  const button = sheet.querySelector(".object-lock-button");
  if (button) updateObjectLockButton(button, locked);
  for (const control of sheet.querySelectorAll("[data-lock-editable]")) {
    control.disabled = locked || control.dataset.lockEditable !== "true";
  }
  const notice = sheet.querySelector(".shape-style-locked");
  if (notice) notice.hidden = !locked;
}

function detailSection(state, object, key, label, content, changed) {
  const sections = state.objectSheetSections ??= {};
  const panel = element("div", "sheet-panel");
  panel.id = `object-${object.id}-${key}`;
  panel.hidden = !sections[key];
  const header = element("div", "sheet-panel-heading");
  const title = element("strong");
  title.textContent = label;
  header.append(title);
  panel.append(header, content);
  const button = iconButton(label, toolIcon(key), "sheet-toggle");
  button.setAttribute("aria-controls", panel.id);
  button.setAttribute("aria-expanded", String(!panel.hidden));
  const setOpen = (open) => {
    sections[key] = open;
    panel.hidden = !open;
    button.setAttribute("aria-expanded", String(open));
  };
  const close = iconButton("Close details", toolIcon("close"), "close-button");
  close.addEventListener("click", () => {
    setOpen(false);
    button.focus();
    changed?.();
  });
  header.append(close);
  button.addEventListener("click", () => {
    const open = panel.hidden;
    const sheet = button.closest(".object-sheet");
    for (const other of sheet.querySelectorAll('.sheet-toggle[aria-expanded="true"]')) {
      if (other !== button) other.click();
    }
    setOpen(open);
    changed?.();
  });
  return { button, panel };
}

function shapeStyleEditor(target, shape, locked) {
  const editable = shape.canEdit(target);
  const disabled = !editable || locked;
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
  for (const control of controls.querySelectorAll("input, select")) {
    control.dataset.lockEditable = String(editable);
    control.disabled = disabled;
  }
  const notice = element("small", "shape-style-locked");
  notice.textContent = "Unlock the object to edit its style.";
  notice.hidden = !locked;
  container.append(notice);
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

function heading(object, actions, buttons) {
  const container = element("div", "sheet-heading");
  container.setAttribute("role", "toolbar");
  container.setAttribute("aria-label", `Actions for ${object.name || `Object ${object.id}`}`);
  if (object.location?.path) {
    const source = iconButton("Open in Editor", toolIcon("source"), "sheet-source-button");
    source.addEventListener("click", () => actions.revealSource(object));
    container.append(source);
  }
  if (actions.objectLocks?.canLock(object.id)) {
    container.append(objectLockButton(object, actions.objectLocks));
  }
  // Constraints precede dimensions, matching the layout editing workflow.
  container.append(buttons[1], buttons[0], ...buttons.slice(2));
  return container;
}

function iconButton(label, icon, className) {
  const button = element("button", `sheet-action ${className}`);
  button.type = "button";
  button.title = label;
  button.setAttribute("aria-label", label);
  button.append(icon);
  return button;
}

function objectLockButton(object, objectLocks) {
  const button = element("button", "sheet-action object-lock-button");
  button.type = "button";
  updateObjectLockButton(button, objectLocks.isLocked(object.id));
  button.addEventListener("click", () => objectLocks.toggle(object.id));
  return button;
}

function updateObjectLockButton(button, locked) {
  if (button.getAttribute("aria-pressed") === String(locked)) return;
  button.title = locked ? "Unlock object" : "Lock object";
  button.setAttribute("aria-label", button.title);
  button.setAttribute("aria-pressed", String(locked));
  button.classList.toggle("is-locked", locked);
  button.replaceChildren(toolIcon(locked ? "lock" : "unlock"));
}

function bounds(frame, widthEdit) {
  const container = element("div", "bounds");
  container.append(
    bound("X", frame.x),
    bound("Y", frame.y),
    widthEdit
      ? editableBound(
        "W",
        frame.width,
        widthEdit.minimum,
        widthEdit.maximum,
        widthEdit,
      )
      : bound("W", frame.width),
    bound("H", frame.height),
  );
  return container;
}

function editableBound(label, value, minimum, maximum, edit) {
  const node = element("label", "bound-edit");
  const key = element("small");
  key.textContent = label;
  const input = element("input");
  input.type = "number";
  input.value = formatNumber(value);
  input.min = String(minimum);
  input.max = String(maximum);
  input.step = "1";
  input.dataset.lockEditable = "true";
  input.disabled = edit.disabled;
  input.setAttribute("aria-label", "Component width");
  input.addEventListener("change", () => {
    const next = Number(input.value);
    if (!Number.isFinite(next)) return;
    edit.change(Math.min(maximum, Math.max(minimum, next)));
  });
  node.append(key, input);
  return node;
}

function relations(state, object) {
  const container = element("div", "relation-details");
  const heading = element("div", "relation-heading");
  const title = element("h2");
  title.textContent = "Constraints";
  const mode = element("span", "relative-adjustment-status");
  mode.setAttribute("role", "status");
  const key = element("kbd");
  key.textContent = "⇧";
  mode.append(key, document.createTextNode("Adjusting"));
  mode.title = "Shift: adjust constraint offsets";
  heading.append(title, mode);
  container.append(heading);
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
  const icon = toolIcon("source");
  icon.classList.add("source-icon");
  return icon;
}

function bound(label, value) {
  const node = element("span");
  const key = element("small");
  key.textContent = label;
  node.append(key, document.createTextNode(formatNumber(value)));
  return node;
}
