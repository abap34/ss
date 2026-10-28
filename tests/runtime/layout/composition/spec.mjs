#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { root, ssBin, withLspClient } from "../../harness.mjs";
import { editorSnapshot } from "../../editor/support.mjs";

const outputRoot = path.join(root, ".test-tmp", "layout-composition");
await mkdir(outputRoot, { recursive: true });
const output = await mkdtemp(path.join(outputRoot, "run-"));
const gap = 32;
const groupSpacingAfter = 24;
const constraintTolerance = 0.01;
let caseCount = 0;

const prelude = `import std:prelude as *

type Box { label: String width: Number height: Number }
fn box(label: String, width: Number, height: Number) -> Box
  return Box { label = label width = width height = height }
end
fn display(self: Placed<Box>) -> PathShape
  return rectangle(self.value.width, self.value.height)
end
`;
const boxes = `let a = box("A", 120, 80)
let b = box("B", 180, 60)
let c = box("C", 90, 50)`;
const anchor = `~ placed.left == page.left + 80
~ placed.top == page.top - 80`;

const failures = [];
for (const test of [
  testAuthoredPlacementOrder, testNestedUnplacedObjectsAndOrdinaryGroup,
  testIntermediateBinding, testUnusedCompositionValues, testNestedOrdinaryGroupBounds,
  testNaturalWidths, testEqualFrames, testNestedSplitPlacement, testMeasuredSplitFlow, testMeasuredNestedConstraintUpdate, testHorizontalSplitWidths, testVerticalSplitWidths, testEqualChains, testEqualEvaluation, testEqualEditorUpdates, testSameDirectionBinaryGroups,
  testSharedValues, testConstraintUpdate, testPlacedGroupConstraintUpdate,
  testExplicitGap, testOperandEvaluation, testFixedStdlibResolution, testImportedFunctionComposition,
  testInvalidOperands, testConflictsAndMixedDirections, testHorizontalPolicyVariants,
  testHorizontalPolicyInheritance, testNestedHorizontalPolicy, testPolicyAfterPagePlacement,
  testExplicitVerticalPositionPriority, testDefaultAlignmentUpdates, testCenteredChainAndVerticalComposition,
  testFixedRightDoesNotMoveLeft, testFixture,
]) {
  try { await test(); } catch (error) {
    failures.push(test.name);
    console.error(`${test.name}: ${error.message}`);
  }
}
assert(failures.length === 0, `failed composition tests: ${failures.join(", ")}`);
console.log(`layout composition: ${caseCount} cases passed`);

async function testAuthoredPlacementOrder() {
  const { dump } = await dumpSource("authored-placement-order", `import std:themes/default as *
page main
  text!(str(docctx().layout_h_center_offset))
  text!("Second")
end
document
  docctx().layout_h_center_offset = 42
end
`);
  const first = node(dump, "42");
  const second = node(dump, "Second");
  assert(first.y > second.y, "fallback placement followed evaluation order instead of composition order");
  const roots = dump.placement_roots.flatMap((entry) => entry.roots);
  assert(roots.indexOf(first.id) < roots.indexOf(second.id), "placement roots lost authored order");
}

async function testNestedUnplacedObjectsAndOrdinaryGroup() {
  const { dump, source } = await dumpSource("nested-values", `${prelude}
page main
vflow(LayoutPolicy.top)
${boxes}
let placed = place!(a || (b // c))
${anchor}
end
`);
  assertNestedFrames(dump);
  assert.equal(dump.diagnostics.length, 0);
  const groups = groupNodes(dump);
  assert.equal(groups.length, 2);
  const roots = dump.placement_roots.flatMap(entry => entry.roots);
  assert.equal(roots.length, 1);
  const outer = groups.find(item => item.id === roots[0]);
  assertClose(outer.width, 120 + gap + 180, "outer bounding width");
  assertClose(outer.height, 60 + gap + 50, "outer bounding height");
  const b = node(dump, "B");
  const c = node(dump, "C");
  const vertical = relation(dump.constraints, c, "top", b, "bottom", -gap);
  assert(vertical && vertical.role === "position");
  assert(vertical.origin?.path?.endsWith("slide.ss"));
  assert(source.slice(vertical.origin.start, vertical.origin.end).includes("//"), "composition lost its operator source span");
}

async function testIntermediateBinding() {
  const variants = [];
  for (const [name, binding, expression] of [
    ["nested", "", "a || (b // c)"],
    ["bound", "let right = b // c", "a || right"],
  ]) {
    variants.push((await dumpSource(name, `${prelude}
page main
vflow(LayoutPolicy.top)
${boxes}
${binding}
let placed = place!(${expression})
${anchor}
end
`)).dump);
  }
  for (const label of ["A", "B", "C"]) for (const key of ["x", "y", "width", "height"]) {
    assertClose(node(variants[0], label)[key], node(variants[1], label)[key], `binding changed ${label}.${key}`);
  }
}

async function testUnusedCompositionValues() {
  const plain = await dumpSource("unused-plain", "page main\ntext!(\"Visible\")\nend\n");
  const unused = await dumpSource("unused-values", `${prelude}
page main
text!("Visible")
${boxes}
a || (b // c)
group(a, b)
end
`);
  assert.equal(groupNodes(unused.dump).length, 0);
  assert.equal(unused.dump.placement_roots.flatMap(entry => entry.roots).length, 1);
  assert.equal(unused.dump.nodes.filter(item => item.placement?.input.type?.name === "Box").length, 0);
  for (const key of ["x", "y", "width", "height"]) assertClose(node(unused.dump, "Visible")[key], node(plain.dump, "Visible")[key], `unused values changed ${key}`);
}

async function testNestedOrdinaryGroupBounds() {
  const { dump } = await dumpSource("nested-bounds", `${prelude}
page main
vflow(LayoutPolicy.top)
${boxes}
let placed = place!(box("D", 100, 180) || ((a || b) // c))
let outer = first(select<Group<Group<Box, Box>, Box>>(placed))
let e = place!(box("E", 50, 40))
let f = place!(box("F", 50, 40))
${anchor}
~ e.left == outer.right + 16
~ e.top == outer.top
~ f.left == outer.left
~ f.top == outer.bottom - 16
end
`);
  const a = node(dump, "A"), b = node(dump, "B"), c = node(dump, "C");
  const d = node(dump, "D"), e = node(dump, "E"), f = node(dump, "F");
  assertClose(a.x, d.x + d.width + gap, "nested group left boundary");
  assertClose(top(a), top(d), "nested group top boundary");
  assertClose(b.x, a.x + a.width + gap, "nested first row");
  assertClose(c.x, a.x, "nested second row alignment");
  assertClose(top(c), a.y - gap, "nested second row gap");
  assertClose(e.x, a.x + 120 + gap + 180 + 16, "outer right includes nested group");
  assertClose(top(e), top(a), "outer top includes nested group");
  assertClose(f.x, a.x, "outer left includes nested group");
  assertClose(top(f), top(a) - 80 - gap - 50 - 16, "outer bottom includes both rows");
  assert.equal(groupNodes(dump).length, 3);
  assert.equal(dump.placement_roots.flatMap(entry => entry.roots).length, 3);
  assert.equal(dump.diagnostics.length, 0);
}

