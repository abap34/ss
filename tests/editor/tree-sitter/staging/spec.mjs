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
  text! "Title"
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
  const trailing = path.join(directory, "trailing.ss");
  await writeFile(trailing, `page Trailing
  show s >= s.detail
    text! "Detail"
  end
  stages s { introduction detail }
end
`);
  for (const source of [file, inline, trailing]) {
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
  const integers = path.join(directory, "integers.ss");
  await writeFile(integers, `page Range
  stages i { 1:12 }
  show i >= 2
    text!(str(i))
  end
end
page List
  stages i { 7 1 -3 0 }
  text!(str(i))
end
page Multiline
  stages i {
    -2
    :
    0
  }
end
page Step
  stages i { 1:2:9 }
end
page Descending
  stages i { 9:-2:1 }
end
page Combined
  stages i { 1:3 7 10:12 }
end
page MultilineStep
  stages i {
    1
    :
    2
    :
    5
  }
end
page MultilineList
  stages i {
    1
    2
    3
  }
end
`);
  const parsed = await exec(cli, ["parse", integers], options);
  assert.doesNotMatch(parsed.stdout, /\((?:ERROR|MISSING)\b/, "integer stages must parse without recovery");
  assert.equal((parsed.stdout.match(/\(stage_range\b/g) ?? []).length, 7);
  const highlighted = await exec(cli, ["query", "queries/highlights.scm", integers], options);
  assert.match(highlighted.stdout, /operator, .*text: `:`/);
  assert.match(highlighted.stdout, /number, .*text: `12`/);

  const separators = ["", " ", "\t", "\n", "\r\n", ";; Boundary\n", "\n;; Boundary\n\t"];
  const variants = [
    "-0", "0001", "-000002:000002:000004", "-7:2:-2", "-2:-2:-7",
    "-16777216:16777215:16777216", "16777216:-16777215:-16777216",
    "0:2:4 1:2:5", "-4 -2:2:2 3 9:-2:5 20:21",
    "1;; First entry\n3:2:7;; Range\n9",
  ];
  for (const before of separators) {
    for (const after of separators) {
      variants.push(`-3${before}:${after}2${before}:${after}4 8`);
    }
  }
  const combinations = path.join(directory, "combinations.ss");
  await writeFile(combinations, variants.map((entries, index) =>
    `page Variant${index}\n  stages i { ${entries} }\n  text!(str(i))\nend\n`).join("\n"));
  const combinationsParsed = await exec(cli, ["parse", combinations], options);
  assert.doesNotMatch(combinationsParsed.stdout, /\((?:ERROR|MISSING)\b/, "valid integer spellings and trivia combinations must parse without recovery");
  assert.equal((combinationsParsed.stdout.match(/\(stages_declaration\b/g) ?? []).length, variants.length);

  const malformed = ["1::3", "1:2:", "--1", "1 first", "first 1", "1:2.0:3", "1,2", "1...3"];
  for (const [index, entries] of malformed.entries()) {
    const invalid = path.join(directory, `invalid-${index}.ss`);
    await writeFile(invalid, `page Invalid\n  stages i { ${entries} }\nend\npage After\nend\n`);
    let output;
    try {
      output = (await exec(cli, ["parse", invalid], options)).stdout;
    } catch (error) {
      assert.equal(error.code, 1, `unexpected parser failure for ${entries}`);
      output = error.stdout;
    }
    assert.match(output, /\((?:ERROR|MISSING)\b/, `invalid stages must require recovery: ${entries}`);
    assert.match(output, /\(page_declaration \[3, 0\]/, "invalid stages must retain the following page");
  }
  console.log(`Integer staging grammar: ${variants.length} valid spellings and trivia combinations, ${malformed.length} malformed declarations passed`);
  console.log("Staging grammar: stages at the start, middle, and end, nested predicates, highlighting, and folding passed");
} finally {
  await rm(directory, { recursive: true, force: true });
}
