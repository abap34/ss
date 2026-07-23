import { setRect, svgElement } from "./dom.js";

const resizeHandleSize = Object.freeze({
  hit: 20,
  marker: 7,
});

export function createResizeHandle(
  kind,
  label,
  direction,
  bounds,
  editable,
) {
  const handle = svgElement(
    "g",
    `${kind}-handle${editable ? "" : " is-disabled"}`,
  );
  handle.setAttribute("aria-label", label);
  handle.setAttribute("aria-disabled", String(!editable));
  const hit = svgElement("rect", `${kind}-hit`);
  setCenteredSquare(hit, resizeHandleSize.hit);
  const marker = svgElement("rect", `${kind}-marker`);
  setCenteredSquare(marker, resizeHandleSize.marker);
  setResizeHandlePosition(handle, direction, bounds);
  handle.append(hit, marker);
  handle.addEventListener("click", (event) => event.stopPropagation());
  return handle;
}

export function setResizeHandlePosition(handle, direction, bounds) {
  const horizontal = direction.includes("left")
    ? bounds.x
    : direction.includes("right")
    ? bounds.x + bounds.width
    : bounds.x + bounds.width / 2;
  const vertical = direction.includes("top")
    ? bounds.y
    : direction.includes("bottom")
    ? bounds.y + bounds.height
    : bounds.y + bounds.height / 2;
  handle.setAttribute("transform", `translate(${horizontal} ${vertical})`);
}

function setCenteredSquare(rect, size) {
  const offset = -size / 2;
  setRect(rect, { x: offset, y: offset, width: size, height: size });
}