async function testNaturalWidths() {
  const { dump } = await dumpSource("natural-widths", `page main
place!(text("short") || text("a considerably longer line"))
end
`);
  const a = node(dump, "short"), b = node(dump, "a considerably longer line");
  assert(b.width > a.width * 2, `composition equalized natural widths: ${a.width}, ${b.width}`);
  assertClose(b.x, a.x + a.width + gap, "natural horizontal gap");
  assertClose(centerY(b), centerY(a), "natural center alignment");
}

async function testEqualFrames() {
  const leaves = `let a = text("Short")
let b = text("A longer description with a different natural width")
let c = text("Third item")`;
  for (const [name, expression] of [
    ["horizontal", "a |=| b"], ["vertical", "a /=/ b"],
    ["nested", "a |=| (b /=/ c)"], ["transposed", "(a |=| b) /=/ c"],
    ["horizontal-chain", "a |=| b |=| c"], ["vertical-chain", "a /=/ b /=/ c"],
    ["horizontal-grouped", "(a |=| b) |=| c"], ["vertical-grouped", "a /=/ (b /=/ c)"],
    ["horizontal-natural-child", "a |=| (b // c)"], ["vertical-natural-child", "(a || b) /=/ c"],
  ]) {
    for (const spacing of [24, 48]) {
      const { dump } = await dumpSource(`equal-${name}-${spacing}`, `${prelude}
page equal
vflow(LayoutPolicy.center)
${leaves}
let g = place!((${expression}) with { gap = ${spacing} })
~ g.width == 1000
~ g.height == 400
~ g.left == page.left + 100
~ g.top == page.top - 100
end
`);
      const g = groupNodes(dump).find((item) => dump.placement_roots.some((entry) => entry.roots.includes(item.id)));
      assertClose(g.x, 100, "outer left");
      assertClose(top(g), 620, "outer top");
      assertClose(g.width, 1000, "outer width");
      assertClose(g.height, 400, "outer height");
      assertSplitTree(dump, g);
    }
  }

  for (const operator of ["|=|", "/=/"]) {
    const horizontal = operator === "|=|";
    const split = await dumpSource(`natural-split-${horizontal}`, `${prelude}
page natural
vflow(LayoutPolicy.top)
let g = place!(text("Short") ${operator} text("A longer line for natural measurement"))
end
`);
    const after = groupNodes(split.dump)[0];
    assertClose(after.width, 1088, "implicit outer width");
    const children = split.dump.contains.find((entry) => entry.parent === after.id)?.children;
    const contentHeight = Math.max(...split.dump.nodes.filter((item) => children.includes(item.id)).map((item) => item.height));
    assertClose(after.height, horizontal ? contentHeight : 2 * contentHeight + gap, "implicit outer height fits final-width contents");
    assertSplitTree(split.dump, after);
  }

  const { dump } = await dumpSource("equal-edges-wrap", `${prelude}
page edges
let a = text("Short")
let b = text("${"Words need to wrap inside their assigned column. ".repeat(8)}")
let g = place!(a |=| b)
~ g.left == page.left + 100
~ g.right == page.left + 900
~ g.bottom == page.bottom + 100
~ g.top == page.bottom + 600
end
`);
  const g = groupNodes(dump)[0];
  assertClose(g.width, 800, "opposing edges determine outer width");
  assertClose(g.height, 500, "opposing edges determine outer height");
  assert(node(dump, "Short").height < dump.nodes.find((item) => item.content?.startsWith("Words need")).height, "text was not measured at the split width");
  assertSplitTree(dump, g);

  for (const [name, operator, dimensions] of [
    ["width-conflict", "|=|", "~ a.width == 100\n~ b.width == 200"],
    ["height-conflict", "/=/", "~ a.height == 100\n~ b.height == 200"],
    ["insufficient-space", "|=|", "~ g.width == 20"],
  ]) {
    await expectFailure(name, `${prelude}
page conflict
let g = place!(text("A") ${operator} text("B"))
let a = first(children(g))
let b = first(children(g) - selection(a))
${dimensions}
end
`, name === "insufficient-space" ? "NegativeFrameSize" : "ConstraintConflict");
  }

  const updated = await dumpSource("equal-horizontal-update", `${prelude}
page update
let g = place!(text("A") |=| text("B"))
let a = first(children(g))
let b = first(children(g) - selection(a))
~ g.width == 800
~ g.height == 300
~ g.left == page.left + 80
~ g.top == page.top - 100
~!~ b.left == page.left + 900
end
`);
  const right = node(updated.dump, "B");
  assertClose(right.x, 900, "position update did not override split constraints");
  assert(!updated.dump.constraints.some((item) => item.group_split && item.target_node === right.id && ["left", "right"].includes(item.target_anchor)), "removed split constraints were regenerated");
  assert(updated.dump.overridden_constraints.filter((item) => item.group_split && item.target_node === right.id && ["left", "right"].includes(item.target_anchor)).length === 2, "both split edges must participate in update normalization");

  for (const [index, scenario] of ["|=|", "/=/"].flatMap((operator) =>
    ["top", "center"].flatMap((policy) => [40, 80].map((offset) => ({ operator, policy, offset }))),
  ).entries()) {
    const { operator, policy, offset } = scenario;
    const { dump } = await dumpSource(`equal-first-update-${index}`, `import std:themes/default as *
page update
vflow(LayoutPolicy.${policy})
let g = place!(text("Move me") ${operator} text("Guide"))
~ g.left == page.left + 80
~ g.top == page.top - 100
~ g.width == 800
~ g.height == 300
let a = first(children(g))
~!~ a.left == page.left + 97
~!~ a.top == page.top - ${offset}
end
`);
    const first = node(dump, "Move me");
    const second = node(dump, "Guide");
    assertClose(first.x, 97, "first cell horizontal update");
    assertClose(top(first), 720 - offset, "first cell vertical update");
    if (operator === "|=|") {
      assertClose(second.x, 496, "unchanged second column boundary");
      assertClose(policy === "top" ? top(second) : centerY(second), policy === "top" ? top(first) : centerY(first), "remaining sibling alignment");
    } else assertClose(top(second), 454, "unchanged second row boundary");
    assert(dump.diagnostics.length === 0, `first cell update diagnostics: ${JSON.stringify(dump.diagnostics)}`);
  }

  for (const operator of ["||", "//", "|=|", "/=/"]) {
    await expectFailure(`placed-operands-${operator.replaceAll("/", "v").replaceAll("|", "h")}`, `${prelude}
page invalid
let a = text!("Already placed")
let b = text!("Also placed")
place!(a ${operator} b)
end
`, "InvalidPlacementInput");
  }

  await expectFailure("negative-split-gap", `import std:text as { Text }
${prelude}
page invalid
let a = Text { content = "A" }
let b = Text { content = "B" }
place!((a |=| b) with { gap = -1 })
end
`, "InvalidGroupSplit");
}

