import { setAttributes, svgElement } from "./dom.js";

const definitions = Object.freeze({
  select: {
    viewBox: "0 0 20 20",
    path: "M3.5 2.2v14.1l3.8-3.5 2.7 5.1 2.5-1.3-2.7-5 5.2-.6z",
  },
  pan: {
    viewBox: "0 0 20 20",
    path: "M10 2v16M2 10h16M10 2 7 5M10 2l3 3M18 10l-3-3M18 10l-3 3M10 18l-3-3M10 18l3-3M2 10l3-3M2 10l3 3",
    stroke: true,
  },
});

export function toolIcon(name) {
  const definition = definitions[name];
  if (!definition) throw new Error(`unknown toolbar icon: ${name}`);
  const svg = svgElement("svg", `pointer-mode-icon pointer-mode-icon--${name}`);
  setAttributes(svg, {
    viewBox: definition.viewBox,
    "aria-hidden": "true",
    focusable: "false",
  });
  const path = svgElement("path");
  setAttributes(path, definition.stroke
    ? {
      d: definition.path,
      fill: "none",
      stroke: "currentColor",
      "stroke-width": 1.6,
      "stroke-linecap": "round",
      "stroke-linejoin": "round",
    }
    : { d: definition.path, fill: "currentColor" });
  svg.append(path);
  return svg;
}
