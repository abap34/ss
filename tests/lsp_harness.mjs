#!/usr/bin/env node
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const root = path.resolve(fileURLToPath(new URL("..", import.meta.url)));
const requestedSsBin = process.argv[2] ?? process.env.SS_BIN ?? path.join(root, "zig-out", "bin", "ss");
export const ssBin = resolveCommandPath(requestedSsBin);

export class LspClient {
  constructor({ cwd = root } = {}) {
    this.cwd = cwd;
    this.child = spawn(ssBin, ["lsp"], { cwd, stdio: ["pipe", "pipe", "pipe"] });
    this.nextId = 1;
    this.buffer = Buffer.alloc(0);
    this.pending = new Map();
    this.notificationWaiters = [];
    this.exitWaiters = [];
    this.stderr = "";
    this.exitStatus = null;
    this.closing = null;

    this.child.stderr.setEncoding("utf8");
    this.child.stderr.on("data", (chunk) => {
      this.stderr += chunk;
    });

    this.child.stdout.on("data", (chunk) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      this.readMessages();
    });

    this.child.on("exit", (code, signal) => {
      this.exitStatus = { code, signal };
      const error = new Error(`language server exited with ${code ?? signal}; stderr:\n${this.stderr}`);
      this.rejectOutstanding(error);
      for (const waiter of this.exitWaiters.splice(0)) {
        waiter.resolve(this.exitStatus);
      }
    });

    this.child.on("error", (error) => {
      this.exitStatus = { code: null, signal: "spawn-error" };
      this.rejectOutstanding(error);
      for (const waiter of this.exitWaiters.splice(0)) {
        waiter.resolve(this.exitStatus);
      }
    });
  }

  readMessages() {
    while (true) {
      const headerEnd = this.buffer.indexOf("\r\n\r\n");
      if (headerEnd < 0) return;
      const header = this.buffer.subarray(0, headerEnd).toString("utf8");
      const match = /^Content-Length:\s*(\d+)/im.exec(header);
      if (!match) throw new Error(`missing Content-Length in ${header}`);
      const length = Number(match[1]);
      const bodyStart = headerEnd + 4;
      const bodyEnd = bodyStart + length;
      if (this.buffer.length < bodyEnd) return;
      const message = JSON.parse(this.buffer.subarray(bodyStart, bodyEnd).toString("utf8"));
      this.buffer = this.buffer.subarray(bodyEnd);
      this.handleMessage(message);
    }
  }

  handleMessage(message) {
    if (Object.prototype.hasOwnProperty.call(message, "id")) {
      const waiter = this.pending.get(message.id);
      if (waiter) {
        this.pending.delete(message.id);
        clearTimeout(waiter.timeout);
        if (message.error) waiter.reject(new Error(`${message.error.code}: ${message.error.message}`));
        else waiter.resolve(message.result);
      }
    }
    for (let i = this.notificationWaiters.length - 1; i >= 0; i -= 1) {
      const waiter = this.notificationWaiters[i];
      if (waiter.predicate(message)) {
        this.notificationWaiters.splice(i, 1);
        clearTimeout(waiter.timeout);
        waiter.resolve(message);
      }
    }
  }

  send(message) {
    const body = Buffer.from(JSON.stringify(message), "utf8");
    this.child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
    this.child.stdin.write(body);
  }

  rejectOutstanding(error) {
    for (const waiter of this.pending.values()) {
      clearTimeout(waiter.timeout);
      waiter.reject(error);
    }
    this.pending.clear();
    for (const waiter of this.notificationWaiters.splice(0)) {
      clearTimeout(waiter.timeout);
      waiter.reject(error);
    }
  }

  request(method, params) {
    const id = this.nextId++;
    this.send({ jsonrpc: "2.0", id, method, params });
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`timed out waiting for response ${id} (${method}); stderr:\n${this.stderr}`));
      }, 10000);
      this.pending.set(id, { resolve, reject, timeout });
    });
  }

  notify(method, params) {
    this.send({ jsonrpc: "2.0", method, params });
  }

  waitForNotification(predicate, label = "notification") {
    return new Promise((resolve, reject) => {
      const waiter = {
        predicate,
        resolve,
        reject,
        timeout: null,
      };
      waiter.timeout = setTimeout(() => {
        const index = this.notificationWaiters.indexOf(waiter);
        if (index >= 0) this.notificationWaiters.splice(index, 1);
        reject(new Error(`timed out waiting for ${label}; stderr:\n${this.stderr}`));
      }, 10000);
      this.notificationWaiters.push(waiter);
    });
  }

  async initialize({ rootUri = pathToFileURL(this.cwd).toString(), capabilities = {} } = {}) {
    const result = await this.request("initialize", {
      processId: process.pid,
      rootUri,
      capabilities,
    });
    this.notify("initialized", {});
    return result;
  }

  waitForDiagnostics(uri, predicate = () => true, label = `diagnostics for ${uri}`) {
    return this.waitForNotification(
      (message) =>
        message.method === "textDocument/publishDiagnostics" &&
        message.params?.uri === uri &&
        predicate(message.params.diagnostics, message),
      label,
    );
  }

  openDocument({ uri, text, languageId = "ss-slide", version = 1 }) {
    this.notify("textDocument/didOpen", {
      textDocument: { uri, languageId, version, text },
    });
  }

  changeDocument({ uri, version, text }) {
    this.notify("textDocument/didChange", {
      textDocument: { uri, version },
      contentChanges: [{ text }],
    });
  }

  changeDocumentRange({ uri, version, range, text }) {
    this.notify("textDocument/didChange", {
      textDocument: { uri, version },
      contentChanges: [{ range, text }],
    });
  }

  async close() {
    if (this.closing) return this.closing;
    this.closing = (async () => {
      if (!this.exitStatus) {
        try {
          await this.request("shutdown", null);
          this.notify("exit", {});
        } catch (error) {
          this.child.kill();
          throw error;
        }
      }
      await this.waitForExit();
    })();
    return this.closing;
  }

  waitForExit() {
    if (this.exitStatus) {
      if (this.exitStatus.code === 0) return Promise.resolve();
      return Promise.reject(new Error(`language server exited with ${this.exitStatus.code ?? this.exitStatus.signal}; stderr:\n${this.stderr}`));
    }
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        reject(new Error(`language server did not exit; stderr:\n${this.stderr}`));
      }, 5000);
      this.exitWaiters.push({
        resolve: (status) => {
          clearTimeout(timeout);
          if (status.code === 0) resolve();
          else reject(new Error(`language server exited with ${status.code ?? status.signal}; stderr:\n${this.stderr}`));
        },
      });
    });
  }
}

