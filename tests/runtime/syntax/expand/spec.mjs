import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile, access } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../../harness.mjs";

const scratch = path.join(root, ".test-tmp/syntax-expand");
await mkdir(scratch, { recursive: true });
const directory = await mkdtemp(path.join(scratch, "run-"));
function run(args, status = 0) {
  const result = spawnSync(ssBin, args, { cwd: directory, encoding: "utf8", timeout: 60000 });
  assert.ifError(result.error);
  assert.equal(result.status, status, result.stderr);
  return result;
}
try {
  const source = `page _
  stages s { first second }
  text! "Title"
  show s >= s.second
    let detail = text! "Details"
  end
end
`;
  await writeFile(path.join(directory, "example.ss"), source);
  const output = run(["expand", "example.ss"]).stdout;
  assert.equal((output.match(/^page /gm) ?? []).length, 2);
  assert.match(output, /let #drawing-58 = \(\(\) \|-> num_ge\(0, 1\)\)/);
  assert.match(output, /let #drawing-58 = \(\(\) \|-> num_ge\(1, 1\)\)/);
  assert.equal((output.match(/draw_when!\(0, #drawing-58\)/g) ?? []).length, 2);
  assert.doesNotMatch(output, /\bstages\b|\bshow\b|>=/);
  await assert.rejects(access(path.join(directory, ".ss-cache")));

  run(["expand", "example.ss", "expanded.ss"]);
  assert.equal(await readFile(path.join(directory, "expanded.ss"), "utf8"), output);
  run(["dump", "--quiet", "example.ss", "dump.json"]);
  const dump = JSON.parse(await readFile(path.join(directory, "dump.json"), "utf8"));
  const pages = dump.modules.find(module => module.kind === "project").program.pages;
  for (const page of pages) assert(output.includes(`page ${JSON.stringify(page.name)}`));
  assert.match(run(["expand", "--help"]).stdout, /before type checking/);
  assert.match(run(["help"]).stdout, /ss expand/);
  for (const shell of ["bash", "zsh", "fish"]) {
    assert.match(run(["completion", shell, "--print"]).stdout, /\bexpand\b/);
  }

  await writeFile(path.join(directory, "ss.toml"), '[project]\nentry = "example.ss"\n');
  assert.equal(run(["expand", "--project", "."]).stdout, output);
  const conflict = run(["expand", "example.ss", "example.ss"], 1);
  assert.match(conflict.stderr, /OutputPathConflictsWithInput/);
  assert.equal(await readFile(path.join(directory, "example.ss"), "utf8"), source);

  await writeFile(path.join(directory, "unresolved.ss"), 'import "./missing"\npage _\nreport_error!("Must not execute")\nunknown!()\nend\n');
  assert.match(run(["expand", "unresolved.ss"]).stdout, /unknown!\(\)/);
  await writeFile(path.join(directory, "invalid.ss"), "page _\nstages s {}\nend\n");
  assert.match(run(["expand", "invalid.ss"], 1).stderr, /EmptyStages/);
  assert.match(run(["expand", "absent.ss"], 1).stderr, /InputNotFound/);
  assert.match(run(["expand", "--invalid"], 1).stderr, /unknown flag/);
} finally {
  await rm(directory, { recursive: true, force: true });
}
console.log("Expanded source: generated names, primitive calls, parse-only behavior, and output safety passed");
