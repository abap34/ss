#!/usr/bin/env node
import { spawn } from "node:child_process";
import { deepStrictEqual } from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { assert, root, ssBin } from "../../harness.mjs";

const pageHeight = 720;

await testDocumentAndPageVflowPolicies();
await testPageAnchorFixture();
await testPageNumbersPreserveContentLayout();

async function testDocumentAndPageVflowPolicies() {
  const project = await mkdtempProject("ss-layout-vflow-policy-");
  try {
    const slide = path.join(project, "slide.ss");
    const dumpPath = path.join(project, "dump.json");
    await writeFile(slide, vflowPolicySource(), "utf8");

    const dump = await dumpSlide(project, dumpPath);
    const document = nodeByKind(dump, "document");
    assert(document.fields.layout_v === "center", `document layout_v should be explicit center, got ${JSON.stringify(document.fields)}`);
    assert(document.fields.layout_v_center_offset === "40", `document center offset should be explicit 40, got ${JSON.stringify(document.fields)}`);

    const inheritedPage = pageByName(dump, "inherited");
    assert(!hasField(inheritedPage, "layout_v"), `page default must not become explicit layout_v: ${JSON.stringify(inheritedPage.fields)}`);
    assert(!hasField(inheritedPage, "layout_v_center_offset"), `page default must not become explicit center offset: ${JSON.stringify(inheritedPage.fields)}`);
    assertStackCenter(dump, "Inherited Title", "Inherited Subtitle", pageHeight / 2 - 40);

    const inheritedAnchor = nodeByContent(dump, "Inherited Anchor");
    const inheritedTitle = nodeByContent(dump, "Inherited Title");
    assert(
      inheritedTitle.y + inheritedTitle.height > inheritedAnchor.y + inheritedAnchor.height,
      `document-centered vflow should not chain from the fixed anchor, anchor ${frameSummary(inheritedAnchor)}, title ${frameSummary(inheritedTitle)}`,
    );

    const pageCentered = pageByName(dump, "page_centered");
    assert(pageCentered.fields.layout_v === "center", `page vflow should set explicit layout_v, got ${JSON.stringify(pageCentered.fields)}`);
    assert(pageCentered.fields.layout_v_center_offset === "-80", `page vflow should set explicit offset, got ${JSON.stringify(pageCentered.fields)}`);
    assertStackCenter(dump, "Page Centered Title", "Page Centered Subtitle", pageHeight / 2 + 80);

    const topFlowPage = pageByName(dump, "top_flow_override");
    assert(topFlowPage.fields.layout_v === "top_flow", `page top_flow override should be explicit, got ${JSON.stringify(topFlowPage.fields)}`);
    const topAnchor = nodeByContent(dump, "Top Flow Anchor");
    const topTitle = nodeByContent(dump, "Top Flow Title");
    assert(
      Math.abs(topTitle.y + topTitle.height - 660) <= 0.01,
      `top_flow title should use its default position independently of the fixed anchor, anchor ${frameSummary(topAnchor)}, title ${frameSummary(topTitle)}`,
    );
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testPageAnchorFixture() {
  const project = await mkdtempProject("page-anchors-");
  try {
    const fixture = path.join(root, "tests", "fixtures", "layout", "page-anchors", "slide.ss");
    const dumpPath = path.join(project, "dump.json");
    await runSs(["check", "--quiet", fixture], root);
    await runSs(["dump", "--quiet", fixture, dumpPath], root);
    const dump = JSON.parse(await readFile(dumpPath, "utf8"));
    const objectsOnPage = (name) => {
      const page = pageByName(dump, name);
      const children = dump.contains.find((entry) => entry.parent === page.id).children;
      return dump.nodes.filter((item) => children.includes(item.id));
    };
    const baseline = objectsOnPage("baseline");
    const anchored = objectsOnPage("anchored");
    const centered = objectsOnPage("centered");
    for (const content of ["First block", "Second block"]) {
      const expected = baseline.find((item) => item.content === content);
      const actual = anchored.find((item) => item.content === content);
      for (const field of ["x", "y", "width", "height"]) {
        assertClose(actual[field], expected[field], `page decoration changed ${content}.${field}`);
      }
    }
    const first = baseline.find((item) => item.content === "First block");
    const second = baseline.find((item) => item.content === "Second block");
    assertClose(first.y + first.height, 660, "horizontal page anchors should preserve vertical flow");
    assertClose(second.y + second.height, first.y - 24, "unanchored blocks should flow in placement order");
    const centeredFirst = centered.find((item) => item.content === "First block");
    const centeredSecond = centered.find((item) => item.content === "Second block");
    assertClose((centeredFirst.y + centeredFirst.height + centeredSecond.y) / 2, pageHeight / 2, "page anchors should preserve the automatic stack center");
    for (const objects of [anchored, centered]) {
      const badge = objects.find((item) => item.content === "DRAFT");
      const note = objects.find((item) => item.content === "Fixed note");
      assertClose(badge.y + badge.height, pageHeight - 24, "direct page anchor");
      assertClose(note.y + note.height, badge.y - 16, "transitive page anchor");
    }
    for (const objects of [baseline, anchored, centered]) {
      assertClose(objects.find((item) => item.role === "pageno").y, 20, "generated page number anchor");
      assertClose(objects.find((item) => item.role === "footer").y, 20, "generated footer anchor");
    }
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testPageNumbersPreserveContentLayout() {
  const project = await mkdtempProject("page-number-comparison-");
  const imports = "import std:themes/default as *\n";
  const policies = ["", "vflow_doc(LayoutPolicy.top)", "vflow_doc(LayoutPolicy.center)", "vflow_doc(LayoutPolicy.center, 40)"];
  let comparisons = 0;
  try {
    for (const policy of policies) {
      const pages = `document
${policy}
end

page flowing
text!("First paragraph")
let body = text!("Several words wrap across lines while retaining their measured layout.")
~ body.width == 280
end

page headed
head!("Fixed heading")
let body = text!("Body below a heading and a rule")
~ body.width == 320
end

page composed
let left = text("Left column with several words that wrap")
let upper = text("Right upper paragraph")
let lower = text("Right lower paragraph")
~ left.width == 240
~ upper.width == 220
~ lower.width == 220
place!(left || (upper // lower))
end
`;
      await writeFile(path.join(project, "slide.ss"), imports + pages, "utf8");
      const baseline = await dumpSlide(project, path.join(project, "without-numbers.json"));
      assert(!baseline.nodes.some((item) => item.role === "pageno"), "baseline unexpectedly contains a page number");

      for (const position of ["before", "after"]) {
        const generation = "\ndocument\npagenos!()\nend\n";
        const source = imports + (position === "before" ? generation + pages : pages + generation);
        await writeFile(path.join(project, "slide.ss"), source, "utf8");
        const numbered = await dumpSlide(project, path.join(project, `numbers-${position}.json`));
        assert(numbered.page_order.length === baseline.page_order.length, "page numbering changed page count");
        for (const name of ["flowing", "headed", "composed"]) {
          const pageObjects = (dump) => {
            const page = pageByName(dump, name);
            const children = dump.contains.find((entry) => entry.parent === page.id).children;
            return dump.nodes.filter((item) => children.includes(item.id));
          };
          const expected = pageObjects(baseline);
          const objects = pageObjects(numbered);
          const numbers = objects.filter((item) => item.role === "pageno");
          assert(numbers.length === 1, `${name} should receive exactly one page number`);
          assertClose(numbers[0].y, 20, `${name} page number position`);
          const actual = objects.filter((item) => item.role !== "pageno");
          const metadata = (items) => items.map(({ name, role, content, fields }) => ({ name, role, content, fields }));
          deepStrictEqual(metadata(actual), metadata(expected), `${name}: numbering changed existing content or style`);
          for (let index = 0; index < expected.length; index += 1) {
            for (const field of ["x", "y", "width", "height"]) {
              assertClose(actual[index][field], expected[index][field], `${policy || "default"}, numbers ${position}, ${name}, object ${index}.${field}`);
            }
          }
          comparisons += 1;
        }
      }
    }
  } finally {
    await rm(project, { recursive: true, force: true });
  }
  console.log(`page numbering: ${comparisons} page comparisons passed`);
}

function vflowPolicySource() {
  return `import std:themes/default as *

document
vflow_doc(LayoutPolicy.center, 40)
end

page inherited
let anchor = text!("Inherited Anchor")
~ anchor.bottom == page.bottom + 20

${stackSource("Inherited Title", "Inherited Subtitle")}
end

page page_centered
vflow(LayoutPolicy.center, sub(0, 80))
${stackSource("Page Centered Title", "Page Centered Subtitle")}
end

page top_flow_override
vflow(LayoutPolicy.top_flow)
let anchor = text!("Top Flow Anchor")
~ anchor.bottom == page.top - 20

let title = text!("Top Flow Title")
end
`;
}

function stackSource(titleText, subtitleText) {
  return `let title = text!("${titleText}")

let subtitle = text!("${subtitleText}")`;
}

async function dumpSlide(project, dumpPath) {
  await runSs(["dump", "slide.ss", dumpPath], project);
  return JSON.parse(await readFile(dumpPath, "utf8"));
}

function assertStackCenter(dump, titleContent, subtitleContent, expected) {
  const title = nodeByContent(dump, titleContent);
  const subtitle = nodeByContent(dump, subtitleContent);
  const top = title.y + title.height;
  const bottom = subtitle.y;
  assertClose((top + bottom) / 2, expected, `stack center for ${titleContent} and ${subtitleContent} should be ${expected}, title ${frameSummary(title)}, subtitle ${frameSummary(subtitle)}`);
}

function nodeByKind(dump, kind) {
  const node = dump.nodes.find((candidate) => candidate.kind === kind);
  assert(node, `node with kind ${kind} was not found`);
  return node;
}

function pageByName(dump, name) {
  const node = dump.nodes.find((candidate) => candidate.kind === "page" && candidate.name === name);
  assert(node, `page ${JSON.stringify(name)} was not found`);
  return node;
}

function nodeByContent(dump, content) {
  const node = dump.nodes.find((candidate) => candidate.content === content);
  assert(node, `node with content ${JSON.stringify(content)} was not found`);
  return node;
}

function hasField(node, fieldName) {
  return Object.prototype.hasOwnProperty.call(node.fields, fieldName);
}

function assertClose(actual, expected, message) {
  assert(Math.abs(actual - expected) <= 0.01, `${message}; got ${actual}`);
}

function frameSummary(node) {
  return `x=${node.x}, y=${node.y}, width=${node.width}, height=${node.height}`;
}

async function runSs(args, cwd) {
  const result = await spawnCollect(ssBin, args, cwd);
  if (result.code !== 0) {
    throw new Error(`ss ${args.join(" ")} failed with ${result.code}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  }
  return result;
}

async function spawnCollect(command, args, cwd) {
  return await new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    const timeout = setTimeout(() => {
      timedOut = true;
      child.kill("SIGKILL");
    }, 30000);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => { clearTimeout(timeout); reject(error); });
    child.on("close", (code) => {
      clearTimeout(timeout);
      if (timedOut) reject(new Error(`ss ${args.join(" ")} timed out after 30 seconds\n${stderr}`));
      else resolve({ code: code ?? -1, stdout, stderr });
    });
  });
}

async function mkdtempProject(prefix) {
  const output = path.join(root, ".ss-cache", "tests", "layout", "vflow");
  await mkdir(output, { recursive: true });
  return mkdtemp(path.join(output, prefix));
}
