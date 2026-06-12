const fs = require("fs");
const path = require("path");
const childProcess = require("child_process");
const esbuild = require("esbuild");

const root = path.resolve(__dirname, "..");
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

function typecheck() {
  childProcess.execFileSync(process.execPath, [
    require.resolve("typescript/bin/tsc"),
    "-p",
    root,
    "--noEmit",
  ], { stdio: "inherit" });
}

function copyPdfJsAssets() {
  const pdfjsRoot = path.join(root, "node_modules", "pdfjs-dist");
  const targetRoot = path.join(outDir, "pdfjs");
  fs.rmSync(targetRoot, { recursive: true, force: true });
  fs.mkdirSync(path.join(targetRoot, "build"), { recursive: true });
  fs.copyFileSync(
    path.join(pdfjsRoot, "build", "pdf.min.mjs"),
    path.join(targetRoot, "build", "pdf.min.mjs"),
  );
  fs.copyFileSync(
    path.join(pdfjsRoot, "build", "pdf.worker.min.mjs"),
    path.join(targetRoot, "build", "pdf.worker.min.mjs"),
  );
  fs.cpSync(path.join(pdfjsRoot, "cmaps"), path.join(targetRoot, "cmaps"), { recursive: true });
  fs.cpSync(path.join(pdfjsRoot, "standard_fonts"), path.join(targetRoot, "standard_fonts"), { recursive: true });
}

async function main() {
  fs.rmSync(outDir, { recursive: true, force: true });
  fs.mkdirSync(outDir, { recursive: true });
  copyPdfJsAssets();

  if (watch) {
    const context = await esbuild.context(buildOptions);
    await context.watch();
    console.log("Watching VS Code extension sources.");
    return;
  }

  typecheck();
  await esbuild.build(buildOptions);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
