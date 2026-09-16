#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import { root, ssBin } from "../../harness.mjs";

const exec = promisify(execFile);
const operators = ["||", "//", "|=|", "/=/"];
const gaps = ["", " ", "\n", "\n\n", "\n;; generated comment\n\t", "\r\n# generated comment\r\n  "];
const labels = ["A short", "B a considerably longer sentence", "C middle text"];
const leaf = (index) => ({ leaf: index });
const chain = (operator, ...children) => ({ operator, children });
const seeds = [];
for (const operator of operators) {
  seeds.push(chain(operator, leaf(0), leaf(1)), chain(operator, leaf(0), leaf(1), leaf(2)));
  for (const inner of operators) {
    seeds.push(chain(operator, chain(inner, leaf(0), leaf(1)), leaf(2)));
    seeds.push(chain(operator, leaf(0), chain(inner, leaf(1), leaf(2))));
  }
}

const output = path.join(root, ".ss-cache/tests/syntax/formatting");
await mkdir(output, { recursive: true });
const directory = await mkdtemp(path.join(output, "run-"));
const prelude = `import std:core/prelude as *
fn mark!(label: String) -> Object
  return text!(label)
end
`;
const cases = [];
for (const policy of ["top", "center"]) {
  for (const [seed, tree] of seeds.entries()) {
    const reference = `${policy}_${seed}`;
    cases.push({ id: `${reference}_base`, reference, baseline: true, policy, expression: print(tree) });
    // The parser test exhausts the Cartesian product. The runtime boundary
    // samples every gap, literal form and parenthesis mask for every tree.
    for (let variant = 0; variant < 12; variant += 1) {
      const format = { mask: variant % 8, gap: variant % gaps.length, literal: Math.floor(variant / 3) % 4, before: variant % 2 === 0 };
      cases.push({ id: `${reference}_${variant}`, reference, policy, format, expression: print(tree, format) });
    }
  }
}
await writeFile(path.join(directory, "cases.json"), JSON.stringify(cases, null, 2));
const references = new Map();
let comparisons = 0;
let conflictComparisons = 0;
for (let offset = 0; offset < cases.length; offset += 13) {
  // Keep each baseline and its variants together, including combinations
  // whose intrinsic sizes already produce a layout conflict in the baseline.
  const batch = cases.slice(offset, offset + 13);
  const dump = await runBatch(`batch-${offset}`, batch);
  for (const item of batch) {
    const actual = profile(dump, item.id);
    if (item.baseline) references.set(item.reference, actual);
    else {
      assert.deepEqual(actual, references.get(item.reference), `formatting changed evaluation/layout: ${item.id}\n${JSON.stringify(item.format)}\n${item.expression}\nArtifacts: ${directory}`);
      comparisons += 1;
      if (actual.failures?.length) conflictComparisons += 1;
    }
  }
}

// These parentheses change equal-cell grouping, so the comparison must reject
// them. This guards against accidentally comparing only rendered leaf text.
const controls = [
  chain("|=|", leaf(0), leaf(1), leaf(2)),
  chain("|=|", chain("|=|", leaf(0), leaf(1)), leaf(2)),
  chain("|=|", leaf(1), leaf(0), leaf(2)),
].map((tree, index) => ({ id: `control_${index}`, policy: "top", expression: print(tree) }));
const controlDump = await runBatch("controls", controls);
assert(controlDump.nodes, "semantic controls must have valid layouts");
assert.notDeepEqual(profile(controlDump, "control_0"), profile(controlDump, "control_1"), "comparison lost group boundaries");
assert.notDeepEqual(profile(controlDump, "control_0"), profile(controlDump, "control_2"), "comparison lost evaluation order");
assert.equal(comparisons, 960);
assert(comparisons - conflictComparisons >= 480, "too few successful layouts exercised");
console.log(`generated formatting: ${comparisons - conflictComparisons} layout and ${conflictComparisons} conflict equivalence comparisons and 2 semantic controls passed`);
console.log(`generated formatting artifacts: ${directory}`);

function print(tree, format) {
  let site = 0;
  const gap = format ? gaps[format.gap] : "";
  function expression(node, nested = false) {
    const position = site++;
    const depth = Number(nested && node.children !== undefined) + (format && (format.mask & (1 << (position % 3))) ? 2 : 0);
    let text;
    if (node.children) {
      const before = !format ? " " : format.before ? gap : format.gap % 2 ? "\t" : "";
      const after = format ? gap : " ";
      text = node.children.map((child) => expression(child, true)).join(`${before}${node.operator}${after}`);
    } else {
      const label = labels[node.leaf];
      switch (format ? (format.literal + node.leaf) % 4 : 0) {
        case 0: text = `mark!(${gap}"${label}"${gap})`; break;
        case 1: text = `mark! "${label}"`; break;
        case 2: text = `mark!(<<\n${label}\n\t>>${gap})`; break;
        case 3: text = `mark! << # generated header\n${label}\n\t>>`; break;
      }
    }
    for (let index = 0; index < depth; index += 1) text = `(${gap}${text}${gap})`;
    return text;
  }
  return expression(tree);
}

