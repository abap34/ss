import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { cp, mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const exec = promisify(execFile);
const root = fileURLToPath(new URL("../../../", import.meta.url));
const sourceGrammar = path.join(root, "editor/tree-sitter-ss");
const cli = path.join(sourceGrammar, "node_modules/.bin/tree-sitter");
const directory = await mkdtemp(path.join(tmpdir(), "ss-zed-grammar-test-"));
const options = { cwd: root, timeout: 30000, killSignal: "SIGKILL", maxBuffer: 8 * 1024 * 1024 };
try {
  const archive = path.join(directory, "grammar.tar");
  const { stdout } = await exec("python3", [path.join(root, "editor/zed/tools/check-grammar.py"), "--archive", archive], {
    ...options, timeout: 90000,
  });
  const reference = JSON.parse(stdout);
  await exec("tar", ["-xf", archive, "-C", directory], options);
  const grammar = path.join(directory, reference.path);
  await mkdir(path.join(grammar, "test"), { recursive: true });
  await cp(path.join(sourceGrammar, "test/corpus"), path.join(grammar, "test/corpus"), { recursive: true });

  // Compile the committed parser directly. Archives preserve old mtimes, so a
  // forced rebuild also prevents reuse of another revision's cached ss parser.
  await exec(cli, ["test", "--rebuild"], { ...options, cwd: grammar });
  await exec(process.execPath, [path.join(root, "tests/editor/tree-sitter/spec.mjs"), grammar], {
    ...options, timeout: 90000,
  });
  const fixture = path.join(sourceGrammar, "test/highlight.ss");
  const parsed = await exec(cli, ["parse", fixture], { ...options, cwd: grammar });
  assert.doesNotMatch(parsed.stdout, /\((?:ERROR|MISSING)\b/, "Zed's pinned grammar must parse the current fixture");
  const queries = ["highlights", "outline", "indents", "brackets"];
  for (const query of queries) {
    await exec(cli, ["query", path.join(root, `editor/zed/languages/ss/${query}.scm`), fixture, "--quiet"], {
      ...options, cwd: grammar,
    });
  }
  console.log(`Zed pinned grammar ${reference.revision.slice(0, 8)}: current corpus, syntax cases, and ${queries.length} queries passed`);
} finally {
  await rm(directory, { recursive: true, force: true });
}
