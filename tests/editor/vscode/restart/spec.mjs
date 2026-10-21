#!/usr/bin/env node
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../..");
const require = createRequire(import.meta.url);
const esbuild = require(path.join(root, "editor/vscode/node_modules/esbuild"));
const commands = new Map();
const clients = [];
const events = [];
const errors = [];
const logs = [];
let startFailure;
let releaseStart;
let pauseStart = false;
const disposable = () => ({ dispose() {} });
class LanguageClient {
  constructor() { clients.push(this); }
  async start() {
    if (startFailure) throw startFailure;
    if (pauseStart) await new Promise((resolve) => { releaseStart = resolve; });
    this.running = true;
  }
  async stop(timeout) {
    this.stopTimeout = timeout;
    this.running = false;
    if (this.stopFailure) throw this.stopFailure;
  }
  async dispose() { this.disposed = true; }
  setTrace() {}
  isRunning() { return this.running; }
}
const mock = {
  LanguageClient,
  Uri: { file: (file) => ({ toString: () => file }) },
  CancellationTokenSource: class {
    listeners = new Set();
    token = {
      isCancellationRequested: false,
      onCancellationRequested: (listener) => {
        this.listeners.add(listener);
        return { dispose: () => this.listeners.delete(listener) };
      },
    };
    cancel() {
      this.token.isCancellationRequested = true;
      for (const listener of this.listeners) listener();
    }
    dispose() { this.listeners.clear(); }
  },
  Trace: { Off: 0 },
  commands: { registerCommand(name, handler) { commands.set(name, handler); return disposable(); } },
  workspace: {
    getConfiguration: () => ({ get: (_key, fallback) => fallback }),
    createFileSystemWatcher: disposable,
    onDidChangeConfiguration: disposable,
  },
  window: {
    createOutputChannel: () => ({ appendLine: (line) => logs.push(line), dispose() {} }),
    showErrorMessage: async (message) => errors.push(message),
  },
  PageGuideDecorations: class { dispose() {} },
  EditorController: class {
    constructor(_context, _output, provider, restart) { mock.provider = provider; mock.restart = restart; }
    serverRestarting() { events.push("restarting"); }
    serverRestarted() { events.push("restarted"); }
    serverRestartFailed() { events.push("failed"); }
    dispose() {}
  },
  initializeProjectSettings: disposable,
  onDidChangeProjectSettings: disposable,
  setProjectSettingsProvider() {},
  projectSettings: async () => undefined,
};
globalThis.__ssRestartMock = mock;
const modules = {
  vscode: ["workspace", "window", "commands", "Uri", "CancellationTokenSource"],
  "vscode-languageclient/node": ["LanguageClient", "Trace"],
  "./pageGuide": ["PageGuideDecorations"],
  "./projectConfig": ["initializeProjectSettings", "onDidChangeProjectSettings", "setProjectSettingsProvider", "projectSettings"],
  "./editor/controller": ["EditorController"],
};
const compiled = await esbuild.build({
  stdin: {
    contents: `export * from './editor/vscode/src/extension';
      export { ServerProcess } from './editor/vscode/src/serverProcess';`,
    resolveDir: root, loader: "ts",
  },
  bundle: true, write: false, format: "esm", platform: "node",
  plugins: [{
    name: "restart-mocks",
    setup(build) {
      build.onResolve({ filter: /.*/ }, (args) => modules[args.path]
        ? { path: args.path, namespace: "restart-test" } : undefined);
      build.onLoad({ filter: /.*/, namespace: "restart-test" }, (args) => ({
        contents: modules[args.path].map((name) =>
          `export const ${name} = globalThis.__ssRestartMock.${name};`).join("\n"),
      }));
    },
  }],
});
const { activate, deactivate, ServerProcess } = await import(
  `data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString("base64")}`
);
await activate({ subscriptions: [] });
assert.equal(clients.length, 1);
const restart = commands.get("ss.editor.restart");
assert.equal(typeof restart, "function");
assert.equal(mock.restart, restart, "webview and command palette use different restart paths");

clients[0].stopFailure = new Error("Stopping the server timed out");
pauseStart = true;
const first = restart();
assert.equal(first, restart(), "repeated clicks started concurrent restarts");
await waitFor(() => releaseStart != null);
assert.equal(clients[0].stopTimeout, 2_000);
assert.equal(clients[0].disposed, true);
assert.equal(clients.length, 2, "a shutdown timeout prevented a new server from starting");
assert.equal(events.at(-1), "restarting");
releaseStart();
await first;
pauseStart = false;
assert.equal(mock.provider(), clients[1]);
assert.equal(events.at(-1), "restarted");
assert(logs.some((line) => /shutdown failed/.test(line)));