async function runBatch(name, batch) {
  const file = path.join(directory, `${name}.ss`);
  const destination = path.join(directory, `${name}.json`);
  const source = prelude + batch.map((item) => `\npage ${item.id}\nvflow(LayoutPolicy.${item.policy})\nlet g = ${item.expression}\nplace!(g)\nend\n`).join("");
  await writeFile(file, source);
  try {
    await exec(ssBin, ["dump", "--quiet", file, destination], { cwd: directory, timeout: 30000, killSignal: "SIGKILL", maxBuffer: 2 * 1024 * 1024 });
  } catch (error) {
    if (error.code !== 1 || !error.stderr?.includes("ConstraintConflict")) {
      throw new Error(`generated formatting failed in ${file}\n${error.stderr ?? error.message}`, { cause: error });
    }
    await exec(ssBin, ["debug", "layout", "conflicts", "--quiet", file, "--output", destination], {
      cwd: directory, timeout: 30000, killSignal: "SIGKILL", maxBuffer: 2 * 1024 * 1024,
    });
    const report = JSON.parse(await readFile(destination, "utf8"));
    assert(report.failures.length > 0, `missing conflict report in ${file}`);
    return report;
  }
  const dump = JSON.parse(await readFile(destination, "utf8"));
  assert(dump.diagnostics.every((diagnostic) => diagnostic.severity !== "error"), `unexpected error diagnostics in ${file}`);
  return dump;
}

function profile(dump, name) {
  if (dump.kind === "ss-layout-conflicts") return conflictProfile(dump, name);
  const page = dump.nodes.find((node) => node.kind === "page" && node.name === name);
  assert(page, `missing page ${name}`);
  const children = new Map(dump.contains.map((entry) => [entry.parent, entry.children]));
  const ids = new Set();
  function visit(id) {
    for (const child of children.get(id) ?? []) {
      if (ids.has(child)) continue;
      ids.add(child);
      visit(child);
    }
  }
  visit(page.id);
  const nodes = dump.nodes.filter((node) => ids.has(node.id));
  const names = new Map(nodes.map((node, index) => [node.id, index]));
  names.set(page.id, "page");
  function identity(id) {
    assert(names.has(id), `reference to an unexpected node ${id} in ${name}`);
    return names.get(id);
  }
  return {
    // Creation order also checks exactly-once, left-to-right evaluation.
    nodes: nodes.map((node) => ({ role: node.role, content: node.content, payload: node.payload_kind, frame: [node.x, node.y, node.width, node.height], measurement: node.measurement })),
    children: nodes.map((node) => (children.get(node.id) ?? []).map(identity)),
    roots: (dump.placement_roots.find((entry) => entry.page === page.id)?.roots ?? []).map(identity),
    diagnostics: dump.diagnostics.filter((diagnostic) => diagnostic.page_id === page.id).map(({ origin, page_id, node_id, ...diagnostic }) => ({
      ...diagnostic, node: node_id === null ? null : identity(node_id),
    })),
    constraints: dump.constraints.filter((constraint) => ids.has(constraint.target_node)).map(({ origin, target_node, source_node, ...constraint }) => ({
      ...constraint, target: identity(target_node), source: source_node === null ? "page" : identity(source_node),
    })),
  };
}

function conflictProfile(report, name) {
  const page = report.pages.find((item) => item.name === name);
  assert(page, `missing page ${name}`);
  const objects = report.objects.filter((object) => object.page_id === page.id);
  const names = new Map(objects.map((object, index) => [object.id, index]));
  names.set(page.id, "page");
  function normalize(value) {
    if (value === null || typeof value !== "object") return value;
    if (Array.isArray(value)) return value.map(normalize);
    return Object.fromEntries(Object.entries(value).flatMap(([key, item]) => {
      if (["origin", "location", "index", "constraint_index", "existing_constraint_index", "sources"].includes(key)) return [];
      if (key === "node_id" || key === "page_id") {
        assert(names.has(item), `reference outside page ${name}: ${item}`);
        return [[key, names.get(item)]];
      }
      return [[key, normalize(item)]];
    }));
  }
  return {
    objects: objects.map(({ id, name: objectName, ...object }) => normalize(object)),
    relations: report.relations.filter((relation) => names.has(relation.target.node_id)).map(normalize),
    failures: report.failures.filter((failure) => failure.page_id === page.id).map(normalize),
  };
}
