import { element } from "./dom.js";
import { renderObjectSheet, sourceButton } from "./details.js";
import { InteractionController } from "./interaction.js";
import { renderPage } from "./document.js";
import { strokeStylePicker } from "./shape-style.js";

const rulerSize = 26;
const rulerInterval = 100;
const minimumRulerTickSpacing = 50;
const viewportMarginRatio = 0.04;
const buildStatusPresentation = {
  starting: { label: "Starting…", icon: "" },
  building: { label: "Building…", icon: "" },
  complete: { label: "Build complete", icon: "✓" },
  failed: { label: "Build failed", icon: "!" },
  unavailable: { label: "Language server unavailable", icon: "×" },
};

export class WorkspaceView {
  constructor(state, actions) {
    this.state = state;
    this.actions = actions;
    this.root = null;
    this.viewport = null;
    this.interaction = new InteractionController(state, {
      ...actions,
    });
  }

  render() {
    this.interaction.reset();
    const main = element("main", "workspace");
    main.append(this.toolbar());
    const viewport = element("div", `viewport viewport--${this.state.mode}`);
    const pages = element("div", "pages-stage");
    if (this.state.snapshot) {
      const visiblePages = this.state.mode === "single"
        ? this.state.snapshot.layout.pages.filter((page) =>
          page.id === this.state.currentPageId
        )
        : this.state.snapshot.layout.pages;
      for (const page of visiblePages) pages.append(this.pageShell(page));
    } else {
      const empty = element("div", "empty-state");
      empty.textContent = emptyPreviewMessage(this.state.buildStatus);
      pages.append(empty);
    }
    viewport.append(pages);
    main.append(viewport);
    const selected = this.selectedObject();
    if (selected) {
      main.append(renderObjectSheet(this.state, selected, {
        close: () => {
          this.state.selectedObjectId = null;
          this.actions.render();
        },
        revealSource: this.actions.revealSource,
        shape: this.actions.shape,
        objectLocks: this.actions.objectLocks,
      }));
    }
    if (this.state.toast) {
      const toast = element(
        "div",
        `toast toast--${this.state.toast.kind}`,
      );
      toast.setAttribute(
        "role",
        this.state.toast.kind === "error" ? "alert" : "status",
      );
      toast.textContent = this.state.toast.message;
      main.append(toast);
    }
    this.root = main;
    this.viewport = viewport;
    return main;
  }

  toolbar() {
    const bar = element("div", "toolbar");
    const mode = element("select", "page-mode");
    mode.setAttribute("aria-label", "Page display");
    mode.append(
      modeOption("single", "Single page", this.state.mode),
      modeOption("continuous", "Continuous", this.state.mode),
    );
    mode.addEventListener("change", () => {
      this.state.mode = mode.value;
      this.actions.render();
    });
    const status = element("div", "build-status");
    status.setAttribute("role", "status");
    status.setAttribute("aria-live", "polite");
    status.setAttribute("aria-atomic", "true");
    applyBuildStatus(
      status,
      this.state.buildStatus,
      this.state.buildDurationMs,
    );
    const tools = element("div", "shape-tools");
    tools.setAttribute("role", "group");
    tools.setAttribute("aria-label", "Drawing tools");
    tools.append(
      this.toolButton("select", "Select", "↖"),
      this.shapePicker(),
    );
    const style = this.shapeStyleControls();
    const stylePopover = this.shapeStylePopover();
    bar.append(mode, tools, style, stylePopover, status);
    return bar;
  }

  toolButton(tool, label, glyph) {
    const button = element("button", "shape-tool");
    button.type = "button";
    button.title = label;
    button.setAttribute("aria-label", label);
    button.setAttribute("aria-pressed", String(this.state.shapeTool === tool));
    button.classList.toggle("is-active", this.state.shapeTool === tool);
    button.textContent = glyph;
    if (tool !== "select") {
      button.disabled = !this.actions.shape.canInsert(this.state.currentPageId);
    }
    button.addEventListener("click", () => this.actions.shape.selectTool(tool));
    return button;
  }

