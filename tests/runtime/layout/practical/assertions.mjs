import assert from "node:assert/strict";

// Dump coordinates are rounded to one decimal place; font measurements are not
// pinned to one operating system. Explicit geometry is checked to 0.2 points.
export const tolerance = 0.2;
// Table borders are centered on the logical edge (0.8-point default stroke).
const inkTolerance = 0.6;
export const top = (item) => item.y + item.height;
export const right = (item) => item.x + item.width;
export const center = (item) => item.y + item.height / 2;
export const close = (actual, expected, label) => assert(Math.abs(actual - expected) <= tolerance, `${label}: expected ${expected}, got ${actual}`);

export function pageObjects(dump, name) {
  const page = dump.nodes.find((item) => item.kind === "page" && item.name === name);
  assert(page, `missing page ${name}`);
  const ids = new Set();
  function visit(id) {
    for (const child of dump.contains.find((entry) => entry.parent === id)?.children ?? []) {
      if (ids.has(child)) continue;
      ids.add(child);
      visit(child);
    }
  }
  visit(page.id);
  return dump.nodes.filter((item) => ids.has(item.id));
}

export function item(dump, page, prefix) {
  const found = pageObjects(dump, page).filter((entry) => entry.content?.startsWith(prefix));
  assert.equal(found.length, 1, `${page}: expected one object starting with ${JSON.stringify(prefix)}`);
  return found[0];
}

export function contains(outer, inner, label, padding = 0) {
  assert(inner.x >= outer.x + padding - tolerance && right(inner) <= right(outer) - padding + tolerance &&
    inner.y >= outer.y + padding - tolerance && top(inner) <= top(outer) - padding + tolerance,
  `${label}: child frame escapes its container (${JSON.stringify({ outer: frame(outer), inner: frame(inner) })})`);
}

export function frame(item) {
  return { x: item.x, y: item.y, width: item.width, height: item.height };
}

export function assertHealthy(dump) {
  assert.deepEqual(dump.diagnostics, [], "practical layout must not produce diagnostics");
  for (const page of dump.nodes.filter((node) => node.kind === "page")) {
    const nodes = pageObjects(dump, page.name);
    assert(nodes.length > 3, `${page.name}: empty content`);
    for (const node of nodes) {
      for (const [key, value] of Object.entries(frame(node))) assert(Number.isFinite(value), `${page.name}/${node.id}: non-finite ${key}`);
      assert(node.width > 0 && node.height > 0, `${page.name}/${node.id}: collapsed frame`);
      contains(page, node, `${page.name}/${node.id}: page bounds`);
      if (node.role === "group") {
        for (const id of dump.contains.find((entry) => entry.parent === node.id)?.children ?? []) {
          const child = nodes.find((entry) => entry.id === id);
          assert(child, `${page.name}: missing child ${id}`);
          contains(node, child, `${page.name}/${node.id}: group bounds`);
        }
      }
      if (!["text", "code"].includes(node.render?.kind) || !node.content) continue;
      const measurement = node.measurement;
      assert(measurement, `${page.name}/${node.id}: missing text measurement`);
      close(measurement.measured_width, node.width, `${page.name}/${node.id}: stale measured width`);
      for (const key of ["logical_bounds", "ink_bounds"]) {
        const bounds = measurement[key];
        const allowance = key === "ink_bounds" ? inkTolerance : tolerance;
        assert(bounds.x >= -allowance && bounds.y >= -allowance && bounds.x + bounds.width <= node.width + allowance && bounds.y + bounds.height <= node.height + allowance,
          `${page.name}/${node.id}: clipped ${key}: ${JSON.stringify(bounds)} in ${JSON.stringify(frame(node))}`);
      }
    }
    const leaves = nodes.filter((node) => node.role !== "group");
    for (let i = 0; i < leaves.length; i += 1) {
      for (const b of leaves.slice(i + 1)) {
        const a = leaves[i];
        const overlapX = Math.min(right(a), right(b)) - Math.max(a.x, b.x);
        const overlapY = Math.min(top(a), top(b)) - Math.max(a.y, b.y);
        assert(overlapX <= tolerance || overlapY <= tolerance, `${page.name}: overlapping objects ${a.id} and ${b.id}`);
      }
    }
    const numbers = leaves.filter((node) => node.role === "pageno");
    assert.equal(numbers.length, 1, `${page.name}: missing or duplicated page number`);
    close(numbers[0].y, 20, `${page.name}: footer position`);
  }
}

