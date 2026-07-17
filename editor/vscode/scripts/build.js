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

const pdfSourceRoot = path.join(repoRoot, "src", "render", "html", "pdf");
const pdfRuntimeImports = {
  name: "ss-pdf-runtime-imports",
  setup(build) {
    build.onResolve({ filter: /^@ss\/pdf\/[^/]+$/ }, (args) => {
      const name = args.path.slice("@ss/pdf/".length);
      if (!/^[a-z][a-z0-9-]*$/.test(name)) {
        return { errors: [{ text: `Invalid PDF runtime module: ${args.path}` }] };
      }
      return { path: path.join(pdfSourceRoot, `${name}.js`) };
    });
  },
};

const pdfRuntimeOptions = {
  entryPoints: [path.join(pdfSourceRoot, "index.js")],
  bundle: true,
  outfile: path.join(outDir, "render", "pdf.js"),
  format: "esm",
  platform: "browser",
  target: "chrome120",
  plugins: [pdfRuntimeImports],
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
    path.join(repoRoot, "third_party", "pdfjs", "LICENSE"),
    path.join(pdfjsRoot, "LICENSE"),
  );
}

async function main() {
  fs.rmSync(outDir, { recursive: true, force: true });
  fs.mkdirSync(outDir, { recursive: true });
  copySchemaAssets();
  copyRenderAssets();

  if (watch) {
    const extensionContext = await esbuild.context(buildOptions);
    const pdfRuntimeContext = await esbuild.context(pdfRuntimeOptions);
    await Promise.all([
      extensionContext.watch(),
      pdfRuntimeContext.watch(),
    ]);
    console.log("Watching VS Code extension sources.");
    return;
  }

  typecheck();
  await esbuild.build(webviewCheckOptions);
  await esbuild.build(pdfRuntimeOptions);
  await esbuild.build(buildOptions);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
