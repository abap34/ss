import { setAttributes, svgElement } from "./dom.js";
import {
  anchorSegment,
  constraintGeometry,
  frameByNode,
  signed,
} from "./geometry.js";

export function renderConstraints(snapshot, page, objectId, resolveFrame) {
  const group = svgElement("g", "constraint-layer");
  for (
    const relation of snapshot.layout.relations.filter((item) =>
      item.target?.node_id === objectId
    )
  ) {
    const sourceFrame = relation.source.type === "page"
      ? { x: 0, y: 0, width: page.width, height: page.height }
      : resolveFrame?.(relation.source.node_id) ??
        frameByNode(snapshot, page, relation.source.node_id);
    const targetFrame = resolveFrame?.(relation.target.node_id) ??
      frameByNode(snapshot, page, relation.target.node_id);
    if (!sourceFrame || !targetFrame) continue;
    const sourceSegment = anchorSegment(sourceFrame, relation.source.anchor);
    const targetSegment = anchorSegment(targetFrame, relation.target.anchor);
    const geometry = constraintGeometry(
      sourceSegment,
      targetSegment,
      relation.axis,
    );
    const sourceKind = relation.source.type === "page" ? "page" : "object";
    const relationGroup = svgElement(
      "g",
      `constraint constraint--${sourceKind}${
        relation.kind === "fallback" ? " constraint--fallback" : ""
      }`,
    );
    relationGroup.append(
      segmentLine(
        geometry.source,
        "constraint-anchor constraint-anchor--source",
      ),
    );
    relationGroup.append(
      segmentLine(
        geometry.target,
        "constraint-anchor constraint-anchor--target",
      ),
    );
    const connector = svgElement("line", "constraint-connector");
    setAttributes(connector, {
      x1: geometry.connector.x1,
      y1: geometry.connector.y1,
      x2: geometry.connector.x2,
      y2: geometry.connector.y2,
    });
    relationGroup.append(connector);
    const label = svgElement("text", "constraint-offset");
    setAttributes(label, {
      x: geometry.label.x,
      y: geometry.label.y,
    });
    label.textContent = signed(relation.offset);
    relationGroup.append(label);
    group.append(relationGroup);
  }
  return group;
}

function segmentLine(value, className) {
  const line = svgElement("line", className);
  setAttributes(line, value);
  return line;
}
