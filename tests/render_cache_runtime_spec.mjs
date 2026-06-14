#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, readdir, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./lsp_harness.mjs";

await testRenderCacheGenerations();
await testCacheClearRejectsActiveRender();

async function testRenderCacheGenerations() {
  const project = await mkdtempProject("ss-render-cache-");
  try {
    const slide = path.join(project, "slide.ss");
    const firstSource = deckSource("First page", "Second page");
    await writeFile(slide, firstSource, "utf8");

    await runSs(["render", "slide.ss", "out-1.pdf", "--cache-id", "stable-deck"], project);
    const cacheRoot = path.join(project, ".ss-cache", "render");
    await assertPathMissing(path.join(cacheRoot, "documents"), "document cache directory should not be created");
    await assertPathMissing(path.join(cacheRoot, "pages"), "top-level page cache directory should not be created");
    await assertPathMissing(path.join(cacheRoot, "chunks"), "top-level chunk cache directory should not be created");

    const firstGeneration = await singleGeneration(cacheRoot);
    const firstPages = await pdfFiles(path.join(firstGeneration.path, "pages"));
    assert(firstPages.length === 2, `expected two cached page PDFs, got ${firstPages.length}`);

    const secondSource = deckSource("First page", "Changed second page");
    await writeFile(slide, secondSource, "utf8");
    await runSs(["render", "slide.ss", "out-2.pdf", "--cache-id", "stable-deck"], project);

    const secondGeneration = await singleGeneration(cacheRoot);
    assert(secondGeneration.name !== firstGeneration.name, "second render should publish a fresh generation");
    const secondPages = await pdfFiles(path.join(secondGeneration.path, "pages"));
    assert(secondPages.length === 2, `expected two cached page PDFs after rerender, got ${secondPages.length}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testCacheClearRejectsActiveRender() {
  const project = await mkdtempProject("ss-render-cache-clear-");
  try {
    const leases = path.join(project, ".ss-cache", "render", "leases");
    await mkdir(leases, { recursive: true });
    await writeFile(path.join(leases, "active.json"), JSON.stringify({ schema: 1, pid: process.pid }), "utf8");

    const result = await runSs(["cache", "clear"], project, { allowFailure: true });
    assert(result.code !== 0, "cache clear should fail while an active lease exists");
    assert(
      result.stderr.includes("render cache is currently in use"),
      `cache clear did not report active lease: ${result.stderr}`,
    );
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

function deckSource(first, second) {
  return `import std:themes/default as *

page one
text!("${first}")
end

page two
text!("${second}")
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

async function singleGeneration(cacheRoot) {
  const decks = await readdir(path.join(cacheRoot, "decks"), { withFileTypes: true });
  const deckDirs = decks.filter((entry) => entry.isDirectory());
  assert(deckDirs.length === 1, `expected one deck cache, got ${deckDirs.map((entry) => entry.name).join(", ")}`);

  const generationsRoot = path.join(cacheRoot, "decks", deckDirs[0].name, "generations");
  const entries = await readdir(generationsRoot, { withFileTypes: true });
  const generations = entries.filter((entry) => entry.isDirectory() && !entry.name.startsWith(".building-"));
  assert(generations.length === 1, `expected one published generation, got ${generations.map((entry) => entry.name).join(", ")}`);
  return {
    name: generations[0].name,
    path: path.join(generationsRoot, generations[0].name),
  };
}

async function pdfFiles(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  return entries.filter((entry) => entry.isFile() && entry.name.endsWith(".pdf"));
}

async function assertPathMissing(target, message) {
  try {
    await stat(target);
  } catch (error) {
    if (error?.code === "ENOENT") return;
    throw error;
  }
  const files = await readdir(target).catch(() => []);
  throw new Error(`${message}; found ${target} with entries ${files.join(", ")}`);
}
