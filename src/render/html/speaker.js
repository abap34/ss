// One presentation owns the clock and both views, including when its controls
// live in a separate same-origin window. Navigation never copies session state.
export class SpeakerView {
  constructor(actions) {
    this.actions = actions;
    this.elapsed = 0;
    this.startedAt = null;
    this.embedded = null;
    this.popup = null;
    this.popupSurface = null;
    this.interval = null;
    this.theme = "light";
  }

  start() {
    this.elapsed = 0;
    this.startedAt = performance.now();
  }

  close() {
    this.releaseEmbedded();
    this.release(this.popupSurface);
    this.popupSurface = null;
    this.popup?.close();
    this.popup = null;
    clearInterval(this.interval);
    this.interval = null;
    this.startedAt = null;
  }

  releaseEmbedded() {
    this.release(this.embedded);
    this.embedded = null;
  }

  release(surface) {
    if (!surface) return;
    surface.observer.disconnect();
    for (const frame of [surface.current, surface.upcoming]) {
      frame.previewGeneration = (frame.previewGeneration || 0) + 1;
      frame.disposePreview?.();
      frame.disposePreview = null;
      frame.refreshPreview = null;
    }
  }

  render() {
    this.releaseEmbedded();
    this.embedded = this.createSurface(document);
    this.update(this.embedded);
    this.startTicking();
    return this.embedded.root;
  }

  refresh() {
    this.update(this.embedded);
    if (this.popup && !this.popup.closed) this.update(this.popupSurface);
  }

