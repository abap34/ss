const assert = require("assert");
const fs = require("fs");
const path = require("path");
const esbuild = require("esbuild");

const root = path.resolve(__dirname, "..");
const repoRoot = path.resolve(root, "..", "..");
const outDir = path.join(repoRoot, ".ss-cache", "editor-vscode-tests");
const bundled = path.join(outDir, "renderDiagnostics.cjs");

fs.mkdirSync(outDir, { recursive: true });
esbuild.buildSync({
  entryPoints: [path.join(root, "src", "renderDiagnostics.ts")],
  bundle: true,
  outfile: bundled,
  platform: "node",
  format: "cjs",
  target: "node18",
});

const { parseSsDiagnosticsJson } = require(bundled);

testStructuredRenderDiagnostic();
testStructuredWarningDiagnostic();
testUnlocatedDiagnosticIsSkipped();

function testStructuredRenderDiagnostic() {
  const snapshotPath = path.join(repoRoot, ".ss-cache", "preview", "snapshot", "slide.ss");
  const originalPath = path.join(repoRoot, "tests", "fixtures", "project-basic", "slide.ss");
  const payload = JSON.stringify({
    schema: 1,
    kind: "ss-diagnostics",
    diagnostics: [{
      phase: "render",
      severity: "error",
      code: "RenderFailed",
      message: "RenderFailed: math expression failed",
      path: snapshotPath,
      origin: `path:${snapshotPath}:bytes:10-20`,
      range: {
        start: { line: 10, character: 1 },
        end: { line: 10, character: 10 },
      },
    }],
  });

  const diagnostics = parseSsDiagnosticsJson(payload, {
    [path.resolve(snapshotPath)]: path.resolve(originalPath),
  });
  assert.strictEqual(diagnostics.length, 1);
  assert.strictEqual(diagnostics[0].filePath, path.resolve(originalPath));
  assert.strictEqual(diagnostics[0].line, 10);
  assert.strictEqual(diagnostics[0].character, 1);
  assert.strictEqual(diagnostics[0].endLine, 10);
  assert.strictEqual(diagnostics[0].endCharacter, 10);
  assert.strictEqual(diagnostics[0].code, "RenderFailed");
  assert.strictEqual(diagnostics[0].severity, "error");
  assert(diagnostics[0].message.includes("math expression failed"));
}

function testStructuredWarningDiagnostic() {
  const sourcePath = path.join(repoRoot, "slide.ss");
  const payload = JSON.stringify({
    schema: 1,
    kind: "ss-diagnostics",
    diagnostics: [{
      phase: "render",
      severity: "warning",
      code: "ContentOverflow",
      message: "object overflows its frame",
      path: sourcePath,
      range: {
        start: { line: 1, character: 2 },
        end: { line: 1, character: 3 },
      },
    }],
  });
  const diagnostics = parseSsDiagnosticsJson(payload, {});
  assert.strictEqual(diagnostics.length, 1);
  assert.strictEqual(diagnostics[0].filePath, sourcePath);
  assert.strictEqual(diagnostics[0].line, 1);
  assert.strictEqual(diagnostics[0].character, 2);
  assert.strictEqual(diagnostics[0].code, "ContentOverflow");
  assert.strictEqual(diagnostics[0].severity, "warning");
}

function testUnlocatedDiagnosticIsSkipped() {
  const payload = JSON.stringify({
    schema: 1,
    kind: "ss-diagnostics",
    diagnostics: [{
      phase: "render",
      severity: "error",
      code: "RenderFailed",
      message: "render backend failed",
      path: path.join(repoRoot, "slide.ss"),
      range: null,
    }],
  });
  assert.strictEqual(parseSsDiagnosticsJson(payload, {}).length, 0);
}
