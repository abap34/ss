#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, readdir, rm, stat, utimes, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./harness.mjs";

await testRenderCacheGenerations();
await testMeasurementCacheIsReused();
await testRenderCompilationReusesTextShapes();
await testRenderCachePruneIntervalSkipsFreshStamp();
await testCacheStatsCommands();
await testCacheClearRejectsActiveRender();

async function testRenderCacheGenerations() {
  const project = await mkdtempProject("ss-render-cache-");
  try {
    const slide = path.join(project, "slide.ss");
    const firstPagesSource = Array.from({ length: 18 }, (_, index) => `Page ${index + 1}`);
    const firstSource = deckSource(firstPagesSource);
    await writeFile(slide, firstSource, "utf8");

    await runSs(["render", "slide.ss", "out-1.pdf"], project);
    const cacheRoot = path.join(project, ".ss-cache", "render");
    await assertPathMissing(path.join(cacheRoot, "documents"), "document cache directory should not be created");
    await assertPathMissing(path.join(cacheRoot, "pages"), "top-level page cache directory should not be created");
    await assertPathMissing(path.join(cacheRoot, "chunks"), "top-level chunk cache directory should not be created");

    const contentCache = path.join(cacheRoot, "ss-pdf-render-ir-v1");
    const firstPages = await pdfFiles(path.join(contentCache, "pages"));
    assert(firstPages.length === firstPagesSource.length, `expected ${firstPagesSource.length} cached page PDFs, got ${firstPages.length}`);
    const firstDocuments = await pdfFiles(path.join(contentCache, "documents"));
    assert(firstDocuments.length === 1, `expected one cached document PDF, got ${firstDocuments.length}`);
    await assertPdfFile(path.join(contentCache, "documents", firstDocuments[0]), "first render should cache the assembled PDF");

    const secondPagesSource = [...firstPagesSource];
    secondPagesSource[7] = "Changed page 8";
    const secondSource = deckSource(secondPagesSource);
    await writeFile(slide, secondSource, "utf8");
    const secondRun = await runSs(["render", "slide.ss", "out-2.pdf"], project);
    assert(secondRun.stderr.includes("pages 17/18"), `rerender did not report mixed page cache hits and misses:\n${secondRun.stderr}`);

    const secondPages = await pdfFiles(path.join(contentCache, "pages"));
    assertAddedFiles(firstPages, secondPages, 1, "changing one page should add exactly one page cache entry");
    const secondDocuments = await pdfFiles(path.join(contentCache, "documents"));
    assertAddedFiles(firstDocuments, secondDocuments, 1, "changing one page should add exactly one document cache entry");

    const pageStats = await fileStats(path.join(contentCache, "pages"), secondPages);
    const documentStats = await fileStats(path.join(contentCache, "documents"), secondDocuments);
    const thirdRun = await runSs(["render", "slide.ss", "out-3.pdf"], project);
    assert(thirdRun.stderr.includes("pages 18/18"), `identical rerender did not report a full document cache hit:\n${thirdRun.stderr}`);
    assertFileSetUnchanged(pageStats, await fileStats(path.join(contentCache, "pages"), await pdfFiles(path.join(contentCache, "pages"))), "identical rerender changed page cache entries");
    assertFileSetUnchanged(documentStats, await fileStats(path.join(contentCache, "documents"), await pdfFiles(path.join(contentCache, "documents"))), "identical rerender changed document cache entries");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testMeasurementCacheIsReused() {
  const project = await mkdtempProject("ss-measure-cache-");
  try {
    const slide = path.join(project, "slide.ss");
    await writeFile(
      slide,
      `import std:themes/default as *

page measure
text!("A moderately long line that goes through native text measurement.")
end
`,
      "utf8",
    );

    await runSs(["dump", "slide.ss", "dump-1.json"], project);
    const measurementDir = path.join(project, ".ss-cache", "render", "artifacts", "native", "measurements");
    const measurementCachePath = path.join(measurementDir, "measurements.tsv");
    const firstStats = await fileStatSignature(measurementCachePath);
    assert(firstStats.size > 0, "first dump should create a measurement cache index");
    await delay(50);
    await runSs(["dump", "slide.ss", "dump-2.json"], project);
    const secondStats = await fileStatSignature(measurementCachePath);
    assertFileStatUnchanged(firstStats, secondStats, "second dump should reuse the existing measurement cache index");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testRenderCompilationReusesTextShapes() {
  const project = await mkdtempProject("ss-render-text-cache-");
  try {
    const slide = path.join(project, "slide.ss");
    await writeFile(slide, deckSource(Array.from({ length: 24 }, () => "Repeated compiler text")), "utf8");

    const result = await runSs(["render", "slide.ss", "out.pdf"], project, {
      env: { SS_MEASURE_PROFILE: "1", SS_RENDER_JOBS: "2" },
    });
    const profile = result.stderr.match(/text shape: hit (\d+) .* miss (\d+)/);
    assert(profile, `render profile omitted text shape counters:\n${result.stderr}`);
    assert(Number(profile[1]) > 0, `render compilation did not reuse any text shapes:\n${result.stderr}`);
    assert(Number(profile[2]) > 0, `render compilation did not record the initial text shape:\n${result.stderr}`);
    await assertPdfFile(path.join(project, "out.pdf"), "rendered PDF should remain valid after the text cache is released");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testRenderCachePruneIntervalSkipsFreshStamp() {
  const project = await mkdtempProject("ss-render-cache-prune-");
  try {
    const slide = path.join(project, "slide.ss");
    await writeFile(slide, deckSource(["Prune interval"]), "utf8");

    const artifacts = path.join(project, ".ss-cache", "render", "artifacts");
    await mkdir(artifacts, { recursive: true });
    const oldArtifact = path.join(artifacts, "old.bin");
    await writeFile(oldArtifact, "x".repeat(1024), "utf8");
    await writeFile(path.join(artifacts, ".prune-stamp"), "", "utf8");
    const oldDate = new Date(Date.now() - 60_000);
    await utimes(oldArtifact, oldDate, oldDate);

    await runSs(["render", "slide.ss", "out-1.pdf"], project, {
      env: { SS_CACHE_MAX_BYTES: "1b" },
    });
    await stat(oldArtifact);

    await runSs(["render", "slide.ss", "out-2.pdf"], project, {
      env: { SS_CACHE_MAX_BYTES: "1b", SS_CACHE_PRUNE_INTERVAL_SECONDS: "always" },
    });
    await assertPathMissing(oldArtifact, "forced prune should remove the stale artifact");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testCacheStatsCommands() {
  const project = await mkdtempProject("ss-cache-stats-");
  try {
    const projectStats = await runSs(["cache", "project", "stats"], project);
    assert(projectStats.stderr.includes("render cache:"), `project cache stats omitted render cache path: ${projectStats.stderr}`);

    const treeSitterStats = await runSs(["cache", "tree-sitter", "stats"], project);
    assert(treeSitterStats.stderr.includes("tree-sitter cache:"), `tree-sitter cache stats omitted cache path: ${treeSitterStats.stderr}`);
    assert(treeSitterStats.stderr.includes("current manifest hash:"), `tree-sitter cache stats omitted manifest hash: ${treeSitterStats.stderr}`);
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

    const result = await runSs(["cache", "project", "clear"], project, { allowFailure: true });
    assert(result.code !== 0, "cache project clear should fail while an active lease exists");
    assert(
      result.stderr.includes("project render cache is currently in use"),
      `cache project clear did not report active lease: ${result.stderr}`,
    );
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

function deckSource(pages) {
  return `import std:themes/default as *

${pages
  .map(
    (text, index) => `page p${index + 1}
text!("${text}")
end`,
  )
  .join("\n\n")}
`;
}

async function mkdtempProject(prefix) {
  return mkdtemp(path.join(os.tmpdir(), prefix));
}

async function runSs(args, cwd, options = {}) {
  const result = await spawnCollect(ssBin, args, cwd, options);
  if (!options.allowFailure && result.code !== 0) {
    throw new Error(`ss ${args.join(" ")} failed with ${result.code}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  }
  return result;
}

async function spawnCollect(command, args, cwd, options = {}) {
  return await new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, env: { ...process.env, ...options.env }, stdio: ["ignore", "pipe", "pipe"] });
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

async function pdfFiles(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  return entries
    .filter((entry) => entry.isFile() && entry.name.endsWith(".pdf"))
    .map((entry) => entry.name)
    .sort();
}

function assertAddedFiles(first, second, expected, message) {
  const firstSet = new Set(first);
  const added = second.filter((file) => !firstSet.has(file));
  assert(second.length === first.length + expected && added.length === expected, `${message}; added ${added.join(", ")}`);
}

async function fileStats(directory, files) {
  return new Map(await Promise.all(files.map(async (file) => [file, await fileStatSignature(path.join(directory, file))])));
}

function assertFileSetUnchanged(first, second, message) {
  assert(first.size === second.size, `${message}; file count changed from ${first.size} to ${second.size}`);
  for (const [file, firstStat] of first) {
    const secondStat = second.get(file);
    assert(secondStat, `${message}; ${file} disappeared`);
    assertFileStatUnchanged(firstStat, secondStat, `${message}; ${file}`);
  }
}

async function fileStatSignature(filePath) {
  const info = await stat(filePath);
  return {
    size: info.size,
    mtime: info.mtimeNs ?? BigInt(Math.round(info.mtimeMs * 1_000_000)),
  };
}

function assertFileStatUnchanged(first, second, message) {
  assert(first.size === second.size, `${message}; size changed from ${first.size} to ${second.size}`);
  assert(first.mtime === second.mtime, `${message}; mtime changed from ${first.mtime} to ${second.mtime}`);
}

async function delay(ms) {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function assertPdfFile(target, message) {
  const info = await stat(target);
  assert(info.isFile() && info.size > 8, `${message}; invalid PDF file at ${target}`);
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
