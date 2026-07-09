#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, root, ssBin } from "./harness.mjs";

await testCompletionPrintsScriptWithoutInstalling();
await testBashCompletionInstallsWithYes();
await testFishCompletionAsksBeforeWriting();
await testDeniedCompletionInstallDoesNotWrite();
await testZshCompletionAddsInitBlockOnce();

async function testCompletionPrintsScriptWithoutInstalling() {
  const home = await mkdtempHome("ss-completion-print-");
  try {
    const xdgData = path.join(home, "data");
    const result = await runCompletion(["completion", "bash", "--print"], home, { XDG_DATA_HOME: xdgData });
    assert(result.code === 0, `completion --print failed:\n${combined(result)}`);
    assert(result.stdout.includes("# ss bash completion"), `bash script was not printed:\n${combined(result)}`);
    assert(!(await exists(path.join(xdgData, "bash-completion", "completions", "ss"))), "--print should not install completion files");
  } finally {
    await rm(home, { recursive: true, force: true });
  }
}

async function testBashCompletionInstallsWithYes() {
  const home = await mkdtempHome("ss-completion-bash-");
  try {
    const xdgData = path.join(home, "data");
    const result = await runCompletion(["completion", "bash", "--yes"], home, { XDG_DATA_HOME: xdgData });
    assert(result.code === 0, `bash completion install failed:\n${combined(result)}`);
    const target = path.join(xdgData, "bash-completion", "completions", "ss");
    const script = await readFile(target, "utf8");
    assert(script.includes("complete -F _ss ss"), `bash completion was not written to ${target}`);
    assert(result.stderr.includes(`create ${target}`), `install plan did not mention bash target:\n${combined(result)}`);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
}

async function testFishCompletionAsksBeforeWriting() {
  const home = await mkdtempHome("ss-completion-fish-");
  try {
    const xdgConfig = path.join(home, "config");
    const target = path.join(xdgConfig, "fish", "completions", "ss.fish");
    const result = await runCompletion(["completion", "fish"], home, { XDG_CONFIG_HOME: xdgConfig }, "y\n");
    assert(result.code === 0, `fish completion install failed:\n${combined(result)}`);
    assert(result.stderr.includes("Proceed? [y/N]"), `fish install did not prompt:\n${combined(result)}`);
    const script = await readFile(target, "utf8");
    assert(script.includes("complete -c ss"), `fish completion was not written to ${target}`);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
}

async function testDeniedCompletionInstallDoesNotWrite() {
  const home = await mkdtempHome("ss-completion-deny-");
  try {
    const xdgConfig = path.join(home, "config");
    const target = path.join(xdgConfig, "fish", "completions", "ss.fish");
    const result = await runCompletion(["completion", "fish"], home, { XDG_CONFIG_HOME: xdgConfig }, "n\n");
    assert(result.code === 0, `denied fish completion command should succeed:\n${combined(result)}`);
    assert(result.stderr.includes("completion install cancelled"), `denied install did not report cancellation:\n${combined(result)}`);
    assert(!(await exists(target)), `denied install should not create ${target}`);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
}

async function testZshCompletionAddsInitBlockOnce() {
  const home = await mkdtempHome("ss-completion-zsh-");
  try {
    const zshrc = path.join(home, ".zshrc");
    await writeFile(zshrc, "# user config\n", "utf8");
    const target = path.join(home, ".zsh", "completions", "_ss");

    const first = await runCompletion(["completion", "zsh", "--yes"], home);
    assert(first.code === 0, `zsh completion install failed:\n${combined(first)}`);
    const script = await readFile(target, "utf8");
    assert(script.includes("#compdef ss"), `zsh completion was not written to ${target}`);
    const firstZshrc = await readFile(zshrc, "utf8");
    assert(firstZshrc.includes("# >>> ss completion >>>"), `zsh init block was not added:\n${firstZshrc}`);

    const second = await runCompletion(["completion", "zsh", "--yes"], home);
    assert(second.code === 0, `second zsh completion install failed:\n${combined(second)}`);
    const secondZshrc = await readFile(zshrc, "utf8");
    assert(countOccurrences(secondZshrc, "# >>> ss completion >>>") === 1, `zsh init block was duplicated:\n${secondZshrc}`);
    assert(second.stderr.includes(`already current ${zshrc}`), `second install did not report current zshrc:\n${combined(second)}`);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
}

async function runCompletion(args, home, extraEnv = {}, input = "") {
  return await new Promise((resolve, reject) => {
    const child = spawn(ssBin, args, {
      cwd: root,
      env: {
        ...process.env,
        HOME: home,
        ...extraEnv,
      },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timeout = setTimeout(() => {
      child.kill();
      reject(new Error(`completion command timed out: ss ${args.join(" ")}`));
    }, 10000);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timeout);
      resolve({ code: code ?? -1, stdout, stderr });
    });
    child.stdin.end(input);
  });
}

async function mkdtempHome(prefix) {
  return await mkdtemp(path.join(os.tmpdir(), prefix));
}

async function exists(filePath) {
  try {
    await stat(filePath);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

function countOccurrences(text, needle) {
  return text.split(needle).length - 1;
}

function combined(result) {
  return `${result.stdout}\n${result.stderr}`;
}
