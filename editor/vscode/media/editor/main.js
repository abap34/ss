import { element } from "./dom.js";
import { renderActivityRail, renderSidebar } from "./sidebar.js";
import { WorkspaceView } from "./workspace.js";

const vscode = acquireVsCodeApi();
const state = {
  snapshot: null,
  sidebar: "pages",
  mode: "single",
  currentPageId: null,
  selectedObjectId: null,
  constraints: true,
  sync: { state: "working", label: "Starting…" },
};
const app = document.getElementById("app");

const actions = {
  post: (message) => vscode.postMessage(message),
  render,
  revealSource,
  selectObject,
  selectPage,
};
const workspace = new WorkspaceView(state, actions);
const resizeObserver = new ResizeObserver(() => workspace.updateScale());

window.addEventListener("message", (event) => {
  const message = event.data || {};
  if (message.type === "snapshot") {
    acceptSnapshot(message);
  } else if (message.type === "sync") {
    state.sync = { state: message.state, label: message.label };
    workspace.updateSync();
  } else if (message.type === "editResult") {
    state.sync = { state: "error", label: message.message || "Edit rejected" };
    render();
  }
});

function acceptSnapshot(message) {
  state.snapshot = message.snapshot;
  state.sync = state.snapshot.stale
    ? { state: "error", label: "Showing last valid layout" }
    : { state: "ok", label: `Synced · ${message.duration} ms` };
  const pages = state.snapshot.layout.pages || [];
  if (!pages.some((page) => page.id === state.currentPageId)) {
    state.currentPageId = pages[0]?.id ?? null;
  }
  const objects = state.snapshot.layout.objects || [];
  if (!objects.some((object) => object.id === state.selectedObjectId)) {
    state.selectedObjectId = null;
  }
  render();
}

function render() {
  resizeObserver.disconnect();
  app.replaceChildren();
  const shell = element("div", "editor-shell");
  shell.append(renderActivityRail(state, toggleSidebar));
  if (state.sidebar) shell.append(renderSidebar(state, actions));
  shell.append(workspace.render());
  app.append(shell);
  if (workspace.viewport) resizeObserver.observe(workspace.viewport);
  requestAnimationFrame(() => workspace.updateScale());
}

function toggleSidebar(view) {
  state.sidebar = state.sidebar === view ? null : view;
  render();
}

function selectPage(pageId) {
  state.currentPageId = pageId;
  if (state.mode === "single") state.selectedObjectId = null;
  render();
  if (state.mode === "continuous") {
    requestAnimationFrame(() => {
      app.querySelector(`.page-shell[data-page-id="${pageId}"]`)
        ?.scrollIntoView({ behavior: "smooth", block: "center" });
    });
  }
}

function selectObject(objectId, pageId, rerender = true) {
  state.selectedObjectId = objectId;
  state.currentPageId = pageId;
  if (rerender) render();
}

function revealSource(object) {
  if (!object.location?.path) return;
  vscode.postMessage({
    type: "revealSource",
    path: object.location.path,
    start: object.location.start,
    end: object.location.end,
  });
}

render();
vscode.postMessage({ type: "ready" });
