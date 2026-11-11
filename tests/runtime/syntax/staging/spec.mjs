import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { ssBin } from "../../harness.mjs";

const exec = promisify(execFile);
const directory = await mkdtemp(path.join(os.tmpdir(), "ss-staging-diagnostics-test-"));
const cases = [
  ["EmptyStages", "page Demo\nstages s {}\nend\n", "at least one stage name"],
  ["DuplicateStageName", "page Demo\nstages s { first first }\nend\n", "unique name"],
  ["DuplicateStageValue", "page Demo\nstages i { 1 3 1 }\nend\n", "unique integer"],
  ["DuplicateStageValue", "page Demo\nstages i { 1:3 2 }\nend\n", "unique integer"],
  ["DuplicateStageValue", "page Demo\nstages i { 1:2:5 3:2:7 }\nend\n", "unique integer"],
  ["InvalidStageInteger", "page Demo\nstages i { 1.5 }\nend\n", "integer literal"],
  ["InvalidStageInteger", "page Demo\nstages i { 16777217 }\nend\n", "integer literal"],
  ["InvalidStageInteger", "page Demo\nstages i { -16777217 }\nend\n", "integer literal"],
  ["InvalidStageInteger", "page Demo\nstages i { 999999999999999999999 }\nend\n", "integer literal"],
  ["InvalidStageInteger", "page Demo\nstages i { 1: }\nend\n", "integer literal"],
  ["InvalidStageInteger", "page Demo\nstages i { 1:2.5 }\nend\n", "integer literal"],
  ["InvalidStageInteger", "page Demo\nstages i { 1:1.5:3 }\nend\n", "integer literal"],
  ["InvalidStageInteger", "page Demo\nstages i { 1..=3 }\nend\n", "integer literal"],
  ["InvalidStageRange", "page Demo\nstages i { 3:1 }\nend\n", "nonzero integer step"],
  ["InvalidStageRange", "page Demo\nstages i { 1:0:3 }\nend\n", "nonzero integer step"],
  ["InvalidStageRange", "page Demo\nstages i { 7:0:7 }\nend\n", "nonzero integer step"],
  ["InvalidStageRange", "page Demo\nstages i { 1:-1:3 }\nend\n", "nonzero integer step"],
  ["InvalidStageRange", "page Demo\nstages i { 3:1:1 }\nend\n", "nonzero integer step"],
  ["DuplicateStageValue", "page Demo\nstages i { 0 -0 }\nend\n", "unique integer"],
  ["DuplicateStageValue", "page Demo\nstages i { 1 001 }\nend\n", "unique integer"],
  ["DuplicateStageValue", "page Demo\nstages i { 9:-2:1 3 }\nend\n", "unique integer"],
  ["InvalidStageInteger", "page Demo\nstages i { 1:16777217:3 }\nend\n", "integer literal"],
  ["InvalidStageInteger", "page Demo\nstages i { 1:2:16777217 }\nend\n", "integer literal"],
  ["InvalidStageInteger", "page Demo\nstages i { 1::3 }\nend\n", "integer literal"],
  ["InvalidStageInteger", "page Demo\nstages i { 1:2: }\nend\n", "integer literal"],
  ["InvalidStageInteger", "page Demo\nstages i { 1:2:3:4 }\nend\n", "integer literal"],
  ["InvalidStageInteger", "page Demo\nstages i { --1 }\nend\n", "integer literal"],
  ["InvalidStageInteger", "page Demo\nstages i { - 1 }\nend\n", "integer literal"],
  ["InvalidStageRange", "page Demo\nstages i { -0:-0:0 }\nend\n", "nonzero integer step"],
  ["MixedStageEntries", "page Demo\nstages i { first 2 }\nend\n", "stage names or integers"],
  ["MixedStageEntries", "page Demo\nstages i { 1 second }\nend\n", "stage names or integers"],
  ["MixedStageEntries", "page Demo\nstages i { 1:3 second }\nend\n", "stage names or integers"],
  ["MixedStageEntries", "page Demo\nstages i { first 1:3 }\nend\n", "stage names or integers"],
  ["MixedStageEntries", "page Demo\nstages i { first\n;; Integer follows\n-1 }\nend\n", "stage names or integers"],
  ["UnknownStage", "page Demo\nstages i { 1:2 }\ntext!(str(i.missing))\nend\n", "declared"],
  ["UnknownStage", "page Demo\nstages s { first }\nshow s == s.missing\nend\nend\n", "declared"],
  ["DuplicateStagesDeclaration", 'page Demo\nstages s { first }\ntext! "Body"\nstages t { second }\nend\n', "only one stages declaration"],
  ["InvalidStagesLocation", 'page Demo\nshow true\nstages s { first }\nend\nend\n', "directly inside a page"],
  ["DrawingConditionTypeMismatch", 'page Demo\nstages s { first second }\nshow s\ntext! "Body"\nend\nend\n', "Bool condition"],
  ["DrawingConditionHasEffects", 'fn create!() -> Bool\ntext! "Unexpected"\nreturn true\nend\npage Demo\nshow create!()\nend\nend\n', "only read values"],
  ["DrawingConditionHasEffects", 'fn change!() -> Bool\ndocctx().layout_h_center_offset = 42\nreturn true\nend\npage Demo\nshow change!()\nend\nend\n', "only read values"],
  ["DrawingConditionHasEffects", 'fn constrain!(item: Placed<Text>) -> Bool\n~ item.width == 10\nreturn true\nend\npage Demo\nlet item = text! "Body"\nshow constrain!(item)\nend\nend\n', "only read values"],
];
try {
  const file = path.join(directory, "slide.ss");
  for (const [code, source, guidance] of cases) {
    await writeFile(file, source);
    let failure;
    try {
      await exec(ssBin, ["check", "--quiet", "--color", "never", file], { cwd: directory, timeout: 15000, killSignal: "SIGKILL" });
    } catch (error) {
      failure = error;
    }
    assert.equal(failure?.code, 1, `${code}: expected a source error`);
    assert(failure.stderr.includes(code) && failure.stderr.includes(guidance), `${code}: missing useful diagnosis: ${failure.stderr}`);
    assert.match(failure.stderr, /slide\.ss:\d+:\d+:/, `${code}: missing source location`);
    assert.doesNotMatch(failure.stderr, /unexpected failure|report this as an ss bug/, `${code}: a source mistake was reported as an internal failure`);
    if (code === "DuplicateStagesDeclaration") {
      assert(failure.stderr.includes("slide.ss:4:1:"), `duplicate declaration must point to the second stages keyword: ${failure.stderr}`);
      assert.equal((failure.stderr.match(/^ERROR:/gm) ?? []).length, 1, "duplicate declarations must not produce cascading errors");
    }
    if (code === "DrawingConditionTypeMismatch") {
      assert(failure.stderr.includes("Demo / first") && failure.stderr.includes("Demo / second"), "expanded page diagnostics must identify their stage");
    }
    if (code === "DuplicateStageName") {
      assert(failure.stderr.includes("slide.ss:2:18:"), `duplicate name must point to the repeated token: ${failure.stderr}`);
      assert.equal((failure.stderr.match(/^ERROR:/gm) ?? []).length, 1, "a repeated stage name must not produce cascading errors");
    }
  }
} finally {
  await rm(directory, { recursive: true, force: true });
}
console.log(`Staging diagnostics: ${cases.length} source errors include locations and guidance`);
await import("./integers.mjs");
