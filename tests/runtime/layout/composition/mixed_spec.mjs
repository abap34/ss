import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { root, ssBin, withLspClient } from "../../harness.mjs";
import { pdfAsset } from "../../../support/assets/pdf.mjs";
import { imageSourceIs } from "../../../support/display.mjs";

const scratch = path.join(root, ".test-tmp/mixed-composition");
await mkdir(scratch, { recursive: true });
const output = await mkdtemp(path.join(scratch, "case-"));
const close = (actual, expected, message) => assert(Math.abs(actual - expected) < 0.1, `${message}: ${actual} != ${expected}`);
function run(...args) {
  const result = spawnSync(ssBin, args, { cwd: output, encoding: "utf8", timeout: 60000 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
}
function assertPainted(html, code, pdf) {
  const tags = html.match(/<[^>]*data-ss-node-id="\d+"[^>]*>/g) ?? [];
  assert(tags.some((tag) => tag.includes(`data-ss-node-id="${code.id}"`) && tag.includes('class="ss-item ss-text"')),
    "the code block must be painted");
  const asset = tags.find((tag) => tag.includes(`data-ss-node-id="${pdf.id}"`) && tag.includes('class="ss-item ss-pdf"'));
  assert(asset, "the PDF must be painted");
  assert(Number(asset.match(/(?:;|")left:([\d.-]+)pt/)?.[1]) >= code.x + code.width,
    "the painted PDF must stay in the column next to the code");
}
async function verify(name, source) {
  const entry = `${name}.ss`;
  await writeFile(path.join(output, entry), source);
  run("check", "--quiet", entry);
  run("dump", "--quiet", entry, "--output", "dump.json");
  const dump = JSON.parse(await readFile(path.join(output, "dump.json"), "utf8"));
  assert.deepEqual(dump.diagnostics, []);
  const group = dump.nodes.find((node) => node.placement?.input.kind === "group");
  const code = dump.nodes.find((node) => node.placement?.display.kind === "text" && node.content?.includes("struct Box"));
  const pdf = dump.nodes.find((node) => imageSourceIs(node, "pdf"));
  for (const node of [group, code, pdf]) {
    assert(node, "the mixed composition must retain its group and both children");
    assert(node.width > 0 && node.height > 0, `empty composition node: ${JSON.stringify(node)}`);
  }
  run("render", "--quiet", entry, "--format", "html", "--output", "rendered.html");
  const html = await readFile(path.join(output, "rendered.html"), "utf8");
  assertPainted(html, code, pdf);
  const pdfFrame = dump.nodes.find((node) => node.id === group.placement.children[1]);
  close(pdf.x, pdfFrame.x, "the expanded PDF must stay inside its allocated cell");
  close(pdf.y, pdfFrame.y, "the expanded PDF must follow vertical positioning");
  close(code.x, group.x, "the code must stay in the first cell");
  close(pdfFrame.x - code.x - code.width, 32, "the columns must retain their gap");
  close(code.width, pdf.width, "the cells must have equal widths");
  close(group.y + group.height, 720 - 232.96, "the group must retain its updated top");
  for (const node of [code, pdf]) {
    assert(node.x >= 0 && node.y >= 0 && node.x + node.width <= 1280 && node.y + node.height <= 720,
      "both drawn leaves must stay on the page");
  }
  run("render", "--quiet", entry, "--output", "rendered.pdf");
  assert.equal((await readFile(path.join(output, "rendered.pdf"))).subarray(0, 5).toString(), "%PDF-");
  const uri = pathToFileURL(path.join(output, entry)).href;
  await withLspClient({ cwd: output }, async (client) => {
    await client.initialize();
    const ready = client.waitForDiagnostics(uri);
    client.openDocument({ uri, text: source });
    assert.deepEqual((await ready).params.diagnostics, []);
    const snapshot = await client.request("ss/editorSnapshot", { textDocument: { uri } });
    assert(!snapshot.stale);
    assertPainted(snapshot.display.html, code, pdf);
    for (const node of [code, pdf]) {
      const preview = snapshot.layout.objects.find((object) => object.id === node.id);
      assert(preview, "the preview must retain the drawn leaf");
      close(preview.x, node.x, "preview x");
      close(preview.y, node.y, "preview y");
    }
  });
}
try {
  const source = await readFile(path.join(root, "tests/fixtures/layout/composition/mixed-display.ss"), "utf8");
  await writeFile(path.join(output, "asset.pdf"), pdfAsset());
  await verify("markdown", source);
  await verify("code", source.replace("let group_item = text! <<\n```c", "let group_item = code! <<").replace("\n```\n>>", "\n>>"));
  console.log("Positioned code and PDF compositions passed through CLI and editor snapshots");
} finally {
  await rm(output, { recursive: true, force: true });
}
