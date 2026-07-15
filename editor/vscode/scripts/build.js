const fs = require("fs");
const path = require("path");
const childProcess = require("child_process");
const esbuild = require("esbuild");

const root = path.resolve(__dirname, "..");
const repoRoot = path.resolve(root, "..", "..");
const outDir = path.join(root, "out");
const watch = process.argv.includes("--watch");

const buildOptions = {
  entryPoints: [path.join(root, "src", "extension.ts")],
  bundle: true,
  outfile: path.join(outDir, "extension.js"),
  external: ["vscode"],
  format: "cjs",
  platform: "node",
  target: "node18",
  sourcemap: true,
  sourcesContent: false,
};

const webviewCheckOptions = {
  entryPoints: [path.join(root, "media", "editor", "main.js")],
  bundle: true,
  write: false,
  format: "esm",
  platform: "browser",
  target: "chrome120",
  external: ["../../out/render/pdf.js", "../../out/pdfjs/pdf.mjs"],
};

function typecheck() {
  childProcess.execFileSync(process.execPath, [
    require.resolve("typescript/bin/tsc"),
    "-p",
    root,
    "--noEmit",
  ], { stdio: "inherit" });
}

function copySchemaAssets() {
  const targetRoot = path.join(outDir, "schemas");
  fs.rmSync(targetRoot, { recursive: true, force: true });
  fs.mkdirSync(targetRoot, { recursive: true });
  fs.copyFileSync(
    path.join(repoRoot, "schemas", "ss-toml.schema.json"),
    path.join(targetRoot, "ss-toml.schema.json"),
  );
}

function copyRenderAssets() {
  const pdfjsRoot = path.join(outDir, "pdfjs");
  const renderRoot = path.join(outDir, "render");
  fs.mkdirSync(pdfjsRoot, { recursive: true });
  fs.mkdirSync(renderRoot, { recursive: true });
  fs.copyFileSync(
    path.join(repoRoot, "third_party", "pdfjs", "pdf.mjs"),
    path.join(pdfjsRoot, "pdf.mjs"),
  );
  fs.copyFileSync(
    path.join(repoRoot, "third_party", "pdfjs", "pdf.worker.mjs"),
    path.join(pdfjsRoot, "pdf.worker.mjs"),
  );
  fs.copyFileSync(
    path.join(repoRoot, "src", "render", "html", "pdf.js"),
    path.join(renderRoot, "pdf.js"),
  );
}

async function main() {
  fs.rmSync(outDir, { recursive: true, force: true });
  fs.mkdirSync(outDir, { recursive: true });
  copySchemaAssets();
  copyRenderAssets();

  if (watch) {
    const context = await esbuild.context(buildOptions);
    await context.watch();
    console.log("Watching VS Code extension sources.");
    return;
  }

  typecheck();
  await esbuild.build(webviewCheckOptions);
  await esbuild.build(buildOptions);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
