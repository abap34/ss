import { setAttributes, svgElement } from "./dom.js";

const markerRadius = 3;

export function updateSnapGuides(layer, guides, scale) {
  layer.replaceChildren();
  for (const guide of guides) {
    const vertical = guide.axis === "x";
    const line = svgElement("line", "snap-guide");
    setAttributes(line, vertical
      ? { x1: guide.coordinate, x2: guide.coordinate, y1: guide.start, y2: guide.end }
      : { x1: guide.start, x2: guide.end, y1: guide.coordinate, y2: guide.coordinate });
    layer.append(line);
    for (const point of guide.points) {
      const x = vertical ? guide.coordinate : point;
      const y = vertical ? point : guide.coordinate;
      const marker = svgElement("path", "snap-marker");
      const dx = markerRadius / scale.x;
      const dy = markerRadius / scale.y;
      marker.setAttribute("d", `M${x - dx} ${y}H${x + dx}M${x} ${y - dy}V${y + dy}`);
      layer.append(marker);
    }
  }
}