  openWindow() {
    if (this.popup && !this.popup.closed) {
      this.popup.focus();
      this.actions.showSlides();
      return;
    }
    const popup = window.open("", "", "popup,width=1200,height=850");
    if (!popup) {
      if (this.embedded) this.embedded.status.textContent = "Allow pop-up windows to open the presenter view in a separate window.";
      return;
    }
    this.popup = popup;
    const doc = popup.document;
    doc.open();
    doc.write('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>ss presenter view</title></head><body></body></html>');
    doc.close();
    for (const style of document.head.querySelectorAll('style, link[rel="stylesheet"]')) {
      doc.head.append(doc.importNode(style, true));
    }
    // A newly opened about:blank document inherits the opener's origin, even
    // for a deck opened from disk. It needs no server or additional bundle.
    doc.documentElement.dataset.ssReady = "true";
    this.popupSurface = this.createSurface(doc);
    doc.body.append(this.popupSurface.root);
    popup.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        event.preventDefault();
        popup.close();
      } else if (!acceptsInput(event.target)) {
        this.actions.handleKeydown(event);
      }
    });
    popup.addEventListener("pagehide", () => {
      if (this.popup !== popup) return;
      this.release(this.popupSurface);
      this.popupSurface = null;
      this.popup = null;
    }, { once: true });
    this.update(this.popupSurface);
    this.startTicking();
    this.actions.showSlides();
    popup.focus();
  }

  createSurface(doc) {
    const node = (tag, name, text = null) => {
      const result = doc.createElement(tag);
      result.className = name;
      if (text !== null) result.textContent = text;
      return result;
    };
    const button = (name, label, action) => {
      const result = node("button", "speaker-button");
      result.type = "button";
      result.dataset.speakerAction = name;
      setButtonIcon(result, name, label);
      result.addEventListener("click", action);
      return result;
    };
    const root = node("section", "speaker-view");
    root.setAttribute("aria-label", "Presenter view");
    root.dataset.theme = this.theme;
    const header = node("header", "speaker-header");
    const counter = node("span", "speaker-counter");
    const previous = button("previous", "Previous", () => this.actions.previous());
    const next = button("next", "Next", () => this.actions.next());
    const navigation = node("nav", "speaker-navigation");
    navigation.setAttribute("aria-label", "Slide navigation");
    navigation.append(previous, counter, next);
    const theme = button("theme", "Switch to dark theme", () => {
      this.theme = this.theme === "light" ? "dark" : "light";
      for (const surface of [this.embedded, this.popupSurface]) this.updateTheme(surface);
    });
    header.append(theme);
    if (doc === document) {
      if (this.actions.allowWindow) header.append(button("window", "Open in separate window", () => this.openWindow()));
      header.append(button("slides", "Show slides", () => this.actions.showSlides()));
    } else {
      header.append(button("close", "Close presenter window", () => doc.defaultView.close()));
    }
    const timing = node("section", "speaker-timing");
    const elapsed = node("time", "speaker-elapsed");
    const clock = node("time", "speaker-clock");
    const pause = button("pause", "Pause timer", () => {
      if (this.startedAt === null) this.startedAt = performance.now();
      else {
        this.elapsed = this.elapsedNow();
        this.startedAt = null;
      }
      this.tick();
    });
    timing.append(node("span", "speaker-label", "Elapsed"), elapsed, pause,
      button("reset", "Reset timer", () => {
        this.elapsed = 0;
        if (this.startedAt !== null) this.startedAt = performance.now();
        this.tick();
      }), node("span", "speaker-label speaker-clock-label", "Current time"), clock);
    header.prepend(timing);
    const slides = node("div", "speaker-slides");
    const preview = (label, className) => {
      const section = node("section", `speaker-slide ${className}`);
      section.setAttribute("aria-label", label);
      const frame = node("div", "speaker-preview");
      frame.setAttribute("aria-hidden", "true");
      section.append(frame);
      slides.append(section);
      return frame;
    };
    const current = preview("Current slide", "speaker-current");
    const upcoming = preview("Next slide", "speaker-upcoming");
    const notesSection = node("section", "speaker-notes-section");
    const notes = node("div", "speaker-notes");
    notes.tabIndex = 0;
    notes.setAttribute("role", "region");
    notes.setAttribute("aria-label", "Speaker notes");
    notesSection.append(notes);
    const status = node("p", "speaker-status");
    status.setAttribute("role", "status");
    root.append(header, slides, navigation, notesSection, status);
    const observer = new ResizeObserver(() => {
      for (const frame of [current, upcoming]) {
        fitPreview(frame);
        frame.refreshPreview?.();
      }
    });
    observer.observe(current);
    observer.observe(upcoming);
    const surface = { root, counter, previous, next, theme, elapsed, clock, pause, current, upcoming, notes, status, observer, pageId: null };
    this.updateTheme(surface);
    return surface;
  }

  updateTheme(surface) {
    if (!surface) return;
    surface.root.dataset.theme = this.theme;
    const dark = this.theme === "dark";
    setButtonIcon(surface.theme, dark ? "sun" : "moon", `Switch to ${dark ? "light" : "dark"} theme`);
    surface.theme.setAttribute("aria-pressed", String(dark));
  }

  update(surface) {
    if (!surface) return;
    const pages = this.actions.getPages();
    const index = pages.findIndex((page) => page.id === this.actions.getPageId());
    const page = pages[index];
    surface.counter.textContent = page ? `${index + 1} / ${pages.length}` : "";
    surface.previous.disabled = index <= 0;
    surface.next.disabled = index < 0 || index >= pages.length - 1;
    const notes = page?.notes || "";
    if (surface.notes.textContent !== notes) surface.notes.textContent = notes;
    if (surface.pageId !== page?.id) surface.notes.scrollTop = 0;
    surface.pageId = page?.id;
    this.preview(surface.current, page);
    this.preview(surface.upcoming, pages[index + 1]);
    this.tick();
  }

  preview(frame, page) {
    const generation = frame.previewGeneration = (frame.previewGeneration || 0) + 1;
    frame.disposePreview?.();
    frame.disposePreview = null;
    frame.refreshPreview = null;
    frame.replaceChildren();
    if (!page) {
      frame.textContent = "End of presentation";
      return;
    }
    const source = this.actions.previewPage(page.id);
    if (!source) return;
    const clone = source.cloneNode(true);
    const sourceCanvases = source.querySelectorAll("canvas");
    for (const [index, canvas] of clone.querySelectorAll("canvas").entries()) {
      const original = sourceCanvases[index];
      canvas.width = original.width;
      canvas.height = original.height;
      if (canvas.width && canvas.height) canvas.getContext("2d")?.drawImage(original, 0, 0);
    }
    const pageElement = clone.matches(".ss-page") ? clone : clone.querySelector(".ss-page");
    if (!pageElement) return;
    pageElement.removeAttribute("aria-hidden");
    pageElement.inert = true;
    frame.append(pageElement);
    fitPreview(frame);
    queueMicrotask(() => {
      if (frame.previewGeneration !== generation || !frame.isConnected || frame.firstElementChild !== pageElement) return;
      const mounted = this.actions.renderPreview?.(frame);
      frame.disposePreview = mounted?.dispose;
      frame.refreshPreview = mounted?.refresh;
      Promise.resolve(mounted?.ready).catch((error) => {
        if (!frame.isConnected || frame.firstElementChild !== pageElement) return;
        const status = frame.closest(".speaker-view")?.querySelector(".speaker-status");
        if (status) status.textContent = `Could not prepare slide preview: ${error.message}`;
      });
    });
  }

  elapsedNow() {
    return this.elapsed + (this.startedAt === null ? 0 : performance.now() - this.startedAt);
  }

  tick() {
    if (this.popup?.closed) {
      this.release(this.popupSurface);
      this.popupSurface = null;
      this.popup = null;
    }
    for (const surface of [this.embedded, this.popupSurface]) {
      if (!surface) continue;
      surface.elapsed.textContent = formatElapsed(this.elapsedNow());
      surface.clock.textContent = new Date().toLocaleTimeString();
      surface.clock.dateTime = new Date().toISOString();
      const paused = this.startedAt === null;
      if (surface.pause.getAttribute("aria-pressed") !== String(paused)) {
        setButtonIcon(surface.pause, paused ? "play" : "pause", paused ? "Resume timer" : "Pause timer");
      }
      surface.pause.setAttribute("aria-pressed", String(this.startedAt === null));
    }
    if (!this.embedded && !this.popupSurface) {
      clearInterval(this.interval);
      this.interval = null;
    }
  }

  startTicking() {
    this.interval ??= setInterval(() => this.tick(), 250);
    this.tick();
  }
}

