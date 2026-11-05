const baselineCache = new Map();
const selectionRoots = new WeakSet();
const selectionDragDistance = 3;

export async function alignTextBaselines(root) {
  const document = root.nodeType === 9
    ? root
    : root.ownerDocument;
  if (!document) return;
  const runs = [...root.querySelectorAll(".ss-text-run[data-ss-baseline-y]")];
  if (runs.length === 0) return;
  if (!selectionRoots.has(root)) {
    selectionRoots.add(root);
    let pointerDown = null;
    root.addEventListener("pointerdown", (event) => {
      pointerDown = { x: event.clientX, y: event.clientY };
    });
    root.addEventListener("click", (event) => {
      const start = pointerDown;
      pointerDown = null;
      const link = event.target.closest?.("a.ss-text-select[href]");
      if (!link || event.detail === 0 || !start ||
          Math.hypot(event.clientX - start.x, event.clientY - start.y) <= selectionDragDistance) return;
      const selection = document.getSelection();
      if (selection && !selection.isCollapsed && selection.containsNode(link, true)) event.preventDefault();
    });
  }

  const pending = new Map();
  for (const run of runs) {
    const style = getComputedStyle(run);
    const key = baselineKey(style, run);
    if (baselineCache.has(key) || pending.has(key)) continue;
    const probe = createProbe(document, style, run);
    document.body.append(probe.element);
    pending.set(key, probe);
  }

  try {
    await document.fonts.ready;
    for (const [key, probe] of pending) {
      const box = probe.element.getBoundingClientRect();
      const marker = probe.marker.getBoundingClientRect();
      baselineCache.set(key, marker.bottom - box.top);
    }
  } finally {
    for (const probe of pending.values()) probe.element.remove();
  }

  for (const run of runs) {
    const baselineY = Number(run.dataset.ssBaselineY);
    if (!Number.isFinite(baselineY)) continue;
    const browserBaseline = baselineCache.get(baselineKey(getComputedStyle(run), run));
    if (!Number.isFinite(browserBaseline)) continue;
    run.style.top = `calc(${baselineY}pt - ${browserBaseline}px)`;
    const selection = run.querySelector(".ss-text-select");
    if (selection) {
      const width = Number.parseFloat(getComputedStyle(run).width);
      const naturalWidth = Number.parseFloat(getComputedStyle(selection).width);
      if (width > 0 && naturalWidth > 0) selection.style.transform = `scaleX(${width / naturalWidth})`;
    }
  }
}

function baselineKey(style, run) {
  return [
    style.fontFamily,
    style.fontSize,
    style.fontWeight,
    style.fontStyle,
    style.fontStretch,
    style.fontFeatureSettings,
    style.fontVariationSettings,
    style.fontOpticalSizing,
    style.lineHeight,
    run.lang,
  ].join("\u0000");
}

function createProbe(document, style, run) {
  const element = document.createElement("span");
  Object.assign(element.style, {
    position: "fixed",
    left: "-100000px",
    top: "0",
    width: "max-content",
    visibility: "hidden",
    pointerEvents: "none",
    whiteSpace: "pre",
    fontFamily: style.fontFamily,
    fontSize: style.fontSize,
    fontWeight: style.fontWeight,
    fontStyle: style.fontStyle,
    fontStretch: style.fontStretch,
    fontFeatureSettings: style.fontFeatureSettings,
    fontVariationSettings: style.fontVariationSettings,
    fontOpticalSizing: style.fontOpticalSizing,
    fontKerning: "none",
    fontSynthesis: "none",
    lineHeight: style.lineHeight,
  });
  element.lang = run.lang;
  element.dir = run.dir;
  element.append(document.createTextNode(probeText(run)));
  const marker = document.createElement("span");
  Object.assign(marker.style, {
    display: "inline-block",
    width: "0",
    height: "0",
    padding: "0",
    margin: "0",
    verticalAlign: "baseline",
  });
  element.append(marker);
  return { element, marker };
}

function probeText(run) {
  const cluster = run.querySelector(".ss-text-cluster");
  return cluster?.textContent || run.textContent || "M";
}
