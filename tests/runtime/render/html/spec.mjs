#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "../../harness.mjs";

await testDeterministicBundleReplacement();
await testStructuredMathDoesNotRequireTex();
await testWatchPublishesHtmlGenerations();

async function testDeterministicBundleReplacement() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-html-render-"));
  try {
    await writeFile(path.join(project, "shape.svg"), '<svg xmlns="http://www.w3.org/2000/svg" width="80" height="40"><rect width="80" height="40" fill="#369"/></svg>\n');
    await writeSlide(project, "image!(\"shape.svg\")");

    await expectSuccess(await runSs(["render", "--format", "html", "slide.ss", "deck-a"], project), "first HTML render");
    await expectSuccess(await runSs(["render", "slide.ss", "deck-b", "--format", "html"], project), "second HTML render");

    const first = await readBundle(path.join(project, "deck-a"));
    const second = await readBundle(path.join(project, "deck-b"));
    assertBundlesEqual(first, second);
    assert(first.files.includes("index.html"), "HTML bundle omitted index.html");
    assert(first.files.includes("ss.css"), "HTML bundle omitted ss.css");
    assert(first.files.includes("manifest.json"), "HTML bundle omitted manifest.json");
    assert(!first.files.includes("ss.js"), "bundle without PDF resources included JavaScript");

    const index = first.contents.get("index.html").toString("utf8");
    const css = first.contents.get("ss.css").toString("utf8");
    const manifest = JSON.parse(first.contents.get("manifest.json").toString("utf8"));
    assert(manifest.schema === 1 && manifest.kind === "ss-html-bundle", `invalid HTML manifest: ${JSON.stringify(manifest)}`);
    const svg = manifest.resources.find((resource) => resource.kind === "svg");
    assert(svg, `manifest omitted SVG resource: ${JSON.stringify(manifest)}`);
    assert(first.files.includes(svg.path), `manifest resource does not exist: ${svg.path}`);
    assert(index.includes(svg.path), `HTML does not reference SVG resource: ${svg.path}`);
    for (const resource of manifest.resources) {
      assert(resource.digest.startsWith("sha256:") && resource.digest.length === 71, `invalid resource digest: ${JSON.stringify(resource)}`);
      assert(!path.isAbsolute(resource.path) && !resource.path.split("/").includes(".."), `unsafe resource path: ${resource.path}`);
      assert(first.files.includes(resource.path), `resource file is absent: ${resource.path}`);
      const referenced = index.includes(resource.path) || css.includes(resource.path);
      assert(referenced, `published resource is not referenced by HTML or CSS: ${resource.path}`);
    }

    await writeFile(path.join(project, "deck-a", "stale.txt"), "old generation\n");
    await writeSlide(project, 'text!("Second generation")');
    await expectSuccess(await runSs(["render", "--format", "html", "--output", "deck-a", "slide.ss"], project), "replacement HTML render");
    const replaced = await readBundle(path.join(project, "deck-a"));
    const replacedManifest = JSON.parse(replaced.contents.get("manifest.json").toString("utf8"));
    assert(!replaced.files.includes("stale.txt"), "atomic replacement retained an unrelated old file");
    assert(!replaced.files.includes(svg.path), "atomic replacement retained an obsolete resource");
    assert(!replacedManifest.resources.some((resource) => resource.kind === "svg"), "replacement manifest retained an obsolete SVG resource");
    assert(replaced.contents.get("index.html").toString("utf8").includes("Second generation"), "replacement did not publish the new document");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testStructuredMathDoesNotRequireTex() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-html-math-"));
  try {
    await writeSlide(project, `math!("x_1^2 + \\frac{\\alpha}{\\sqrt{y}}")
text! <<
Inline $x_1^2 + \\alpha$

$$
\\frac{a+b}{\\sqrt{c}}
$$
>>`);
    const emptyPath = path.join(project, "empty-path");
    await mkdir(emptyPath);
    await expectSuccess(
      await runSs(["render", "--format", "html", "slide.ss", "deck"], project, { env: { PATH: emptyPath } }),
      "structured math HTML render without TeX",
    );
    await expectSuccess(
      await runSs(["render", "slide.ss", "deck.pdf"], project, { env: { PATH: emptyPath } }),
      "structured math PDF render without TeX",
    );
    assert((await stat(path.join(project, "deck.pdf"))).isFile(), "structured math PDF was not created");
    const bundle = await readBundle(path.join(project, "deck"));
    const index = bundle.contents.get("index.html").toString("utf8");
    assert(count(index, "ss-math-text") >= 3, "block，inline，or display math did not use native HTML elements");
    assert(count(index, "class=\"ss-mathml\"") >= 3, "block，inline，or display math omitted MathML semantics");
    assert(!index.includes("data-pdf-src"), "structured math used a PDF fallback");
    assert(!bundle.files.includes("ss.js"), "structured math unnecessarily packaged PDF.js");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

function count(value, pattern) {
  return value.split(pattern).length - 1;
}

async function testWatchPublishesHtmlGenerations() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-html-watch-"));
  let child;
  try {
    await writeSlide(project, 'text!("Watch generation one")');
    child = spawn(ssBin, ["watch", "render", "--format", "html", "--interval-ms", "50", "slide.ss", "watched"], {
      cwd: project,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const output = collectOutput(child);
    await waitForFile(path.join(project, "watched", "index.html"), (value) => value.includes("Watch generation one"));
    await writeSlide(project, 'text!("Watch generation two")');
    await waitForFile(path.join(project, "watched", "index.html"), (value) => value.includes("Watch generation two"));
    await new Promise((resolve) => setTimeout(resolve, 250));
    const log = output.text();
    const changes = [...log.matchAll(/watch: change detected/g)].length;
    assert(changes === 1, `watch should publish one generation for one source edit，got ${changes}:\n${log}`);
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

async function readBundle(root) {
  const files = [];
  const contents = new Map();
  await visit("");
  files.sort();
  return { files, contents };

  async function visit(relative) {
    const directory = path.join(root, relative);
    const entries = await readdir(directory, { withFileTypes: true });
    for (const entry of entries) {
      const child = relative ? `${relative}/${entry.name}` : entry.name;
      if (entry.isDirectory()) await visit(child);
      else {
        files.push(child);
        contents.set(child, await readFile(path.join(root, child)));
      }
    }
  }
}

function assertBundlesEqual(left, right) {
  assert(JSON.stringify(left.files) === JSON.stringify(right.files), `bundle file lists differ:\n${left.files.join("\n")}\n---\n${right.files.join("\n")}`);
  for (const file of left.files) {
    assert(left.contents.get(file).equals(right.contents.get(file)), `bundle file differs: ${file}`);
  }
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
