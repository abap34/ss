import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { root, withLspClient } from "../../harness.mjs";

const scratch = path.join(root, ".test-tmp/page-ranges");
await mkdir(scratch, { recursive: true });
const directory = await mkdtemp(path.join(scratch, "project-"));
const entry = path.join(directory, "slide.ss");
const uri = pathToFileURL(entry).href;
const query = { textDocument: { uri } };
const initial = 'import std:themes/default as *\npage _\n  text!("First")\nend\n';
let cases = 0;
try {
  await writeFile(path.join(directory, "ss.toml"), '[project]\nentry="slide.ss"\n[editor.lsp]\ndebounce=60000\n[editor.wysiwyg.refresh]\nautomatic=false\n');
  await writeFile(entry, initial);
  await withLspClient({ cwd: directory, measureProfile: true }, async client => {
    await client.initialize();
    assert.deepEqual(await client.request("ss/pageRanges", query), { version: null, pages: [{ startLine: 1, endLine: 3 }] });
    const ready = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: initial, version: 1 });
    assert.deepEqual((await ready).params.diagnostics, []);
    let version = 1;
    async function check(source, expected, label) {
      client.changeDocument({ uri, text: source, version: ++version });
      const result = await client.request("ss/pageRanges", query);
      assert.deepEqual(result, {
        version, pages: expected?.map(([startLine, endLine]) => ({ startLine, endLine })) ?? null,
      }, label);
      cases++;
    }
    const bodies = [
      ['stages s { first second third }', 'show s >= s.first', '  if true', '    text!("Body")', '  else', '    text!("Other")', '  end', 'end'],
      ['let helper = (content: String) |-> text(content)', 'helper("Nested lambda")'],
      ['let config = Appearance {', '  page = "A field, not a page"', '}', 'page.background_fill = c"white"'],
      ['text!("Multiline', 'page Fake', 'end', 'Text")', 'text!("A literal backslash\\")'],
      ['let sample = text << ;; literal', 'page Fake', 'if true', 'end', '>>', 'text!("Real body")'],
    ];
    for (const operator of ["||", "//", "|=|", "/=/"]) {
      bodies.push(['let sample = text <<', 'page Fake', 'end', `>> ${operator} text << ;; second literal`, 'page AnotherFake', 'end', '>>']);
    }
    for (const body of bodies) {
      const preamble = [';; Unicode before pages: \u{1f680}', 'fn/! helper(content: String) -> Text', '  return text(content)', 'end ;; global function'];
      const lines = [...preamble, 'page _', ...body, 'end ;; page boundary', '', 'document', '  let outside = "Not part of a page"', 'end', 'page "After"', '  text!("Last")', 'end'];
      const second = lines.indexOf('page "After"');
      const expected = [[preamble.length, preamble.length + body.length + 1], [second, second + 2]];
      await check(lines.join("\n"), expected, `nested syntax ${cases}`);
      await check(lines.join("\r\n") + "\r\n", expected, `CRLF syntax ${cases}`);
    }
    const lines = [];
    const expected = [];
    for (let i = 0; i < 25; i++) {
      const start = lines.length;
      lines.push('page _', '  stages s { first second }', '  text!("Body")', 'end');
      expected.push([start, start + 3]);
    }
    await check(lines.join("\n"), expected, "one range per physical declaration, independent of stages and repeated names");
    await check(`import "./not-created-yet" as pending\ninclude "not-created-yet.ss"\n${initial.replace('import std:themes/default as *\n', '')}`, [[2, 4]], "imports and includes do not require module resolution");
    await check(initial.replace('text!("First")', 'let invalid: Number = false'), [[1, 3]], "type checking is not needed for page boundaries");
    for (const source of [
      initial.replace('text!("First")', 'text!('),
      initial.replace('text!("First")', 'text!("'),
      initial.replace('text!("First")', 'text! <<\npage Fake'),
      initial.replace('page _', 'page '),
      initial.slice(0, initial.lastIndexOf('end')),
      `const style = Appearance {\n${initial}`,
    ]) await check(source, null, "incomplete syntax must not publish an empty or partial page list");
    await check(initial, [[1, 3]], "repairing syntax restores authoritative boundaries");
    await check('const example: String = <<\npage Fake\nend\n>>\n', [], "valid source without pages clears decorations");
    await check('', [], "an empty document has no pages");
    await client.close();
    const builds = Number(client.stderr.match(/analysis static semantics: (\d+) calls/)?.[1] ?? 0);
    assert.equal(builds, 1, `page boundary requests triggered semantic analysis\n${client.stderr}`);
  });
  console.log(`Page ranges: ${cases} compiler syntax, physical source, incomplete edits and version cases passed`);
} finally {
  await rm(directory, { recursive: true, force: true });
}
