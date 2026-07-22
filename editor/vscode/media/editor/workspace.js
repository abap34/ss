import { element } from "./dom.js";
import { renderObjectSheet, sourceButton } from "./details.js";
import {
  iconCatalogPolicy,
  shouldLoadMoreIcons,
} from "./icon-insertion.js";
import { InteractionController } from "./interaction.js";
import { renderPage } from "./document.js";
import { strokeStylePicker } from "./shape-style.js";
import { toolIcon } from "./tool-icons.js";

const rulerSize = 26;
const rulerInterval = 100;
const minimumRulerTickSpacing = 50;
const viewportMarginRatio = 0.04;
const wheelDeltaModeLine = 1;
const wheelDeltaModePage = 2;
export const zoomPolicy = Object.freeze({
  minimumScale: 0.1,
  maximumScale: 4,
  pinchSensitivity: 0.004,
  wheelLinePixels: 16,
});
export const buildStatusPresentation = {
  starting: { label: "Starting…", icon: "" },
  building: { label: "Building…", icon: "" },
  complete: { label: "Build complete", icon: "✓" },
  manual: { label: "Build required", icon: "↻" },
  failed: { label: "Build failed", icon: "!" },
  unavailable: { label: "Language server unavailable", icon: "×" },
};

export class WorkspaceView {
  constructor(state, actions) {
    this.state = state;
    this.actions = actions;
    this.root = null;
    this.viewport = null;
    this.iconGalleryKey = null;
    this.iconGalleryScrollTop = 0;
    this.pan = null;
    this.handlePinch = this.handlePinch.bind(this);
    this.beginPan = this.beginPan.bind(this);
    this.updatePan = this.updatePan.bind(this);
    this.finishPan = this.finishPan.bind(this);
    this.interaction = new InteractionController(state, {
      ...actions,
    });
  }

