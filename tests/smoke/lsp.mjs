#!/usr/bin/env node
import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));
const ssBin = process.env.SS_BIN ?? path.join(root, "zig-out", "bin", "ss");
const fixture = path.join(root, "tests", "fixtures", "project-basic", "slide.ss");
const partsFixture = path.join(root, "tests", "fixtures", "project-basic", "parts.ss");
const defaultTheme = path.join(root, "stdlib", "themes", "default.ss");
const uri = pathToFileURL(fixture).toString();
const partsUri = pathToFileURL(partsFixture).toString();
const defaultThemeUri = pathToFileURL(defaultTheme).toString();
const source = await readFile(fixture, "utf8");

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
  position: { line: 4, character: 15 },
});
assert(completion.items?.some((item) => item.label === "page"), "completion did not include language keywords");
assert(!completion.items?.some((item) => item.label === "place"), "completion still exposed removed place keyword");

const hover = await request("textDocument/hover", {
  textDocument: { uri },
  position: { line: 4, character: 16 },
});
assert(hover === null || hover.contents, "hover response was malformed");

const definition = await request("textDocument/definition", {
  textDocument: { uri },
  position: { line: 4, character: 17 },
});
assert(Array.isArray(definition), `expected definition array, got ${JSON.stringify(definition)}`);
assert(definition.some((location) => location.uri === partsUri && location.range?.start?.line === 0 && location.range?.start?.character === 3), `definition did not jump to parts.ss: ${JSON.stringify(definition)}`);

const pairedDefinition = await request("textDocument/definition", {
  textDocument: { uri },
  position: { line: 5, character: 2 },
});
assert(Array.isArray(pairedDefinition), `expected paired definition array, got ${JSON.stringify(pairedDefinition)}`);
assert(
  pairedDefinition.some((location) => location.uri === defaultThemeUri && location.range?.start?.line === 67 && location.range?.start?.character === 5),
  `definition did not jump to default theme cover: ${JSON.stringify(pairedDefinition)}`,
);

const brokenDiagnosticsPromise = waitForNotification(
  (message) => message.method === "textDocument/publishDiagnostics" && message.params?.uri === uri,
);
notify("textDocument/didChange", {
  textDocument: { uri, version: 2 },
  contentChanges: [{
    range: { start: { line: 3, character: 0 }, end: { line: 3, character: 4 } },
    text: "pag",
  }],
});
const brokenDiagnostics = await brokenDiagnosticsPromise;
assert(brokenDiagnostics.params.diagnostics.length > 0, "ranged didChange did not publish diagnostics for broken source");

const fixedDiagnosticsPromise = waitForNotification(
  (message) => message.method === "textDocument/publishDiagnostics" && message.params?.uri === uri,
);
notify("textDocument/didChange", {
  textDocument: { uri, version: 3 },
  contentChanges: [{
    range: { start: { line: 3, character: 0 }, end: { line: 3, character: 3 } },
    text: "page",
  }],
});
const fixedDiagnostics = await fixedDiagnosticsPromise;
assert(fixedDiagnostics.params.diagnostics.length === 0, "ranged didChange did not clear diagnostics after restoring source");

const warningDiagnosticsPromise = waitForNotification(
  (message) => message.method === "textDocument/publishDiagnostics" && message.params?.uri === uri,
);
notify("textDocument/didChange", {
  textDocument: { uri, version: 4 },
  contentChanges: [{
    range: { start: { line: 12, character: 0 }, end: { line: 12, character: 0 } },
    text: "new(\"loose\", \"body\", \"text\")\n",
  }],
});
const warningDiagnostics = await warningDiagnosticsPromise;
assert(
  warningDiagnostics.params.diagnostics.some((diagnostic) => diagnostic.message?.includes("UnplacedObject")),
  `expected UnplacedObject diagnostic, got ${JSON.stringify(warningDiagnostics.params.diagnostics)}`,
);

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