  shapePicker() {
    const choices = [
      ["rectangle", "Rectangle"],
      ["circle", "Circle"],
      ["arrow", "Arrow"],
    ];
    const active = choices.find(([tool]) => this.state.shapeTool === tool);
    const picker = element("details", "shape-picker");
    const summary = element("summary");
    summary.setAttribute("aria-label", active?.[1] || "Shapes");
    summary.setAttribute("aria-pressed", String(Boolean(active)));
    summary.title = active?.[1] || "Shapes";
    const icon = element("span", "shape-picker-summary-icon");
    icon.append(shapePreview(active?.[0] || "rectangle"));
    const label = element("span");
    label.textContent = active?.[1] || "Shapes";
    const chevron = element("span", "shape-picker-chevron");
    chevron.textContent = "⌄";
    summary.append(icon, label, chevron);

    const panel = element("div", "shape-picker-panel");
    const heading = element("strong");
    heading.textContent = "Basic shapes";
    const gallery = element("div", "shape-picker-gallery");
    for (const [tool, name] of choices) {
      const button = element(
        "button",
        `shape-choice${this.state.shapeTool === tool ? " is-active" : ""}`,
      );
      button.type = "button";
      button.disabled = !this.actions.shape.canInsert(this.state.currentPageId);
      button.setAttribute("aria-label", name);
      button.setAttribute("aria-pressed", String(this.state.shapeTool === tool));
      button.append(shapePreview(tool));
      const caption = element("span");
      caption.textContent = name;
      button.append(caption);
      button.addEventListener("click", () => {
        picker.open = false;
        this.actions.shape.selectTool(tool);
      });
      gallery.append(button);
    }
    panel.append(heading, gallery);
    picker.append(summary, panel);
    return picker;
  }

  shapeStyleControls() {
    const group = element("div", "shape-style-controls");
    const draft = this.state.shapeStyle;
    group.append(
      styleToggle("Fill", draft.fill.enabled, (enabled) => {
        this.actions.shape.setDraft({
          ...draft,
          fill: { ...draft.fill, enabled },
        });
      }),
      colorControl("Fill color", draft.fill.color, (color) => {
        this.actions.shape.setDraft({
          ...draft,
          fill: { ...draft.fill, color },
        });
      }),
      numberControl("Fill opacity", draft.fill.opacity, 0, 1, 0.05, (opacity) => {
        this.actions.shape.setDraft({
          ...draft,
          fill: { ...draft.fill, opacity },
        });
      }),
      styleToggle("Stroke", draft.stroke.enabled, (enabled) => {
        this.actions.shape.setDraft({
          ...draft,
          stroke: { ...draft.stroke, enabled },
        });
      }),
      colorControl("Stroke color", draft.stroke.color, (color) => {
        this.actions.shape.setDraft({
          ...draft,
          stroke: { ...draft.stroke, color },
        });
      }),
      strokeStylePicker(draft.stroke.style, {
        ariaLabel: "Stroke style",
        disabled: this.actions.shape.isBusy(),
        change: (style) => {
          this.actions.shape.setDraft({
            ...draft,
            stroke: { ...draft.stroke, style },
          });
        },
      }),
      numberControl("Stroke width", draft.stroke.width, 0.1, 24, 0.1, (width) => {
        this.actions.shape.setDraft({
          ...draft,
          stroke: { ...draft.stroke, width },
        });
      }),
    );
    for (const input of group.querySelectorAll("input")) {
      input.disabled = this.actions.shape.isBusy();
    }
    return group;
  }

  shapeStylePopover() {
    const popover = element("details", "shape-style-popover");
    const summary = element("summary");
    summary.textContent = "Style";
    summary.setAttribute("aria-label", "Shape style");
    const panel = element("div", "shape-style-popover-panel");
    panel.append(this.shapeStyleControls());
    popover.append(summary, panel);
    return popover;
  }

  updateBuildStatus() {
    const status = this.root?.querySelector(".build-status");
    if (!status) return false;
    applyBuildStatus(
      status,
      this.state.buildStatus,
      this.state.buildDurationMs,
    );
    const empty = this.root.querySelector(".empty-state");
    if (empty) empty.textContent = emptyPreviewMessage(this.state.buildStatus);
    return true;
  }

  pageShell(page) {
    const shell = element("article", "page-shell");
    shell.dataset.pageId = String(page.id);
    shell.dataset.pageWidth = String(page.width);
    shell.dataset.pageHeight = String(page.height);
    shell.append(this.ruler("horizontal", page.width));
    shell.append(this.ruler("vertical", page.height));
    const surface = element("div", "page-surface");
    const preview = renderPage(this.state.snapshot, page.id);
    this.actions.translation.applyPreview(preview, page.id);
    surface.append(preview);
    surface.append(this.interaction.renderLayer(page));
    shell.append(surface);
    if (page.location?.path) {
      const open = sourceButton(page, this.actions.revealSource);
      open.classList.add("page-source-button");
      open.title = `Open ${page.name || `Page ${page.index}`} in Editor`;
      open.setAttribute("aria-label", open.title);
      shell.append(open);
    }
    if (this.state.mode === "continuous") {
      const caption = element("div", "page-caption");
      caption.textContent = page.name;
      shell.append(caption);
    }
    return shell;
  }

  ruler(axis, extent) {
    const node = element("div", `ruler ruler--${axis}`);
    node.setAttribute("aria-hidden", "true");
    for (let value = 0; value <= extent; value += rulerInterval) {
      const major = value % (rulerInterval * 2) === 0;
      const tick = element(
        "span",
        `ruler-tick${major ? " ruler-tick--major" : ""}`,
      );
      const percent = `${(value / extent) * 100}%`;
      if (axis === "horizontal") tick.style.left = percent;
      else tick.style.bottom = percent;
      if (value !== 0) {
        const label = element("small");
        label.textContent = String(value);
        tick.append(label);
      }
      node.append(tick);
    }
    return node;
  }

