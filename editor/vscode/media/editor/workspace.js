import { element } from "./dom.js";
import { renderObjectSheet } from "./details.js";
import { InteractionController } from "./interaction.js";
import { renderPage } from "./document.js";

const rulerSize = 26;
const singlePageMargin = 32;

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
      empty.textContent = "Building WYSIWYG preview…";
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
      const toast = element("div", "error-toast");
      toast.setAttribute("role", "alert");
      toast.textContent = this.state.toast;
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
    bar.append(mode);
    return bar;
  }

  pageShell(page) {
    const shell = element("article", "page-shell");
    shell.dataset.pageId = String(page.id);
    shell.dataset.pageWidth = String(page.width);
    shell.dataset.pageHeight = String(page.height);
    shell.append(this.ruler("horizontal", page.width));
    shell.append(this.ruler("vertical", page.height));
    const surface = element("div", "page-surface");
    surface.append(renderPage(this.state.snapshot, page.id));
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
    for (let value = 0; value <= extent; value += 100) {
      const major = value % 200 === 0;
      const tick = element(
        "span",
        `ruler-tick${major ? " ruler-tick--major" : ""}`,
      );
      const percent = `${(value / extent) * 100}%`;
      if (axis === "horizontal") tick.style.left = percent;
      else tick.style.top = percent;
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
    const horizontalMargin = this.state.mode === "single"
      ? singlePageMargin * 2
      : 40;
    const verticalMargin = this.state.mode === "single"
      ? singlePageMargin * 2
      : 32;
    const availableWidth = Math.max(
      80,
      viewport.clientWidth - horizontalMargin - rulerSize,
    );
    const availableHeight = Math.max(
      60,
      viewport.clientHeight - verticalMargin - rulerSize,
    );
    const scale = this.state.mode === "single"
      ? Math.min(availableWidth / widths[0], availableHeight / heights[0])
      : Math.min(1, availableWidth / Math.max(...widths));
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

function modeOption(value, label, current) {
  const option = element("option");
  option.value = value;
  option.textContent = label;
  option.selected = value === current;
  return option;
}
