import { element } from "./dom.js";
import { alignTextBaselines } from "../../out/render/text.js";
import { buildFailureMessage } from "./diagnostics.js";
import { disposePages } from "./document.js";
import { defaultIconDraft, IconController } from "./icon-insertion.js";
import { EditorNavigation } from "./navigation.js";
import { ObjectLockController } from "./object-locks.js";
import { disposePdfItems, disposePdfRuntime } from "./pdf.js";
import { renderActivityRail, renderSidebar } from "./sidebar.js";
import { defaultShapeStyle, ShapeController } from "./shape-insertion.js";
import { TranslationController } from "./translation.js";
import { WorkspaceView } from "./workspace.js";

const vscode = acquireVsCodeApi();
let persistedState = vscode.getState() || {};
const state = {
  snapshot: null,
  revision: -1,
  buildRevision: -1,
  buildStatus: "starting",
  buildDurationMs: null,
  sidebar: "pages",
  mode: "single",
  currentPageId: null,
  selectedObjectId: null,
  shapeTool: "select",
  shapeStyle: structuredClone(defaultShapeStyle),
  iconPickerOpen: false,
  iconQuery: "",
  iconStyle: "all",
  iconCatalog: null,
  iconCatalogPending: false,
  iconDraft: structuredClone(defaultIconDraft),
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
const sidebarScrollPositions = new Map();
const successToastDuration = 2500;
const errorToastDuration = 5000;

const translation = new TranslationController(state, {
  post: (message) => vscode.postMessage(message),
  render,
});
const shape = new ShapeController(state, {
  post: (message) => vscode.postMessage(message),
  render,
  selectObject,
});
const icon = new IconController(state, {
  post: (message) => vscode.postMessage(message),
  render,
  selectObject,
});
const objectLocks = new ObjectLockController(state, {
  persist: (value) => persistWebviewState({ objectLocks: value }),
  render,
}, persistedState.objectLocks);
const actions = {
  render,
  revealSource,
  selectObject,
  selectPage,
  navigatePage,
  translation,
  shape,
  icon,
  objectLocks,
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
    setBuildStatus("failed", message.revision, message.buildDurationMs);
    translation.cancel();
    showError(message.message || "WYSIWYG preview update failed.");
  } else if (message.type === "editResult") {
    const editOutcome = translation.acceptResult(message);
    if (editOutcome?.status === "applied") {
      showSuccess("Constraint applied to source.");
    } else if (editOutcome?.status === "failed") {
      showError(editOutcome.message);
    }
  } else if (message.type === "shapeEditResult") {
    const editOutcome = shape.acceptResult(message);
    if (editOutcome?.status === "failed") showError(editOutcome.message);
  } else if (message.type === "iconCatalog" ||
      message.type === "iconCatalogError") {
    const outcome = icon.acceptCatalog(message);
    if (outcome?.status === "failed") showError(outcome.message);
  } else if (message.type === "iconEditResult") {
    const outcome = icon.acceptResult(message);
    if (outcome?.status === "failed") showError(outcome.message);
  }
});

function acceptSnapshot(message) {
  if (!Number.isSafeInteger(message.revision) ||
      message.revision <= state.revision ||
      message.revision < state.buildRevision || !message.snapshot) return;
  const snapshot = materializeSnapshotDisplay(message.snapshot);
  if (!snapshot) {
    vscode.postMessage({ type: "refreshFull" });
    return;
  }
  if (state.toast?.kind === "error") clearToast();
  textAlignmentFailed = false;
  const preservesDisplay = state.snapshot?.display === snapshot.display;
  if (state.snapshot && !preservesDisplay) disposePages(state.snapshot);
  if (!preservesDisplay) disposePdfItems(app);
  state.revision = message.revision;
  state.snapshot = snapshot;
  const editOutcome = translation.reconcile(
    snapshot,
    message.documentVersion,
  );
  const buildFailure = buildFailureMessage(snapshot);
  setBuildStatus(
    buildFailure ? "failed" : "complete",
    message.revision,
    message.buildDurationMs,
  );
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
  objectLocks.reconcile(state.snapshot);
  const shapeOutcome = shape.reconcile(state.snapshot);
  const iconOutcome = icon.reconcile(state.snapshot);
  if (!buildFailure && shapeOutcome?.status === "applied") {
    state.toast = {
      kind: "success",
      message: shapeOutcome.operation === "insert"
        ? "Shape inserted into source."
        : shapeOutcome.operation === "geometry"
        ? "Line geometry applied to source."
        : "Shape style applied to source.",
    };
    toastDuration = successToastDuration;
  } else if (!buildFailure && iconOutcome?.status === "applied") {
    state.toast = { kind: "success", message: "Icon inserted into source." };
    toastDuration = successToastDuration;
  }
  render();
  if (toastDuration != null) scheduleToastClear(toastDuration);
}

