#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "../../harness.mjs";

await testVectorShapes();
await testImmutableShapeConstructors();
await testStdlibShapeCatalog();
await testPathCommandOrderDiagnostic();

async function testVectorShapes() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-vector-shapes-"));
  try {
    await writeFile(path.join(project, "slide.ss"), `import std:themes/default as *

page vector
let patterned = place!(rectangle(
  240,
  150,
  vector_style(
    crosshatch_fill(c"#b45309", c"#fef3c7", 35, 10, 1),
    vector_stroke(c"#92400e", 2, LineCap.round, LineJoin.round)
  )
))
~ patterned.left == page.left + 80
~ patterned.top == page.top - 80

let gradient = place!(circle(
  180,
  140,
  vector_style(
    linear_gradient_fill(c"#38bdf8", c"#4f46e5", gradient_down_right()),
    vector_stroke(c"#1e3a8a", 2, LineCap.round, LineJoin.round)
  )
))
~ gradient.left == page.left + 500
~ gradient.top == page.top - 70

let custom = place!(path_shape(
  path(
    move_to(0, 0.5),
    quadratic_to(0.25, 0, 0.5, 0.5),
    arc_to(0.5, 0.5, 0, false, true, 1, 0.5),
    line_to(1, 1),
    line_to(0, 1),
    close_path()
  ),
  260,
  170,
  vector_style(
    radial_gradient_fill(c"#fff1f2", c"#fb7185"),
    vector_stroke(c"#881337", 3, LineCap.round, LineJoin.round)
  )
))
~ custom.left == page.left + 280
~ custom.top == page.top - 390

let elbow = elbow_line!(
  180,
  110,
  LineStyle {
    stroke = dashed_stroke(c"#4b5563", 2, 9, 5)
    marker_start = marker_arrow_open(10, c"#4b5563", 2)
    marker_end = marker_arrow_open(10, c"#4b5563", 2)
  }
)
~ elbow.left == page.left + 760
~ elbow.top == page.top - 360

end
`, "utf8");

    expectSuccess(await runSs(["dump", "slide.ss", "dump.json"], project), "vector shape dump");
    expectSuccess(await runSs(["render", "--format", "html", "slide.ss", "deck.html"], project), "vector shape HTML render");
    expectSuccess(await runSs(["render", "slide.ss", "deck.pdf"], project), "vector shape PDF render");

    const dump = JSON.parse(await readFile(path.join(project, "dump.json"), "utf8"));
    const vectorNodes = dump.nodes.filter((node) => node.placement?.display.kind === "path_shape");
    assert(vectorNodes.length === 4, `expected four vector shape nodes, got ${vectorNodes.length}`);

    for (const node of vectorNodes) {
      const storedPath = taggedRecordField(node.placement.input, "path");
      assert(storedPath.kind === "path", `vector shape did not store a Path value: ${JSON.stringify(node.placement.input)}`);
      assert(storedPath.commands.length > 0, `vector shape stored an empty Path value: ${JSON.stringify(node.placement.input)}`);
      assert(
        storedPath.commands.every((command) => ["move_to", "line_to", "cubic_to", "close"].includes(command.verb)),
        `Path was not normalized to the rendering basis: ${JSON.stringify(node.placement.input)}`,
      );
    }
    const customPath = taggedRecordField(vectorNodes[2].placement.input, "path");
    assert(customPath.commands.filter((command) => command.verb === "cubic_to").length >= 2, "quadratic and arc commands were not lowered to cubic curves");
    const elbowPath = taggedRecordField(vectorNodes[3].placement.input, "path");
    assert(
      elbowPath.commands.map((command) => command.verb).join(",") === "move_to,line_to,line_to",
      `elbow line did not preserve its orthogonal route: ${JSON.stringify(elbowPath)}`,
    );

    const html = await readFile(path.join(project, "deck.html"), "utf8");
    const pdf = await readFile(path.join(project, "deck.pdf"));
    assert(pdf.subarray(0, 5).toString() === "%PDF-", "PDF rendering did not produce a PDF document");
    assert(count(html, "ss-vector-path") === 6, "HTML did not contain the four shapes and two marker paths");
    assert(count(html, "<linearGradient") === 1, "HTML omitted the linear gradient definition");
    assert(count(html, "<radialGradient") === 1, "HTML omitted the radial gradient definition");
    assert(count(html, "<pattern") === 1, "HTML omitted the tile pattern definition");
    assert(/patternTransform="matrix\((?!1\.000000000 0\.000000000 0\.000000000 1\.000000000)/.test(html), "HTML omitted the hatch rotation");
    assert(html.includes('stroke-dasharray="9.000000000 5.000000000"'), "HTML omitted the line dash pattern");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testImmutableShapeConstructors() {
  const names = ["rectangle", "circle", "arrow_shape", "speech_bubble", "line", "elbow_line"];
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-immutable-shapes-"));
  try {
    const declarations = names.map(name => `const ${name}_value: PathShape = ${name}(180, 90)`).join("\n");
    const pages = names.map(name => `page ${name}
  let total = selection_count(select<PathShape>(pagectx()))
  let label = place!(text_api::Text { content = "Shapes: " ++ str(total) })
  let original: Placed<PathShape> = ${name}!(180, 90)
  let changed = place!(${name}_value with { width = 90 })
  let copies = place!(duplicate(${name}_value))
  let wrapped = place!(Diagram { value = ${name}_value })
  ~ label.left == page.left + 64
  ~ label.top == page.top - 32
  ~ original.left == page.left + 64
  ~ original.top == page.top - 100
  ~ changed.left == original.right + 48
  ~ changed.top == original.top
  ~ copies.left == page.left + 64
  ~ copies.top == page.top - 260
  ~ wrapped.left == page.left + 560
  ~ wrapped.top == page.top - 100
end`).join("\n");
    const header = `import std:graphics as *
import std:text as text_api
fn duplicate<T>(value: T) -> Group<T, T> = value || value
type Diagram { value: PathShape }
fn display(self: Placed<Diagram>) -> PathShape = self.value.value
${declarations}
`;
    await writeFile(path.join(project, "slide.ss"), header + "page unused\nend\n");
    expectSuccess(await runSs(["dump", "--quiet", "slide.ss", "unused.json"], project), "unused shape values");
    const unused = JSON.parse(await readFile(path.join(project, "unused.json"), "utf8"));
    assert(!unused.nodes.some(node => node.placement), "shape construction allocated a placement");
    assert(unused.constraints.length === 0, "shape construction installed hidden constraints");
    await writeFile(path.join(project, "slide.ss"), header + pages);
    expectSuccess(await runSs(["dump", "--quiet", "slide.ss", "dump.json"], project), "immutable shape dump");
    const dump = JSON.parse(await readFile(path.join(project, "dump.json"), "utf8"));
    assert(dump.diagnostics.length === 0, JSON.stringify(dump.diagnostics));
    assert(dump.nodes.filter(node => node.content === "Shapes: 5").length === names.length, "forward queries missed shape placements");
    const shapes = dump.nodes.filter(node => node.placement?.display.kind === "path_shape");
    assert(shapes.length === 30 && new Set(shapes.map(node => node.id)).size === 30, "reused shapes lost independent placement identity");
    for (const page of dump.page_order) {
      const members = shapes.filter(node => node.placement.page === page);
      assert(members.length === 5, "a shape was assigned to the wrong page");
      assert(members.filter(node => Math.abs(node.width - 90) < 0.1).length === 1, "with did not change exactly one input");
      for (const node of members) {
        assert(Object.keys(node.fields).length === 0, "shape retained mutable properties");
        assert(Math.abs(node.height - 90) < 0.1, "shape height changed during reuse");
      }
    }
    expectSuccess(await runSs(["render", "--quiet", "slide.ss", "deck.pdf"], project), "immutable shape PDF");
    await writeFile(path.join(project, "circle.ss"), "page defaults\nlet item = circle!(156)\nend\n");
    expectSuccess(await runSs(["dump", "--quiet", "circle.ss", "circle.json"], project), "circle default height");
    const circle = JSON.parse(await readFile(path.join(project, "circle.json"), "utf8")).nodes.find(node => node.placement?.display.kind === "path_shape");
    assert(Math.abs(circle.width - 156) < 0.1 && Math.abs(circle.height - 156) < 0.1, "circle height did not default to its width");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testStdlibShapeCatalog() {
  const constructors = ["rectangle", "circle", "arrow_shape", "speech_bubble", "line", "elbow_line"];
  const fills = [
    'hatch_fill(c"#334155")',
    'crosshatch_fill(c"#334155")',
    'grid_fill(c"#334155")',
    'dots_fill(c"#334155")',
    'checker_fill(c"#334155")',
    'brick_fill(c"#334155")',
    'waves_fill(c"#334155")',
    'stipple_sparse_fill(c"#334155")',
    'stipple_fill(c"#334155")',
    'stipple_dense_fill(c"#334155")',
    'linear_gradient_fill(c"#ffffff", c"#334155", gradient_left())',
    'radial_gradient_fill(c"#ffffff", c"#334155")',
  ];
  const markers = ["marker_arrow_open()"];
  const declarations = constructors.map((name, index) => {
    const column = index % 8;
    const row = Math.floor(index / 8);
    return `let shape_${index} = ${name}!()
~ shape_${index}.left == page.left + ${20 + column * 150}
~ shape_${index}.top == page.top - ${20 + row * 135}`;
  }).join("\n");
  const valueBindings = [
    ...fills.map((value, index) => `let fill_${index} = ${value}`),
    ...markers.map((value, index) => `let marker_${index} = ${value}`),
  ].join("\n");

  const project = await mkdtemp(path.join(os.tmpdir(), "ss-shape-catalog-"));
  try {
    await writeFile(path.join(project, "slide.ss"), `import std:themes/default as *

page shape-catalog
${declarations}
${valueBindings}
end
`, "utf8");
    expectSuccess(await runSs(["dump", "slide.ss", "dump.json"], project), "stdlib shape catalog dump");
    const dump = JSON.parse(await readFile(path.join(project, "dump.json"), "utf8"));
    const vectorNodes = dump.nodes.filter((node) => node.placement?.display.kind === "path_shape");
    assert(vectorNodes.length === constructors.length, `expected ${constructors.length} stdlib shapes, got ${vectorNodes.length}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testPathCommandOrderDiagnostic() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-vector-path-order-"));
  try {
    await writeFile(path.join(project, "slide.ss"), `import std:themes/default as *

page invalid
path(line_to(1, 1))
end
`, "utf8");
    const result = await runSs(["check", "slide.ss"], project);
    assert(result.code !== 0, "a path beginning with line_to unexpectedly passed checking");
    assert(
      `${result.stdout}\n${result.stderr}`.includes("InvalidPathCommandOrder"),
      `path command order diagnostic was not preserved:\n${result.stdout}\n${result.stderr}`,
    );
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

function taggedRecordField(record, name) {
  assert(record.kind === "record", `expected tagged record, got ${JSON.stringify(record)}`);
  return record.fields.find((field) => field.name === name)?.value;
}

function count(value, pattern) {
  return value.split(pattern).length - 1;
}

function runSs(args, cwd) {
  return new Promise((resolve, reject) => {
    const child = spawn(ssBin, args, { cwd, timeout: 30000, killSignal: "SIGKILL", stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", (code, signal) => resolve({ code: code ?? -1, signal, stdout, stderr }));
  });
}

function expectSuccess(result, label) {
  assert(result.code === 0, `${label} failed with ${result.code ?? result.signal}:\n${result.stdout}\n${result.stderr}`);
}
