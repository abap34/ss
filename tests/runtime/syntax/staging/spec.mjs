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
  ["UnknownStage", "page Demo\nstages s { first }\nshow s == s.missing\nend\nend\n", "declared"],
  ["InvalidStagesLocation", 'page Demo\ntext! "Body"\nstages s { first }\nend\n', "start of a page"],
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
