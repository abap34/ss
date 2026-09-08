/** @param {Pick<import("../../src/editor/protocol.js").EditorSnapshot, "editing"> | null} snapshot
 * @param {number} nodeId */
export function editingTargetByNode(snapshot, nodeId) {
  return snapshot?.editing?.find((candidate) =>
    candidate.node_id === nodeId
  ) || null;
}

/** @param {Pick<import("../../src/editor/protocol.js").EditorSnapshot, "editing"> | null} snapshot
 * @param {number} pageId
 * @param {string} binding */
export function editingTargetByBinding(snapshot, pageId, binding) {
  return snapshot?.editing?.find((candidate) =>
    candidate.page_id === pageId && candidate.binding === binding
  ) || null;
}

/** @param {{page_id: number, binding: string}} target */
export function editingTargetKey(target) {
  return JSON.stringify([target.page_id, target.binding]);
}