startFailure = new Error("executable unavailable");
await restart();
assert.equal(events.at(-1), "failed");
assert(errors.some((message) => /executable unavailable/.test(message)));
startFailure = undefined;
await restart();
assert.equal(events.at(-1), "restarted", "a failed restart prevented retrying");
await deactivate();
assert.equal(mock.provider(), undefined);
assert(clients.every((client) => client.disposed));
await testUnresponsiveProcessTermination();
await testRestartAfterProcessExit();
delete globalThis.__ssRestartMock;
console.log("WYSIWYG restart: shutdown timeout, repeated clicks, startup failure and retry passed");

async function testUnresponsiveProcessTermination() {
  if (process.platform === "win32") return;
  const scratch = path.join(root, ".ss-cache/editor-restart-test");
  await mkdir(scratch, { recursive: true });
  const directory = await mkdtemp(path.join(scratch, "stalled-"));
  const executable = path.join(directory, "server");
  const manager = new ServerProcess();
  try {
    await writeFile(executable, `#!/usr/bin/env node
const { spawn } = require('node:child_process');
const child = spawn(process.execPath, ['-e', 'process.on("SIGTERM", () => {}); setInterval(() => {}, 1000)'], { stdio: 'ignore' });
process.on('SIGTERM', () => {});
process.stdout.write(String(child.pid) + '\\n');
setInterval(() => {}, 1000);
`);
    await chmod(executable, 0o755);
    const first = await manager.start(executable);
    let childPid;
    first.process.stdout.on("data", (data) => { childPid = Number(data.toString().trim()); });
    await waitFor(() => Number.isInteger(childPid));
    await manager.stop();
    assert.equal(first.process.signalCode, "SIGKILL", "unresponsive server was not forcibly terminated");
    await waitFor(() => {
      try {
        const state = execFileSync("ps", ["-o", "stat=", "-p", String(childPid)], { encoding: "utf8", timeout: 1000 }).trim();
        return state === "" || state.startsWith("Z");
      } catch (error) {
        if (error.status === 1) return true;
        throw error;
      }
    });
    const next = await manager.start(executable);
    assert.notEqual(next.process.pid, first.process.pid);
    await manager.stop();
    await manager.stop();
    const interrupted = manager.start(executable);
    await manager.stop();
    await assert.rejects(interrupted, /startup was cancelled/);
    await assert.rejects(manager.start(path.join(directory, "missing")), /ENOENT/);
    await manager.stop();
  } finally {
    await manager.stop();
    await rm(directory, { recursive: true, force: true });
  }
}

async function waitFor(predicate) {
  const deadline = Date.now() + 2_000;
  while (!predicate()) {
    assert(Date.now() < deadline, "restart did not reach the expected state");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

async function testRestartAfterProcessExit() {
  if (process.platform === "win32") return;
  const scratch = path.join(root, ".ss-cache/editor-restart-test");
  const directory = await mkdtemp(path.join(scratch, "exited-"));
  const executable = path.join(directory, "server");
  const exits = [];
  const manager = new ServerProcess(message => exits.push(message));
  const kill = process.kill;
  try {
    await writeFile(executable, "#!/usr/bin/env node\nprocess.exit(7);\n");
    await chmod(executable, 0o755);
    const crashed = await manager.start(executable);
    await waitFor(() => crashed.process.exitCode === 7);
    process.kill = (pid, signal) => {
      assert.notEqual(pid, -crashed.process.pid, "restart signaled an exited process group");
      return kill(pid, signal);
    };
    await writeFile(executable, "#!/usr/bin/env node\nsetInterval(() => {}, 1000);\n");
    const recovered = await manager.start(executable);
    assert.notEqual(recovered.process.pid, crashed.process.pid);
    assert(exits.some(message => message.includes("code 7")), "server exit was not logged");

    // A real permission failure on a live process must still be reported, and
    // ownership retained so a later stop can retry instead of leaking it.
    process.kill = (pid, signal) => {
      if (pid === -recovered.process.pid) throw Object.assign(new Error("kill EPERM"), { code: "EPERM" });
      return kill(pid, signal);
    };
    await assert.rejects(manager.stop(), error => error.code === "EPERM");
    process.kill = kill;
    await manager.stop();
    assert.equal(recovered.process.signalCode, "SIGKILL");
    const signaled = await manager.start(executable);
    signaled.process.kill("SIGKILL");
    await waitFor(() => signaled.process.signalCode === "SIGKILL");
    process.kill = (pid, signal) => {
      assert.notEqual(pid, -signaled.process.pid, "restart signaled a terminated process group");
      return kill(pid, signal);
    };
    await manager.start(executable);
    await manager.stop();
  } finally {
    process.kill = kill;
    await manager.stop();
    await rm(directory, { recursive: true, force: true });
  }
}
