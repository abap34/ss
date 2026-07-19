export const svgNamespace = "http://www.w3.org/2000/svg";

export function element(tag, className) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  return node;
}

export function svgElement(tag, className) {
  const node = document.createElementNS(svgNamespace, tag);
  if (className) node.setAttribute("class", className);
  return node;
}

export function setAttributes(node, attributes) {
  for (const [name, value] of Object.entries(attributes)) {
    if (value != null) node.setAttribute(name, String(value));
  }
}

export function setRect(node, rect) {
  setAttributes(node, {
    x: rect.x,
    y: rect.y,
    width: Math.max(0, rect.width),
    height: Math.max(0, rect.height),
  });
}

export function color(value) {
  if (!Array.isArray(value)) return "transparent";
  return `rgb(${Math.round(value[0] * 255)} ${Math.round(value[1] * 255)} ${
    Math.round(value[2] * 255)
  })`;
}