  render() {
    this.interaction.reset();
    this.cleanupPan();
    const main = element("main", "workspace");
    main.append(this.toolbar());
    const viewport = element("div", `viewport viewport--${this.state.mode}`);
    viewport.classList.toggle("viewport--pan", this.state.pointerMode === "pan");
    viewport.addEventListener("wheel", this.handlePinch, { passive: false });
    viewport.addEventListener("pointerdown", this.beginPan, true);
    viewport.addEventListener("click", (event) => {
      if (this.state.pointerMode !== "pan") return;
      event.preventDefault();
      event.stopPropagation();
    }, true);
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
    if (this.state.iconPickerOpen) {
      requestAnimationFrame(() => {
        const search = this.root?.querySelector(".icon-picker-search");
        if (search) {
          search.focus();
          search.setSelectionRange(search.value.length, search.value.length);
        }
        const gallery = this.root?.querySelector(".icon-picker-gallery");
        if (!gallery) return;
        gallery.scrollTop = this.iconGalleryScrollTop;
        this.maybeLoadMoreIcons(gallery);
      });
    }
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
    const zoom = this.zoomControls();
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
      this.pointerModeButton("select", "Select"),
      this.pointerModeButton("pan", "Pan view"),
      this.shapePicker(),
      this.iconPicker(),
    );
    bar.append(mode, zoom, tools);
    if (this.state.shapeTool !== "select") {
      const iconActive = this.state.shapeTool === "icon";
      bar.append(
        iconActive ? this.iconStyleControls() : this.shapeStyleControls(),
        iconActive ? this.iconStylePopover() : this.shapeStylePopover(),
      );
    }
    bar.append(status);
    return bar;
  }

  zoomControls() {
    const controls = element("div", "zoom-controls");
    controls.setAttribute("role", "group");
    controls.setAttribute("aria-label", "Zoom controls");
    const selection = element("select", "zoom-select");
    selection.setAttribute("aria-label", "Zoom");
    const fit = element("option");
    fit.value = "fit";
    const actual = element("option");
    actual.value = "actual";
    actual.textContent = "100%";
    selection.append(fit, actual);
    selection.addEventListener("change", () => {
      if (selection.value === "fit") this.setZoom("fit");
      else if (selection.value === "actual") this.setZoom("manual", 1);
    });
    controls.append(selection);
    this.updateZoomControls(this.state.previewScale, controls);
    return controls;
  }

  handlePinch(event) {
    if (!event.ctrlKey || !this.state.snapshot) return;
    event.preventDefault();
    const viewport = event.currentTarget;
    const delta = normalizedWheelDelta(event, viewport.clientHeight);
    const current = normalizedScale(this.state.previewScale, 1);
    const next = clampScale(current * Math.exp(
      -delta * zoomPolicy.pinchSensitivity,
    ));
    if (Math.abs(next - current) < 0.0005) return;
    this.setZoom("manual", next, {
      clientX: event.clientX,
      clientY: event.clientY,
    });
  }

  setZoom(mode, scale = this.state.zoomScale, point = null) {
    const viewport = this.viewport;
    const anchor = viewport
      ? viewportAnchor(viewport, point?.clientX, point?.clientY)
      : null;
    this.state.zoomMode = mode === "manual" ? "manual" : "fit";
    if (this.state.zoomMode === "manual") {
      this.state.zoomScale = clampScale(normalizedScale(scale, 1));
    }
    this.updateScale();
    if (!viewport || !anchor) return;
    restoreViewportAnchor(viewport, anchor);
    requestAnimationFrame(() => {
      if (this.viewport === viewport) restoreViewportAnchor(viewport, anchor);
    });
  }

  updateZoomControls(scale, root = this.root) {
    const controls = root?.classList?.contains("zoom-controls")
      ? root
      : root?.querySelector?.(".zoom-controls");
    if (!controls) return;
    const current = normalizedScale(scale, 1);
    const selection = controls.querySelector(".zoom-select");
    const fit = selection?.querySelector('option[value="fit"]');
    const actual = selection?.querySelector('option[value="actual"]');
    if (!selection || !fit || !actual) return;
    const percentage = formatZoomPercentage(current);
    fit.textContent = `Fit ${percentage}`;
    const unavailable = !this.state.snapshot;
    selection.disabled = unavailable;
    selection.querySelector('option[value="manual"]')?.remove();
    if (this.state.zoomMode === "manual" && Math.abs(current - 1) >= 0.0005) {
      const manual = element("option");
      manual.value = "manual";
      manual.textContent = percentage;
      selection.insertBefore(manual, actual);
      selection.value = "manual";
    } else {
      selection.value = this.state.zoomMode === "manual" ? "actual" : "fit";
    }
  }

  pointerModeButton(mode, label) {
    const button = element("button", "shape-tool");
    button.type = "button";
    button.title = label;
    button.setAttribute("aria-label", label);
    const active = this.state.pointerMode === mode &&
      (mode === "pan" || this.state.shapeTool === "select");
    button.setAttribute("aria-pressed", String(active));
    button.classList.toggle("is-active", active);
    button.append(toolIcon(mode));
    button.disabled = this.actions.shape.isBusy() || this.actions.icon.isBusy();
    button.addEventListener("click", () => this.setPointerMode(mode));
    return button;
  }

  setPointerMode(mode) {
    if (this.actions.shape.isBusy() || this.actions.icon.isBusy()) return;
    this.state.pointerMode = mode === "pan" ? "pan" : "select";
    this.state.shapeTool = "select";
    this.actions.render();
  }

  beginPan(event) {
    if (this.state.pointerMode !== "pan" || event.button !== 0 || this.pan) {
      return;
    }
    const viewport = event.currentTarget;
    event.preventDefault();
    event.stopPropagation();
    this.pan = {
      pointerId: event.pointerId,
      viewport,
      startX: event.clientX,
      startY: event.clientY,
      scrollLeft: viewport.scrollLeft,
      scrollTop: viewport.scrollTop,
    };
    viewport.classList.add("viewport--panning");
    viewport.setPointerCapture(event.pointerId);
    viewport.addEventListener("pointermove", this.updatePan);
    viewport.addEventListener("pointerup", this.finishPan);
    viewport.addEventListener("pointercancel", this.finishPan);
  }

  updatePan(event) {
    const pan = this.pan;
    if (!pan || event.pointerId !== pan.pointerId) return;
    event.preventDefault();
    pan.viewport.scrollLeft = pan.scrollLeft - (event.clientX - pan.startX);
    pan.viewport.scrollTop = pan.scrollTop - (event.clientY - pan.startY);
  }

  finishPan(event) {
    if (!this.pan || event.pointerId !== this.pan.pointerId) return;
    event.preventDefault();
    this.cleanupPan();
  }

  cleanupPan() {
    const pan = this.pan;
    if (!pan) return;
    const viewport = pan.viewport;
    viewport.removeEventListener("pointermove", this.updatePan);
    viewport.removeEventListener("pointerup", this.finishPan);
    viewport.removeEventListener("pointercancel", this.finishPan);
    if (viewport.hasPointerCapture?.(pan.pointerId)) {
      viewport.releasePointerCapture(pan.pointerId);
    }
    viewport.classList.remove("viewport--panning");
    this.pan = null;
  }

  shapePicker() {
    const groups = [
      {
        label: "Lines",
        choices: [["line", "Line"]],
      },
      {
        label: "Basic shapes",
        choices: [
          ["rectangle", "Rectangle"],
          ["circle", "Circle"],
          ["arrow", "Block arrow"],
          ["speech_bubble", "Speech bubble"],
        ],
      },
    ];
    const choices = groups.flatMap((group) => group.choices);
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
    for (const group of groups) {
      const section = element("section", "shape-picker-section");
      const heading = element("strong");
      heading.textContent = group.label;
      const gallery = element("div", "shape-picker-gallery");
      for (const [tool, name] of group.choices) {
        const button = element(
          "button",
          `shape-choice shape-choice--${tool}${
            this.state.shapeTool === tool ? " is-active" : ""
          }`,
        );
        button.type = "button";
        button.disabled = !this.actions.shape.canInsert(this.state.currentPageId);
        button.setAttribute("aria-label", name);
        button.setAttribute("aria-pressed", String(this.state.shapeTool === tool));
        if (tool === "line") button.title = "Line (L)";
        button.append(shapePreview(tool));
        const caption = element("span");
        caption.textContent = name;
        button.append(caption);
        if (tool === "line") {
          const shortcut = element("kbd", "shape-choice-shortcut");
          shortcut.textContent = "L";
          shortcut.setAttribute("aria-hidden", "true");
          button.append(shortcut);
        }
        button.addEventListener("click", () => {
          picker.open = false;
          this.actions.shape.selectTool(tool);
        });
        gallery.append(button);
      }
      section.append(heading, gallery);
      panel.append(section);
    }
    picker.append(summary, panel);
    return picker;
  }

  iconPicker() {
    const draft = this.state.iconDraft;
    const picker = element("details", "icon-picker");
    picker.open = this.state.iconPickerOpen;
    const summary = element("summary");
    summary.setAttribute("aria-label", draft.name ? `Icons: ${draft.name}` : "Icons");
    summary.setAttribute("aria-pressed", String(this.state.shapeTool === "icon"));
    summary.title = draft.name ? `Icon: ${draft.name}` : "Icons";
    const icon = element("span", "shape-picker-summary-icon icon-picker-summary-icon");
    icon.style.color = draft.color;
    if (draft.svg) appendTrustedSvg(icon, draft.svg);
    else icon.append(element("span", "icon-picker-placeholder"));
    const label = element("span");
    label.textContent = "Icons";
    const chevron = element("span", "shape-picker-chevron");
    chevron.textContent = "⌄";
    summary.append(icon, label, chevron);

    const panel = element("div", "icon-picker-panel");
    const search = element("input", "icon-picker-search");
    search.type = "search";
    search.value = this.state.iconQuery;
    search.maxLength = iconCatalogPolicy.queryMaxLength;
    search.placeholder = "Search icon names";
    search.setAttribute("aria-label", "Search icon names");
    search.addEventListener("input", () => this.actions.icon.setQuery(search.value));
    const tabs = element("div", "icon-style-tabs");
    tabs.setAttribute("role", "group");
    tabs.setAttribute("aria-label", "Icon style");
    for (const [style, name] of [
      ["all", "All"],
      ["solid", "Solid"],
      ["regular", "Regular"],
      ["brands", "Brands"],
    ]) {
      const button = element(
        "button",
        `icon-style-tab${this.state.iconStyle === style ? " is-active" : ""}`,
      );
      button.type = "button";
      button.textContent = name;
      button.setAttribute("aria-pressed", String(this.state.iconStyle === style));
      button.addEventListener("click", () => this.actions.icon.setStyle(style));
      tabs.append(button);
    }
    const category = element("select", "icon-category-select");
    category.setAttribute("aria-label", "Icon category");
    category.append(modeOption("all", "All categories", this.state.iconCategory));
    for (const item of this.state.iconCategories || []) {
      category.append(modeOption(item.id, item.label, this.state.iconCategory));
    }
    category.addEventListener("change", () => {
      this.actions.icon.setCategory(category.value);
    });
    const status = element("div", "icon-catalog-status");
    const catalog = this.state.iconCatalog;
    if (this.state.iconCatalogError) {
      const message = element("span", "icon-catalog-error");
      message.textContent = this.state.iconCatalogError;
      const retry = element("button", "icon-catalog-retry");
      retry.type = "button";
      retry.textContent = "Retry";
      retry.addEventListener("click", () => this.actions.icon.retryCatalog());
      status.append(message, retry);
    } else if (this.state.iconCatalogPending && !catalog) {
      status.textContent = "Loading icons…";
    } else if (catalog) {
      const message = element("span");
      message.textContent = catalog.total_matches === 0
        ? "No matching icons"
        : `${catalog.icons.length} of ${catalog.total_matches} icons${
          this.state.iconCatalogPending ? " · Loading…" : ""
        }`;
      status.append(message);
    } else {
      status.textContent = "Open the picker to load icons";
    }
    const gallery = element("div", "icon-picker-gallery");
    const galleryKey = `${this.state.iconQuery}\u0000${this.state.iconStyle}\u0000${
      this.state.iconCategory
    }`;
    if (this.iconGalleryKey !== galleryKey) {
      this.iconGalleryKey = galleryKey;
      this.iconGalleryScrollTop = 0;
    }
    gallery.addEventListener("scroll", () => {
      this.iconGalleryScrollTop = gallery.scrollTop;
      this.maybeLoadMoreIcons(gallery);
    });
    for (const entry of catalog?.icons || []) {
      const button = element(
        "button",
        `icon-choice${draft.source === entry.id ? " is-active" : ""}`,
      );
      button.type = "button";
      button.disabled = !this.state.snapshot || this.state.snapshot.stale ||
        !this.state.snapshot.page_editing?.some((target) =>
          target.page_id === this.state.currentPageId && target.insert_icons
        );
      button.title = entry.id;
      button.setAttribute("aria-label", `${entry.name}, ${entry.style}`);
      const preview = element("span", "icon-choice-preview");
      preview.style.color = draft.color;
      appendTrustedSvg(preview, entry.svg);
      const caption = element("span", "icon-choice-name");
      caption.textContent = entry.name;
      button.append(preview, caption);
      button.addEventListener("click", () => this.actions.icon.select(entry));
      gallery.append(button);
    }
    panel.append(search, tabs, category, status, gallery);
    picker.append(summary, panel);
    picker.addEventListener("toggle", () => {
      if (picker.open !== this.state.iconPickerOpen) {
        this.actions.icon.setPickerOpen(picker.open);
      }
    });
    return picker;
  }

  maybeLoadMoreIcons(gallery) {
    if (!this.state.iconPickerOpen || this.state.iconCatalogPending ||
        !this.state.iconCatalog?.has_more || !shouldLoadMoreIcons(gallery)) {
      return false;
    }
    return this.actions.icon.loadMore();
  }

  iconStyleControls() {
    const group = element("div", "shape-style-controls icon-style-controls");
    group.append(colorControl(
      "Icon color",
      this.state.iconDraft.color,
      (color) => this.actions.icon.setColor(color),
    ));
    return group;
  }

  iconStylePopover() {
    const popover = element("details", "shape-style-popover");
    const summary = element("summary");
    summary.textContent = "Color";
    summary.setAttribute("aria-label", "Icon color");
    const panel = element("div", "shape-style-popover-panel");
    panel.append(this.iconStyleControls());
    popover.append(summary, panel);
    return popover;
  }

  shapeStyleControls() {
    const line = this.state.shapeTool === "line";
    const group = element(
      "div",
      `shape-style-controls${line ? " shape-style-controls--line" : ""}`,
    );
    const draft = this.state.shapeStyle;
    const controls = [];
    if (!line) {
      controls.push(
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
      );
    }
    controls.push(
      colorControl(line ? "Line color" : "Stroke color", draft.stroke.color, (color) => {
        this.actions.shape.setDraft({
          ...draft,
          stroke: { ...draft.stroke, color },
        });
      }),
      strokeStylePicker(draft.stroke.style, {
        ariaLabel: line ? "Line style" : "Stroke style",
        disabled: this.actions.shape.isBusy(),
        change: (style) => {
          this.actions.shape.setDraft({
            ...draft,
            stroke: { ...draft.stroke, style },
          });
        },
      }),
      numberControl(line ? "Line weight" : "Stroke width", draft.stroke.width, 0.1, 24, 0.1, (width) => {
        this.actions.shape.setDraft({
          ...draft,
          stroke: { ...draft.stroke, width },
        });
      }),
    );
    group.append(...controls);
    for (const input of group.querySelectorAll("input")) {
      input.disabled = this.actions.shape.isBusy();
    }
    return group;
  }

  shapeStylePopover() {
    const popover = element("details", "shape-style-popover");
    const summary = element("summary");
    summary.textContent = "Style";
    summary.setAttribute(
      "aria-label",
      this.state.shapeTool === "line" ? "Line style" : "Shape style",
    );
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
    const automaticRulers = scaleWithRulers * rulerInterval >=
      minimumRulerTickSpacing;
    const automaticScale = automaticRulers ? scaleWithRulers : fitScale(0);
    const manual = this.state.zoomMode === "manual";
    const scale = manual
      ? clampScale(normalizedScale(this.state.zoomScale, 1))
      : automaticScale;
    const showRulers = manual
      ? scale * rulerInterval >= minimumRulerTickSpacing
      : automaticRulers;
    this.state.previewScale = scale;
    viewport.classList.toggle("viewport--rulers-hidden", !showRulers);
    for (const shell of shells) {
      const width = Number(shell.dataset.pageWidth);
      const height = Number(shell.dataset.pageHeight);
      shell.style.setProperty("--page-width", `${width * scale}px`);
      shell.style.setProperty("--page-height", `${height * scale}px`);
      shell.style.setProperty("--preview-scale", String(scale));
    }
    this.updateZoomControls(scale);
    return scale;
  }

  selectedObject() {
    return this.state.snapshot?.layout.objects.find(
      (object) => object.id === this.state.selectedObjectId,
    ) || null;
  }
}

