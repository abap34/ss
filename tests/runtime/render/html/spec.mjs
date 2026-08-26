#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "../../harness.mjs";

await testDeterministicSingleFileReplacement();
if (await commandAvailable("pdflatex")) await testLatexMathUsesPdfResources();
await testWatchPublishesHtmlGenerations();

async function testDeterministicSingleFileReplacement() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-html-render-"));
  try {
    await writeFile(path.join(project, "shape.svg"), '<svg xmlns="http://www.w3.org/2000/svg" width="80" height="40"><rect width="80" height="40" fill="#369"/></svg>\n');
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page first
image!("shape.svg")
image!("shape.svg")
end

page second
image!("shape.svg")
image!("shape.svg")
end
`,
      "utf8",
    );

    await expectSuccess(
      await runSs(["render", "--format", "html", "slide.ss", "deck-a.html"], project, { env: { SS_RENDER_JOBS: "1" } }),
      "serial HTML render",
    );
    await expectSuccess(
      await runSs(["render", "slide.ss", "deck-b.html", "--format", "html"], project, { env: { SS_RENDER_JOBS: "4" } }),
      "parallel HTML render",
    );

    const first = await readFile(path.join(project, "deck-a.html"));
    const second = await readFile(path.join(project, "deck-b.html"));
    assert(first.equals(second), "identical renders produced different HTML files");
    const document = first.toString("utf8");
    assert(count(document, "<section class=\"ss-page\"") === 2, "HTML omitted a page element");
    assert(document.includes('data-ss-src="ss-resource:svg:'), "HTML did not reference the embedded SVG resource");
    assert(count(document, 'data-ss-src="ss-resource:svg:') === 4, "repeated SVG uses did not share one resource reference");
    assert(count(document, 'data-media-type="image/svg+xml"') === 1, "repeated SVG bytes were serialized more than once");
    assert(document.includes("data:text/css;charset=utf-8;base64,"), "HTML did not embed its style sheet");
    assert(count(document, "data:text/javascript;charset=utf-8;base64,") === 3, "non-PDF content did not embed exactly resource loading, page navigation, and text alignment");
    assert(!document.includes('data-ss-third-party-license="pdf.js"'), "non-PDF content embedded the PDF.js license");
    assert(!document.includes("manifest.json") && !document.includes("assets/"), "HTML retained an external bundle reference");

    await writeSlide(project, 'text!("Second generation")');
    await expectSuccess(await runSs(["render", "--format", "html", "--output", "deck-a.html", "slide.ss"], project), "replacement HTML render");
    const replacedPath = path.join(project, "deck-a.html");
    assert((await stat(replacedPath)).isFile(), "replacement did not retain one HTML file");
    const replaced = await readFile(replacedPath, "utf8");
    assert(replaced.includes("Second generation"), "replacement did not publish the new document");
    assert(!replaced.includes('data-media-type="image/svg+xml"'), "replacement retained an obsolete SVG resource");

    const protectedOutput = path.join(project, "protected.html");
    await mkdir(protectedOutput);
    const protectedFile = path.join(protectedOutput, "keep.txt");
    await writeFile(protectedFile, "keep this directory\n");
    await expectFailure(
      await runSs(["render", "--format", "html", "--output", "protected.html", "slide.ss"], project),
      "directory output rejection",
    );
    assert((await stat(protectedOutput)).isDirectory(), "HTML render replaced an existing directory");
    assert(await readFile(protectedFile, "utf8") === "keep this directory\n", "HTML render modified an existing directory");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testLatexMathUsesPdfResources() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-html-latex-"));
  try {
    await writeSlide(project, `latex!("$x_1^2 + \\frac{\\alpha}{\\sqrt{y}}$")
text! <<
Inline $x_1^2 + \\alpha$

$$
\\frac{a+b}{\\sqrt{c}}
$$
>>
end

page second
latex!("$z_2^3 + \\frac{b}{c}$")`);
    await expectSuccess(
      await runSs(["render", "--format", "html", "slide.ss", "deck.html"], project, { env: { SS_RENDER_JOBS: "4" } }),
      "LaTeX math HTML render",
    );
    await expectSuccess(
      await runSs(["render", "slide.ss", "deck.pdf"], project),
      "LaTeX math PDF render",
    );
    assert((await stat(path.join(project, "deck.pdf"))).isFile(), "LaTeX math PDF was not created");
    const document = await readFile(path.join(project, "deck.html"), "utf8");
    assert(count(document, "class=\"ss-item ss-latex ss-pdf\"") >= 4, "LaTeX objects or Markdown mathematics omitted PDF items");
    assert(document.includes('data-pdf-src="ss-resource:latex_pdf:'), "LaTeX output did not reference an embedded PDF resource");
    assert(document.includes('data-media-type="application/pdf"'), "LaTeX PDF resource was not embedded");
    assert(document.includes('class="ss-latex-semantic" role="math"'), "LaTeX output omitted math semantics");
    assert(!document.includes("MathML"), "obsolete structured MathML output remained");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

function count(value, pattern) {
  return value.split(pattern).length - 1;
}

async function commandAvailable(command) {
  return new Promise((resolve) => {
    const child = spawn(command, ["--version"], { stdio: "ignore" });
    child.once("error", () => resolve(false));
    child.once("exit", (code) => resolve(code === 0));
  });
}

async function testWatchPublishesHtmlGenerations() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-html-watch-"));
  let child;
  try {
    await writeSlide(project, 'text!("Watch generation one")');
    child = spawn(ssBin, ["watch", "render", "--format", "html", "--interval-ms", "50", "slide.ss", "watched.html"], {
      cwd: project,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const output = collectOutput(child);
    await waitForFile(path.join(project, "watched.html"), (value) => value.includes("Watch generation one"));
    await writeSlide(project, 'text!("Watch generation two")');
    await waitForFile(path.join(project, "watched.html"), (value) => value.includes("Watch generation two"));
    await new Promise((resolve) => setTimeout(resolve, 250));
    const log = output.text();
    const changes = [...log.matchAll(/watch: change detected/g)].length;
    assert(changes === 1, `watch should publish one generation for one source edit, got ${changes}:\n${log}`);
  } finally {
    if (child && child.exitCode === null) {
      child.kill("SIGTERM");
      await new Promise((resolve) => child.once("exit", resolve));
    }
    await rm(project, { recursive: true, force: true });
  }
}

async function writeSlide(project, body) {
  await writeFile(
    path.join(project, "slide.ss"),
    `import std:themes/default as *

page demo
${body}
end
`,
    "utf8",
  );
}

async function waitForFile(file, predicate) {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    try {
      if ((await stat(file)).isFile()) {
        const value = await readFile(file, "utf8");
        if (predicate(value)) return;
      }
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`timed out waiting for ${file}`);
}

function collectOutput(child) {
  let value = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { value += chunk; });
  child.stderr.on("data", (chunk) => { value += chunk; });
  return { text: () => value };
}

async function runSs(args, cwd, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(ssBin, args, {
      cwd,
      env: { ...process.env, ...options.env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("exit", (code, signal) => resolve({ code, signal, stdout, stderr }));
  });
}

function expectSuccess(result, label) {
  assert(result.code === 0, `${label} failed with ${result.code ?? result.signal}:\n${result.stdout}\n${result.stderr}`);
}

function expectFailure(result, label) {
  assert(result.code !== 0, `${label} unexpectedly succeeded:\n${result.stdout}\n${result.stderr}`);
}
