import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

export function command(binary, args, cwd, expected = 0, env = process.env) {
  const result = spawnSync(binary, args, { cwd, env, encoding: "utf8", timeout: 60000 });
  assert.ifError(result.error);
  assert.equal(result.status, expected, `${binary} ${args.join(" ")}\n${result.stdout}\n${result.stderr}`);
  return result;
}
export const git = (directory, ...args) => command("git", args, directory).stdout.trim();
export async function writeFiles(directory, files) {
  for (const [file, content] of Object.entries(files)) {
    await mkdir(path.dirname(path.join(directory, file)), { recursive: true });
    await writeFile(path.join(directory, file), content);
  }
}
export async function repository(work, name, files) {
  const directory = path.join(work, name);
  await mkdir(directory);
  git(directory, "init", "-b", "main");
  git(directory, "config", "user.name", "Package Test");
  git(directory, "config", "user.email", "packages@example.invalid");
  await writeFiles(directory, files);
  git(directory, "add", ".");
  git(directory, "commit", "-m", "Initial package");
  return directory;
}
export function commit(directory, message) {
  git(directory, "add", ".");
  git(directory, "commit", "-m", message);
  return git(directory, "rev-parse", "HEAD");
}
