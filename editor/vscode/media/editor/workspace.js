import { element } from "./dom.js";
import { renderObjectSheet } from "./details.js";
import { InteractionController } from "./interaction.js";
import { renderPage } from "./document.js";

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
    applyBuildStatus(status, this.state.buildStatus);
    bar.append(mode, status);
    return bar;
  }

  updateBuildStatus() {
    const status = this.root?.querySelector(".build-status");
    if (!status) return false;
    applyBuildStatus(status, this.state.buildStatus);
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

function applyBuildStatus(node, status) {
  const presentation = buildStatusPresentation[status] ||
    buildStatusPresentation.starting;
  node.className = `build-status build-status--${status}`;
  node.title = presentation.label;
  const icon = element("span", "build-status-icon");
  icon.setAttribute("aria-hidden", "true");
  icon.textContent = presentation.icon;
  const label = element("span", "build-status-label");
  label.textContent = presentation.label;
  node.replaceChildren(icon, label);
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