const iconPaths = {
  previous: "m14 6-6 6 6 6",
  next: "m10 6 6 6-6 6",
  pause: "M9 5v14M15 5v14",
  play: "m8 5 11 7-11 7Z",
  reset: "M4 10a8 8 0 1 1 1 7M4 4v6h6",
  window: "M14 4h6v6m0-6-9 9M10 4H5a1 1 0 0 0-1 1v14a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-5",
  slides: "M4 5h16v12H4ZM12 17v4m-4 0h8",
  close: "m6 6 12 12M6 18 18 6",
  moon: "M20 14a8 8 0 0 1-10-10A8 8 0 1 0 20 14Z",
  sun: "M12 3v2m0 14v2M3 12h2m14 0h2M5.6 5.6 7 7m10 10 1.4 1.4M5.6 18.4 7 17M17 7l1.4-1.4M16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0",
};

function setButtonIcon(button, name, label) {
  const doc = button.ownerDocument;
  const icon = doc.createElementNS("http://www.w3.org/2000/svg", "svg");
  for (const [key, value] of Object.entries({
    viewBox: "0 0 24 24", fill: "none", stroke: "currentColor",
    "stroke-width": "1.6", "stroke-linecap": "round", "stroke-linejoin": "round",
    "aria-hidden": "true", focusable: "false",
  })) icon.setAttribute(key, value);
  const path = doc.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", iconPaths[name] || iconPaths.moon);
  icon.append(path);
  button.replaceChildren(icon);
  button.title = label;
  button.setAttribute("aria-label", label);
}

export function formatElapsed(milliseconds) {
  const seconds = Math.max(0, Math.floor(milliseconds / 1000));
  return [Math.floor(seconds / 3600), Math.floor(seconds / 60) % 60, seconds % 60]
    .map((value) => String(value).padStart(2, "0")).join(":");
}

function fitPreview(frame) {
  const page = frame.firstElementChild;
  if (!page) return;
  const width = Number.parseFloat(page.style.width) * 4 / 3;
  const height = Number.parseFloat(page.style.height) * 4 / 3;
  if (!(width > 0 && height > 0)) return;
  frame.style.aspectRatio = `${width} / ${height}`;
  page.style.transform = `scale(${frame.clientWidth / width})`;
}

export function acceptsInput(target) {
  return !!target?.closest?.("input, textarea, select, [contenteditable]:not([contenteditable='false']), .speaker-notes");
}
