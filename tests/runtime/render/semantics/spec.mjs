import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../../harness.mjs";

const parent = path.join(root, ".ss-cache/tests/render/semantics");
await mkdir(parent, { recursive: true });
const project = await mkdtemp(path.join(parent, "run-"));
const slide = path.join(project, "slide.ss");
const run = (args) => execFileSync(ssBin, args, { cwd: project, encoding: "utf8", timeout: 60000 });
const source = (attributes, content = "Custom meaning") => `
import std:themes/default as *
import std:internal/classes as { Text }
type Custom = object {
  base = Text
  roles = ["custom-meaning"]
  semantics: SemanticStyle = SemanticStyle { ${attributes} }
}
page main
  title_obj!("Standard title")
  sub_obj!("Standard subtitle")
  code_obj!("source")
  fig_obj!("diagram")
  txt_obj!("${content}", "custom-meaning")
end
`;

await writeFile(slide, source("role = SemanticRole.heading, heading_level = 3"));
run(["render", "--quiet", "--format", "html", slide, "first.html"]);
const first = await readFile(path.join(project, "first.html"), "utf8");
for (const tag of ["h1", "h2", "h3", "pre", "figure"]) {
  assert(first.includes(`<${tag} data-ss-semantic-id`), `missing ${tag}`);
}
await writeFile(slide, source("role = SemanticRole.caption"));
run(["render", "--quiet", "--format", "html", slide, "second.html"]);
const second = await readFile(path.join(project, "second.html"), "utf8");
assert(second.includes("<figcaption data-ss-semantic-id"));
assert(!second.includes("<h3 data-ss-semantic-id"));

// Native math items must retain their semantic nodes under explicit headings.
if (spawnSync("pdflatex", ["--version"], { timeout: 10000 }).status === 0) {
  await writeFile(slide, source("role = SemanticRole.heading, heading_level = 3", "Formula $x$"));
  run(["render", "--quiet", "--format", "html", slide, "math.html"]);
  const math = await readFile(path.join(project, "math.html"), "utf8");
  assert(math.includes("<h3 data-ss-semantic-id"));
  assert(math.includes('class="ss-latex-semantic" role="math"'));
}
console.log("semantic attributes: source declarations, HTML updates, and available math rendering passed");
