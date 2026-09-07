import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmod, mkdir, mkdtemp, rm, stat, utimes, writeFile } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../../harness.mjs";

const scratch = path.join(root, ".ss-cache", "tests", "cache-pruning");
await mkdir(scratch, { recursive: true });
await testActiveLease();
await testReferenceGroups();
console.log("Cache pruning: active leases and reference groups passed");

async function createProject() {
  const project = await mkdtemp(path.join(scratch, "project-"));
  await writeFile(path.join(project, "ss.toml"),
    '[project]\nentry = "slide.ss"\n[cache]\nmax_size_mib = 1\nprune_interval_seconds = 0\n');
  await writeFile(path.join(project, "slide.ss"),
    'import std:themes/default as *\npage main\ntext!("Cache pruning")\nend\n');
  await mkdir(artifacts(project), { recursive: true });
  return project;
}

function artifacts(project) {
  return path.join(project, ".ss-cache", "render", "artifacts");
}

async function render(project, name = "slide.ss", extra = {}) {
  return run(["render", "--quiet", name, `${name}.pdf`], project, extra);
}

async function testActiveLease() {
  const project = await createProject();
  const release = path.join(project, "release");
  let active;
  try {
    const fakeBin = path.join(project, "bin");
    await mkdir(fakeBin);
    const executable = path.join(fakeBin, "pdflatex");
    await writeFile(executable,
      `#!/bin/sh\n: > ${quote(path.join(project, "started"))}\nwhile [ ! -e ${quote(release)} ]; do /bin/sleep 0.02; done\nexit 1\n`);
    await chmod(executable, 0o755);
    await writeFile(path.join(project, "active.ss"),
      'import std:themes/default as *\npage main\nlatex!("$x$")\nend\n');
    active = render(project, "active.ss", {
      allowFailure: true,
      env: { PATH: `${fakeBin}${path.delimiter}${process.env.PATH ?? ""}` },
    });
    // Attach a handler immediately while the other renderer is exercising the lease.
    active.catch(() => {});
    await waitForFile(path.join(project, "started"), 5_000);
    const old = path.join(artifacts(project), "old.bin");
    await seed(old, 2 * 1024 * 1024, 120_000);
    await render(project);
    await stat(old);
    await missing(path.join(artifacts(project), ".prune-stamp"));
    const clear = await run(["cache", "project", "clear"], project, { allowFailure: true });
    assert.notEqual(clear.code, 0);
    assert.match(clear.stderr, /project render cache is currently in use/);
    await writeFile(release, "");
    const failed = await active;
    assert.notEqual(failed.code, 0);
    active = null;
    await render(project);
    await missing(old);
    await stat(path.join(artifacts(project), ".prune-stamp"));
  } finally {
    await writeFile(release, "").catch(() => {});
    await active?.catch(() => {});
    await rm(project, { recursive: true, force: true });
  }
}

async function testReferenceGroups() {
  const project = await createProject();
  try {
    const directory = path.join(artifacts(project), "native");
    await mkdir(directory);
    const recentPdf = path.join(directory, "latex-batch-recent.pdf");
    const oldPdf = path.join(directory, "latex-batch-old.pdf");
    // The recent references keep their shared batch alive even when that PDF is oldest.
    await seed(recentPdf, 700 * 1024, 120_000);
    await seed(oldPdf, 700 * 1024, 60_000);
    for (const [name, pdf, age] of [
      ["recent-1.ref", "latex-batch-recent.pdf", 1_000],
      ["recent-2.ref", "latex-batch-recent.pdf", 2_000],
      ["old-1.ref", "latex-batch-old.pdf", 60_000],
      ["old-2.ref", "latex-batch-old.pdf", 60_000],
    ]) {
      const file = path.join(directory, name);
      await writeFile(file, `0\t1\t1\t0\t1\t${pdf}\n`);
      const date = new Date(Date.now() - age);
      await utimes(file, date, date);
    }
    await render(project);
    await stat(recentPdf);
    await stat(path.join(directory, "recent-1.ref"));
    await stat(path.join(directory, "recent-2.ref"));
    await missing(oldPdf);
    await missing(path.join(directory, "old-1.ref"));
    await missing(path.join(directory, "old-2.ref"));
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function seed(file, size, age) {
  await writeFile(file, Buffer.alloc(size));
  const date = new Date(Date.now() - age);
  await utimes(file, date, date);
}

async function missing(file) {
  await assert.rejects(stat(file), { code: "ENOENT" });
}

async function waitForFile(file, timeout) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try {
      await stat(file);
      return;
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`Timed out waiting for ${file}`);
}

function run(args, cwd, { allowFailure = false, env = {} } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(ssBin, args, {
      cwd, env: { ...process.env, ...env }, detached: true, stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      try { process.kill(-child.pid, "SIGKILL"); } catch (error) {
        if (error.code !== "ESRCH") reject(error);
      }
    }, 20_000);
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (data) => { stderr += data; });
    child.on("error", (error) => { clearTimeout(timer); reject(error); });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      if (timedOut || (code !== 0 && !allowFailure)) {
        reject(new Error(`ss ${args.join(" ")}: ${timedOut ? "timed out" : code ?? signal}\n${stderr}`));
      } else resolve({ code, stderr });
    });
  });
}

function quote(value) {
  return `'${value.replaceAll("'", "'\\''")}'`;
}
