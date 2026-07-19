import { element } from "./dom.js";
import { alignTextBaselines } from "../../out/render/text.js";
import { buildFailureMessage } from "./diagnostics.js";
import { disposePages } from "./document.js";
import { EditorNavigation } from "./navigation.js";
import { disposePdfItems, disposePdfRuntime } from "./pdf.js";
import { renderActivityRail, renderSidebar } from "./sidebar.js";
import { TranslationController } from "./translation.js";
import { WorkspaceView } from "./workspace.js";

const vscode = acquireVsCodeApi();
const persistedState = vscode.getState() || {};
const state = {
  snapshot: null,
  revision: -1,
  buildRevision: -1,
  buildStatus: "starting",
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
let renderGeneration = 0;
let textAlignmentFailed = false;
const successToastDuration = 2500;
const errorToastDuration = 5000;

const translation = new TranslationController(state, {
  post: (message) => vscode.postMessage(message),
  render,
});
const actions = {
  render,
  revealSource,
  selectObject,
  selectPage,
  translation,
};
const navigation = new EditorNavigation(state);
const workspace = new WorkspaceView(state, actions);
const resizeObserver = new ResizeObserver(() => workspace.updateScale());

app.addEventListener("ss-pdf-error", (event) => {
  showError(event.detail?.message || "PDF preview rendering failed.");
});

window.addEventListener("message", (event) => {
  const message = event.data || {};
  if (message.type === "snapshot") {
    acceptSnapshot(message);
  } else if (message.type === "buildStatus") {
    acceptBuildStatus(message);
  } else if (message.type === "error") {
    if (!Number.isSafeInteger(message.revision) ||
        message.revision <= state.revision ||
        message.revision < state.buildRevision) return;
    state.revision = message.revision;
    setBuildStatus("failed", message.revision);
    translation.cancel();
    showError(message.message || "WYSIWYG preview update failed.");
  } else if (message.type === "editResult") {
    const editOutcome = translation.acceptResult(message);
    if (editOutcome?.status === "applied") {
      showSuccess("Constraint applied to source.");
    } else if (editOutcome?.status === "failed") {
      showError(editOutcome.message);
    }
  }
});

function acceptSnapshot(message) {
  if (!Number.isSafeInteger(message.revision) ||
      message.revision <= state.revision ||
      message.revision < state.buildRevision || !message.snapshot) return;
  if (state.toast?.kind === "error") clearToast();
  textAlignmentFailed = false;
  if (state.snapshot) disposePages(state.snapshot);
  disposePdfItems(app);
  state.revision = message.revision;
  state.snapshot = message.snapshot;
  const editOutcome = translation.reconcile(
    message.snapshot,
    message.documentVersion,
  );
  const buildFailure = buildFailureMessage(message.snapshot);
  setBuildStatus(buildFailure ? "failed" : "complete", message.revision);
  let toastDuration = null;
  if (buildFailure) {
    state.toast = { kind: "error", message: buildFailure };
  } else if (editOutcome?.status === "failed") {
    state.toast = { kind: "error", message: editOutcome.message };
    toastDuration = errorToastDuration;
  }
  let renderStyle = document.getElementById("ss-render-style");
  if (!renderStyle) {
    renderStyle = document.createElement("style");
    renderStyle.id = "ss-render-style";
    document.head.append(renderStyle);
  }
  renderStyle.textContent = state.snapshot.display.css;
  navigation.reconcile(state.snapshot);
  render();
  if (toastDuration != null) scheduleToastClear(toastDuration);
}

function acceptBuildStatus(message) {
  if (!setBuildStatus(message.status, message.revision)) return;
  const clearedError = (message.status === "starting" || message.status === "building") &&
    state.toast?.kind === "error";
  if (clearedError) clearToast();
  if (clearedError || !workspace.updateBuildStatus()) render();
}

function setBuildStatus(status, revision) {
  if (!buildStatuses.has(status) || !Number.isSafeInteger(revision) ||
      revision < state.buildRevision) return false;
  if (revision === state.buildRevision &&
      terminalBuildStatuses.has(state.buildStatus)) return false;
  if (revision === state.buildRevision && status === state.buildStatus) {
    return false;
  }
  state.buildRevision = revision;
  state.buildStatus = status;
  return true;
}

function showSuccess(message) {
  state.toast = { kind: "success", message };
  render();
  scheduleToastClear(successToastDuration);
}

function showError(message) {
  state.toast = { kind: "error", message };
  render();
  scheduleToastClear(errorToastDuration);
}

function clearToast() {
  if (toastTimer != null) clearTimeout(toastTimer);
  toastTimer = null;
  state.toast = null;
}

function scheduleToastClear(duration) {
  if (toastTimer != null) clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    toastTimer = null;
    state.toast = null;
    render();
  }, duration);
}

function render() {
  const generation = ++renderGeneration;
  navigation.rememberViewport(workspace.viewport);
  resizeObserver.disconnect();
  app.replaceChildren();
  delete app.dataset.ssTextAligned;
  const shell = element("div", "editor-shell");
  shell.append(renderActivityRail(state, { toggleSidebar, toggleTheme }));
  if (state.sidebar) shell.append(renderSidebar(state, actions));
  shell.append(workspace.render());
  app.append(shell);
  void alignTextBaselines(app).then(() => {
    if (generation !== renderGeneration) return;
    app.dataset.ssTextAligned = "true";
  }).catch((error) => {
    if (generation !== renderGeneration || textAlignmentFailed) return;
    textAlignmentFailed = true;
    showError(error instanceof Error ? error.message : String(error));
  });
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

const buildStatuses = new Set([
  "starting",
  "building",
  "complete",
  "failed",
  "unavailable",
]);
const terminalBuildStatuses = new Set(["complete", "failed", "unavailable"]);

render();
vscode.postMessage({ type: "ready" });
window.addEventListener("beforeunload", () => {
  if (state.snapshot) disposePages(state.snapshot);
  disposePdfItems(app);
  void disposePdfRuntime();
});
