#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { assert, root, ssBin } from "../../harness.mjs";

const outputRoot = path.join(root, ".ss-cache", "tests", "layout-composition");
await mkdir(outputRoot, { recursive: true });
const output = await mkdtemp(path.join(outputRoot, "run-"));
const gap = 32;
let caseCount = 0;

const prelude = `import std:core/prelude as *

fn box(label: String, width: Number, height: Number) -> Object
  let item = new(label, "body", "text")
  ~ item.width == width
  ~ item.height == height
  return item
end
`;
const boxes = `let a = box("A", 120, 80)
let b = box("B", 180, 60)
let c = box("C", 90, 50)`;
const anchor = `~ a.left == page.left + 80
~ a.top == page.top - 80`;

await testNestedPlacedObjects();
await testNestedUnplacedObjectsAndOrdinaryGroup();
await testIntermediateBinding();
await testOrdinaryGroupInference();
await testNestedOrdinaryGroupBounds();
await testUnplacedComposition();
await testNaturalWidths();
await testSameDirectionBinaryGroups();
await testSharedObjects();
await testConstraintUpdate();
await testInferredGroupConstraintUpdate();
await testExplicitGap();
await testOperandEvaluation();
await testFixedStdlibResolution();
await testImportedFunctionComposition();
await testInvalidOperands();
await testConflictsAndMixedDirections();
await testHorizontalPolicyVariants();
await testHorizontalPolicyInheritance();
await testNestedHorizontalPolicy();
await testPolicyAfterPagePlacement();
await testExplicitVerticalPositionPriority();
await testDefaultAlignmentUpdates();
await testCenteredChainAndVerticalComposition();
await testOrdinaryGroupPolicyIsolation();
await testFixedRightDoesNotMoveLeft();
await testFixture();
console.log(`layout composition: ${caseCount} cases passed`);

async function testNestedPlacedObjects() {
  const { dump, source } = await dumpSource("placed", `${prelude}
page placed
vflow(LayoutPolicy.top)
${boxes}
place!(a)
place!(b)
place!(c)
${anchor}
a || (b // c)
end
`);
  assertNestedFrames(dump);
  assertNoDiagnostic(dump, "UnplacedObject");
  assert(groupNodes(dump).length === 0, "composition implicitly attached a group");
  const roots = dump.flow_roots.flatMap((entry) => entry.roots);
  assert(roots.length === 3, `composition changed existing placement roots: ${roots}`);
  const b = node(dump, "B");
  const c = node(dump, "C");
  const vertical = relation(dump.constraints, c, "top", b, "bottom", -gap);
  assert(vertical && vertical.role === "position", "vertical composition did not add an ordinary position constraint");
  assert(vertical.origin?.path?.endsWith("slide.ss"), `composition constraint lost its source file: ${JSON.stringify(vertical)}`);
  const originText = source.slice(vertical.origin.start, vertical.origin.end);
  assert(originText.includes("//"), `composition constraint origin does not cover its operator: ${originText}`);
}

async function testNestedUnplacedObjectsAndOrdinaryGroup() {
  const { dump } = await dumpSource("unplaced-then-placed", `${prelude}
page placed
vflow(LayoutPolicy.top)
${boxes}
let combined = a || (b // c)
place!(combined)
${anchor}
end
`);
  assertNestedFrames(dump);
  assertNoDiagnostic(dump, "UnplacedObject");
  const groups = groupNodes(dump);
  assert(groups.length === 2, `expected two ordinary groups, got ${groups.length}`);
  const rootId = dump.flow_roots.flatMap((entry) => entry.roots);
  assert(rootId.length === 1, `placing the returned group should add one placement root: ${rootId}`);
  const outer = groups.find((item) => item.id === rootId[0]);
  assert(outer, "composition did not return an ordinary group Object");
  assertClose(outer.width, 120 + gap + 180, "outer group bounding width");
  assertClose(outer.height, 60 + gap + 50, "outer group bounding height");
}

async function testIntermediateBinding() {
  const nested = await dumpSource("nested", `${prelude}
page comparison
${boxes}
place!(a || (b // c))
${anchor}
end
`);
  const bound = await dumpSource("bound", `${prelude}
page comparison
${boxes}
let right = b // c
place!(a || right)
${anchor}
end
`);
  for (const label of ["A", "B", "C"]) {
    for (const field of ["x", "y", "width", "height"]) {
      assertClose(node(bound.dump, label)[field], node(nested.dump, label)[field], `${label}.${field} changed after introducing a binding`);
    }
  }
}

