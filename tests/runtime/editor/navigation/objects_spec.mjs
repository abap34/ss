import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { withLspClient } from "../../harness.mjs";

const directory = await mkdtemp(path.join(os.tmpdir(), "ss-object-source-navigation-"));
const entry = path.join(directory, "slide.ss");
const chapter = path.join(directory, "chapter.ss");
const uri = pathToFileURL(entry).href;
const library = `fn decorate!() -> Void
  text!("Decoration")
end
fn early!() -> Void
  decorate!()
  return
end
fn card!() -> Placed<Text>
  decorate!()
  return text!("Card")
end
fn pair!() -> Placed<Group<Text, Text>>
  return group!(text!("First"), text!("Second"))
end
fn identity!(value: Placed<Text>) -> Placed<Text>
  decorate!()
  return value
end
fn default_item!(value: Placed<Text> = text!("Default")) -> Placed<Text>
  return value
end
`;
const cases = [
  ["void_result", "lib::decorate!()"],
  ["early_return", "lib::early!()"],
  ["returned_and_extra", "let item = lib::card!()"],
  ["returned_group", "let item = lib::pair!()"],
  ["default_argument", "let item = lib::default_item!()"],
  ["callback", "callback()", "let callback = () |-> lib::decorate!()"],
  ["standard_component", 'let item = code!("x = 1", "julia")'],
];
let body = `;; Unicode before the calls: 日本語
${cases.map(([name, call, setup = ""]) => `page ${name}\n  ${setup}\n  ${call}\nend`).join("\n")}
page existing_argument
  let original = text!("Original")
  let same = lib::identity!(original)
end
`;
const source = 'import "./library" as lib\ninclude "chapter.ss"\n';
try {
  await writeFile(entry, source);
  await writeFile(chapter, body);
  await writeFile(path.join(directory, "library.ss"), library);
  await withLspClient({ cwd: directory }, async (client) => {
    await client.initialize();
    const ready = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: source });
    assert.deepEqual((await ready).params.diagnostics, []);
    const verify = async () => {
      const snapshot = await client.request("ss/editorSnapshot", { textDocument: { uri } });
      assert(!snapshot.stale);
      const textAt = object => {
        assert.equal(object.location?.path, chapter, JSON.stringify(object));
        return Buffer.from(body).subarray(object.location.start, object.location.end).toString();
      };
      for (const [name, call] of cases) {
        const page = snapshot.layout.pages.find(page => page.name === name);
        const objects = snapshot.layout.objects.filter(object => object.page_id === page.id);
        assert(objects.length > 0, name);
        for (const object of objects) assert.equal(textAt(object), call, name);
      }
      const page = snapshot.layout.pages.find(page => page.name === "existing_argument");
      const locations = snapshot.layout.objects.filter(object => object.page_id === page.id).map(textAt);
      assert(locations.includes('let original = text!("Original")'), "passing an existing object must preserve its source");
      assert(locations.includes("let same = lib::identity!(original)"), "new decoration must point to the call");
    };
    await verify();
    const chapterUri = pathToFileURL(chapter).href;
    const opened = client.waitForDiagnostics(chapterUri);
    client.openDocument({ uri: chapterUri, text: body });
    assert.deepEqual((await opened).params.diagnostics, []);
    body = `;; Inserted before every call\n${body}`;
    const changed = client.waitForDiagnostics(chapterUri);
    client.changeDocument({ uri: chapterUri, text: body, version: 2 });
    assert.deepEqual((await changed).params.diagnostics, []);
    await verify();
  });
  console.log("Object source navigation points to calls and preserves existing arguments");
} finally {
  await rm(directory, { recursive: true, force: true });
}
