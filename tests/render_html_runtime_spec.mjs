#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./lsp_harness.mjs";

await testRenderHtmlFromExtension();
await testRenderHtmlFromFormat();
await testRenderHtmlRejectsPdfCacheId();
await testCheckRejectsUnusedOutputArgument();

async function testRenderHtmlFromExtension() {
  const project = await mkdtempProject("ss-render-html-ext-");
  try {
    const slide = path.join(project, "slide.ss");
    const output = path.join(project, "deck.html");
    await writeFile(slide, deckSource("HTML by extension"), "utf8");

    await runSs(["render", "slide.ss", "deck.html"], project);
    const html = await readFile(output, "utf8");
    assertHtmlDeck(html, ["HTML", "by", "extension"]);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testRenderHtmlFromFormat() {
  const project = await mkdtempProject("ss-render-html-format-");
  try {
    const slide = path.join(project, "slide.ss");
    const output = path.join(project, "slide.html");
    await writeFile(slide, deckSource("HTML by format"), "utf8");

    await runSs(["render", "slide.ss", "--format", "html"], project);
    await stat(output);
    const html = await readFile(output, "utf8");
    assertHtmlDeck(html, ["HTML", "by", "format"]);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testCheckRejectsUnusedOutputArgument() {
  const project = await mkdtempProject("ss-cli-check-args-");
  try {
    await writeFile(path.join(project, "slide.ss"), deckSource("Check args"), "utf8");
    const result = await runSs(["check", "slide.ss", "unused.out"], project, { allowFailure: true });
    assert(result.code !== 0, "check should reject an unused output argument");
    assert(result.stderr.includes("too many arguments"), `unexpected check error: ${result.stderr}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testRenderHtmlRejectsPdfCacheId() {
  const project = await mkdtempProject("ss-render-html-cache-id-");
  try {
    await writeFile(path.join(project, "slide.ss"), deckSource("Cache id"), "utf8");
    const result = await runSs(["render", "slide.ss", "--format", "html", "--cache-id", "stable"], project, { allowFailure: true });
    assert(result.code !== 0, "HTML render should reject --cache-id");
    assert(result.stderr.includes("--cache-id is only valid for PDF render output"), `unexpected cache-id error: ${result.stderr}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

function assertHtmlDeck(html, words) {
  assert(html.startsWith("<!doctype html>"), "HTML render did not produce a document");
  assert(html.includes("<svg "), "HTML render did not include SVG page content");
  assert(html.includes("<text "), "HTML render did not include text spans");
  for (const word of words) {
    assert(html.includes(word), `HTML render did not include deck text: ${word}`);
  }
}

function deckSource(text) {
  return `import std:themes/default as *

page main
text!("${text}")
end
`;
}

async function mkdtempProject(prefix) {
  return mkdtemp(path.join(os.tmpdir(), prefix));
}

async function runSs(args, cwd, options = {}) {
  const result = await spawnCollect(ssBin, args, cwd);
  if (!options.allowFailure && result.code !== 0) {
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