async function testNestedSplitPlacement() {
  for (const policy of ["top", "center"]) {
    for (const fixedWidth of [false, true]) {
      for (const positioned of [false, true]) {
        const { dump } = await dumpSource(`nested-split-${policy}-${fixedWidth}-${positioned}`, `page nested
vflow(LayoutPolicy.${policy})
let g = place!(group(text("Short"), text("Second line") |=| text("Third")))
${fixedWidth ? "let inner = first(select<Group<Text, Text>>(g))\n~ inner.width == 400" : ""}
${positioned ? "~ g.left == page.left + 96\n~ g.top == page.top - 80" : ""}
end
`);
        const rootId = dump.placement_roots[0].roots[0];
        const outer = groupNodes(dump).find(item => item.id === rootId);
        const inner = groupNodes(dump).find(item => item.id !== rootId);
        assertClose(outer.x, 96, "nested group page inset");
        if (positioned) assertClose(top(outer), 640, "nested group explicit top");
        if (fixedWidth) assertClose(inner.width, 400, "nested group explicit width");
        assertSplitTree(dump, inner);
        assert(dump.diagnostics.length === 0, `nested group diagnostics: ${JSON.stringify(dump.diagnostics)}`);
      }
    }
  }
}

async function testMeasuredSplitFlow() {
  for (const policy of ["center", "top"]) {
    for (const expression of ["a |=| b", "a /=/ b", "a |=| (b /=/ c)", "a /=/ (b |=| c)"]) {
      const { dump } = await dumpSource(`measured-flow-${policy}-${caseCount}`, `page main
vflow(LayoutPolicy.${policy})
text!("Before split")
let a = text("Short")
let b = text("${"Words wrap at the allocated width. ".repeat(5)}")
${expression.includes("c") ? 'let c = text("Third")' : ""}
let g = place!(${expression})
~ g.width == 1000
text!("After split")
end
`);
      const before = node(dump, "Before split"), after = node(dump, "After split");
      const g = groupNodes(dump).find(item => dump.placement_roots.some(entry => entry.roots.includes(item.id)));
      assertClose(before.y - top(g), gap, "split follows preceding component");
      assertClose(g.y - top(after), groupSpacingAfter, "following component reserves split height");
      assertClose(g.height, requiredHeight(g), "split fits final-width measurements");
      assertSplitTree(dump, g);
      if (policy === "center") assertClose((top(before) + after.y) / 2, 360, "components share page centering");
      assert.equal(dump.diagnostics.length, 0);

      function requiredHeight(item) {
        const input = item.placement?.input;
        if (input?.kind !== "group") return item.measurement.logical_bounds.height;
        const children = item.placement.children.map(id => dump.nodes.find(candidate => candidate.id === id));
        const maximum = Math.max(...children.map(requiredHeight));
        return input.composition === "equal_vertical" ? children.length * maximum + (children.length - 1) * input.gap : maximum;
      }
    }
  }
}

async function testMeasuredNestedConstraintUpdate() {
  const { dump } = await dumpSource("measured-nested-update", `page main
text!("Before split")
let g = place!(text("Short") |=| (text("Second line") // text("Third")))
let items = select<Text>(g)
let a = first(items)
let b = first(items - selection(a))
let c = first(items - selection(a) - selection(b))
~!~ c.top == b.bottom - 80
~ g.width == 1000
text!("After split")
end
`);
  const b = node(dump, "Second line"), c = node(dump, "Third");
  const outer = groupNodes(dump).find(item => item.placement.input.composition === "equal_horizontal");
  assertClose(b.y - top(c), 80, "updated nested spacing survives measurement");
  assertClose(outer.height, b.height + c.height + 80, "outer height includes child update");
  assertClose(node(dump, "Before split").y - top(outer), gap, "updated split reserves space above");
  assertClose(outer.y - top(node(dump, "After split")), groupSpacingAfter, "updated split reserves space below");
  assert.equal(dump.diagnostics.length, 0);
}

