export function editorSnapshot() {
  return {
    schema: 1,
    kind: "ss-editor-snapshot",
    snapshot_id: "10-current",
    generation: 10,
    entry_path: "/workspace/slide.ss",
    source_paths: ["/workspace/slide.ss"],
    coordinate_space: { unit: "pt", origin: "page-top-left", x_axis: "right", y_axis: "down" },
    layout: {
      pages: [
        { id: 11, index: 1, name: "Overview", width: 1280, height: 720 },
        { id: 22, index: 2, name: "Details", width: 1280, height: 720 },
      ],
      objects: [
        { id: 101, page_id: 11, name: "summary", role: "body", x: 100, y: 500, width: 360, height: 100, group: false },
        { id: 201, page_id: 22, name: "anchor", role: "label", x: 60, y: 530, width: 120, height: 60, group: false },
        {
          id: 202,
          page_id: 22,
          name: "detail",
          role: "body",
          x: 240,
          y: 470,
          width: 380,
          height: 120,
          group: false,
          location: { path: "/workspace/slide.ss", line: 8, column: 1, start: 40, end: 75 },
        },
      ],
      anchors: [],
      relations: [
        relation(0, "explicit", "horizontal", 240, "~ detail.left == page.left + 240", "page", null, "left", "left"),
        relation(1, "explicit", "horizontal", 60, "~ detail.left == anchor.right + 60", "node", 201, "right", "left"),
        relation(2, "fallback", "vertical", 130, "~!~ detail.top == page.top - 130", "page", null, "top", "top"),
      ],
      failures: [],
    },
    display: {
      schema: 2,
      html: sharedHtml(),
      css: ".ss-page{position:relative;overflow:hidden;background:#fff}.ss-item{position:absolute}.ss-box{background:#b7d8d0}.ss-pdf{overflow:hidden}.ss-pdf>canvas,.ss-pdf-layer{position:absolute;inset:0;width:100%;height:100%}.ss-pdf-layer{overflow:hidden}",
      has_pdf: true,
      assets: [],
    },
    outline: [
      { id: 11, parent_id: null, page_id: 11, kind: "page", label: "Overview" },
      { id: 101, parent_id: 11, page_id: 11, kind: "object", label: "Summary" },
      { id: 22, parent_id: null, page_id: 22, kind: "page", label: "Details" },
      { id: 201, parent_id: 22, page_id: 22, kind: "object", label: "Anchor" },
      { id: 202, parent_id: 22, page_id: 22, kind: "object", label: "Detail" },
    ],
    editing: [
      { node_id: 101, page_id: 11, page_index: 1, page_name: "Overview", binding: "summary", binding_required: false, statement_start: 0, statement_end: 20, path: "/workspace/slide.ss", page_start: 0, page_end: 30 },
      { node_id: 202, page_id: 22, page_index: 2, page_name: "Details", binding: "detail", binding_required: false, statement_start: 40, statement_end: 75, path: "/workspace/slide.ss", page_start: 31, page_end: 90 },
    ],
  };
}

export function testDocument() {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; worker-src 'self' blob:; connect-src 'self'; font-src 'self' data:"><link rel="stylesheet" href="main.css"></head>
<body><div id="app"></div><script>
globalThis.__messages = [];
globalThis.__persisted = {};
globalThis.acquireVsCodeApi = () => ({
  postMessage(message) { globalThis.__messages.push(structuredClone(message)); },
  getState() { return globalThis.__persisted; },
  setState(value) { globalThis.__persisted = structuredClone(value); },
});
</script><script type="module" src="main.js"></script></body></html>`;
}

function relation(index, kind, axis, offset, expression, sourceType, sourceNode, sourceAnchor, targetAnchor) {
  return {
    index,
    kind,
    axis,
    offset,
    expression,
    location: { path: "/workspace/slide.ss", line: 10 + index, column: 1, start: 50 + index, end: 60 + index },
    source: { type: sourceType, node_id: sourceNode, label: sourceType === "page" ? "page" : "anchor", anchor: sourceAnchor },
    target: { type: "node", node_id: 202, label: "detail", anchor: targetAnchor },
  };
}

function sharedHtml() {
  return `<section class="ss-page" data-ss-page-id="11" style="width:1280pt;height:720pt"><div class="ss-item ss-box" data-ss-item-id="4294967297" data-ss-node-id="101" style="left:100pt;top:120pt;width:360pt;height:100pt"></div><div class="ss-item ss-pdf" data-pdf-src="asset.pdf" data-page="1" data-view-box="0,0,240,120" data-rotation="0" data-canvas-background="transparent" data-copy-annotations="false" style="left:600pt;top:120pt;width:200pt;height:100pt"><div class="ss-pdf-layer ss-pdf-text"></div><div class="ss-pdf-layer ss-pdf-annotations"></div></div></section><section class="ss-page" data-ss-page-id="22" style="width:1280pt;height:720pt"><div class="ss-item ss-box" data-ss-item-id="8589934593" data-ss-node-id="201" style="left:60pt;top:130pt;width:120pt;height:60pt"></div><div class="ss-item ss-box" data-ss-item-id="8589934594" data-ss-node-id="202" style="left:240pt;top:130pt;width:380pt;height:120pt"></div></section>`;
}
