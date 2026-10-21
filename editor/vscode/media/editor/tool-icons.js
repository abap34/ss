import { setAttributes, svgElement } from "./dom.js";

// Selection icons from Lucide, revision c29c276f16590cf017126671535ad8c792be64d8.
// https://github.com/lucide-icons/lucide — see tool-icons.LICENSE.
const definitions = Object.freeze({
  source: {
    path: "m10 9-3 3 3 3m4 0 3-3-3-3",
    rect: { x: 3, y: 3, width: 18, height: 18, rx: 2 },
  },
  lock: {
    path: "M7 11V7a5 5 0 0 1 10 0v4",
    rect: { width: 18, height: 11, x: 3, y: 11, rx: 2, ry: 2 },
  },
  unlock: {
    path: "M7 11V7a5 5 0 0 1 9.9-1",
    rect: { width: 18, height: 11, x: 3, y: 11, rx: 2, ry: 2 },
  },
  bounds: {
    path: "M3 7V5a2 2 0 0 1 2-2h2m10 0h2a2 2 0 0 1 2 2v2m0 10v2a2 2 0 0 1-2 2h-2M7 21H5a2 2 0 0 1-2-2v-2",
  },
  constraints: {
    path: "M9 17H7A5 5 0 0 1 7 7h2m6 0h2a5 5 0 1 1 0 10h-2M8 12h8",
  },
  style: {
    path: "M10 5H3m9 14H3M14 3v4m2 10v4m5-9h-9m9 7h-5m5-14h-7M8 10v4m0-2H3",
  },
  close: {
    path: "M18 6 6 18M6 6l12 12",
  },
  restart: {
    path: "M12 2v10M18.4 5.6a9 9 0 1 1-12.8 0",
  },
  select: {
    viewBox: "0 0 20 20",
    filled: true,
    path: "M3.5 2.2v14.1l3.8-3.5 2.7 5.1 2.5-1.3-2.7-5 5.2-.6z",
  },
  pan: {
    viewBox: "0 0 20 20",
    path: "M10 2v16M2 10h16M10 2 7 5M10 2l3 3M18 10l-3-3M18 10l-3 3M10 18l-3-3M10 18l3-3M2 10l3-3M2 10l3 3",
    strokeWidth: 1.6,
  },
});

export function toolIcon(name) {
  const definition = definitions[name];
  if (!definition) throw new Error(`unknown toolbar icon: ${name}`);
  const svg = svgElement("svg", `pointer-mode-icon pointer-mode-icon--${name}`);
  setAttributes(svg, {
    viewBox: definition.viewBox || "0 0 24 24",
    "aria-hidden": "true",
    focusable: "false",
    ...(!definition.filled ? {
      fill: "none",
      stroke: "currentColor",
      "stroke-width": definition.strokeWidth ?? 2,
      "stroke-linecap": "round",
      "stroke-linejoin": "round",
    } : { fill: "currentColor" }),
  });
  const path = svgElement("path");
  setAttributes(path, { d: definition.path });
  svg.append(path);
  if (definition.rect) {
    const rect = svgElement("rect");
    setAttributes(rect, definition.rect);
    svg.append(rect);
  }
  return svg;
}