export async function withLspClient(options, body) {
  const client = new LspClient(options);
  try {
    const result = await body(client);
    await client.close();
    return result;
  } catch (error) {
    try {
      await client.close();
    } catch {
      client.child.kill();
    }
    throw error;
  }
}

export function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function resolveCommandPath(command) {
  if (command.includes("/") && !path.isAbsolute(command)) return path.resolve(root, command);
  return command;
}

export function assertUniqueCompletionLabels(completion, label) {
  const seen = new Set();
  for (const item of completion.items ?? []) {
    assert(!seen.has(item.label), `${label} contained duplicate completion label ${item.label}`);
    seen.add(item.label);
  }
}

export function assertCompletionHas(completion, label, context) {
  assert(
    completion.items?.some((item) => item.label === label),
    `${context} did not include ${label}: ${JSON.stringify(completion)}`,
  );
}

export function assertCompletionMissing(completion, labels, context) {
  for (const label of labels) {
    assert(
      !completion.items?.some((item) => item.label === label),
      `${context} unexpectedly included ${label}: ${JSON.stringify(completion)}`,
    );
  }
}

export function positionAfter(source, needle, occurrence = 0) {
  return positionAtOffset(source, nthIndexOf(source, needle, occurrence) + needle.length);
}

export function positionAt(source, needle, characterOffset = 0, occurrence = 0) {
  return positionAtOffset(source, nthIndexOf(source, needle, occurrence) + characterOffset);
}

export function positionAtOffset(source, offset) {
  let line = 0;
  let lineStart = 0;
  for (let i = 0; i < offset; i += 1) {
    if (source.charCodeAt(i) === 10) {
      line += 1;
      lineStart = i + 1;
    }
  }
  return { line, character: offset - lineStart };
}

export function nthIndexOf(source, needle, occurrence = 0) {
  let from = 0;
  for (let i = 0; i <= occurrence; i += 1) {
    const index = source.indexOf(needle, from);
    assert(index >= 0, `source did not contain ${needle}`);
    if (i === occurrence) return index;
    from = index + needle.length;
  }
  throw new Error(`source did not contain occurrence ${occurrence} of ${needle}`);
}

export function functionDefinitionLocation(uri, text, name) {
  const needles = [`fn/! ${name}`, `fn ${name}`, `const ${name}`];
  const lines = text.split("\n");
  for (const needle of needles) {
    const line = lines.findIndex((lineText) => lineText.includes(needle));
    if (line < 0) continue;
    const character = lines[line].indexOf(name);
    assert(character >= 0, `fixture did not contain ${name} on ${needle} line`);
    return { uri, line, character };
  }
  throw new Error(`fixture did not contain a definition for ${name}`);
}

export function isDefinitionLocation(location, expected) {
  const start = location.range?.start;
  return location.uri === expected.uri && start?.line === expected.line && start?.character === expected.character;
}
