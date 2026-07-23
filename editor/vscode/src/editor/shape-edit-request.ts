import { WebviewMessage } from "./protocol";

export type ShapeEditMessage = Extract<WebviewMessage, {
  type: "insertShape" | "editShapeStyle" | "editLineGeometry" | "editShapeBounds";
}>;

export type ShapeEditOperation = "insert" | "style" | "geometry" | "resize";

interface ShapeEditRequest {
  method: string;
  params: object;
}

export function shapeEditOperation(
  message: ShapeEditMessage,
): ShapeEditOperation {
  switch (message.type) {
    case "insertShape":
      return "insert";
    case "editShapeStyle":
      return "style";
    case "editLineGeometry":
      return "geometry";
    case "editShapeBounds":
      return "resize";
  }
}

export function shapeEditRequest(
  documentUri: string,
  message: ShapeEditMessage,
): ShapeEditRequest {
  const common = {
    textDocument: { uri: documentUri },
    snapshotId: message.snapshotId,
    pageId: message.pageId,
  };
  switch (message.type) {
    case "insertShape":
      return {
        method: "ss/insertShape",
        params: "start" in message
          ? {
            ...common,
            kind: message.kind,
            start: message.start,
            end: message.end,
            arrowStart: message.arrowStart,
            arrowEnd: message.arrowEnd,
            stroke: message.stroke,
          }
          : {
            ...common,
            kind: message.kind,
            bounds: message.bounds,
            fill: message.fill,
            stroke: message.stroke,
          },
      };
    case "editShapeStyle":
      return {
        method: "ss/shapeStyleEdit",
        params: message.kind === "line"
          ? {
            ...common,
            nodeId: message.nodeId,
            arrowStart: message.arrowStart,
            arrowEnd: message.arrowEnd,
            stroke: message.stroke,
          }
          : {
            ...common,
            nodeId: message.nodeId,
            fill: message.fill,
            stroke: message.stroke,
          },
      };
    case "editLineGeometry":
      return {
        method: "ss/editLineGeometry",
        params: {
          ...common,
          nodeId: message.nodeId,
          start: message.start,
          end: message.end,
        },
      };
    case "editShapeBounds":
      return {
        method: "ss/editShapeBounds",
        params: {
          ...common,
          nodeId: message.nodeId,
          bounds: message.bounds,
        },
      };
  }
}
