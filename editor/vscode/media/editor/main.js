import { element } from "./dom.js";
import { EditorNavigation } from "./navigation.js";
import { renderActivityRail, renderSidebar } from "./sidebar.js";
import { WorkspaceView } from "./workspace.js";

const vscode = acquireVsCodeApi();
const persistedState = vscode.getState() || {};
const state = {
  snapshot: null,
  sidebar: "pages",
  mode: "single",
  currentPageId: null,
  selectedObjectId: null,
  theme: persistedState.theme === "light" || persistedState.theme === "dark"
    ? persistedState.theme
    : initialTheme(),
  toast: null,
};
const app = document.getElementById("app");
document.documentElement.dataset.theme = state.theme;
let toastTimer = null;

const actions = {
  post: (message) => vscode.postMessage(message),
  render,
  revealSource,
  selectObject,
  selectPage,
};
const navigation = new EditorNavigation(state);
const workspace = new WorkspaceView(state, actions);
const resizeObserver = new ResizeObserver(() => workspace.updateScale());

window.addEventListener("message", (event) => {
  const message = event.data || {};
  if (message.type === "snapshot") {
    acceptSnapshot(message);
  } else if (message.type === "error") {
    showError(message.message || "WYSIWYG preview update failed.");
  } else if (message.type === "editResult") {
    if (message.status !== "stale") {
      showError(message.message || "The edit could not be applied.");
    }
  }
});

function acceptSnapshot(message) {
  state.snapshot = message.snapshot;
  let renderStyle = document.getElementById("ss-render-style");
  if (!renderStyle) {
    renderStyle = document.createElement("style");
    renderStyle.id = "ss-render-style";
    document.head.append(renderStyle);
  }
  renderStyle.textContent = state.snapshot.display.css;
  navigation.reconcile(state.snapshot);
  render();
}

function showError(message) {
  state.toast = message;
  render();
  if (toastTimer != null) clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    toastTimer = null;
    state.toast = null;
    render();
  }, 5000);
}

function render() {
  navigation.rememberViewport(workspace.viewport);
  resizeObserver.disconnect();
  app.replaceChildren();
  const shell = element("div", "editor-shell");
  shell.append(renderActivityRail(state, { toggleSidebar, toggleTheme }));
  if (state.sidebar) shell.append(renderSidebar(state, actions));
  shell.append(workspace.render());
  app.append(shell);
  navigation.restoreViewport(workspace.viewport);
  if (workspace.viewport) resizeObserver.observe(workspace.viewport);
  requestAnimationFrame(() => {
    workspace.updateScale();
    navigation.restoreViewport(workspace.viewport);
  });
}

function toggleSidebar(view) {
  state.sidebar = state.sidebar === view ? null : view;
  render();
}

function toggleTheme() {
  state.theme = state.theme === "dark" ? "light" : "dark";
  document.documentElement.dataset.theme = state.theme;
  vscode.setState({ ...persistedState, theme: state.theme });
  render();
}

function selectPage(pageId) {
  if (!navigation.selectPage(pageId)) return;
  render();
  if (state.mode === "continuous") {
    requestAnimationFrame(() => {
      app.querySelector(`.page-shell[data-page-id="${pageId}"]`)
        ?.scrollIntoView({ behavior: "smooth", block: "center" });
    });
  }
}

function selectObject(objectId, pageId, rerender = true) {
  const result = navigation.selectObject(objectId, pageId);
  if (!result.selected) return;
  if (rerender) render();
  if (rerender && result.pageChanged && state.mode === "continuous") {
    requestAnimationFrame(() => {
      app.querySelector(`.page-shell[data-page-id="${pageId}"]`)
        ?.scrollIntoView({ behavior: "smooth", block: "center" });
    });
  }
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

function initialTheme() {
  return document.body.classList.contains("vscode-light") ||
      document.body.classList.contains("vscode-high-contrast-light")
    ? "light"
    : "dark";
}

render();
vscode.postMessage({ type: "ready" });
