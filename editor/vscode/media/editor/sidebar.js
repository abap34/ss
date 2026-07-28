import { element } from "./dom.js";
import { renderPage } from "./document.js";

export function renderActivityRail(state, actions) {
  const rail = element("nav", "activity-rail");
  rail.setAttribute("aria-label", "Sidebar views");
  rail.append(activityButton(state, "pages", "Pages", actions.toggleSidebar));
  rail.append(
    activityButton(state, "outline", "Outline", actions.toggleSidebar),
  );
  const theme = element("button", "activity-theme");
  const nextTheme = state.theme === "dark" ? "light" : "dark";
  theme.type = "button";
  theme.title = `Use ${nextTheme} theme`;
  theme.setAttribute("aria-label", theme.title);
  theme.append(
    element("span", `activity-icon activity-icon--theme-${nextTheme}`),
  );
  theme.addEventListener("click", actions.toggleTheme);
  rail.append(theme);
  return rail;
}

export function renderSidebar(state, actions) {
  const aside = element("aside", "sidebar");
  aside.dataset.sidebarView = state.sidebar;
  const header = element("header", "sidebar-title");
  header.textContent = state.sidebar === "outline" ? "Outline" : "Pages";
  aside.append(header);
  if (!state.snapshot) {
    const loading = element("div", "sidebar-loading");
    loading.textContent = "Building document…";
    aside.append(loading);
    return aside;
  }
  aside.append(
    state.sidebar === "outline"
      ? outlinePanel(state, actions)
      : pagesPanel(state, actions),
  );
  return aside;
}

export function reconcileSidebarSnapshot(root, state, previousSnapshot) {
  const sidebar = root.querySelector(".sidebar[data-sidebar-view]");
  if (!state.sidebar) return sidebar == null;
  if (!sidebar || sidebar.dataset.sidebarView !== state.sidebar ||
      !sameSidebarModel(state.sidebar, previousSnapshot, state.snapshot)) {
    return false;
  }
  if (state.sidebar === "pages") {
    const entries = [...sidebar.querySelectorAll(".page-entry[data-page-id]")];
    if (entries.length !== state.snapshot.layout.pages.length) return false;
    for (let index = 0; index < entries.length; index += 1) {
      const page = state.snapshot.layout.pages[index];
      const entry = entries[index];
      if (Number(entry.dataset.pageId) !== page.id) return false;
      entry.classList.toggle("is-active", page.id === state.currentPageId);
    }
    return true;
  }
  for (const row of sidebar.querySelectorAll(".outline-row[data-outline-id]")) {
    const id = Number(row.dataset.outlineId);
    row.classList.toggle(
      "is-active",
      id === state.selectedObjectId || id === state.currentPageId,
    );
  }
  return true;
}

function activityButton(state, view, label, toggleSidebar) {
  const button = element("button", state.sidebar === view ? "is-active" : "");
  button.type = "button";
  button.title = label;
  button.setAttribute("aria-label", label);
  button.setAttribute("aria-pressed", String(state.sidebar === view));
  button.append(element("span", `activity-icon activity-icon--${view}`));
  button.addEventListener("click", () => toggleSidebar(view));
  return button;
}

function pagesPanel(state, actions) {
  const list = element("div", "page-list");
  for (const page of state.snapshot.layout.pages) {
    const button = element(
      "button",
      `page-entry${page.id === state.currentPageId ? " is-active" : ""}`,
    );
    button.type = "button";
    button.dataset.pageId = String(page.id);
    const thumb = element("span", "page-thumbnail");
    thumb.append(renderPage(state.snapshot, page.id, true));
    const label = element("span", "page-entry-label");
    const number = element("strong");
    number.textContent = String(page.index);
    const name = element("small");
    name.textContent = page.name || `Page ${page.index}`;
    label.append(number, name);
    button.append(thumb, label);
    button.addEventListener("click", () => actions.selectPage(page.id));
    list.append(button);
  }
  return list;
}

function outlinePanel(state, actions) {
  const list = element("div", "outline-list");
  const unique = new Map();
  for (const item of state.snapshot.outline || []) {
    if (!unique.has(item.id)) unique.set(item.id, item);
  }
  const children = new Map();
  for (const item of unique.values()) {
    const key = item.parent_id ?? 0;
    if (!children.has(key)) children.set(key, []);
    children.get(key).push(item);
  }
  for (const page of state.snapshot.layout.pages) {
    const root = unique.get(page.id) || {
      id: page.id,
      parent_id: null,
      page_id: page.id,
      kind: "page",
      label: page.name,
    };
    list.append(outlineRow(state, actions, root, children, 0, new Set()));
  }
  return list;
}

function outlineRow(state, actions, item, children, depth, seen) {
  const fragment = document.createDocumentFragment();
  if (seen.has(item.id)) return fragment;
  seen.add(item.id);
  const active = item.id === state.selectedObjectId ||
    item.id === state.currentPageId;
  const row = element(
    "div",
    `outline-row outline-row--${item.kind}${active ? " is-active" : ""}`,
  );
  row.dataset.outlineId = String(item.id);
  row.style.setProperty("--depth", String(depth));
  const button = element("button", "outline-row-select");
  button.type = "button";
  button.append(element("span", `outline-glyph outline-glyph--${item.kind}`));
  const label = element("span", "outline-label");
  label.textContent = item.label || item.kind;
  button.append(label);
  button.addEventListener("click", () => {
    if (item.kind === "page") actions.selectPage(item.page_id);
    else actions.selectObject(item.id, item.page_id);
  });
  row.append(button);
  if (item.kind !== "page" && actions.objectLocks?.canLock(item.id)) {
    row.append(outlineLockButton(item, actions.objectLocks));
  }
  fragment.append(row);
  for (const child of children.get(item.id) || []) {
    fragment.append(
      outlineRow(state, actions, child, children, depth + 1, seen),
    );
  }
  return fragment;
}

function outlineLockButton(item, objectLocks) {
  const locked = objectLocks.isLocked(item.id);
  const button = element(
    "button",
    `outline-lock${locked ? " is-locked" : ""}`,
  );
  button.type = "button";
  button.title = locked ? `Unlock ${item.label}` : `Lock ${item.label}`;
  button.setAttribute("aria-label", button.title);
  button.setAttribute("aria-pressed", String(locked));
  button.append(element("span", "object-lock-icon"));
  button.addEventListener("click", () => objectLocks.toggle(item.id));
  return button;
}

function sameSidebarModel(view, previous, current) {
  if (!previous || !current) return false;
  if (view === "pages") {
    return sameItems(
      previous.layout?.pages,
      current.layout?.pages,
      (page) => [page.id, page.index, page.name],
    );
  }
  return sameItems(
    previous.outline,
    current.outline,
    (item) => [
      item.id,
      item.parent_id,
      item.page_id,
      item.kind,
      item.label,
      item.role,
    ],
  ) && sameItems(
    previous.editing,
    current.editing,
    (target) => [
      target.node_id,
      target.page_id,
      target.page_index,
      target.page_name,
      target.binding,
      target.binding_required,
      target.path,
    ],
  );
}

function sameItems(before = [], after = [], project) {
  if (before.length !== after.length) return false;
  return before.every((item, index) => {
    const left = project(item);
    const right = project(after[index]);
    return left.length === right.length &&
      left.every((value, field) => value === right[field]);
  });
}
