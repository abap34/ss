import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chmod, copyFile, lstat, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../harness.mjs";
import { command, repository } from "./harness.mjs";

const scratch = path.join(root, ".test-tmp/packages-status");
await mkdir(scratch, { recursive: true });
const work = await mkdtemp(path.join(scratch, "status-"));
const deck = path.join(work, "deck");
const bin = path.join(work, "bin");
const gitProbe = path.join(work, "git-called");
const config = '[project]\nentry = "slide.ss"\n';
const declaration = (name, source) => `\n[dependencies.${name}]\ngit = ${JSON.stringify(source)}\n`;
await mkdir(deck);
await mkdir(bin);
await writeFile(path.join(bin, "git"), '#!/bin/sh\nprintf called > "$SS_STATUS_GIT_PROBE"\nexit 1\n');
await chmod(path.join(bin, "git"), 0o755);
const env = { ...process.env, PATH: bin, SS_STATUS_GIT_PROBE: gitProbe };
delete env.NO_COLOR;
delete env.CLICOLOR;
const python = command("sh", ["-c", "command -v python3"], work).stdout.trim();
const terminalOutput = `
import errno, os, pty, select, subprocess, sys
master, slave = pty.openpty()
try:
    result = subprocess.run(sys.argv[1:], stdout=slave, stderr=subprocess.PIPE, timeout=10)
    # macOS discards unread output when the last slave descriptor closes.
    while select.select([master], [], [], 0)[0]:
        try:
            data = os.read(master, 4096)
        except OSError as error:
            if error.errno == errno.EIO: break
            raise
        if not data: break
        sys.stdout.buffer.write(data)
    sys.stderr.buffer.write(result.stderr)
    sys.exit(result.returncode)
finally:
    os.close(slave)
    os.close(master)
`;
const stripColor = value => value.replace(/\x1b\[[0-9;]*m/g, "").replace(/\r\n/g, "\n");

// Include directory/file mtimes and contents to detect writes, including locks
// and cache directories. Reads may change atime, so it is intentionally omitted.
async function snapshot() {
  const files = ["", ...await readdir(deck, { recursive: true })].sort();
  return Promise.all(files.map(async file => {
    const target = path.join(deck, file);
    const stat = await lstat(target);
    const digest = stat.isFile() ? createHash("sha256").update(await readFile(target)).digest("hex") : null;
    return [file, stat.mode, stat.mtimeMs, digest];
  }));
}
async function status(args = [], { cwd = deck, expected = 0, tty = false, environment = {} } = {}) {
  const before = await snapshot();
  const invocation = [ssBin, "status", ...args];
  const result = tty
    ? command(python, ["-c", terminalOutput, ...invocation], cwd, expected, { ...env, ...environment })
    : command(ssBin, invocation.slice(1), cwd, expected, { ...env, ...environment });
  assert.deepEqual(await snapshot(), before, "status must not change project files or cache state");
  await assert.rejects(lstat(gitProbe), { code: "ENOENT" }, "status must not invoke Git");
  if (expected === 0) assert.equal(result.stderr, "");
  return result;
}
try {
  await writeFile(path.join(deck, "ss.toml"), config);
  assert.match((await status()).stdout, /No dependencies declared\.\nss.lock: not needed/);

  const base = await repository(work, "base", {
    "ss.toml": '[package]\nname = "base"\n', "lib.ss": "",
  });
  const wrapper = await repository(work, "wrapper", {
    "ss.toml": '[package]\nname = "wrapper"\n' + declaration("base", base), "lib.ss": "",
  });
  const declared = config + declaration("wrapper", wrapper);
  await writeFile(path.join(deck, "ss.toml"), declared);
  let result = await status();
  assert.match(result.stdout, /wrapper \(/);
  assert.match(result.stdout, /ss.lock: missing; run 'ss fetch'/);
  assert.match((await status(["--color", "always"])).stdout, /\x1b\[33mmissing; run 'ss fetch'\x1b\[0m/);
  command(ssBin, ["fetch"], deck);
  const bytes = await readFile(path.join(deck, "ss.lock"), "utf8");
  const lock = JSON.parse(bytes);
  result = await status();
  assert.match(result.stdout, /ss.lock: up to date/);
  assert.match(result.stdout, /wrapper@[0-9a-f]{12}  direct  fetched/);
  assert.match(result.stdout, /base@[0-9a-f]{12}  transitive  fetched/);
  for (const p of lock.packages) assert(result.stdout.includes(p.commit.slice(0, 12)));

  const plain = result.stdout;
  assert(!plain.includes("\x1b["), "redirected output must not contain color by default");
  for (const [args, options] of [
    [["--color", "always"], {}],
    [[], { tty: true }],
    [["--color", "always"], { environment: { NO_COLOR: "1", CLICOLOR: "0" } }],
  ]) {
    const colored = (await status(args, options)).stdout;
    assert.match(colored, /\x1b\[32mup to date\x1b\[0m/);
    assert.match(colored, /\x1b\[32mfetched\x1b\[0m/);
    assert.match(colored, /\x1b\[36mwrapper\x1b\[0m/);
    assert.equal(stripColor(colored), plain, "color must not change status information");
  }
  for (const [args, options] of [
    [["--color", "never"], { tty: true }],
    [[], { tty: true, environment: { NO_COLOR: "1" } }],
    [[], { tty: true, environment: { CLICOLOR: "0" } }],
  ]) {
    const uncolored = (await status(args, options)).stdout;
    assert(!uncolored.includes("\x1b["));
    assert.equal(stripColor(uncolored), plain);
  }

  const nested = path.join(deck, "nested");
  await mkdir(nested);
  assert.equal((await status([], { cwd: nested })).stdout, result.stdout);
  assert.equal((await status(["--project", deck], { cwd: work })).stdout, result.stdout);
  const custom = path.join(deck, "custom.toml");
  await copyFile(path.join(deck, "ss.toml"), custom);
  assert.equal((await status(["--project", custom], { cwd: work })).stdout, result.stdout);

  const packageSource = p => path.join(deck, ".ss-cache", "packages", "sources", p.id);
  const basePackage = lock.packages.find(p => p.name === "base");
  await rm(packageSource(basePackage), { recursive: true, force: true });
  result = await status();
  assert.match(result.stdout, /base@[0-9a-f]{12}  transitive  not fetched/);
  assert.match(result.stdout, /ss fetch --locked/);
  assert.match((await status(["--color", "always"])).stdout, /\x1b\[33mnot fetched\x1b\[0m/);
  const wrapperPackage = lock.packages.find(p => p.name === "wrapper");
  await writeFile(path.join(packageSource(wrapperPackage), ".git", "ss-commit"), "0".repeat(40));
  assert.match((await status()).stdout, /wrapper@[0-9a-f]{12}  direct  not fetched/);

  for (const changed of [config, declared + declaration("base", base), declared + 'branch = "main"\n']) {
    await writeFile(path.join(deck, "ss.toml"), changed);
    result = await status();
    assert.match(result.stdout, /ss.lock: out of date; run 'ss fetch'/);
    assert.match((await status(["--color", "always"])).stdout, /\x1b\[33mout of date; run 'ss fetch'\x1b\[0m/);
    assert(!result.stdout.includes("ss fetch --locked"), "stale declarations require resolution first");
  }
  assert.match(result.stdout, /branch=main/);
  await writeFile(path.join(deck, "ss.toml"), declared);
  for (const invalid of ["{ invalid json", JSON.stringify({ ...lock, version: 999 })]) {
    await writeFile(path.join(deck, "ss.lock"), invalid);
    assert.match((await status([], { expected: 1 })).stderr, /InvalidPackageLock/);
  }
  await writeFile(path.join(deck, "ss.lock"), bytes);
  for (const args of [["--locked"], ["--git", base], ["wrapper"], ["--project"], ["--unknown"]]) {
    assert.match((await status(args, { expected: 1 })).stderr, /usage:/);
  }
  for (const args of [["--color"], ["--color", "unknown"]]) {
    assert.match((await status(args, { expected: 1 })).stderr, /(?:missing value for|invalid) --color/);
  }
  assert.match((await status([], { cwd: work, expected: 1 })).stderr, /PackageProjectNotFound/);
  console.log("Package status: read-only offline inspection, direct/transitive packages, missing sources, stale and invalid locks passed");
} finally {
  await rm(work, { recursive: true, force: true });
}
