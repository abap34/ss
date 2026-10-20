import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const exec = promisify(execFile);
const root = fileURLToPath(new URL("../../../", import.meta.url));
const sourceGrammar = path.join(root, "editor/tree-sitter-ss");
const cli = path.join(sourceGrammar, "node_modules/.bin/tree-sitter");
const manifest = await readFile(path.join(root, "editor/zed/extension.toml"), "utf8");
const section = manifest.split("[grammars.ss]")[1]?.split("\n[")[0];
assert.ok(section, "Zed must configure the ss grammar");
function field(name) {
  const value = section.match(new RegExp(`^${name} = ("[^"\\n]+")\\s*$`, "m"))?.[1];
  assert.ok(value, `Zed grammar must configure ${name}`);
  return JSON.parse(value);
}
const repository = field("repository");
const revision = field("rev");
const grammarPath = field("path");
assert.match(repository, /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+(?:\.git)?$/);
assert.match(revision, /^[0-9a-f]{40}$/, "Zed grammar must pin a full commit SHA");
assert.ok(grammarPath.split("/").every((part) => /^[\w-]+$/.test(part)), "Zed grammar path must be relative");

const output = path.join(root, ".ss-cache/tests/editor/zed");
await mkdir(output, { recursive: true });
const directory = await mkdtemp(path.join(output, "run-"));
const options = { cwd: root, timeout: 30000, killSignal: "SIGKILL", maxBuffer: 8 * 1024 * 1024 };
let sourceRepository = root;
try {
  await exec("git", ["cat-file", "-e", `${revision}^{commit}`], options);
} catch (error) {
  assert.ok(error.code === 1 || error.code === 128, `Could not inspect the pinned grammar commit: ${error.message}`);
  // Shallow CI checkouts may not contain the pinned ancestor. Fetch only that
  // commit into the test cache, sharing existing objects to avoid downloading
  // them again and leaving the checkout and its refs untouched.
  sourceRepository = path.join(directory, "repository.git");
  await exec("git", ["clone", "--bare", "--shared", root, sourceRepository], options);
  await exec("git", ["-C", sourceRepository, "fetch", "--no-tags", "--depth=1", repository, revision], {
    ...options, timeout: 60000, env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
  });
}
const archive = path.join(directory, "grammar.tar");
await exec("git", ["-C", sourceRepository, "archive", "--format=tar", `--output=${archive}`, revision,
  `${grammarPath}/grammar.js`, `${grammarPath}/tree-sitter.json`, `${grammarPath}/src`], options);
await exec("tar", ["-xf", archive, "-C", directory], options);
const grammar = path.join(directory, grammarPath);
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
console.log(`Zed pinned grammar ${revision.slice(0, 8)}: current corpus, syntax cases, and ${queries.length} queries passed`);