  updateScale() {
    const viewport = this.viewport;
    if (!viewport || !this.state.snapshot) return;
    const shells = [...viewport.querySelectorAll(".page-shell")];
    if (shells.length === 0) return;
    const widths = shells.map((shell) => Number(shell.dataset.pageWidth));
    const heights = shells.map((shell) => Number(shell.dataset.pageHeight));
    const viewportMarginX = viewport.clientWidth * viewportMarginRatio;
    const viewportMarginY = viewport.clientHeight * viewportMarginRatio;
    viewport.style.setProperty("--viewport-margin-x", `${viewportMarginX}px`);
    viewport.style.setProperty("--viewport-margin-y", `${viewportMarginY}px`);
    const horizontalMargin = viewportMarginX * 2;
    const verticalMargin = viewportMarginY * 2;
    const fitScale = (reservedRulerSpace) => {
      const availableWidth = Math.max(
        80,
        viewport.clientWidth - horizontalMargin - reservedRulerSpace,
      );
      const availableHeight = Math.max(
        60,
        viewport.clientHeight - verticalMargin - reservedRulerSpace,
      );
      return this.state.mode === "single"
        ? Math.min(availableWidth / widths[0], availableHeight / heights[0])
        : Math.min(1, availableWidth / Math.max(...widths));
    };
    const scaleWithRulers = fitScale(rulerSize);
    const showRulers = scaleWithRulers * rulerInterval >=
      minimumRulerTickSpacing;
    const scale = showRulers ? scaleWithRulers : fitScale(0);
    viewport.classList.toggle("viewport--rulers-hidden", !showRulers);
    for (const shell of shells) {
      const width = Number(shell.dataset.pageWidth);
      const height = Number(shell.dataset.pageHeight);
      shell.style.setProperty("--page-width", `${width * scale}px`);
      shell.style.setProperty("--page-height", `${height * scale}px`);
      shell.style.setProperty("--preview-scale", String(scale));
    }
  }

  selectedObject() {
    return this.state.snapshot?.layout.objects.find(
      (object) => object.id === this.state.selectedObjectId,
    ) || null;
  }
}

function applyBuildStatus(node, status, durationMs) {
  const presentation = buildStatusPresentation[status] ||
    buildStatusPresentation.starting;
  node.className = `build-status build-status--${status}`;
  node.title = presentation.label;
  const icon = element("span", "build-status-icon");
  icon.setAttribute("aria-hidden", "true");
  icon.textContent = presentation.icon;
  const label = element("span", "build-status-label");
  label.textContent = presentation.label;
  const duration = formatBuildDuration(durationMs);
  if (duration == null) {
    node.replaceChildren(icon, label);
    return;
  }
  const timing = element("span", "build-status-duration");
  timing.textContent = duration;
  timing.title = `Build time: ${duration}`;
  node.replaceChildren(icon, label, timing);
}

export function formatBuildDuration(durationMs) {
  if (!Number.isFinite(durationMs) || durationMs < 0) return null;
  if (durationMs < 1) return "<1 ms";
  if (durationMs < 999.5) return `${Math.round(durationMs)} ms`;
  return `${Number((durationMs / 1000).toFixed(1))} s`;
}

function emptyPreviewMessage(status) {
  switch (status) {
  case "starting": return "Starting WYSIWYG preview…";
  case "building": return "Building WYSIWYG preview…";
  case "unavailable": return "Language server unavailable.";
  case "failed": return "No preview is available.";
  default: return "No preview is available.";
  }
}

function modeOption(value, label, current) {
  const option = element("option");
  option.value = value;
  option.textContent = label;
  option.selected = value === current;
  return option;
}

function styleToggle(label, checked, change) {
  const control = element("label", "style-toggle");
  const input = element("input");
  input.type = "checkbox";
  input.checked = checked;
  input.addEventListener("change", () => change(input.checked));
  control.append(input, document.createTextNode(label));
  return control;
}

function colorControl(label, value, change) {
  const control = element("label", "style-color");
  control.title = label;
  const input = element("input");
  input.type = "color";
  input.value = value;
  input.setAttribute("aria-label", label);
  input.addEventListener("change", () => change(input.value));
  control.append(input);
  return control;
}

function numberControl(label, value, min, max, step, change) {
  const control = element("label", "style-number");
  const caption = element("span");
  caption.textContent = label === "Fill opacity" ? "α" : "pt";
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
  control.append(input, caption);
  return control;
}

function shapePreview(tool) {
  const preview = element("span", `shape-choice-preview shape-choice-preview--${tool}`);
  preview.setAttribute("aria-hidden", "true");
  return preview;
}