async function testHorizontalSplitWidths() {
  for (const [name, constraints, width, left] of [
    ["default", "", 1088, 96],
    ["width", "~ g.width == 600", 600, 96],
    ["width-position", "~ g.width == 600\n~ g.left == page.left + 200", 600, 200],
    ["edges", "~ g.left == page.left + 120\n~ g.right == page.right - 200", 960, 120],
    ["left", "~ g.left == page.left + 200", 984, 200],
    ["right", "~ g.right == page.right - 200", 984, 96],
    ["center", "~ g.center_x == page.center_x - 100", 888, 96],
    ["margins", "~ g.left == page.left + 120\n~ g.right == page.right - 180", 980, 120],
    ["updated-width", "~ g.width == 600\n~!~ g.width == 700", 700, 96],
  ]) {
    const { dump } = await dumpSource(`horizontal-width-${name}`, `${prelude}
page example
let a = text("Short")
let b = text("Second line")
let g = place!(a |=| b)
${constraints}
end
`);
    const g = groupNodes(dump)[0];
    assertClose(g.width, width, `${name} group width`);
    assertClose(g.x, left, `${name} group left`);
    assertSplitTree(dump, g);
    assert(dump.diagnostics.length === 0, `${name} diagnostics: ${JSON.stringify(dump.diagnostics)}`);
  }

  const asset = path.join(output, "horizontal-split.svg");
  await writeFile(asset, '<svg xmlns="http://www.w3.org/2000/svg" width="240" height="120"><rect width="240" height="120" fill="#2563eb"/></svg>');
  for (const policy of ["left", "center", "right"]) {
    for (const scale of [1, 0.02]) {
      const { dump } = await dumpSource(`horizontal-inferred-${policy}-${scale}`, `import std:themes/default as *
import std:text as { Text }
page example
hflow(LayoutPolicy.${policy})
let pair = place!(Text { content = "Short" } |=| image("${asset}", AssetBlockStyle {} with { asset.scale = ${scale} }))
~ pair.left == page.left + 72
~ pair.width == 1136
end
`);
      const a = node(dump, "Short");
      const b = node(dump, asset);
      assertClose(a.x, 72, "inferred left column inset");
      assertClose(b.x, 656, "image scale changed the right column boundary");
      assertClose(a.width, 552, "inferred left column width");
      assertClose(b.width, 552, "inferred right column width");
      assert(dump.nodes.filter(node => node.placement?.input.kind === "group").length === 1,
        "the equal composition must have one typed group placement");
      assert(dump.diagnostics.length === 0, `inferred split diagnostics: ${JSON.stringify(dump.diagnostics)}`);
    }
  }

  for (const [name, expression, width] of [
    ["horizontal-parent", "a |=| (b |=| c)", 1088],
    ["vertical-parent", "a /=/ (b |=| c)", 1088],
    ["ordinary-parent", "group(a, b |=| c)", null],
    ["natural-parent", "a || (b |=| c)", null],
  ]) {
    const { dump } = await dumpSource(`horizontal-width-${name}`, `${prelude}
page example
let a = text("Short")
let b = text("Second line")
let c = text("Third")
let g = place!(${expression})
end
`);
    const rootId = dump.placement_roots.flatMap((entry) => entry.roots)[0];
    const outer = groupNodes(dump).find((item) => item.id === rootId);
    const inner = groupNodes(dump).find((item) => item.id !== rootId);
    if (width !== null) {
      assertClose(outer.width, width, `${name} outer width`);
      assertSplitTree(dump, outer);
    } else {
      assert(inner.width < 1088, `${name} nested split used the page width`);
      assertSplitTree(dump, inner);
    }
    assert(dump.diagnostics.length === 0, `${name} nested diagnostics: ${JSON.stringify(dump.diagnostics)}`);
  }
}

async function testVerticalSplitWidths() {
  for (const [name, constraints, width, left] of [
    ["default", "", 1088, 96],
    ["width", "~ g.width == 600", 600, 96],
    ["width-position", "~ g.width == 600\n~ g.left == page.left + 200", 600, 200],
    ["edges", "~ g.left == page.left + 120\n~ g.right == page.right - 200", 960, 120],
    ["left", "~ g.left == page.left + 200", 984, 200],
    ["right", "~ g.right == page.right - 200", 984, 96],
    ["center", "~ g.center_x == page.center_x - 100", 888, 96],
    ["margins", "~ g.left == page.left + 120\n~ g.right == page.right - 180", 980, 120],
    ["updated-width", "~ g.width == 600\n~!~ g.width == 700", 700, 96],
    ["positioned-child", "~ a.left == page.left + 200", 1088, 96],
  ]) {
    const { dump } = await dumpSource(`vertical-width-${name}`, `page main
let g = place!(text("Short") /=/ text("Second line"))
let a = first(children(g))
${constraints}
end
`);
    const g = groupNodes(dump)[0];
    assertClose(g.width, width, `${name} group width`);
    assertClose(g.x, left, `${name} group left`);
    assert(node(dump, "Short").width < node(dump, "Second line").width, "short text lost natural width");
    if (name === "positioned-child") assertClose(node(dump, "Short").x, 200, "explicit child position");
    assertSplitTree(dump, g);
    assert.equal(dump.diagnostics.length, 0);
  }

  for (const policy of ["left", "center", "right"]) {
    const { dump } = await dumpSource(`vertical-width-policy-${policy}`, `page main
hflow(LayoutPolicy.${policy})
let g = place!(text("Short") /=/ text("${"Words wrap within the available row width. ".repeat(12)}"))
~ g.height == 400
end
`);
    const g = groupNodes(dump)[0];
    const a = node(dump, "Short"), b = dump.nodes.find(item => item.content?.startsWith("Words wrap"));
    assertClose(g.x, 96, `${policy} page inset`);
    assertClose(g.width, 1088, `${policy} page width`);
    assert(b.width <= g.width + constraintTolerance);
    assert(b.x >= g.x - constraintTolerance && b.x + b.width <= g.x + g.width + constraintTolerance);
    const aligned = item => policy === "left" ? item.x : policy === "center" ? item.x + item.width / 2 : item.x + item.width;
    assertClose(aligned(a), aligned(b), `${policy} text alignment`);
    assertSplitTree(dump, g);
    assert.equal(dump.diagnostics.length, 0);
  }

  for (const [name, expression, width] of [
    ["horizontal-parent", "a |=| (b /=/ c)", 800],
    ["vertical-parent", "a /=/ (b /=/ c)", 1088],
    ["ordinary-parent", "group(a, b /=/ c)", null],
    ["natural-parent", "a || (b /=/ c)", null],
  ]) {
    const { dump } = await dumpSource(`vertical-width-${name}`, `page main
let a = text("Short")
let b = text("Second line")
let c = text("Third")
let g = place!(${expression})
${name === "horizontal-parent" ? "~ g.width == 800" : ""}
${name === "vertical-parent" ? "~ g.height == 400" : ""}
end
`);
    const rootId = dump.placement_roots.flatMap(entry => entry.roots)[0];
    const outer = groupNodes(dump).find(item => item.id === rootId);
    const inner = groupNodes(dump).find(item => item.id !== rootId);
    if (width !== null) {
      assertClose(outer.width, width, `${name} root width`);
      assertSplitTree(dump, outer);
    } else {
      assertClose(inner.width, node(dump, "Second line").width, `${name} nested natural width`);
      assertSplitTree(dump, inner);
    }
    assert.equal(dump.diagnostics.length, 0);
  }
}

function assertSplitTree(dump, group) {
  const input = group.placement.input;
  const axis = { equal_horizontal: "horizontal", equal_vertical: "vertical" }[input.composition];
  if (!axis) return;
  const children = group.placement.children.map(id => dump.nodes.find(item => item.id === id));
  assert(children.length >= 2, "split lost containment");
  const horizontal = axis === "horizontal";
  const extent = ((horizontal ? group.width : group.height) - (children.length - 1) * input.gap) / children.length;
  for (const [index, child] of children.entries()) {
    assertClose(horizontal ? child.width : child.height, extent, `equal extent ${index}`);
    assertClose(horizontal ? child.x : top(child), horizontal ? group.x + index * (extent + input.gap) : top(group) - index * (extent + input.gap), `cell position ${index}`);
  }
  for (const child of children.filter(item => item.placement?.input.kind === "group")) {
    assertClose(horizontal ? child.height : child.width, horizontal ? group.height : group.width, "nested group cross-axis extent");
    assertSplitTree(dump, child);
  }
}