async function testOrdinaryGroupInference() {
  const fallbackSource = `${prelude}
page fallback
let a = text!("A")
let b = text!("B")
`;
  const plain = await dumpSource("plain-fallback", `${fallbackSource}end\n`);
  const grouped = await dumpSource("grouped-fallback", `${fallbackSource}group(a, b)\nend\n`);
  assertNoDiagnostic(grouped.dump, "UnplacedObject");
  for (const label of ["A", "B"]) {
    for (const field of ["x", "y", "width", "height"]) {
      assertClose(node(grouped.dump, label)[field], node(plain.dump, label)[field], `unreferenced group changed fallback ${label}.${field}`);
    }
  }

  const inferred = await dumpSource("ordinary-group", `${prelude}
page groups
${boxes}
place!(a)
place!(b)
place!(c)
${anchor}
~ b.left == a.right + 32
~ b.top == a.top
let pair = group(a, b)
pair // c
end
`);
  assertNoDiagnostic(inferred.dump, "UnplacedObject");
  const a = node(inferred.dump, "A");
  const c = node(inferred.dump, "C");
  assertClose(c.x, a.x, "ordinary group left edge");
  assertClose(top(c), a.y - gap, "ordinary group bottom edge");
  assert(groupNodes(inferred.dump).length === 0, "ordinary inferred groups became attached");

  const incomplete = await dumpSource("mixed-placement-group", `${prelude}
page groups
let a = place!(new("A", "body", "text"))
let b = new("B", "body", "text")
group(a, b)
end
`);
  assert(incomplete.dump.diagnostics.some((item) => item.code === "UnplacedObject"), "a group with an unplaced child was treated as completely placed");
  assert(!incomplete.dump.nodes.some((item) => item.content === "B"), "ordinary grouping implicitly placed its unplaced child");

  const separate = await dumpSource("cross-page-group", `${prelude}
page first
place!(new("A", "first_box", "text"))
end
page second
place!(new("B", "second_box", "text"))
end
document
let a = first(objs_all("first_box"))
let b = first(objs_all("second_box"))
group(a, b)
end
`);
  assert(separate.dump.diagnostics.some((item) => item.code === "UnplacedObject"), "a group spanning two pages was inferred onto one page");
  assert(groupNodes(separate.dump).length === 0, "a cross-page group became attached");
}

async function testUnplacedComposition() {
  await expectFailure("unplaced-composition", `${prelude}
page unplaced
let a = new("A", "body", "text")
let b = new("B", "body", "text")
a || b
end
`, "UnownedLayoutObject");
}

async function testNestedOrdinaryGroupBounds() {
  const { dump } = await dumpSource("nested-ordinary-group-bounds", `${prelude}
page nested_group
vflow(LayoutPolicy.top)
${boxes}
let d = box("D", 100, 180)
let e = box("E", 50, 40)
let f = box("F", 50, 40)
place!(a)
place!(b)
place!(c)
place!(d)
place!(e)
place!(f)
~ b.left == a.right + 32
~ b.top == a.top
~ c.left == a.left
~ c.top == a.bottom - 32
let inner = group(a, b)
let outer = group(inner, c)
~ d.left == page.left + 80
~ d.top == page.top - 80
d || outer
~ e.left == outer.right + 16
~ e.top == outer.top
~ f.left == outer.left
~ f.top == outer.bottom - 16
end
`);
  const a = node(dump, "A");
  const b = node(dump, "B");
  const c = node(dump, "C");
  const d = node(dump, "D");
  const e = node(dump, "E");
  const f = node(dump, "F");
  assertClose(a.x, d.x + d.width + gap, "nested ordinary group left boundary");
  assertClose(top(a), top(d), "nested ordinary group top boundary");
  assertClose(b.x, a.x + a.width + gap, "nested ordinary group first row");
  assertClose(c.x, a.x, "nested ordinary group second row alignment");
  assertClose(top(c), a.y - gap, "nested ordinary group second row gap");
  assertClose(e.x, a.x + 120 + gap + 180 + 16, "outer right boundary must include its nested inner group");
  assertClose(top(e), top(a), "outer top boundary must include its nested inner group");
  assertClose(f.x, a.x, "outer left boundary must include its nested inner group");
  assertClose(top(f), top(a) - 80 - gap - 50 - 16, "outer bottom boundary must include both rows");
  assertNoDiagnostic(dump, "UnplacedObject");
  assert(groupNodes(dump).length === 0, "nested ordinary group became attached during composition");
}

