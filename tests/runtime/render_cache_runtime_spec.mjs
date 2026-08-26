#!/usr/bin/env node
import { spawn } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, stat, utimes, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./harness.mjs";

await testRenderCacheGenerations();
await testRenderManifestFallbacks();
await testDeltaRejectsInternalLinkChanges();
await testMeasurementCacheIsReused();
await testRenderCompilationReusesTextShapes();
await testRenderCachePruneIntervalSkipsFreshStamp();
await testCacheStatsCommands();
await testCacheClearRejectsActiveRender();
await testCacheClearRemovesStaleLeaseRecords();

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
    const firstDocumentStats = await fileStats(path.join(contentCache, "documents"), firstDocuments);
    const manifests = (await readdir(path.join(contentCache, "output-manifests"))).filter((name) => name.endsWith(".manifest"));
    assert(manifests.length === 1, `expected one output manifest, got ${manifests.length}`);
    const manifestPath = path.join(contentCache, "output-manifests", manifests[0]);
    const firstManifest = await readFile(manifestPath, "utf8");
    assert(firstManifest.startsWith("ss-pdf-output-manifest-v2\n"), "output manifest omitted its cache version");
    assert(firstManifest.includes("\nassembly\tfull\n"), `initial render did not record full assembly:\n${firstManifest}`);
    assert(firstManifest.includes("\npages\t18\n"), "output manifest omitted the page count");

    const secondPagesSource = [...firstPagesSource];
    secondPagesSource[7] = "Changed page 8";
    const secondSource = deckSource(secondPagesSource);
    await writeFile(slide, secondSource, "utf8");
    await writeFile(path.join(project, "out-1.pdf"), "untrusted output must not be used as the replacement base", "utf8");
    const secondRun = await runSs(["render", "slide.ss", "out-1.pdf"], project);
    assert(secondRun.stderr.includes("pages 17/18"), `rerender did not report mixed page cache hits and misses:\n${secondRun.stderr}`);
    await assertPdfFile(path.join(project, "out-1.pdf"), "replacement render should overwrite an untrusted output from the immutable cache");

    const secondPages = await pdfFiles(path.join(contentCache, "pages"));
    assertAddedFiles(firstPages, secondPages, 1, "changing one page should add exactly one page cache entry");
    const secondDocuments = await pdfFiles(path.join(contentCache, "documents"));
    assertAddedFiles(firstDocuments, secondDocuments, 1, "changing one page should add exactly one document cache entry");
    assertFileSetUnchanged(firstDocumentStats, await fileStats(path.join(contentCache, "documents"), firstDocuments), "page replacement modified the immutable base document");
    const secondManifest = await readFile(manifestPath, "utf8");
    assert(secondManifest !== firstManifest, "one-page change did not update the output manifest");
    assert(secondManifest.includes("\nassembly\tdelta\n"), `one-page change did not use delta assembly:\n${secondManifest}`);

    const pageStats = await fileStats(path.join(contentCache, "pages"), secondPages);
    const documentStats = await fileStats(path.join(contentCache, "documents"), secondDocuments);
    const thirdRun = await runSs(["render", "slide.ss", "out-1.pdf"], project);
    assert(thirdRun.stderr.includes("pages 18/18"), `identical rerender did not report a full document cache hit:\n${thirdRun.stderr}`);
    const thirdManifest = await readFile(manifestPath, "utf8");
    assert(thirdManifest.includes("\nassembly\tdocument-cache\n"), `identical rerender did not record a document cache hit:\n${thirdManifest}`);
    assertFileSetUnchanged(pageStats, await fileStats(path.join(contentCache, "pages"), await pdfFiles(path.join(contentCache, "pages"))), "identical rerender changed page cache entries");
    assertFileSetUnchanged(documentStats, await fileStats(path.join(contentCache, "documents"), await pdfFiles(path.join(contentCache, "documents"))), "identical rerender changed document cache entries");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testRenderManifestFallbacks() {
  const project = await mkdtempProject("ss-render-manifest-fallback-");
  try {
    const slide = path.join(project, "slide.ss");
    const output = path.join(project, "out.pdf");
    const cacheRoot = path.join(project, ".ss-cache", "render", "ss-pdf-render-ir-v1");
    await writeFile(slide, deckSource(["First", "Second", "Third", "Fourth"]), "utf8");
    await runSs(["render", "slide.ss", output], project);
    const manifestDir = path.join(cacheRoot, "output-manifests");
    const manifestNames = (await readdir(manifestDir)).filter((name) => name.endsWith(".manifest"));
    assert(manifestNames.length === 1, `expected one fallback-test manifest, got ${manifestNames.length}`);
    const manifest = path.join(manifestDir, manifestNames[0]);

    await rm(manifest);
    await writeFile(slide, deckSource(["First missing", "Second", "Third", "Fourth"]), "utf8");
    await runSs(["render", "slide.ss", output], project);
    await assertPdfFile(output, "render should fall back when the output manifest is missing");

    await writeFile(manifest, "corrupt manifest\n", "utf8");
    await writeFile(slide, deckSource(["First corrupt", "Second", "Third", "Fourth"]), "utf8");
    await runSs(["render", "slide.ss", output], project);
    await assertPdfFile(output, "render should fall back when the output manifest is corrupt");

    const currentManifest = await readFile(manifest, "utf8");
    const documentDigest = currentManifest.match(/\ndocument\t([0-9a-f]{64})\n/)?.[1];
    assert(documentDigest, `output manifest omitted the document digest:\n${currentManifest}`);
    await rm(path.join(cacheRoot, "documents", `${documentDigest}.pdf`));
    await writeFile(slide, deckSource(["First base missing", "Second", "Third", "Fourth"]), "utf8");
    await runSs(["render", "slide.ss", output], project);
    await assertPdfFile(output, "render should fall back when the immutable base document is missing");

    await writeFile(slide, deckSource(["First base missing", "Second", "Third", "Fourth", "Fifth"]), "utf8");
    await runSs(["render", "slide.ss", output], project);
    await assertPdfFile(output, "render should fall back when the page count changes");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testDeltaRejectsInternalLinkChanges() {
  const project = await mkdtempProject("ss-render-internal-link-delta-");
  try {
    const slide = path.join(project, "slide.ss");
    const output = path.join(project, "out.pdf");
    await writeFile(slide, internalLinkDeckSource("Target", "Jump"), "utf8");
    await runSs(["render", "slide.ss", output], project);

    const manifestDir = path.join(project, ".ss-cache", "render", "ss-pdf-render-ir-v1", "output-manifests");
    const manifestNames = (await readdir(manifestDir)).filter((name) => name.endsWith(".manifest"));
    assert(manifestNames.length === 1, `expected one internal-link manifest, got ${manifestNames.length}`);
    const manifest = path.join(manifestDir, manifestNames[0]);

    await writeFile(slide, internalLinkDeckSource("Target", "Changed jump"), "utf8");
    await runSs(["render", "slide.ss", output], project);
    const changedLinkManifest = await readFile(manifest, "utf8");
    assert(
      changedLinkManifest.includes("\nassembly\tfull\n"),
      `changing a destination link unexpectedly used delta assembly:\n${changedLinkManifest}`,
    );

    await writeFile(slide, internalLinkDeckSource("Changed target", "Changed jump"), "utf8");
    await runSs(["render", "slide.ss", output], project);
    const changedDestinationManifest = await readFile(manifest, "utf8");
    assert(
      changedDestinationManifest.includes("\nassembly\tfull\n"),
      `changing a destination definition unexpectedly used delta assembly:\n${changedDestinationManifest}`,
    );
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
  let renderPromise = null;
  const release = path.join(project, "release-pdflatex");
  try {
    const fakeBin = path.join(project, "bin");
    const started = path.join(project, "pdflatex-started");
    await mkdir(fakeBin);
    const fakePdflatex = path.join(fakeBin, "pdflatex");
    await writeFile(
      fakePdflatex,
      `#!/bin/sh
: > ${shellQuote(started)}
while [ ! -e ${shellQuote(release)} ]; do /bin/sleep 0.02; done
exit 1
`,
      "utf8",
    );
    await chmod(fakePdflatex, 0o755);
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page main
latex!("$x$")
end
`,
      "utf8",
    );
    renderPromise = spawnCollect(ssBin, ["render", "slide.ss", "out.pdf"], project, {
      env: { PATH: `${fakeBin}${path.delimiter}${process.env.PATH ?? ""}` },
    });
    await waitForPath(started, 5_000);

    const result = await runSs(["cache", "project", "clear"], project, { allowFailure: true });
    assert(result.code !== 0, "cache project clear should fail while an active lease exists");
    assert(
      result.stderr.includes("project render cache is currently in use"),
      `cache project clear did not report active lease: ${result.stderr}`,
    );

    await writeFile(release, "", "utf8");
    await renderPromise;
    renderPromise = null;
    await runSs(["cache", "project", "clear"], project);
  } finally {
    await writeFile(release, "", "utf8").catch(() => {});
    await renderPromise?.catch(() => {});
    await rm(project, { recursive: true, force: true });
  }
}

async function testCacheClearRemovesStaleLeaseRecords() {
  const project = await mkdtempProject("ss-render-cache-stale-lease-");
  try {
    const leases = path.join(project, ".ss-cache", "render", "leases");
    await mkdir(leases, { recursive: true });
    await writeFile(path.join(leases, "stale.json"), JSON.stringify({ schema: 1, pid: process.pid }), "utf8");

    await runSs(["cache", "project", "clear"], project);
    await assertPathMissing(path.join(project, ".ss-cache", "render"), "cache clear should remove stale lease records");
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

function internalLinkDeckSource(targetText, linkText) {
  return `import std:themes/default as *

page target
let target = txt_obj("${targetText}", "body")
target.link_id = "target"
place!(target)
end

page link
text! <<
[${linkText}](#target)
>>
end
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

async function waitForPath(target, timeoutMs) {
  const deadline = performance.now() + timeoutMs;
  while (performance.now() < deadline) {
    try {
      await stat(target);
      return;
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    await delay(20);
  }
  throw new Error(`timed out waiting for ${target}`);
}

function shellQuote(value) {
  return `'${value.replaceAll("'", `'"'"'`)}'`;
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
