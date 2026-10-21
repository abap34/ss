import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { root, withLspClient } from "../../harness.mjs";
import { editorSnapshot } from "../support.mjs";

const scratch = path.join(root, ".ss-cache/tests/editor/outline");
await mkdir(scratch, { recursive: true });
const project = await mkdtemp(path.join(scratch, "run-"));
const unicode = "é界🙂".repeat(14);
const exact = "x".repeat(40);
try {
  const slide = path.join(project, "slide.ss");
  const uri = pathToFileURL(slide).toString();
  const source = `type Parts { root: Placed<Text> }
type Card { content: String }
fn display(self: Placed<Card>) -> Text = text(self.value.content)

page names
  let title = text!("Named heading")
  let alias = title
  let parts = Parts { root = text!("Record member") }
  text!(<<
    Alpha    beta
    gamma
  >>)
  place!(group(text("Left"), text("Right")))
  place!(Card { content = "Card body" })
  text!("   ")
  text!("${unicode}")
  text!("${exact}   ")
end
`;
  await writeFile(slide, source, "utf8");
  await withLspClient({ cwd: project }, async (client) => {
    await client.initialize();
    const diagnostics = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: source });
    assert.deepEqual((await diagnostics).params.diagnostics, []);
    const snapshot = await editorSnapshot(client, uri);
    const outline = snapshot.outline;
    const page = outline.find((item) => item.kind === "page");
    assert.equal(page.label, "names");
    const roots = outline.filter((item) => item.parent_id === page.id);
    assert.deepEqual(roots.map((item) => item.label).sort(), [
      "title", "parts.root", "Text · Alpha beta gamma", "Group", "Card", "Text",
      `Text · ${Array.from(unicode).slice(0, 40).join("")}…`, `Text · ${exact}`,
    ].sort(), "outline must use source bindings, input types, and concise text excerpts");
    for (const binding of ["title", "parts.root"]) {
      const target = snapshot.editing.find((item) => item.binding === binding);
      assert.equal(outline.find((item) => item.id === target?.node_id)?.label, binding);
    }
    const group = roots.find((item) => item.label === "Group");
    assert.equal(group.kind, "group");
    assert.deepEqual(outline.filter((item) => item.parent_id === group.id)
      .map((item) => item.label), ["Text · Left", "Text · Right"]);
    const card = roots.find((item) => item.label === "Card");
    assert.deepEqual(outline.filter((item) => item.parent_id === card.id)
      .map((item) => item.label), ["Text · Card body"]);
  });
} finally {
  await rm(project, { recursive: true, force: true });
}
console.log("Editor outline bindings, types, groups, and Unicode excerpts passed.");
