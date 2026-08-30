import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const oldCairoPkgConfig = path.join(root, "tests/fixtures/build/dependencies/cairo-1.15");
const newCairoPkgConfig = path.join(root, "tests/fixtures/build/dependencies/cairo-2");
const oldQpdfPkgConfig = path.join(root, "tests/fixtures/build/dependencies/qpdf-10");
const newQpdfPkgConfig = path.join(root, "tests/fixtures/build/dependencies/qpdf-13");
const dependencyChecker = process.argv[2] ? path.resolve(root, process.argv[2]) : undefined;

assert.ok(dependencyChecker, "dependency checker executable argument is missing");

function runBuild(args, environment = {}) {
  const result = spawnSync("zig", ["build", "--summary", "none", ...args], {
    cwd: root,
    encoding: "utf8",
    env: { ...process.env, ...environment },
    timeout: 60_000,
  });
  assert.equal(result.error?.code, undefined, result.error?.message);
  assert.notEqual(result.status, 0, "diagnostic fixture unexpectedly built successfully");
  return `${result.stdout}\n${result.stderr}`;
}

function runDependencyChecker(args, cwd) {
  const result = spawnSync(dependencyChecker, args, {
    cwd,
    encoding: "utf8",
    timeout: 10_000,
  });
  assert.equal(result.error?.code, undefined, result.error?.message);
  assert.notEqual(result.status, 0, "dependency checker unexpectedly succeeded");
  return `${result.stdout}\n${result.stderr}`;
}

{
  const output = runBuild(["-Dqpdf-cxx=ss-missing-cxx-compiler"]);
  assert.match(output, /C\+\+ compiler 'ss-missing-cxx-compiler' was not found/);
  assert.match(output, /GCC and Clang are both supported/);
  assert.match(output, /-Dqpdf-cxx=clang\+\+/);
  assert.match(output, /-Dqpdf-cxx=\/absolute\/path\/to\/c\+\+/);
}

{
  const temporaryRoot = mkdtempSync(path.join(os.tmpdir(), "ss-pnpm-diagnostic-"));
  try {
    const workspace = path.join(temporaryRoot, "workspace");
    mkdirSync(workspace);
    writeFileSync(path.join(workspace, "pnpm-lock.yaml"), "lockfileVersion: '9.0'\n");
    const output = runDependencyChecker(
      ["node-modules", "workspace", "esbuild/package.json"],
      temporaryRoot,
    );
    assert.match(output, /detected pnpm-lock\.yaml/);
    assert.match(output, /pnpm install --frozen-lockfile/);
    assert.doesNotMatch(output, /npm ci/);
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
}

{
  const temporaryRoot = mkdtempSync(path.join(os.tmpdir(), "ss-npm-diagnostic-"));
  try {
    const workspace = path.join(temporaryRoot, "workspace");
    mkdirSync(workspace);
    writeFileSync(path.join(workspace, "package-lock.json"), "{}\n");
    const output = runDependencyChecker(
      ["node-modules", "workspace", "typescript/package.json"],
      temporaryRoot,
    );
    assert.match(output, /detected package-lock\.json/);
    assert.match(output, /npm ci/);
    assert.doesNotMatch(output, /pnpm install/);
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
}

{
  const output = runBuild(["-Dqpdf-pkg-config=ss-missing-pkg-config"]);
  assert.match(output, /pkg-config command 'ss-missing-pkg-config' was not found/);
  assert.match(output, /-Dqpdf-pkg-config=\/absolute\/path\/to\/pkg-config/);
}

{
  const pkgConfigPath = process.env.PKG_CONFIG_PATH
    ? `${oldCairoPkgConfig}${path.delimiter}${process.env.PKG_CONFIG_PATH}`
    : oldCairoPkgConfig;
  const output = runBuild([], { PKG_CONFIG_PATH: pkgConfigPath });
  assert.match(output, /Cairo 1\.15\.10 is too old/);
  assert.match(output, /requires Cairo 1\.16\.0 or newer/);
}

{
  const pkgConfigPath = process.env.PKG_CONFIG_PATH
    ? `${newCairoPkgConfig}${path.delimiter}${process.env.PKG_CONFIG_PATH}`
    : newCairoPkgConfig;
  const output = runBuild([], { PKG_CONFIG_PATH: pkgConfigPath });
  assert.match(output, /Cairo 2\.0\.0 is newer than the supported range/);
  assert.match(output, /supports Cairo 1\.16\.0 or newer and earlier than 2\.0\.0/);
}

{
  const pkgConfigPath = process.env.PKG_CONFIG_PATH
    ? `${oldQpdfPkgConfig}${path.delimiter}${process.env.PKG_CONFIG_PATH}`
    : oldQpdfPkgConfig;
  const output = runBuild([], { PKG_CONFIG_PATH: pkgConfigPath });
  assert.match(output, /libqpdf 10\.6\.3 is too old/);
  assert.match(output, /requires libqpdf 11\.2\.0 or newer/);
  assert.match(output, /ppa:qpdf\/qpdf/);
}

{
  const pkgConfigPath = process.env.PKG_CONFIG_PATH
    ? `${newQpdfPkgConfig}${path.delimiter}${process.env.PKG_CONFIG_PATH}`
    : newQpdfPkgConfig;
  const output = runBuild([], { PKG_CONFIG_PATH: pkgConfigPath });
  assert.match(output, /libqpdf 13\.0\.0 is newer than the supported range/);
  assert.match(output, /supports libqpdf 11\.2\.0 or newer and earlier than 13\.0\.0/);
}

console.log("build dependency diagnostic tests passed");
