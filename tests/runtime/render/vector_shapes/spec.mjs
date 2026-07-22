#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "../../harness.mjs";

await testVectorShapesAndConnectors();
await testStdlibShapeCatalog();
await testCalloutUsesGenericConnector();
await testPathCommandOrderDiagnostic();

async function testVectorShapesAndConnectors() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-vector-shapes-"));
  try {
    await writeFile(path.join(project, "slide.ss"), `import std:themes/default as *

page vector
let patterned = place!(rounded_rectangle(
  240,
  150,
  0.15,
  vector_style(
    crosshatch_fill(c"#b45309", c"#fef3c7", 35, 10, 1),
    vector_stroke(c"#92400e", 2, LineCap.round, LineJoin.round)
  )
))
~ patterned.left == page.left + 80
~ patterned.top == page.top - 80

let gradient = place!(star(
  180,
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
    stroke = solid_stroke(c"#4b5563", 2)
    marker_start = marker_arrow_open(10, c"#4b5563", 2)
    marker_end = marker_arrow_open(10, c"#4b5563", 2)
  }
)
~ elbow.left == page.left + 760
~ elbow.top == page.top - 360

arrow_connector!(
  patterned,
  gradient,
  ConnectorRoute.curve,
  ConnectorAnchor.right,
  ConnectorAnchor.left,
  vector_stroke(c"#0f766e", 3, LineCap.round, LineJoin.round, "9,5"),
  14
)
end
`, "utf8");

    expectSuccess(await runSs(["dump", "slide.ss", "dump.json"], project), "vector shape dump");
    expectSuccess(await runSs(["render", "--format", "html", "slide.ss", "deck.html"], project), "vector shape HTML render");
    expectSuccess(await runSs(["render", "slide.ss", "deck.pdf"], project), "vector shape PDF render");

    const dump = JSON.parse(await readFile(path.join(project, "dump.json"), "utf8"));
    const vectorNodes = dump.nodes.filter((node) => node.role === "vector_path");
    const connectorNodes = dump.nodes.filter((node) => node.role === "connector");
    assert(vectorNodes.length === 4, `expected four vector shape nodes，got ${vectorNodes.length}`);
    assert(connectorNodes.length === 1, `expected one connector node，got ${connectorNodes.length}`);

    for (const node of vectorNodes) {
      const storedPath = JSON.parse(node.fields.path);
      assert(storedPath.kind === "path", `vector shape did not store a Path value: ${node.fields.path}`);
      assert(storedPath.commands.length > 0, `vector shape stored an empty Path value: ${node.fields.path}`);
      assert(
        storedPath.commands.every((command) => ["move", "line", "cubic", "close"].includes(command.verb)),
        `Path was not normalized to the rendering basis: ${node.fields.path}`,
      );
    }
    const customPath = JSON.parse(vectorNodes[2].fields.path);
    assert(customPath.commands.filter((command) => command.verb === "cubic").length >= 2, "quadratic and arc commands were not lowered to cubic curves");
    const elbowPath = JSON.parse(vectorNodes[3].fields.path);
    assert(
      elbowPath.commands.map((command) => command.verb).join(",") === "move,line,line",
      `elbow line did not preserve its orthogonal route: ${vectorNodes[3].fields.path}`,
    );

    const connector = JSON.parse(connectorNodes[0].fields.connector);
    const source = taggedRecordField(connector, "source");
    const target = taggedRecordField(connector, "target");
    assert(source?.kind === "object" && target?.kind === "object", `connector endpoints did not preserve object references: ${connectorNodes[0].fields.connector}`);
    const markerEnd = taggedRecordField(connector, "marker_end");
    assert(taggedRecordField(markerEnd, "path")?.kind === "path", `connector marker did not preserve its arbitrary Path: ${connectorNodes[0].fields.connector}`);

    const html = await readFile(path.join(project, "deck.html"), "utf8");
    const pdf = await readFile(path.join(project, "deck.pdf"));
    assert(pdf.subarray(0, 5).toString() === "%PDF-", "PDF rendering did not produce a PDF document");
    assert(count(html, "ss-vector-path") === 8, "HTML did not contain the four shapes，derived connector path，and three marker paths");
    assert(count(html, "<linearGradient") === 1, "HTML omitted the linear gradient definition");
    assert(count(html, "<radialGradient") === 1, "HTML omitted the radial gradient definition");
    assert(count(html, "<pattern") === 1, "HTML omitted the tile pattern definition");
    assert(/patternTransform="matrix\((?!1\.000000000 0\.000000000 0\.000000000 1\.000000000)/.test(html), "HTML omitted the hatch rotation");
    assert(html.includes('stroke-dasharray="9.000000000 5.000000000"'), "HTML omitted the connector dash pattern");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testStdlibShapeCatalog() {
  const constructors = [
    "rectangle", "rounded_rectangle", "ellipse", "circle", "capsule",
    "triangle", "right_triangle", "diamond", "parallelogram", "trapezoid",
    "pentagon", "hexagon", "octagon", "star", "chevron", "arrow_shape",
    "plus_shape", "heart", "speech_bubble", "cloud", "rect", "rounded_rect",
    "triangle_up", "triangle_right", "triangle_down", "triangle_left",
    "star4", "star5", "star6", "cross_shape", "chevron_right", "chevron_left",
    "chevron_down", "chevron_up", "block_arrow_right", "block_arrow_left",
    "block_arrow_down", "block_arrow_up", "semicircle", "quarter_circle",
  ];
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
  const markers = [
    "marker_arrow_open()", "marker_arrow_filled()", "marker_triangle()",
    "marker_circle()", "marker_square()", "marker_diamond()", "marker_bar()",
  ];
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
    const vectorNodes = dump.nodes.filter((node) => node.role === "vector_path");
    assert(vectorNodes.length === constructors.length, `expected ${constructors.length} stdlib shapes，got ${vectorNodes.length}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testCalloutUsesGenericConnector() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-callout-connector-"));
  try {
    await writeFile(path.join(project, "slide.ss"), `import std:themes/default as *

page callout
let target = text!("target")
~ target.left == page.left + 180
~ target.top == page.top - 220
bracket_callout!(target, "note", 650, 390, 220, CalloutStyle { left_bracket = true })
end
`, "utf8");
    expectSuccess(await runSs(["dump", "slide.ss", "dump.json"], project), "callout connector dump");
    expectSuccess(await runSs(["render", "--format", "html", "slide.ss", "deck.html"], project), "callout connector HTML render");
    const dump = JSON.parse(await readFile(path.join(project, "dump.json"), "utf8"));
    assert(dump.nodes.filter((node) => node.role === "connector").length === 1, "callout did not use the generic connector object");
    assert(dump.nodes.every((node) => node.role !== "shape"), "callout retained a legacy shape object");
    const html = await readFile(path.join(project, "deck.html"), "utf8");
    assert(count(html, "ss-vector-path") === 2, "callout connector path and marker were not rendered");
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
  assert(record.kind === "record", `expected tagged record，got ${JSON.stringify(record)}`);
  return record.fields.find((field) => field.name === name)?.value;
}

function count(value, pattern) {
  return value.split(pattern).length - 1;
}

function runSs(args, cwd) {
  return new Promise((resolve, reject) => {
    const child = spawn(ssBin, args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
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