async function testEqualChains() {
  for (const operator of ["|=|", "/=/"]) for (const count of [3, 4, 5]) for (const nested of [false, true]) {
    const operands = Array.from({ length: count }, (_, index) => `text("Item ${index}")`);
    if (nested) operands[1] = `(text("Nested one") ${operator} text("Nested two") ${operator} text("Nested three"))`;
    const { dump } = await dumpSource(`equal-chain-${operator === "|=|" ? "h" : "v"}-${count}-${nested}`, `page main
vflow(LayoutPolicy.top)
let g = place!(${operands.join(` ${operator} `)})
~ g.width == 1024
~ g.height == 640
~ g.left == page.left + 80
~ g.top == page.top - 40
end
`);
    const groups = groupNodes(dump);
    assert.equal(groups.length, nested ? 2 : 1, "unparenthesized chain created intermediate groups");
    const rootId = dump.placement_roots.flatMap(entry => entry.roots)[0];
    const g = groups.find(item => item.id === rootId);
    assert.equal(g.placement.children.length, count);
    assertSplitTree(dump, g);
    assert(dump.constraints.some(item => item.group_split && item.source_extent_factor !== 0));
  }
  const bound = await dumpSource("equal-bound-group", `page main
let left = text("A") |=| text("B")
let g = place!(left |=| text("C"))
~ g.width == 1000
end
`);
  assert.equal(groupNodes(bound.dump).length, 2, "bound group was flattened");
  assert(node(bound.dump, "C").width > node(bound.dump, "A").width * 2);
  const reused = await dumpSource("equal-reused-value", `page main
let a = text("A")
place!(a |=| a)
end
`);
  const copies = reused.dump.nodes.filter(item => item.content === "A");
  assert.equal(copies.length, 2);
  assert.notEqual(copies[0].id, copies[1].id);
  assertClose(copies[0].width, copies[1].width, "reused values received unequal cells");
  await expectFailure("group-page-selection", "document\nplace_on!(new_page(docctx(), \"main\"), group(pages(docctx())))\nend\n", "InvalidGroupInput");
}

async function testEqualEvaluation() {
  const { dump } = await dumpSource("equal-evaluation-shadowing", `import std:layout as layout
fn group(a: Text, b: Text) -> Text = a
fn mark(label: String) -> Text
  report_warning(label)
  return text(label)
end
page evaluation
let g = layout::place!(mark("A") |=| (mark("B") /=/ mark("C")) |=| mark("D"))
~ g.width == 1100
~ g.height == 400
end
`);
  const order = dump.diagnostics.filter(item => item.code === "UserReport").map(item => item.message);
  assert(JSON.stringify(order) === JSON.stringify(["A", "B", "C", "D"]), `equal operands were not evaluated once in order: ${order}`);
  const roots = dump.placement_roots.flatMap(entry => entry.roots);
  assert(roots.length === 1, "equal composition did not place a single root");
  const groups = dump.nodes.filter(item => item.placement?.input.kind === "group");
  assert(groups.length === 2, "equal composition lost its nested group");
  for (const label of ["A", "B", "C", "D"]) {
    assert(dump.nodes.filter(item => item.content === label).length === 1, `operand ${label} produced duplicate placements`);
  }
  assertClose(node(dump, "A").width, (1100 - 2 * gap) / 3, "equal syntax was shadowed");
  assertClose(node(dump, "B").height, (400 - gap) / 2, "nested equal syntax was shadowed");
}

async function testEqualEditorUpdates() {
  const expressions = ["a || b || c", "a |=| b |=| c", "(a |=| b) |=| c", "a /=/ b /=/ c", "a // b // c", "a |=| b |=| c", "a /=/ b /=/ c", "a /=/ b /=/ c", "a // b // c"];
  const sources = expressions.map((expression, index) => `${prelude}
page editor
let a = text("Short")
let b = text("A considerably longer line")
let c = text("Third")
let g = place!(${expression})
${index < 6 ? "~ g.width == 1000" : index === 7 ? "~ g.width == 600" : ""}
~ g.height == 500
~ g.left == page.left + 80
~ g.top == page.top - 80
end
`);
  const expected = [];
  for (const [index, source] of sources.entries()) expected.push((await dumpSource(`editor-expected-${index}`, source)).dump);
  const directory = await createCase("editor-updates", sources[0]);
  const file = path.join(directory, "slide.ss");
  const uri = pathToFileURL(file).href;
  await withLspClient({ cwd: directory }, async (client) => {
    await client.initialize();
    for (const [index, source] of sources.entries()) {
      const ready = client.waitForDiagnostics(uri);
      if (index === 0) client.openDocument({ uri, text: source, version: 1 });
      else client.changeDocument({ uri, text: source, version: index + 1 });
      assert((await ready).params.diagnostics.length === 0, `editor diagnostics for ${expressions[index]}`);
      const snapshot = await editorSnapshot(client, uri);
      const objects = expected[index].nodes.filter((item) => item.kind === "object");
      assert(snapshot.layout.objects.length === objects.length, "editor retained stale composition groups");
      for (const node of objects) {
        const actual = snapshot.layout.objects.find((item) => item.id === node.id);
        assert(actual, `editor omitted ${node.id}`);
        for (const key of ["x", "y", "width", "height"]) assertClose(actual[key], node[key], `editor ${expressions[index]} ${node.id}.${key}`);
      }
    }
  });
}

async function testSameDirectionBinaryGroups() {
  for (const operator of ["||", "//"]) {
    const { dump } = await dumpSource(operator === "||" ? "horizontal-chain" : "vertical-chain", `${prelude}
page chain
${boxes}
let placed = place!(a ${operator} b ${operator} c)
${anchor}
end
`);
    const groups = groupNodes(dump);
    assert(groups.length === 2, "same-direction composition was flattened");
    const ids = new Set(groups.map((item) => item.id));
    assert(dump.contains.some((entry) => ids.has(entry.parent) && entry.children.some((id) => ids.has(id))), "same-direction composition lost its binary nested groups");
    const a = node(dump, "A");
    const b = node(dump, "B");
    const c = node(dump, "C");
    if (operator === "||") {
      assertClose(b.x, a.x + a.width + gap, "first horizontal gap");
      assertClose(c.x, b.x + b.width + gap, "second horizontal gap");
    } else {
      assertClose(top(b), a.y - gap, "first vertical gap");
      assertClose(top(c), b.y - gap, "second vertical gap");
    }
  }
}

