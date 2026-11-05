import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { ssBin, withLspClient } from "../../harness.mjs";
import { applyProtocolEdits, previewBounds, requestEdit } from "../../editor/support.mjs";

const directory = await mkdtemp(path.join(os.tmpdir(), "ss-source-include-"));
const main = path.join(directory, "main.ss");
const child = path.join(directory, "parts/body.ss");
const source = `import std:themes/default as *
const title: String = "Shared"
page Before
  text! "Before"
end
include "parts/body.ss"
page After
  text!(caption())
end
`;
let body = `import ./helper as { suffix }
fn caption() -> String = title ++ suffix()
page Body
  stages s { first second }
  let item = text!(caption())
  ~ item.width == 200
  ~!~ item.left == page.left + 20
  ~!~ item.top == page.top - 40
  show s == s.second
    text! "Details"
  end
end
`;
function run(args, success = true) {
  const result = spawnSync(ssBin, args, { cwd: directory, encoding: "utf8", timeout: 60000 });
  assert.ifError(result.error);
  if (success) assert.equal(result.status, 0, result.stderr);
  else assert.notEqual(result.status, 0, result.stderr);
  return result;
}
try {
  await mkdir(path.dirname(child));
  await writeFile(main, source);
  await writeFile(child, body);
  await writeFile(path.join(directory, "parts/helper.ss"), 'fn suffix() -> String = " tail"\n');
  run(["check", "--quiet", main]);
  run(["dump", "--quiet", main, "dump.json"]);
  const dump = JSON.parse(await readFile(path.join(directory, "dump.json"), "utf8"));
  const project = dump.modules.find((module) => module.kind === "project");
  assert.equal(project.sourceFiles[0].path, child);
  assert.equal(project.sourceFiles[0].source, body);
  run(["render", "--quiet", main, "render.pdf"]);
  assert.equal((await readFile(path.join(directory, "render.pdf"))).subarray(0, 4).toString(), "%PDF");
  const expanded = run(["expand", main]).stdout;
  assert(expanded.indexOf('page "Before"') < expanded.indexOf('page "Body / first"'));
  assert(expanded.indexOf('page "Body / second"') < expanded.indexOf('page "After"'));
  assert.doesNotMatch(expanded, /\binclude\s+"|\bstages\s+s|\bshow\s+s/);
  assert.match(run(["dump", "--quiet", main, child], false).stderr, /OutputPathConflictsWithSource/);
  assert.equal(await readFile(child, "utf8"), body);

  await withLspClient({ cwd: directory }, async (client) => {
    await client.initialize();
    const uri = pathToFileURL(main).href;
    const childUri = pathToFileURL(child).href;
    const ready = client.waitForDiagnostics(uri);
    client.openDocument({ uri, version: 1, text: source });
    assert.equal((await ready).params.diagnostics.length, 0);
    let snapshot = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    assert(!snapshot.stale, JSON.stringify(snapshot));
    assert(snapshot.source_paths.includes(child));
    let targets = snapshot.editing.filter((target) => target.binding === "item");
    assert.equal(targets.length, 2);
    assert(targets.every((target) => target.path === child));
    for (const target of targets) assert.match(body.slice(target.statement_start, target.statement_end), /let item/);
    const target = targets[0];
    const bounds = previewBounds(snapshot, target.node_id);
    const edit = await requestEdit(client, uri, snapshot, target, bounds, { ...bounds, x: 140, y: 160 }, "absolute", target.page_id);
    assert.equal(edit.status, "ok", JSON.stringify(edit));
    assert(edit.workspaceEdit.changes[childUri]);
    assert(!edit.workspaceEdit.changes[uri]);
    body = applyProtocolEdits(body, edit.workspaceEdit.changes[childUri]);
    const changed = client.waitForDiagnostics(childUri);
    client.openDocument({ uri: childUri, version: 1, text: body });
    assert.equal((await changed).params.diagnostics.length, 0);
    snapshot = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    targets = snapshot.editing.filter((item) => item.binding === "item");
    for (const item of targets) {
      const updated = previewBounds(snapshot, item.node_id);
      assert(Math.abs(updated.x - 140) < 0.1 && Math.abs(updated.y - 160) < 0.1, JSON.stringify(updated));
    }
  });
  await writeFile(child, "page Broken\n  let value = missing_name\nend\n");
  assert.match(run(["check", "--quiet", main], false).stderr, /parts\/body\.ss:2:/);
  await writeFile(child, 'import ./missing as *\n');
  assert.match(run(["check", "--quiet", main], false).stderr, /parts\/body\.ss:1:/);
  await writeFile(child, 'page Broken\n  let value =\nend\n');
  const syntaxError = run(["check", "--quiet", main], false).stderr;
  assert.match(syntaxError, /parts\/body\.ss:3:/);
  assert.doesNotMatch(syntaxError, /unexpected failure/);
  await writeFile(main, 'import ./library as *\npage Main\n  text!(caption())\nend\n');
  await writeFile(path.join(directory, "library.ss"), 'const title: String = "Library"\ninclude "parts/body.ss"\n');
  await writeFile(child, 'fn caption() -> String = title\n');
  run(["check", "--quiet", main]);
  await writeFile(child, 'import ./missing as *\n');
  assert.match(run(["check", "--quiet", main], false).stderr, /parts\/body\.ss:1:/);
  await writeFile(main, source);
  await writeFile(child, "include \"../main.ss\"\n");
  assert.match(run(["check", "--quiet", main], false).stderr, /IncludeCycle/);
  console.log("Source includes: CLI expansion, shared declarations, relative imports, physical diagnostics, and staged editor edits passed");
} finally {
  await rm(directory, { recursive: true, force: true });
}
