import { spawn } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const ssBin = process.env.SS_BIN ?? path.join(root, "zig-out", "bin", "ss");
const fixture = path.join(root, "tests", "fixtures", "project-basic", "slide.ss");
const uri = pathToFileURL(fixture).toString();
const source = await readFile(fixture, "utf8");
const partsFixture = path.join(root, "tests", "fixtures", "project-basic", "parts.ss");

const child = spawn(ssBin, ["lsp"], { cwd: root, stdio: ["pipe", "pipe", "pipe"] });
let nextId = 1;
let buffer = Buffer.alloc(0);
const pending = new Map();
const notificationWaiters = [];
let stderr = "";

child.stderr.setEncoding("utf8");
child.stderr.on("data", (chunk) => {
  stderr += chunk;
});

child.stdout.on("data", (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  while (true) {
    const headerEnd = buffer.indexOf("\r\n\r\n");
    if (headerEnd < 0) return;
    const header = buffer.subarray(0, headerEnd).toString("utf8");
    const match = /^Content-Length:\s*(\d+)/im.exec(header);
    if (!match) throw new Error(`missing Content-Length in ${header}`);
    const length = Number(match[1]);
    const bodyStart = headerEnd + 4;
    const bodyEnd = bodyStart + length;
    if (buffer.length < bodyEnd) return;
    const message = JSON.parse(buffer.subarray(bodyStart, bodyEnd).toString("utf8"));
    buffer = buffer.subarray(bodyEnd);
    handleMessage(message);
  }
});

function handleMessage(message) {
  if (Object.prototype.hasOwnProperty.call(message, "id")) {
    const waiter = pending.get(message.id);
    if (waiter) {
      pending.delete(message.id);
      waiter.resolve(message);
    }
  }
  for (let i = notificationWaiters.length - 1; i >= 0; i -= 1) {
    const waiter = notificationWaiters[i];
    if (waiter.predicate(message)) {
      notificationWaiters.splice(i, 1);
      waiter.resolve(message);
    }
  }
}

function send(message) {
  const body = Buffer.from(JSON.stringify(message), "utf8");
  child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
  child.stdin.write(body);
}

function request(method, params) {
  const id = nextId++;
  send({ jsonrpc: "2.0", id, method, params });
  return waitForResponse(id);
}

function notify(method, params) {
  send({ jsonrpc: "2.0", method, params });
}

function waitForResponse(id) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`timed out waiting for response ${id}`));
    }, 10000);
    pending.set(id, {
      resolve: (message) => {
        clearTimeout(timeout);
        if (message.error) reject(new Error(`${message.error.code}: ${message.error.message}`));
        else resolve(message.result);
      },
    });
  });
}

function waitForNotification(predicate) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      const index = notificationWaiters.findIndex((waiter) => waiter.resolve === wrappedResolve);
      if (index >= 0) notificationWaiters.splice(index, 1);
      reject(new Error("timed out waiting for notification"));
    }, 10000);
    const wrappedResolve = (message) => {
      clearTimeout(timeout);
      resolve(message);
    };
    notificationWaiters.push({ predicate, resolve: wrappedResolve });
  });
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const initialize = await request("initialize", {
  processId: process.pid,
  rootUri: pathToFileURL(root).toString(),
  capabilities: {},
});
assert(initialize.capabilities?.completionProvider, "initialize did not advertise completion");
assert(initialize.capabilities?.semanticTokensProvider, "initialize did not advertise semantic tokens");
assert(initialize.capabilities?.colorProvider, "initialize did not advertise document colors");
assert(initialize.capabilities?.textDocumentSync === 2, "initialize did not advertise incremental sync");

notify("initialized", {});
const diagnosticsPromise = waitForNotification(
  (message) => message.method === "textDocument/publishDiagnostics" && message.params?.uri === uri,
);
notify("textDocument/didOpen", {
  textDocument: {
    uri,
    languageId: "ss-slide",
    version: 1,
    text: source,
  },
});
const diagnostics = await diagnosticsPromise;
assert(Array.isArray(diagnostics.params.diagnostics), "diagnostics notification missing diagnostics array");
assert(diagnostics.params.diagnostics.length === 0, `expected no diagnostics, got ${JSON.stringify(diagnostics.params.diagnostics)}`);

const completion = await request("textDocument/completion", {
  textDocument: { uri },
  position: { line: 7, character: 12 },
});
assert(completion.items?.some((item) => item.label === "page"), "completion did not include language keywords");

const hover = await request("textDocument/hover", {
  textDocument: { uri },
  position: { line: 7, character: 16 },
});
assert(hover === null || hover.contents, "hover response was malformed");

const definition = await request("textDocument/definition", {
  textDocument: { uri },
  position: { line: 7, character: 18 },
});
assert(definition === null || definition.uri === uri || typeof definition.uri === "string", "definition response was malformed");

const inlay = await request("textDocument/inlayHint", {
  textDocument: { uri },
  range: { start: { line: 0, character: 0 }, end: { line: 14, character: 0 } },
});
assert(Array.isArray(inlay), "inlay hint response was not an array");