async function testSharedValues() {
  const { dump } = await dumpSource("shared-values", `${prelude}
page main
${boxes}
let first = place!(a || (b // c))
let second = place!(b // a)
~ first.left == page.left + 80
~ first.top == page.top - 80
~ second.left == first.right + 80
~ second.top == first.top
end
`);
  const roots = dump.placement_roots.flatMap(entry => entry.roots);
  assert.equal(roots.length, 2);
  for (const label of ["A", "B"]) {
    const copies = dump.nodes.filter(item => boxLabel(item) === label);
    assert.equal(copies.length, 2, `reused ${label} did not receive two placements`);
    assert.notEqual(copies[0].id, copies[1].id);
    assert.notEqual(copies[0].placement.parent, copies[1].placement.parent);
  }
  assert.equal(dump.diagnostics.length, 0);
}

async function testConstraintUpdate() {
  const { dump } = await dumpSource("updated", `${prelude}
page main
let placed = place!(box("A", 120, 80) || box("B", 180, 60))
let a = first(children(placed))
let b = first(children(placed) - selection(a))
let c = place!(box("C", 90, 50))
${anchor}
~!~ b.top == a.bottom - 24
~ c.left == page.left + 600
~ c.top == page.top - 80
end
`);
  const a = node(dump, "A"), b = node(dump, "B");
  assertClose(b.x, a.x + a.width + gap, "vertical update changed horizontal composition");
  assertClose(top(b), a.y - 24, "update did not replace alignment");
  assert(relation(dump.overridden_constraints, b, "top", a, "top", 0)?.default_alignment);
  assert(!relation(dump.constraints, b, "top", a, "top", 0), "overridden alignment was regenerated");
  assertClose(b.width, 180, "position update changed width");
}

async function testExplicitGap() {
  const { dump } = await dumpSource("explicit-gap", `import std:text as { Text }
page gaps
let a = Text { content = "A" }
let b = Text { content = "B" }
let c = Text { content = "C" }
let item = place!((a || ((b // c) with { gap = 12 })) with { gap = 48 })
~ item.left == page.left + 80
~ item.top == page.top - 80
end
`);
  const a = node(dump, "A");
  const b = node(dump, "B");
  const c = node(dump, "C");
  assertClose(b.x, a.x + a.width + 48, "outer immutable spacing");
  assertClose(b.x, c.x, "column alignment");
  assertClose(top(c), b.y - 12, "inner immutable spacing");
}

async function testPlacedGroupConstraintUpdate() {
  const { dump } = await dumpSource("placed-group-update", `${prelude}
page main
vflow(LayoutPolicy.top)
let placed = place!(box("A", 120, 80) || box("B", 180, 60))
${anchor}
~!~ placed.left == page.left + 240
~!~ placed.top == page.top - 160
end
`);
  const a = node(dump, "A"), b = node(dump, "B");
  assertClose(a.x, 240, "group horizontal update");
  assertClose(top(a), 560, "group vertical update");
  assertClose(b.x, a.x + a.width + gap, "group update changed internal gap");
  assertClose(top(b), top(a), "group update changed top alignment");
  for (const [item, width, height] of [[a, 120, 80], [b, 180, 60]]) {
    assertClose(item.width, width, "group update changed width");
    assertClose(item.height, height, "group update changed height");
  }
  assert(relation(dump.constraints, b, "left", a, "right", gap));
  assert(relation(dump.constraints, b, "top", a, "top", 0)?.default_alignment);
  const groups = groupNodes(dump);
  assert.equal(groups.length, 1);
  assert.deepEqual(dump.placement_roots.flatMap(entry => entry.roots), [groups[0].id]);
  const updates = dump.constraint_updates.filter(item => item.active);
  assert.equal(updates.length, 2);
  assert(updates.every(item => item.target_node === groups[0].id));
}

async function testOperandEvaluation() {
  const { dump } = await dumpSource("evaluation-order", `${prelude}
fn mark(label: String) -> Box
  report_warning(label)
  return box(label, 120, 60)
end
page main
place!(mark("A") || (mark("B") // mark("C")))
end
`);
  assert.deepEqual(dump.diagnostics.filter(item => item.code === "UserReport").map(item => item.message), ["A", "B", "C"]);
  for (const label of ["A", "B", "C"]) assert.equal(dump.nodes.filter(item => boxLabel(item) === label).length, 1);
  assert.equal(dump.placement_roots.flatMap(entry => entry.roots).length, 1);
}

async function testFixedStdlibResolution() {
  const { dump } = await dumpSource("shadowing", `import std:layout as layout
page fixed
let a = text("A")
let b = text("B")
let c = text("C")
layout::place!(a || (b // c))
end
`);
  const a = node(dump, "A");
  const b = node(dump, "B");
  const c = node(dump, "C");
  assertClose(b.x, a.x + a.width + gap, "layout alias affected horizontal syntax");
  assertClose(top(c), b.y - gap, "layout alias affected vertical syntax");
}

async function testImportedFunctionComposition() {
  const { dump } = await dumpSource("imported-composition", `import ./component as component
${prelude}
page main
vflow(LayoutPolicy.top)
${boxes}
let placed = place!(component::combine(a, b, c))
${anchor}
end
`, { "component.ss": `fn combine<T>(a: T, b: T, c: T) -> Group<T, Group<T, T>>
  return a || (b // c)
end
` });
  assertNestedFrames(dump);
}

async function testInvalidOperands() {
  for (const operator of ["||", "//", "|=|", "/=/"]) {
    for (const [name, operand] of [
      ["number", "1"], ["string", '"wrong"'], ["boolean", "true"],
      ["page", "pagectx()"], ["selection", "select<Text>(pagectx())"], ["optional", "maybe()"],
    ]) {
      await expectFailure(`invalid-${operator.replaceAll("/", "v").replaceAll("|", "h")}-${name}`, `fn maybe() -> Text? = none
page main
let a = text("A")
a ${operator} ${operand}
end
`, "InvalidGroupInput");
    }
  }
}

async function testConflictsAndMixedDirections() {
  await expectFailure("conflict", `${prelude}
page main
let placed = place!(box("A", 120, 80) || box("B", 180, 60))
let a = first(children(placed))
let b = first(children(placed) - selection(a))
~ b.left == a.right + 64
end
`, "ConstraintConflict");
  await expectFailure("cross-page-constraint", `document
let first_page = new_page(docctx(), "first")
let second_page = new_page(docctx(), "second")
let a = place_on!(first_page, text("A"))
let b = place_on!(second_page, text("B"))
first_page ~ b.left == a.right + 32
end
`, "CrossPageConstraint");
  await expectFailure("mixed-directions", `${prelude}
page main
${boxes}
place!(a || b // c)
end
`);
}