async function testNaturalWidths() {
  const { dump } = await dumpSource("natural-widths", `${prelude}
page natural
let a = text!("short")
let b = text!("a considerably longer line")
a || b
end
`);
  const a = node(dump, "short");
  const b = node(dump, "a considerably longer line");
  assert(b.width > a.width * 2, `composition equalized intrinsic widths: ${a.width}, ${b.width}`);
  assertClose(b.x, a.x + a.width + gap, "natural horizontal gap");
  assertClose(top(b), top(a), "natural top alignment");
}

async function testSameDirectionBinaryGroups() {
  for (const operator of ["||", "//"]) {
    const { dump } = await dumpSource(operator === "||" ? "horizontal-chain" : "vertical-chain", `${prelude}
page chain
${boxes}
place!(a ${operator} b ${operator} c)
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

async function testSharedObjects() {
  const { dump } = await dumpSource("shared", `${prelude}
page shared
vflow(LayoutPolicy.top)
${boxes}
place!(a)
place!(b)
place!(c)
${anchor}
a || b
b // c
end
`);
  assertNestedFrames(dump);
  assertNoDiagnostic(dump, "UnplacedObject");
  assert(dump.nodes.filter((item) => item.content === "B").length === 1, "shared operand was cloned");
  const b = node(dump, "B");
  assert(dump.contains.filter((entry) => entry.children.includes(b.id)).length >= 3, "shared operand lost its existing memberships");
}

async function testConstraintUpdate() {
  const { dump } = await dumpSource("updated", `${prelude}
page update
${boxes}
place!(a)
place!(b)
place!(c)
${anchor}
a || b
~!~ b.top == a.bottom - 24
~ c.left == page.left + 600
~ c.top == page.top - 80
end
`);
  const a = node(dump, "A");
  const b = node(dump, "B");
  assertClose(b.x, a.x + a.width + gap, "vertical update changed horizontal composition");
  assertClose(top(b), a.y - 24, "ordinary update did not replace composition alignment");
  assert(relation(dump.overridden_constraints, b, "top", a, "top", 0)?.default_alignment, "replaced default alignment candidate was not recorded as overridden");
  assert(!relation(dump.constraints, b, "top", a, "top", 0), "composition regenerated an overridden constraint");
  assertClose(b.width, 180, "position update changed width");
}

async function testExplicitGap() {
  const { dump } = await dumpSource("explicit-gap", `import std:core/layout as joins
${prelude}
page gaps
vflow(LayoutPolicy.top)
${boxes}
place!(joins::hjoin(a, joins::vjoin(b, c, 12), 48))
${anchor}
end
`);
  assertNestedFrames(dump, 48, 12);
}

async function testInferredGroupConstraintUpdate() {
  const { dump } = await dumpSource("inferred-group-update", `${prelude}
page update_group
vflow(LayoutPolicy.top)
let a = place!(box("A", 120, 80))
let b = place!(box("B", 180, 60))
~ a.left == page.left + 80
~ a.top == page.top - 80
let combined = a || b
~!~ combined.left == page.left + 240
~!~ combined.top == page.top - 160
end
`);
  const a = node(dump, "A");
  const b = node(dump, "B");
  const page = dump.nodes.find((item) => item.kind === "page");
  assertClose(a.x, page.x + 240, "inferred group update did not move the first child horizontally");
  assertClose(top(a), top(page) - 160, "inferred group update did not move the first child vertically");
  assertClose(b.x, a.x + a.width + gap, "inferred group update changed the internal horizontal gap");
  assertClose(top(b), top(a), "inferred group update changed internal top alignment");
  assertClose(a.width, 120, "inferred group update changed the first width");
  assertClose(a.height, 80, "inferred group update changed the first height");
  assertClose(b.width, 180, "inferred group update changed the second width");
  assertClose(b.height, 60, "inferred group update changed the second height");
  assert(relation(dump.constraints, b, "left", a, "right", gap), "group update removed an internal horizontal constraint");
  assert(relation(dump.constraints, b, "top", a, "top", 0)?.default_alignment, "group update removed internal default alignment");
  assert(groupNodes(dump).length === 0, "updating an inferred group implicitly attached it");
  const roots = dump.flow_roots.flatMap((entry) => entry.roots);
  assert(JSON.stringify(roots) === JSON.stringify([a.id, b.id]), `updating an inferred group changed page placement roots: ${roots}`);
  const updates = dump.constraint_updates.filter((item) => item.active);
  assert(updates.length === 2 && updates[0].target_node === updates[1].target_node, "the two updates did not target the same inferred group");
  assert(!dump.nodes.some((item) => item.id === updates[0].target_node), "updated group appeared in attached dump nodes");
  assertNoDiagnostic(dump, "UnplacedObject");
}

async function testOperandEvaluation() {
  const { dump } = await dumpSource("evaluation-order", `${prelude}
fn mark!(label: String) -> Object
  return place!(box(label, 120, 60))
end

page evaluation
mark!("A") || (mark!("B") // mark!("C"))
end
`);
  for (const label of ["A", "B", "C"]) {
    assert(dump.nodes.filter((item) => item.content === label).length === 1, `operand ${label} was evaluated more than once`);
  }
  const placementOrder = dump.flow_roots.flatMap((entry) => entry.roots).map((id) => dump.nodes.find((item) => item.id === id)?.content);
  assert(JSON.stringify(placementOrder) === JSON.stringify(["A", "B", "C"]), `operands were not evaluated exactly once from left to right: ${JSON.stringify(placementOrder)}`);
}

async function testFixedStdlibResolution() {
  const { dump } = await dumpSource("shadowing", `import std:core/objects as layout
fn hjoin(a: Object, b: Object) -> Object
  return a
end
fn vjoin(a: Object, b: Object) -> Object
  return a
end
page fixed
let a = layout::place!(new("A", "body", "text"))
let b = layout::place!(new("B", "body", "text"))
let c = layout::place!(new("C", "body", "text"))
a || (b // c)
end
`);
  const a = node(dump, "A");
  const b = node(dump, "B");
  const c = node(dump, "C");
  assertClose(b.x, a.x + a.width + gap, "local hjoin or layout alias shadowed horizontal syntax");
  assertClose(top(c), b.y - gap, "local vjoin or layout alias shadowed vertical syntax");
}

async function testImportedFunctionComposition() {
  const { dump } = await dumpSource("imported-composition", `import ./component as component
${prelude}
page imported
vflow(LayoutPolicy.top)
${boxes}
place!(component::combine(a, b, c))
${anchor}
end
`, { "component.ss": `fn combine(a: Object, b: Object, c: Object) -> Object
  return a || (b // c)
end
` });
  assertNestedFrames(dump);
}

async function testInvalidOperands() {
  for (const [name, operand] of [
    ["number", "1"],
    ["string", '"wrong"'],
    ["boolean", "true"],
    ["page", "pagectx()"],
    ["selection", 'select(pagectx(), "page_objects_by_role", "body")'],
    ["optional", "maybe()"],
  ]) {
    await expectFailure(`invalid-${name}`, `${prelude}
fn maybe() -> Object?
  return none
end
page invalid
let a = text!("A")
a || ${operand}
end
`, "TypeMismatch");
  }
}

async function testConflictsAndMixedDirections() {
  await expectFailure("conflict", `${prelude}
page conflict
let a = place!(box("A", 120, 80))
let b = place!(box("B", 180, 60))
a || b
~ b.left == a.right + 64
end
`, "ConstraintConflict");
  await expectFailure("cross-page-composition", `${prelude}
page first
place!(new("A", "first_box", "text"))
end
page second
place!(new("B", "second_box", "text"))
end
document
let a = first(objs_all("first_box"))
let b = first(objs_all("second_box"))
a || b
end
`, "CrossPageConstraint");
  await expectFailure("self-composition", `${prelude}
page conflict
let a = place!(box("A", 120, 80))
a || a
end
`);
  await expectFailure("mixed-directions", `${prelude}
page mixed
${boxes}
place!(a || b // c)
end
`);
}

async function testFixture() {
  const fixture = path.join(root, "tests", "fixtures", "layout-composition", "slide.ss");
  expectSuccess(await runSs(["check", "--quiet", fixture], root), "composition fixture check");
  const dumpPath = path.join(output, "fixture.json");
  expectSuccess(await runSs(["dump", "--quiet", fixture, dumpPath], root), "composition fixture dump");
  const dump = JSON.parse(await readFile(dumpPath, "utf8"));
  assertNoDiagnostic(dump, "UnplacedObject");
  assert(dump.page_order.length === 2, "representative fixture lost a policy example page");
  caseCount += 1;
}

function policyPairSource({ documentPolicy, pagePolicy, before = "", after = "", expression = "a || b", fixedLeft = true } = {}) {
  return `${prelude}
${documentPolicy ? `document\nvflow_doc(LayoutPolicy.${documentPolicy})\nend\n` : ""}
page policy
${pagePolicy ? `vflow(LayoutPolicy.${pagePolicy})` : ""}
let a = place!(box("A", 120, 80))
let b = place!(box("B", 180, 60))
~ a.left == page.left + 80
${fixedLeft ? "~ a.top == page.top - 80" : ""}
${before}
${expression}
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
    assert(groupNodes(dump).length === 0, "policy alignment placed an inferred group");
    assert(dump.flow_roots.flatMap((entry) => entry.roots).length === 2, "policy alignment changed placement roots");
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
  for (const placement of ["children", "combined"]) {
    const { dump } = await dumpSource(`policy-nested-${placement}`, `${prelude}
page nested_policy
vflow(LayoutPolicy.center)
${boxes}
${placement === "children" ? "place!(a)\nplace!(b)\nplace!(c)\na || (b // c)" : "place!(a || (b // c))"}
${anchor}
end
`);
    const a = node(dump, "A");
    const b = node(dump, "B");
    const c = node(dump, "C");
    assertClose(b.x, a.x + a.width + gap, "centered nested horizontal gap");
    assertClose(c.x, b.x, "centered nested right-column alignment");
    assertClose(top(c), b.y - gap, "centered nested vertical gap");
    assertClose(centerY(a), (top(b) + c.y) / 2, "left operand was not centered against the complete right group");
    assert(Math.abs(centerY(a) - centerY(b)) > 1, "nested policy aligned with only the first right child");
    for (const [item, width, height] of [[a, 120, 80], [b, 180, 60], [c, 90, 50]]) {
      assertClose(item.width, width, "nested policy changed width");
      assertClose(item.height, height, "nested policy changed height");
    }
    const roots = dump.flow_roots.flatMap((entry) => entry.roots);
    assert(roots.length === (placement === "children" ? 3 : 1), "nested policy changed placement roots");
    assert(groupNodes(dump).length === (placement === "children" ? 0 : 2), "nested policy changed group attachment");
    assertNoDiagnostic(dump, "UnplacedObject");
  }
}

async function testPolicyAfterPagePlacement() {
  const { dump } = await dumpSource("policy-after-page-placement", `${prelude}
document
let a = box("A", 120, 80)
let b = box("B", 180, 60)
let combined = a || b
let destination = new_page(docctx(), "generated")
destination.layout_v = LayoutPolicy.center
place_on!(destination, combined)
end
`);
  assertHorizontalPolicy(dump, true);
  assert(dump.flow_roots.flatMap((entry) => entry.roots).length === 1, "deferred policy changed explicit group placement");
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
  const { dump } = await dumpSource("policy-centered-chain", `${prelude}
page chain_policy
vflow(LayoutPolicy.center_stack)
${boxes}
place!(a || b || c)
${anchor}
end
`);
  const a = node(dump, "A");
  const b = node(dump, "B");
  const c = node(dump, "C");
  assertClose(centerY(b), centerY(a), "first pair in chain did not center");
  assertClose(centerY(c), centerY(a), "last operand did not center against the preceding group");
  assertClose(b.x, a.x + 120 + gap, "first chain gap");
  assertClose(c.x, b.x + 180 + gap, "second chain gap");
  assert(groupNodes(dump).length === 2, "center policy flattened the binary groups");

  const vertical = await dumpSource("policy-vertical-unchanged", `${prelude}
page vertical_policy
vflow(LayoutPolicy.center)
let a = place!(box("A", 120, 80))
let b = place!(box("B", 180, 60))
${anchor}
a // b
end
`);
  const upper = node(vertical.dump, "A");
  const lower = node(vertical.dump, "B");
  assertClose(lower.x, upper.x, "horizontal policy changed vertical composition left alignment");
  assertClose(top(lower), upper.y - gap, "horizontal policy changed vertical composition gap");
  assert(relation(vertical.dump.constraints, lower, "top", upper, "bottom", -gap), "vertical composition lost its ordinary position constraint");
}

async function testOrdinaryGroupPolicyIsolation() {
  const sourceOptions = {
    pagePolicy: "center",
    before: "~ b.left == a.right + 32",
  };
  const plain = await dumpSource("policy-ordinary-plain", policyPairSource({ ...sourceOptions, expression: "" }));
  const grouped = await dumpSource("policy-ordinary-group", policyPairSource({ ...sourceOptions, expression: "group(a, b)" }));
  for (const label of ["A", "B"]) {
    for (const field of ["x", "y", "width", "height"]) {
      assertClose(node(grouped.dump, label)[field], node(plain.dump, label)[field], `ordinary group changed policy placement ${label}.${field}`);
    }
  }
  assert(Math.abs(centerY(node(grouped.dump, "A")) - centerY(node(grouped.dump, "B"))) > 1, "ordinary horizontal constraints acquired composition alignment");
  assertNoDiagnostic(grouped.dump, "UnplacedObject");
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
  const item = dump.nodes.find((candidate) => candidate.content === content);
  assert(item, `missing object ${JSON.stringify(content)}`);
  return item;
}

function groupNodes(dump) {
  return dump.nodes.filter((item) => item.kind === "object" && item.role === "group");
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