function materializeSnapshotDisplay(snapshot) {
  if (snapshot.display?.kind !== "translation_patch") return snapshot;
  if (
    !state.snapshot ||
    state.snapshot.snapshot_id !== snapshot.display.base_snapshot_id ||
    state.snapshot.display?.schema !== 2
  ) return null;

  const materialized = structuredClone(snapshot);
  if ((snapshot.display.translations || []).length === 0) {
    materialized.display = state.snapshot.display;
    return materialized;
  }
  const display = structuredClone(state.snapshot.display);
  const translations = new Map(
    (display.translations || []).map((item) => [item.node_id, { ...item }]),
  );
  for (const patch of snapshot.display.translations) {
    const current = translations.get(patch.node_id) || {
      node_id: patch.node_id,
      x: 0,
      y: 0,
    };
    current.x += patch.x;
    current.y += patch.y;
    translations.set(patch.node_id, current);
  }
  display.translations = [...translations.values()].filter((item) =>
    Math.abs(item.x) >= 0.0001 || Math.abs(item.y) >= 0.0001
  );
  materialized.display = display;
  return materialized;
}

function acceptBuildStatus(message) {
  if (!setBuildStatus(message.status, message.revision)) return;
  const clearedError = (
    message.status === "starting" ||
    message.status === "building" ||
    message.status === "manual"
  ) &&
    state.toast?.kind === "error";
  if (clearedError) clearToast();
  if (clearedError || !workspace.updateBuildStatus()) render();
}

function setBuildStatus(status, revision, durationMs = null) {
  if (!buildStatuses.has(status) || !Number.isSafeInteger(revision) ||
      revision < state.buildRevision) return false;
  if (revision === state.buildRevision &&
      terminalBuildStatuses.has(state.buildStatus)) return false;
  if (revision === state.buildRevision && status === state.buildStatus) {
    return false;
  }
  state.buildRevision = revision;
  state.buildStatus = status;
  state.buildDurationMs = validBuildDuration(durationMs) ? durationMs : null;
  return true;
}

function validBuildDuration(value) {
  return Number.isFinite(value) && value >= 0;
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
  rememberSidebarScroll();
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
  restoreSidebarScroll();
  if (workspace.viewport) resizeObserver.observe(workspace.viewport);
  requestAnimationFrame(() => {
    workspace.updateScale();
    navigation.restoreViewport(workspace.viewport);
    restoreSidebarScroll();
  });
}

function rememberSidebarScroll() {
  const sidebar = app.querySelector(".sidebar[data-sidebar-view]");
  const view = sidebar?.dataset.sidebarView;
  if (!view) return;
  sidebarScrollPositions.set(view, sidebar.scrollTop);
}

function restoreSidebarScroll() {
  const sidebar = app.querySelector(".sidebar[data-sidebar-view]");
  const view = sidebar?.dataset.sidebarView;
  const scrollTop = view ? sidebarScrollPositions.get(view) : null;
  if (scrollTop != null) sidebar.scrollTop = scrollTop;
}

function toggleSidebar(view) {
  state.sidebar = state.sidebar === view ? null : view;
  render();
}

function toggleTheme() {
  state.theme = state.theme === "dark" ? "light" : "dark";
  document.documentElement.dataset.theme = state.theme;
  persistWebviewState({ theme: state.theme });
  render();
}

function persistWebviewState(update) {
  persistedState = { ...persistedState, ...update };
  vscode.setState(persistedState);
}

function selectPage(pageId) {
  if (!navigation.selectPage(pageId)) return;
  render();
}

function navigatePage(pageId) {
  if (!navigation.selectPage(pageId)) return;
  state.selectedObjectId = null;
  const revealPage = state.mode === "continuous";
  render();
  if (!revealPage) return;
  requestAnimationFrame(() => {
    app.querySelector(`.page-shell[data-page-id="${pageId}"]`)
      ?.scrollIntoView({ block: "center", inline: "nearest" });
  });
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
  "manual",
  "failed",
  "unavailable",
]);
const terminalBuildStatuses = new Set([
  "complete",
  "manual",
  "failed",
  "unavailable",
]);

render();
vscode.postMessage({ type: "ready" });
window.addEventListener("beforeunload", () => {
  if (state.snapshot) disposePages(state.snapshot);
  disposePdfItems(app);
  void disposePdfRuntime();
});