async function testFixture() {
  const fixture = path.join(root, "tests", "fixtures", "layout-composition", "slide.ss");
  expectSuccess(await runSs(["check", "--quiet", fixture], output), "composition fixture check");
  const dumpPath = path.join(output, "fixture.json");
  expectSuccess(await runSs(["dump", "--quiet", fixture, dumpPath], output), "composition fixture dump");
  const dump = JSON.parse(await readFile(dumpPath, "utf8"));
  assertNoDiagnostic(dump, "UnplacedObject");
  assert(dump.page_order.length === 2, "representative fixture lost a policy example page");
  caseCount += 1;
}

function policyPairSource({ documentPolicy, pagePolicy, before = "", after = "", fixedLeft = true } = {}) {
  return `${prelude}
${documentPolicy ? `document\nvflow_doc(LayoutPolicy.${documentPolicy})\nend\n` : ""}
page main
${pagePolicy ? `vflow(LayoutPolicy.${pagePolicy})` : ""}
let placed = place!(box("A", 120, 80) || box("B", 180, 60))
let a = first(children(placed))
let b = first(children(placed) - selection(a))
${before}
~ a.left == page.left + 80
${fixedLeft ? "~ a.top == page.top - 80" : ""}
${after}
end
`;
}

function assertHorizontalPolicy(dump, centered) {
  const a = node(dump, "A");
  const b = node(dump, "B");
  assertClose(b.x, a.x + a.width + gap, "policy changed horizontal adjacency");
  assertClose(centered ? centerY(b) : top(b), centered ? centerY(a) : top(a), centered ? "horizontal center alignment" : "horizontal top alignment");
  assertClose(a.width, 120, "policy changed left width");
  assertClose(a.height, 80, "policy changed left height");
  assertClose(b.width, 180, "policy changed right width");
  assertClose(b.height, 60, "policy changed right height");
  const horizontal = relation(dump.constraints, b, "left", a, "right", gap);
  assert(horizontal && !horizontal.default_alignment, "horizontal adjacency became a default alignment candidate");
  assert(relation(dump.constraints, b, "top", a, "top", 0)?.default_alignment, "vertical alignment was not recorded as a default candidate");
  assertNoDiagnostic(dump, "UnplacedObject");
}

async function testHorizontalPolicyVariants() {
  for (const policy of ["top", "top_flow", "center", "center_stack"]) {
    const { dump } = await dumpSource(`policy-${policy}`, policyPairSource({ pagePolicy: policy }));
    assertHorizontalPolicy(dump, policy.startsWith("center"));
    assert.equal(groupNodes(dump).length, 1, "policy lost its placed group");
    assert.equal(dump.placement_roots.flatMap(entry => entry.roots).length, 1, "policy changed placement roots");
  }
}

async function testHorizontalPolicyInheritance() {
  for (const [documentPolicy, pagePolicy, centered] of [
    [undefined, undefined, true],
    ["top", undefined, false],
    ["center", undefined, true],
    ["center", "top", false],
    ["top", "center", true],
  ]) {
    const { dump } = await dumpSource(`policy-inherit-${documentPolicy}-${pagePolicy ?? "none"}`, policyPairSource({ documentPolicy, pagePolicy }));
    assertHorizontalPolicy(dump, centered);
    const page = dump.nodes.find((item) => item.kind === "page");
    if (!pagePolicy) assert(!Object.hasOwn(page.fields, "layout_v"), "inherited policy became an explicit page definition");
  }
}

async function testNestedHorizontalPolicy() {
  const { dump } = await dumpSource("policy-nested", `${prelude}
page main
vflow(LayoutPolicy.center)
${boxes}
let placed = place!(a || (b // c))
${anchor}
end
`);
  const a = node(dump, "A"), b = node(dump, "B"), c = node(dump, "C");
  assertClose(b.x, a.x + a.width + gap, "nested horizontal gap");
  assertClose(c.x, b.x, "nested column alignment");
  assertClose(top(c), b.y - gap, "nested vertical gap");
  assertClose(centerY(a), (top(b) + c.y) / 2, "left must center against entire right group");
  assert(Math.abs(centerY(a) - centerY(b)) > 1);
  assert.equal(dump.placement_roots.flatMap(entry => entry.roots).length, 1);
  assert.equal(groupNodes(dump).length, 2);
}

async function testPolicyAfterPagePlacement() {
  const { dump } = await dumpSource("policy-after-placement", `${prelude}
document
let destination = new_page(docctx(), "generated")
place_on!(destination, box("A", 120, 80) || box("B", 180, 60))
destination.layout_v = LayoutPolicy.center
end
`);
  assertHorizontalPolicy(dump, true);
  assert.equal(dump.placement_roots.flatMap(entry => entry.roots).length, 1);
}

async function testExplicitVerticalPositionPriority() {
  for (const anchorName of ["top", "bottom", "center_y"]) {
    for (const position of ["before", "after"]) {
      const constraint = `~ b.${anchorName} == a.${anchorName} - 30`;
      const { dump } = await dumpSource(`policy-explicit-${anchorName}-${position}`, policyPairSource({
        pagePolicy: "center",
        [position]: constraint,
      }));
      const a = node(dump, "A");
      const b = node(dump, "B");
      const getAnchor = anchorName === "top" ? top : anchorName === "bottom" ? (item) => item.y : centerY;
      assertClose(getAnchor(b), getAnchor(a) - 30, `ordinary ${anchorName} constraint lost priority over default alignment`);
      assertClose(b.x, a.x + a.width + gap, "explicit vertical position changed horizontal adjacency");
      const explicit = relation(dump.constraints, b, anchorName, a, anchorName, -30);
      assert(explicit && !explicit.default_alignment, "ordinary vertical constraint was not preserved as explicit");
      assertClose(a.height, 80, "ordinary vertical position changed left height");
      assertClose(b.height, 60, "ordinary vertical position changed right height");
    }
  }
}

