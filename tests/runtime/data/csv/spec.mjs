import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { root, ssBin, withLspClient } from '../../harness.mjs';
import { applyProtocolEdits, editingTarget, previewBounds, requestEdit } from '../../editor/support.mjs';

const scratch = path.join(root, '.ss-cache/tests/csv');
await mkdir(scratch, { recursive: true });
const project = await mkdtemp(path.join(scratch, 'project-'));
const sourcePath = path.join(project, 'slide.ss');
const csvPath = path.join(project, 'data.csv');
const prelude = 'import std:themes/default as *\nimport std:data/csv as csv\n';
const source = `${prelude}page table\nlet table = csv::show_table! "data.csv"\n~ table.width == 900\nend\n`;
function run(args) {
  const result = spawnSync(ssBin, args, { cwd: project, encoding: 'utf8', timeout: 30000 });
  assert.ifError(result.error);
  return result;
}
async function dump(csv, program = source) {
  await writeFile(csvPath, csv);
  await writeFile(sourcePath, program);
  const result = run(['dump', '--quiet', 'slide.ss', 'dump.json']);
  assert.equal(result.status, 0, result.stderr);
  const output = JSON.parse(await readFile(path.join(project, 'dump.json'), 'utf8'));
  assert.equal(output.diagnostics.length, 0, JSON.stringify(output.diagnostics));
  return output;
}
const content = output => output.nodes.find(node => node.role === 'body')?.content;
try {
  const output = await dump('\ufeffName,Value,Note\r\n"a,b",001,"line 1\r\nline 2"\r\n"say ""hello""",1.2300,\r\n');
  assert.equal(content(output), '| Name | Value | Note |\n| --- | --- | --- |\n| a,b | 001 | line 1 line 2 |\n| say "hello" | 1.2300 |  |\n');
  assert.equal(content(await dump('A,B\r1,2\r')), '| A | B |\n| --- | --- |\n| 1 | 2 |\n');
  assert.equal(content(await dump('A,B\n,\n')), '| A | B |\n| --- | --- |\n|  |  |\n');
  assert.equal(content(await dump('A,B')), '| A | B |\n| --- | --- |\n');
  assert.equal(content(await dump('')), '');
  assert.equal(content(await dump('\ufeff')), '');
  const plain = await dump('001,1.2300\n002,2.0000', source.replace('csv::show_table! "data.csv"', 'csv::show_table!("data.csv", false)'));
  assert.equal(content(plain), '|  |  |\n| --- | --- |\n| 001 | 1.2300 |\n| 002 | 2.0000 |\n');
  const escaped = content(await dump('Heading\n"a|b *x* _y_ `z` [link](url) <tag> &amp; $x$ \\path"'));
  for (const entity of ['\\|', '\\*', '\\_', '\\`', '\\[', '\\<', '\\&', '\\$', '\\\\']) assert(escaped.includes(entity), escaped);
  const literalPdf = run(['render', '--quiet', 'slide.ss', 'literal.pdf']);
  assert.equal(literalPdf.status, 0, literalPdf.stderr);
  const extractor = spawnSync('pdftotext', ['literal.pdf', '-'], { cwd: project, encoding: 'utf8', timeout: 10000 });
  if (!extractor.error) {
    assert.equal(extractor.status, 0, extractor.stderr);
    for (const literal of ['a|b', '*x*', '_y_', '`z`', '[link](url)', '<tag>', '&amp;', '$x$', '\\path']) assert(extractor.stdout.includes(literal), extractor.stdout);
  } else if (extractor.error.code !== 'ENOENT') throw extractor.error;
  for (const csv of ['A,B\n1', 'A\n"unterminated', 'A\na"b', 'A\n"a"b', 'A,B\n1,2,3', Buffer.from([0xff])]) {
    await writeFile(csvPath, csv);
    await writeFile(sourcePath, source);
    const result = run(['check', '--quiet', 'slide.ss']);
    assert.notEqual(result.status, 0);
    assert(result.stderr.includes('CsvParseFailed: record '), result.stderr);
  }
  const mapped = `${prelude}fn cell(value: String, row: Number, column: Number, end_row: Bool, suffix: String) -> String\nreturn value ++ suffix\nend\npage values\ntext!(csv_map(readlines("data.csv"), cell, "!"))\nend\n`;
  assert.equal(content(await dump('A,B\n1,2', mapped)), 'A!B!1!2!');
  const effects = `${prelude}fn update(value: String, row: Number, column: Number, end_row: Bool, target: Object) -> String
set_prop(target, "link_id", value)
return ""
end
page effects
let target = text! "before"
let summary = text!(prop(target, "link_id", "missing"))
csv_map(readlines("data.csv"), update, target)
end
`;
  const updated = await dump('after', effects);
  assert.equal(updated.nodes.filter(node => node.role === 'body' && node.content === 'after').length, 1, 'Callback effects were not scheduled before readers');
  await writeFile(sourcePath, mapped.replace('row: Number', 'row: String'));
  assert.notEqual(run(['check', '--quiet', 'slide.ss']).status, 0, 'Invalid callback parameter type accepted');
  await writeFile(sourcePath, mapped.replace('-> String\nreturn value ++ suffix', '-> Number\nreturn 1'));
  assert.notEqual(run(['check', '--quiet', 'slide.ss']).status, 0, 'Invalid callback result type accepted');
  await dump('A,B\n1,2', source.replace('page table', 'document\ntheme!(default_theme() with { body.text.size = 31 })\nend\npage table'));
  const styled = JSON.parse(await readFile(path.join(project, 'dump.json'), 'utf8'));
  const text = JSON.parse(styled.nodes.find(node => node.role === 'body').fields.text);
  assert.equal(text.fields.find(field => field.name === 'size').value.value, 31);
  await dump('A,B\nold,001');
  const pdf = run(['render', '--quiet', 'slide.ss', 'table.pdf']);
  assert.equal(pdf.status, 0, pdf.stderr);
  await withLspClient({ cwd: project }, async client => {
    await client.initialize();
    const uri = pathToFileURL(sourcePath).toString();
    const ready = client.waitForDiagnostics(uri);
    client.openDocument({ uri, version: 1, text: source });
    assert.equal((await ready).params.diagnostics.length, 0);
    let snapshot = await client.request('ss/editorSnapshot', { textDocument: { uri } });
    assert(!snapshot.stale, JSON.stringify(snapshot.build_diagnostics));
    const target = editingTarget(snapshot, 'table');
    const from = previewBounds(snapshot, target.node_id);
    const edit = await requestEdit(client, uri, snapshot, target, from, { ...from, x: from.x + 20 }, 'absolute', target.page_id);
    assert.equal(edit.status, 'ok');
    const changed = applyProtocolEdits(source, edit.workspaceEdit.changes[uri]);
    client.changeDocument({ uri, version: 2, text: changed });
    const moved = await client.request('ss/editorSnapshot', { textDocument: { uri }, baseSnapshotId: snapshot.snapshot_id });
    assert.equal(moved.display?.kind, 'translation_patch', JSON.stringify(moved.build_diagnostics));
    await writeFile(csvPath, 'A,B\nnew,002');
    const nextTarget = editingTarget(moved, 'table');
    const nextBounds = previewBounds(moved, nextTarget.node_id);
    const nextEdit = await requestEdit(client, uri, moved, nextTarget, nextBounds, { ...nextBounds, x: nextBounds.x + 20 }, 'absolute', nextTarget.page_id);
    assert.equal(nextEdit.status, 'ok');
    client.changeDocument({ uri, version: 3, text: applyProtocolEdits(changed, nextEdit.workspaceEdit.changes[uri]) });
    snapshot = await client.request('ss/editorSnapshot', { textDocument: { uri }, baseSnapshotId: moved.snapshot_id });
    assert(!snapshot.stale, JSON.stringify(snapshot.build_diagnostics));
    assert.notEqual(snapshot.display?.kind, 'translation_patch', 'Changed CSV incorrectly reused');
    assert(JSON.stringify(snapshot).includes('new'), 'CSV change did not reach the snapshot');
  });
  console.log('CSV parsing, literal table rendering, callback typing, theme, external inputs, and editing passed');
} finally {
  await rm(project, { recursive: true, force: true });
}
