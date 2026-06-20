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

const { fallbackSsDiagnosticMessage, parseSsDiagnostics } = require(bundled);

testRenderFailureDiagnostic();
testWarningDiagnostic();
testFallbackMessage();

function testRenderFailureDiagnostic() {
  const snapshotPath = path.join(repoRoot, ".ss-cache", "preview", "snapshot", "slide.ss");
  const originalPath = path.join(repoRoot, "tests", "fixtures", "project-basic", "slide.ss");
  const output = [
    "\r[==============>   ] 7/8 Pages       0/1      \x1b[K",
    `ERROR: ${snapshotPath}:4:1: RenderFailed: math expression: command failed (exit 1): pdflatex -interaction=nonstopmode -halt-on-error main.tex`,
    "stdout:",
    "! Undefined control sequence.",
    "l.7 \\notacommand",
    " 2 | ",
    " 3 | page bad",
    " 4 | tex!(\"\\notacommand\")",
    "   | -------------------- RenderFailed: duplicate excerpt text",
  ].join("\n");

  const diagnostics = parseSsDiagnostics(output, {
    [path.resolve(snapshotPath)]: path.resolve(originalPath),
  });
  assert.strictEqual(diagnostics.length, 1);
  assert.strictEqual(diagnostics[0].filePath, path.resolve(originalPath));
  assert.strictEqual(diagnostics[0].line, 3);
  assert.strictEqual(diagnostics[0].character, 0);
  assert.strictEqual(diagnostics[0].code, "RenderFailed");
  assert.strictEqual(diagnostics[0].severity, "error");
  assert(diagnostics[0].message.includes("Undefined control sequence"));
  assert(!diagnostics[0].message.includes("duplicate excerpt text"));
}

function testWarningDiagnostic() {
  const sourcePath = path.join(repoRoot, "slide.ss");
  const output = `WARNING: ${sourcePath}:2:3: ContentOverflow: object overflows its frame`;
  const diagnostics = parseSsDiagnostics(output, {});
  assert.strictEqual(diagnostics.length, 1);
  assert.strictEqual(diagnostics[0].filePath, sourcePath);
  assert.strictEqual(diagnostics[0].line, 1);
  assert.strictEqual(diagnostics[0].character, 2);
  assert.strictEqual(diagnostics[0].code, "ContentOverflow");
  assert.strictEqual(diagnostics[0].severity, "warning");
}

function testFallbackMessage() {
  assert.strictEqual(fallbackSsDiagnosticMessage("", 7), "render failed with exit code 7");
  assert.strictEqual(fallbackSsDiagnosticMessage("\x1b[31mfailed\x1b[0m", null), "failed");
}