async function testDefaultAlignmentUpdates() {
  const replaced = await dumpSource("policy-update-replacement", policyPairSource({
    pagePolicy: "center",
    after: "~!~ b.bottom == a.bottom - 25",
  }));
  const a = node(replaced.dump, "A");
  const b = node(replaced.dump, "B");
  assertClose(b.y, a.y - 25, "constraint update did not replace default center alignment");
  assertClose(b.x, a.x + a.width + gap, "constraint update changed horizontal adjacency");
  const updated = relation(replaced.dump.constraints, b, "bottom", a, "bottom", -25);
  assert(updated?.from_update, "replacement did not remain an ordinary constraint update");

  for (const anchorName of ["top", "center_y"]) {
    const { dump } = await dumpSource(`policy-update-delete-${anchorName}`, policyPairSource({
      pagePolicy: "center",
      after: `~!~ b.${anchorName}`,
    }));
    const left = node(dump, "A");
    const right = node(dump, "B");
    assertClose(right.x, left.x + left.width + gap, "deleting vertical alignment changed horizontal adjacency");
    assert(Math.abs(centerY(right) - centerY(left)) > 1, "deleted default center alignment was regenerated during solving");
    assert(dump.constraint_updates.some((item) => item.active && item.target_node === right.id && item.replacement === null), "pure constraint deletion was not preserved");
    assert(!dump.constraints.some((item) => item.target_node === right.id && item.role === "position" && ["top", "bottom", "center_y"].includes(item.target_anchor)), "vertical position survived pure deletion");
  }
}

async function testCenteredChainAndVerticalComposition() {
  const { dump } = await dumpSource("centered-chain", `${prelude}
page main
vflow(LayoutPolicy.center_stack)
${boxes}
let placed = place!(a || b || c)
${anchor}
end
`);
  const a = node(dump, "A"), b = node(dump, "B"), c = node(dump, "C");
  assertClose(centerY(b), centerY(a), "first pair did not center");
  assertClose(centerY(c), centerY(a), "last operand did not center against complete group");
  assertClose(b.x, a.x + 120 + gap, "first chain gap");
  assertClose(c.x, b.x + 180 + gap, "second chain gap");
  assert.equal(groupNodes(dump).length, 2);
  const vertical = await dumpSource("vertical-policy", `${prelude}
page main
vflow(LayoutPolicy.center)
let placed = place!(box("A", 120, 80) // box("B", 180, 60))
${anchor}
end
`);
  const upper = node(vertical.dump, "A"), lower = node(vertical.dump, "B");
  assertClose(lower.x, upper.x, "horizontal policy changed vertical alignment");
  assertClose(top(lower), upper.y - gap, "vertical gap");
  assert(relation(vertical.dump.constraints, lower, "top", upper, "bottom", -gap));
}

async function testFixedRightDoesNotMoveLeft() {
  const { dump } = await dumpSource("policy-fixed-right", policyPairSource({
    pagePolicy: "center",
    fixedLeft: false,
    before: "~ b.top == page.top - 140",
  }));
  const a = node(dump, "A");
  const b = node(dump, "B");
  const page = dump.nodes.find((item) => item.kind === "page");
  assertClose(top(b), top(page) - 140, "default alignment moved the explicitly positioned right operand");
  assertClose(b.x, a.x + a.width + gap, "fixed right position changed horizontal adjacency");
  assert(Math.abs(centerY(a) - centerY(b)) > 1, "default alignment moved the unspecified left operand in reverse");
}

function centerY(item) {
  return item.y + item.height / 2;
}

function assertNestedFrames(dump, horizontalGap = gap, verticalGap = gap) {
  const a = node(dump, "A");
  const b = node(dump, "B");
  const c = node(dump, "C");
  assertClose(a.width, 120, "left width");
  assertClose(b.width, 180, "right upper width");
  assertClose(c.width, 90, "right lower width");
  assertClose(b.x, a.x + a.width + horizontalGap, "nested horizontal gap");
  assertClose(top(b), top(a), "nested top alignment");
  assertClose(c.x, b.x, "nested left alignment");
  assertClose(top(c), b.y - verticalGap, "nested vertical gap");
}

function node(dump, content) {
  const found = dump.nodes.find(item => item.content === content || boxLabel(item) === content);
  assert(found, `missing node ${content}`);
  return found;
}

function boxLabel(item) {
  const input = item.placement?.input;
  return input?.type?.name === "Box" ? input.fields.find(field => field.name === "label")?.value.value : undefined;
}

function groupNodes(dump) {
  return dump.nodes.filter(item => item.placement?.input.kind === "group");
}

function relation(constraints, target, targetAnchor, source, sourceAnchor, offset) {
  return constraints.find((item) => item.target_node === target.id && item.target_anchor === targetAnchor && item.source_node === source.id && item.source_anchor === sourceAnchor && item.offset === offset);
}

function top(item) {
  return item.y + item.height;
}

function assertClose(actual, expected, label) {
  assert(Math.abs(actual - expected) <= 0.11, `${label}: expected ${expected}, got ${actual}`);
}

function assertNoDiagnostic(dump, code) {
  assert(!dump.diagnostics.some((item) => item.code === code), `unexpected ${code}: ${JSON.stringify(dump.diagnostics)}`);
}

async function createCase(name, source, files = {}) {
  const directory = path.join(output, name);
  await mkdir(directory, { recursive: true });
  await writeFile(path.join(directory, "slide.ss"), source, "utf8");
  for (const [file, body] of Object.entries(files)) await writeFile(path.join(directory, file), body, "utf8");
  caseCount += 1;
  return directory;
}

async function dumpSource(name, source, files = {}) {
  const directory = await createCase(name, source, files);
  expectSuccess(await runSs(["dump", "slide.ss", "dump.json"], directory), name);
  return { source, dump: JSON.parse(await readFile(path.join(directory, "dump.json"), "utf8")) };
}

async function expectFailure(name, source, diagnostic) {
  const directory = await createCase(name, source);
  const result = await runSs(["check", "slide.ss"], directory);
  assert(result.code !== 0, `${name} unexpectedly succeeded`);
  const text = `${result.stdout}\n${result.stderr}`.replace(/\u001b\[[0-9;]*m/g, "");
  if (diagnostic) assert(text.includes(diagnostic), `${name} omitted ${diagnostic}:\n${text}`);
}

function expectSuccess(result, label) {
  assert(result.code === 0, `${label} failed with ${result.code}\n${result.stdout}\n${result.stderr}`);
}

async function runSs(args, cwd) {
  return await new Promise((resolve, reject) => {
    const child = spawn(ssBin, args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const timeout = setTimeout(() => {
      timedOut = true;
      child.kill("SIGKILL");
    }, 30000);
    child.on("error", (error) => { clearTimeout(timeout); reject(error); });
    child.on("close", (code) => {
      clearTimeout(timeout);
      if (timedOut) reject(new Error(`ss ${args.join(" ")} timed out after 30 seconds\n${stderr}`));
      else resolve({ code: code ?? -1, stdout, stderr });
    });
  });
}
