#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "../../harness.mjs";

const pageHeight = 720;

await testDocumentAndPageVflowPolicies();

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
      topTitle.y + topTitle.height > 600,
      `top_flow title should be placed near the explicit top anchor, anchor ${frameSummary(topAnchor)}, title ${frameSummary(topTitle)}`,
    );
  } finally {
    await rm(project, { recursive: true, force: true });
  }
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
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (code) => resolve({ code: code ?? -1, stdout, stderr }));
  });
}

async function mkdtempProject(prefix) {
  return mkdtemp(path.join(os.tmpdir(), prefix));
}