const symbols = await request("textDocument/documentSymbol", {
  textDocument: { uri },
});
assert(Array.isArray(symbols) && symbols.some((symbol) => symbol.name === "title"), "document symbols did not include the page");

const folding = await request("textDocument/foldingRange", {
  textDocument: { uri },
});
assert(Array.isArray(folding) && folding.length > 0, "folding ranges were empty");

const semanticTokens = await request("textDocument/semanticTokens/full", {
  textDocument: { uri },
});
assert(Array.isArray(semanticTokens.data) && semanticTokens.data.length > 0, "semantic tokens were empty");

const colors = await request("textDocument/documentColor", {
  textDocument: { uri },
});
assert(Array.isArray(colors) && colors.length > 0, "document colors were empty");

const presentations = await request("textDocument/colorPresentation", {
  textDocument: { uri },
  color: colors[0].color,
  range: colors[0].range,
});
assert(Array.isArray(presentations) && presentations[0]?.label?.startsWith("c\"#"), "color presentation was malformed");

const projectInfo = await request("ss/projectInfo", {
  textDocument: { uri },
});
assert(projectInfo.entryPath === fixture, "projectInfo entryPath did not resolve from ss.toml");
assert(projectInfo.assetBaseDir === path.dirname(fixture), "projectInfo assetBaseDir did not resolve from ss.toml");
assert(projectInfo.localModules?.includes(partsFixture), "projectInfo did not report imported local modules");

const otherDir = path.join(root, ".ss-cache", "lsp-other-project");
const otherSlide = path.join(otherDir, "slide.ss");
const otherUri = pathToFileURL(otherSlide).toString();
await mkdir(otherDir, { recursive: true });
await writeFile(path.join(otherDir, "ss.toml"), '[project]\nentry = "slide.ss"\nasset_base_dir = "."\n', "utf8");
const otherSource = 'import std:themes/default\n\npage other\nend\n';
await writeFile(otherSlide, otherSource, "utf8");
const otherDiagnosticsPromise = waitForNotification(
  (message) => message.method === "textDocument/publishDiagnostics" && message.params?.uri === otherUri,
);
notify("textDocument/didOpen", {
  textDocument: {
    uri: otherUri,
    languageId: "ss-slide",
    version: 1,
    text: otherSource,
  },
});
const otherDiagnostics = await otherDiagnosticsPromise;
assert(otherDiagnostics.params.diagnostics.length === 0, "second project opened with diagnostics");
const firstProjectInfoAfterSecondOpen = await request("ss/projectInfo", {
  textDocument: { uri },
});
assert(firstProjectInfoAfterSecondOpen.entryPath === fixture, "projectInfo used the latest global snapshot instead of the requested document");

const rangedBrokenDiagnosticsPromise = waitForNotification(
  (message) => message.method === "textDocument/publishDiagnostics" && message.params?.uri === uri,
);
notify("textDocument/didChange", {
  textDocument: { uri, version: 2 },
  contentChanges: [{
    range: { start: { line: 3, character: 0 }, end: { line: 3, character: 4 } },
    text: "pag",
  }],
});
const rangedBrokenDiagnostics = await rangedBrokenDiagnosticsPromise;
assert(rangedBrokenDiagnostics.params.diagnostics.length > 0, "ranged didChange did not publish diagnostics for broken source");

const rangedFixedDiagnosticsPromise = waitForNotification(
  (message) => message.method === "textDocument/publishDiagnostics" && message.params?.uri === uri,
);
notify("textDocument/didChange", {
  textDocument: { uri, version: 3 },
  contentChanges: [{
    range: { start: { line: 3, character: 0 }, end: { line: 3, character: 3 } },
    text: "page",
  }],
});
const rangedFixedDiagnostics = await rangedFixedDiagnosticsPromise;
assert(rangedFixedDiagnostics.params.diagnostics.length === 0, "ranged didChange did not clear diagnostics after restoring source");

const brokenDiagnosticsPromise = waitForNotification(
  (message) => message.method === "textDocument/publishDiagnostics" && message.params?.uri === uri,
);
notify("textDocument/didChange", {
  textDocument: { uri, version: 4 },
  contentChanges: [{ text: "page broken\nlet x =\nend\n" }],
});
const brokenDiagnostics = await brokenDiagnosticsPromise;
assert(brokenDiagnostics.params.diagnostics.length > 0, "didChange did not publish diagnostics for broken source");

const fixedDiagnosticsPromise = waitForNotification(
  (message) => message.method === "textDocument/publishDiagnostics" && message.params?.uri === uri,
);
notify("textDocument/didChange", {
  textDocument: { uri, version: 5 },
  contentChanges: [{ text: source }],
});
const fixedDiagnostics = await fixedDiagnosticsPromise;
assert(fixedDiagnostics.params.diagnostics.length === 0, "didChange did not clear diagnostics after restoring source");

await request("shutdown", null);
notify("exit", {});

await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("language server did not exit")), 5000);
  child.on("exit", (code) => {
    clearTimeout(timeout);
    if (code === 0) resolve();
    else reject(new Error(`language server exited with ${code}; stderr:\n${stderr}`));
  });
});