export function assertPractical(dump, { width = 1000, centered = false, cardShift = 0, cardDrop = 0 } = {}) {
  assertHealthy(dump);
  assert.equal(dump.page_order.length, 6, "practical page count");
  const description = item(dump, "columns", "## Collection notes");
  const upper = item(dump, "columns", "## Input summary");
  const lower = item(dump, "columns", "## Output summary");
  close(description.x, 120, "column left margin");
  close(description.width, (width - 32) / 2, "equal column width");
  close(upper.width, description.width, "upper column width");
  close(lower.width, description.width, "lower column width");
  close(upper.x, 120 + (width + 32) / 2, "right column position");
  close(lower.x, upper.x, "right column alignment");
  close(upper.height, 204, "upper cell height");
  close(lower.height, 204, "lower cell height");
  close(top(upper), 540, "column top");
  close(top(lower), upper.y - 32, "vertical split gap");
  close(centered ? center(description) : top(description), centered ? 320 : 540, "column policy alignment");

  for (const [prefix, x, y] of [["## Observe", 142, 336], ["## Compare", 142, 114], ["## Explain", 646, 336], ["## Review", 646, 114]]) {
    const cell = item(dump, "matrix", prefix);
    close(cell.x, x, `${prefix}: nested horizontal padding`);
    close(cell.y, y, `${prefix}: nested vertical padding`);
    const column = dump.nodes.find((node) => node.role === "group" &&
      dump.contains.some((entry) => entry.parent === node.id && entry.children.includes(cell.id)));
    assert(column, `${prefix}: missing column group`);
    close(column.width, 472, `${prefix}: equal parent column width`);
    // Vertical splitting fixes height; short text keeps its natural width.
    assert(cell.width <= 452 + tolerance, `${prefix}: text exceeds padded column width`);
    close(cell.height, 190, `${prefix}: padded row height`);
  }

  const table = item(dump, "table_code", "| stage |");
  const tableNote = item(dump, "table_code", "Table note:");
  const program = item(dump, "table_code", "records =");
  const codeNote = item(dump, "table_code", "Program note:");
  close(table.width, 484, "table final width");
  close(program.width, 484, "code final width");
  assert(table.height > 200, "table rows did not wrap");
  assert(program.height > 70, "code lost its line breaks");
  close(top(tableNote), table.y - 20, "table follower gap");
  close(top(codeNote), program.y - 20, "code follower gap");
  close(program.x, table.x + 516, "table/code columns");

  const flow = [item(dump, "flow", "Flow introduction:"), item(dump, "flow", "- First,"), item(dump, "flow", "Flow conclusion:")];
  assert(flow[0].height > 40, "flow introduction did not wrap");
  assert(top(flow[0]) < item(dump, "flow", "A heading followed").y - tolerance, "flow introduction moved above its heading");
  for (const [index, object] of flow.entries()) {
    close(object.width, 680, "flow width");
    if (index) assert(top(object) < flow[index - 1].y - tolerance, "flow block ordering or spacing changed");
  }

  const diagram = item(dump, "image_caption", "diagram.svg");
  const caption = item(dump, "image_caption", "Diagram caption:");
  const annotation = item(dump, "image_caption", "## Reading the diagram");
  close(diagram.width, 640, "image width");
  close(diagram.height, 320, "image aspect ratio");
  close(diagram.x, 120, "image group left margin");
  close(top(diagram), 550, "image group top margin");
  close(top(caption), diagram.y - 20, "image/caption gap");
  close(annotation.x, right(diagram) + 32, "side note gap");
  close(center(annotation), center(diagram), "side note center");

  const cards = ["## Collect\n", "## Transform\n", "## Inspect\n"].map((prefix) => item(dump, "cards", prefix));
  for (const [index, card] of cards.entries()) {
    close(card.x, 150 + cardShift + index * 324, "card horizontal position");
    close(top(card), 510 - cardDrop, "card top alignment");
    close(card.width, 300, "card width");
    close(card.height, 170, "card height");
  }
  const summary = item(dump, "cards", "Card summary:");
  close(summary.x, cards[0].x, "summary left alignment");
  close(top(summary), cards[0].y - 28, "summary follows moved group");
}

export function geometry(dump, pageName) {
  return (pageName ? pageObjects(dump, pageName) : dump.nodes.filter((item) => item.kind === "object"))
    .map((item) => ({ id: item.id, role: item.role, content: item.content, ...frame(item) }));
}
