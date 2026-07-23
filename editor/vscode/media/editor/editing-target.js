export function editingTargetByNode(snapshot, nodeId) {
  return snapshot?.editing?.find((candidate) =>
    candidate.node_id === nodeId
  ) || null;
}

export function editingTargetByBinding(snapshot, pageId, binding) {
  return snapshot?.editing?.find((candidate) =>
    candidate.page_id === pageId && candidate.binding === binding
  ) || null;
}

export function editingTargetKey(target) {
  return JSON.stringify([target.page_id, target.binding]);
}