function normalizedScale(value, fallback) {
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function clampScale(value) {
  return Math.min(
    zoomPolicy.maximumScale,
    Math.max(zoomPolicy.minimumScale, value),
  );
}

function formatZoomPercentage(scale) {
  return `${Math.round(scale * 100)}%`;
}

function normalizedWheelDelta(event, viewportHeight) {
  if (event.deltaMode === wheelDeltaModeLine) {
    return event.deltaY * zoomPolicy.wheelLinePixels;
  }
  if (event.deltaMode === wheelDeltaModePage) {
    return event.deltaY * viewportHeight;
  }
  return event.deltaY;
}

function viewportAnchor(viewport, clientX, clientY) {
  const rect = viewport.getBoundingClientRect();
  const viewportX = Number.isFinite(clientX)
    ? Math.min(viewport.clientWidth, Math.max(0, clientX - rect.left))
    : viewport.clientWidth / 2;
  const viewportY = Number.isFinite(clientY)
    ? Math.min(viewport.clientHeight, Math.max(0, clientY - rect.top))
    : viewport.clientHeight / 2;
  return {
    x: (viewport.scrollLeft + viewportX) /
      Math.max(viewport.scrollWidth, 1),
    y: (viewport.scrollTop + viewportY) /
      Math.max(viewport.scrollHeight, 1),
    viewportX,
    viewportY,
  };
}

function restoreViewportAnchor(viewport, anchor) {
  const maximumLeft = Math.max(0, viewport.scrollWidth - viewport.clientWidth);
  const maximumTop = Math.max(0, viewport.scrollHeight - viewport.clientHeight);
  viewport.scrollLeft = Math.min(
    maximumLeft,
    Math.max(0, anchor.x * viewport.scrollWidth - anchor.viewportX),
  );
  viewport.scrollTop = Math.min(
    maximumTop,
    Math.max(0, anchor.y * viewport.scrollHeight - anchor.viewportY),
  );
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

export function emptyPreviewMessage(status) {
  switch (status) {
  case "starting": return "Starting WYSIWYG preview…";
  case "building": return "Building WYSIWYG preview…";
  case "manual":
    return "Run “ss: Build WYSIWYG Preview” to build the preview.";
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

function appendTrustedSvg(target, source) {
  const template = document.createElement("template");
  template.innerHTML = source;
  target.append(template.content.cloneNode(true));
}
