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

const webviewOptions = {
  entryPoints: [path.join(root, "media", "editor", "main.js")],
  bundle: true,
  outfile: path.join(outDir, "editor", "main.js"),
  format: "esm",
  platform: "browser",
  target: "chrome120",
  external: ["../../out/pdfjs/pdf.mjs"],
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

// Compile the webview and its PDF controller together so their DOM contracts
// cannot come from different builds, including when an old out/ tree exists.
webviewOptions.plugins = [pdfRuntimeImports, {
  name: "ss-webview-pdf-runtime",
  setup(build) {
    build.onResolve({ filter: /^\.\.\/\.\.\/out\/render\/pdf\.js$/ }, () => ({
      path: path.join(pdfSourceRoot, "index.js"),
    }));
  },
}];

const presentationOptions = {
  entryPoints: [path.join(repoRoot, "src/render/html/presentation.js")],
  bundle: true,
  outfile: path.join(outDir, "render", "presentation.js"),
  format: "esm",
  platform: "browser",
  target: "chrome120",
  plugins: [{ name: "ss-dom", setup(build) {
    build.onResolve({ filter: /^@ss\/dom$/ }, () => ({ path: path.join(repoRoot, "src/render/html/dom.js") }));
    build.onResolve({ filter: /^@ss\/speaker$/ }, () => ({ path: path.join(repoRoot, "src/render/html/speaker.js") }));
  } }],
};

function typecheck() {
  for (const config of ["tsconfig.json", "tsconfig.webview.json"]) {
    childProcess.execFileSync(process.execPath, [
      require.resolve("typescript/bin/tsc"),
      "-p",
      path.join(root, config),
      "--noEmit",
    ], { stdio: "inherit" });
  }
}

function copySchemaAssets() {
  const targetRoot = path.join(outDir, "schemas");
  fs.rmSync(targetRoot, { recursive: true, force: true });
  fs.mkdirSync(targetRoot, { recursive: true });
  fs.copyFileSync(
    path.join(repoRoot, "src", "project", "ss-toml.schema.json"),
    path.join(targetRoot, "ss-toml.schema.json"),
  );
}

function copyRenderAssets() {
  const pdfjsRoot = path.join(outDir, "pdfjs");
  const renderRoot = path.join(outDir, "render");
  fs.mkdirSync(pdfjsRoot, { recursive: true });
  fs.mkdirSync(renderRoot, { recursive: true });
  fs.writeFileSync(path.join(renderRoot, "package.json"), '{"type":"module"}\n');
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
  for (const name of ["text.js", "dom.js", "presentation.css"]) {
    fs.copyFileSync(path.join(repoRoot, "src/render/html", name), path.join(renderRoot, name));
  }
}

async function main() {
  fs.rmSync(outDir, { recursive: true, force: true });
  fs.mkdirSync(outDir, { recursive: true });
  copySchemaAssets();
  copyRenderAssets();
  await esbuild.build(presentationOptions);

  if (watch) {
    const extensionContext = await esbuild.context(buildOptions);
    const presentationContext = await esbuild.context(presentationOptions);
    const pdfRuntimeContext = await esbuild.context(pdfRuntimeOptions);
    const webviewContext = await esbuild.context(webviewOptions);
    await Promise.all([
      extensionContext.watch(),
      presentationContext.watch(),
      pdfRuntimeContext.watch(),
      webviewContext.watch(),
    ]);
    console.log("Watching VS Code extension sources.");
    return;
  }

  typecheck();
  await esbuild.build(webviewOptions);
  await esbuild.build(pdfRuntimeOptions);
  await esbuild.build(buildOptions);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
