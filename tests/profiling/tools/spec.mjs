import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { traceProcessor } from "../tools.mjs";

test("processor acquisition shares concurrent work and retries after failure", { timeout: 10_000 }, async (context) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "ss-processor-client-test-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  const previousPython = process.env.PYTHON;
  context.after(() => {
    if (previousPython === undefined) delete process.env.PYTHON;
    else process.env.PYTHON = previousPython;
  });
  const executable = path.join(directory, "installer");
  const attempts = path.join(directory, "attempts");
  const binary = path.join(directory, "processor");
  await writeFile(executable, `#!/usr/bin/env python3
from pathlib import Path
import sys
attempts = Path(${JSON.stringify(attempts)})
count = int(attempts.read_text()) + 1 if attempts.exists() else 1
attempts.write_text(str(count))
if count == 1:
    print("expected acquisition failure", file=sys.stderr)
    sys.exit(1)
print(${JSON.stringify(binary)})
`);
  await chmod(executable, 0o755);
  process.env.PYTHON = executable;
  const failed = traceProcessor();
  assert.equal(traceProcessor(), failed);
  await assert.rejects(failed, /expected acquisition failure/);
  const retried = traceProcessor();
  assert.equal(traceProcessor(), retried);
  assert.equal(await retried, binary);
  assert.equal(await readFile(attempts, "utf8"), "2");
  assert.equal(await traceProcessor(), binary);
});
