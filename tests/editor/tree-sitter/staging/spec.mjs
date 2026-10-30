import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const exec = promisify(execFile);
const root = fileURLToPath(new URL("../../../../", import.meta.url));
const grammar = path.join(root, "editor/tree-sitter-ss");
const cli = path.join(grammar, "node_modules/.bin/tree-sitter");
const options = { cwd: grammar, timeout: 30000, killSignal: "SIGKILL", maxBuffer: 1024 * 1024 };
const directory = await mkdtemp(path.join(os.tmpdir(), "ss-staging-grammar-test-"));
try {
  const file = path.join(directory, "staging.ss");
  await writeFile(file, `fn note!(enabled: Bool) -> Void
  show enabled
    text! "Body"
  end
end
page Example
  stages s {
    introduction
    detail
  }
  show s >= s.detail
    show ((value: Number) |-> value > 0)(s)
      note!(true)
    end
  end
end
`);
  const inline = path.join(directory, "inline.ss");
  await writeFile(inline, `page Inline
  stages s { introduction detail }
  show s == s.introduction
    text! "First stage"
  end
end
`);
  for (const source of [file, inline]) {
    // The published-grammar test can leave a different ss parser in the cache.
    const rebuild = source === file ? ["--rebuild"] : [];
    const { stdout } = await exec(cli, ["parse", ...rebuild, source], options);
    assert.doesNotMatch(stdout, /\((?:ERROR|MISSING)\b/, "staging syntax must parse without recovery");
    assert.match(stdout, /\(stages_declaration\b/);
    assert.match(stdout, /\(show_statement\b/);
  }
  const { stdout } = await exec(cli, ["query", "queries/highlights.scm", file], options);
  assert.match(stdout, /keyword, .*text: `stages`/);
  assert.match(stdout, /keyword, .*text: `show`/);
  await exec(cli, ["query", "queries/folds.scm", file, "--quiet"], options);
  console.log("Staging grammar: inline and multiline stages, nested predicates, highlighting, and folding passed");
} finally {
  await rm(directory, { recursive: true, force: true });
}
