const assert = require("assert");
const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const typescript = require("typescript");

const root = path.resolve(__dirname, "..");
const sourcePath = path.join(root, "src", "pdfPreviewServer.ts");
const source = fs.readFileSync(sourcePath, "utf8");
const output = typescript.transpileModule(source, {
  compilerOptions: {
    module: typescript.ModuleKind.CommonJS,
    target: typescript.ScriptTarget.ES2020,
    esModuleInterop: true,
  },
  fileName: sourcePath,
}).outputText;

const moduleObject = { exports: {} };
new Function("exports", "require", "module", "__filename", "__dirname", output)(
  moduleObject.exports,
  require,
  moduleObject,
  sourcePath,
  path.dirname(sourcePath),
);

const { PdfPreviewServer } = moduleObject.exports;

async function main() {
  assert(fs.existsSync(path.join(root, "out", "pdfjs", "build", "pdf.min.mjs")), "PDF.js assets must be copied by the build step");

  const tempDir = await fs.promises.mkdtemp(path.join(os.tmpdir(), "ss-preview-server-"));
  const firstPdf = path.join(tempDir, "first.pdf");
  const secondPdf = path.join(tempDir, "second.pdf");
  await fs.promises.writeFile(firstPdf, Buffer.from("%PDF-1.7\nfirst\n%%EOF\n"));
  await fs.promises.writeFile(secondPdf, Buffer.from("%PDF-1.7\nsecond\n%%EOF\n"));

  const logs = [];
  const server = new PdfPreviewServer(root, { appendLine: (line) => logs.push(line) });
  try {
    const id = await server.register(firstPdf, 1);
    const viewer = await request(server.viewerUrl(id));
    assert.strictEqual(viewer.statusCode, 200);
    assert.match(viewer.text, /data-initial-pdf-uri="http:\/\/127\.0\.0\.1:\d+\/[a-f0-9]+\/pdf\//);
    assert.match(viewer.text, /data-pdfjs-uri="http:\/\/127\.0\.0\.1:\d+\/[a-f0-9]+\/pdfjs\/build\/pdf\.min\.mjs"/);

    const pdf = await request(`${server.origin}/${tokenFromUrl(server.viewerUrl(id))}/pdf/${id}?v=1`);
    assert.strictEqual(pdf.statusCode, 200);
    assert.strictEqual(pdf.headers["content-type"], "application/pdf");
    assert.strictEqual(pdf.body.toString("utf8"), "%PDF-1.7\nfirst\n%%EOF\n");

    const script = await request(`${server.origin}/${tokenFromUrl(server.viewerUrl(id))}/media/pdfPreview.js`);
    assert.strictEqual(script.statusCode, 200);
    assert.match(script.headers["content-type"], /^text\/javascript/);

    const pdfjs = await request(`${server.origin}/${tokenFromUrl(server.viewerUrl(id))}/pdfjs/build/pdf.min.mjs`);
    assert.strictEqual(pdfjs.statusCode, 200);
    assert.match(pdfjs.headers["content-type"], /^text\/javascript/);

    server.update(id, secondPdf, 2);
    const updated = await request(`${server.origin}/${tokenFromUrl(server.viewerUrl(id))}/pdf/${id}?v=2`);
    assert.strictEqual(updated.statusCode, 200);
    assert.strictEqual(updated.body.toString("utf8"), "%PDF-1.7\nsecond\n%%EOF\n");

    server.unregister(id);
    const missing = await request(server.viewerUrl(id));
    assert.strictEqual(missing.statusCode, 404);
  } finally {
    server.dispose();
    await fs.promises.rm(tempDir, { recursive: true, force: true });
  }
}

function tokenFromUrl(value) {
  const url = new URL(value);
  return url.pathname.split("/").filter(Boolean)[0];
}

function request(url) {
  return new Promise((resolve, reject) => {
    http.get(url, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => {
        const body = Buffer.concat(chunks);
        resolve({
          statusCode: response.statusCode,
          headers: response.headers,
          body,
          text: body.toString("utf8"),
        });
      });
    }).on("error", reject);
  });
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
