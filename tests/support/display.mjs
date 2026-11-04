import assert from "node:assert/strict";

export function inputField(record, name) {
  const value = record.fields.find(field => field.name === name)?.value;
  assert(value, `Missing input field: ${name}`);
  return value;
}

export function imageSourceIs(node, kind) {
  return node.placement?.display.kind === "image"
    && inputField(inputField(node.placement.input, "source"), "kind").case === kind;
}

export function displayLeaf(nodes, node) {
  while (node.placement.display.state === "expanded") {
    assert.equal(node.placement.children.length, 1);
    node = nodes.find(child => child.id === node.placement.children[0]);
    assert(node);
  }
  assert(["text", "image", "path_shape"].includes(node.placement.display.kind));
  return node;
}
