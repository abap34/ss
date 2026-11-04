import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { root, ssBin } from "../harness.mjs";

const scratch = path.join(root, ".test-tmp/width-allocation");
await mkdir(scratch, { recursive: true });
const output = await mkdtemp(path.join(scratch, "layout-"));
const source = path.join(root, "tests/fixtures/layout/width-allocation/slide.ss");
const close = (actual, expected) => assert(Math.abs(actual - expected) < 0.1, `${actual} != ${expected}`);
function run(...args) {
  const result = spawnSync(ssBin, args, { cwd: output, encoding: "utf8", timeout: 60000 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
}
try {
  run("check", "--quiet", source);
  run("dump", "--quiet", source, "--output", "dump.json");
  const dump = JSON.parse(await readFile(path.join(output, "dump.json"), "utf8"));
  assert.deepEqual(dump.diagnostics, []);
  const byId = id => dump.nodes.find(node => node.id === id);
  const children = node => node.placement.children.map(byId);
  const roots = dump.page_order.map(page => dump.nodes.find(node => node.placement?.page === page && node.placement.parent === page));
  close(roots[0].x, 96);
  close(roots[0].width, 1088);
  for (const index of [1, 2]) {
    const [text, image] = children(roots[index]);
    close(text.width, 756);
    close(image.width, 300);
    close(image.x - text.x - text.width, 32);
    close(roots[index].width, 1088);
  }
  const [image, text] = children(roots[3]);
  close(image.width, 300);
  close(text.width, 756);
  close(text.x - image.x - image.width, 32);
  const [column, nestedImage] = children(roots[4]);
  close(column.width, 756);
  close(nestedImage.width, 300);
  for (const child of children(column)) close(child.width, 756);
  const [pair, last] = children(roots[5]);
  close(pair.width, 544);
  close(last.width, 512);
  for (const child of children(pair)) close(child.width, 256);
  for (const child of children(roots[6])) close(child.width, (1088 - 64) / 3);
  const [paddedText, paddedImage] = children(roots[7]);
  close(paddedText.width, 732);
  close(paddedImage.width, 324);
  close(roots[8].width, 300);
  assert(roots[8].height > roots[2].placement.children.map(byId)[0].height);
  close(roots[9].width, 150);
  close(roots[9].height, 75);
  close(roots[10].width, 500);
  close(roots[10].height, 150);
  for (const child of children(roots[11])) {
    close(child.width, 150);
    close(child.height, 75);
  }
  close(roots[13].width, 250);
  assert(roots[13].height > roots[12].height * 2, "Code did not grow after wrapping");
  const wrappedLeaf = children(roots[13])[0];
  assert.equal(wrappedLeaf.placement.display.kind, "text");
  assert.equal(wrappedLeaf.render.kind, "code");
  for (const [index, x, width] of [[14, 200, 984], [15, 96, 904], [16, 96, 1008], [17, 200, 400]]) {
    close(roots[index].x, x);
    close(roots[index].width, width);
  }
  for (const index of [18, 19]) {
    const pair = children(roots[index]);
    const text = pair.find(node => node.placement.display.kind === "text");
    const shape = pair.find(node => node.placement.display.kind === "path_shape");
    close(text.width, 896);
    close(shape.width, 160);
  }
  const paddedPair = children(roots[20]);
  close(paddedPair[0].width, 520);
  close(paddedPair[1].width, 536);
  const boundedColumn = children(roots[21])[0];
  close(boundedColumn.width, 268);
  for (const child of children(boundedColumn)) close(child.width, 268);
  close(roots[22].width, 0.3);
  close(roots[22].height, 0.15);
  close(roots[23].width, 0.3);
  close(roots[23].height, 0.15);
  const iconLeaf = children(roots[24])[0];
  close(roots[24].width, 100);
  close(roots[24].height, 10);
  close(iconLeaf.width, 100);
  close(iconLeaf.height, 10);
  const codeLeaf = children(roots[25])[0];
  close(roots[25].height, codeLeaf.height);
  close(roots[25].width, codeLeaf.width);
  assert(roots[25].height > 16);
  run("render", "--quiet", source, "--output", "slides.pdf");
  assert.equal((await readFile(path.join(output, "slides.pdf"))).subarray(0, 5).toString(), "%PDF-");
  const picturePath = path.join(root, "tests/fixtures/layout/width-allocation/diagram.svg");
  for (const [name, statements, diagnostic] of [
    ["shortage", `place!(text("Body") || image("${picturePath}", AssetBlockStyle {} with { asset.scale = 4 }))`, "InvalidWidthAllocation"],
    ["manual", `place!(group(text("A"), text("B")) || image("${picturePath}"))`, "UnboundedGroupWidth"],
    ["padding", `let body = text!("Body", TextBlockStyle {} with { chrome.pad_x = 12 })\n  ~ body.width == 24`, "InvalidWidthAllocation"],
    ["zero-height", `let body = text!("Body")\n  ~ body.height == 0`, "InvalidFrameSize"],
    ["zero-scale", `image!("${picturePath}", AssetBlockStyle {} with { asset.scale = 0 })`, "InvalidNativeDisplay"],
    ["negative-padding", `text!("Body", TextBlockStyle {} with { chrome.pad_x = -1 })`, "InvalidNativeDisplay"],
  ]) {
    await writeFile(path.join(output, `${name}.ss`), `import std:prelude as *\nimport std:text/style as { TextBlockStyle }\nimport std:assets/style as { AssetBlockStyle }\npage invalid\n  ${statements}\nend\n`);
    const result = spawnSync(ssBin, ["check", "--quiet", `${name}.ss`], { cwd: output, encoding: "utf8", timeout: 60000 });
    assert.ifError(result.error);
    assert.notEqual(result.status, 0, name);
    assert.match(result.stderr, new RegExp(diagnostic), name);
    assert.doesNotMatch(result.stderr, /panic:/);
  }
  const probe = spawnSync("pdflatex", ["--version"], { timeout: 10000 });
  if (probe.error?.code !== "ENOENT") {
    assert.ifError(probe.error);
    assert.equal(probe.status, 0);
    const formula = String.raw`\begin{aligned}x &= a+b\\y &= c+d\end{aligned}`;
    const cases = [
      ["short", "Short", false],
      ["long", "A substantially longer paragraph changes the amount of prose preceding the formula.", false],
      ["row_short", "Short", true],
      ["row_long", "A substantially longer paragraph changes the amount of prose preceding the formula.", true],
    ];
    const picture = path.join(root, "tests/fixtures/layout/width-allocation/diagram.svg");
    const mathSource = "import std:prelude as *\n" + cases.map(([name, prose, row]) => `
page ${name}
  let body = text(<<
${prose}

$$
${formula}
$$
>>)
  let content = place!(${row ? `body || image("${picture}")` : "body"})
end
`).join("\n") + `
page separate_math
  let content = place!(text("Short") // math(<<
${formula}
>>))
end
`;
    await writeFile(path.join(output, "math.ss"), mathSource);
    run("render", "--quiet", "--format", "html", "math.ss", "math.html");
    const html = await readFile(path.join(output, "math.html"), "utf8");
    const boxes = [...html.matchAll(/<(?:span|div) class="ss-item ss-latex ss-pdf"[^>]*style="([^"]*)"/g)].map(match => {
      const values = {};
      for (const key of ["left", "width"]) {
        const value = new RegExp(`(?:^|;)${key}:([-0-9.]+)pt(?:;|$)`).exec(match[1]);
        assert(value, match[1]);
        values[key] = Number(value[1]);
      }
      return values;
    });
    assert.equal(boxes.length, 5);
    close(boxes[0].left, boxes[1].left);
    close(boxes[2].left, boxes[3].left);
    for (const index of [0, 1, 4]) close(boxes[index].left, 96 + (1088 - boxes[index].width) / 2);
    for (const index of [2, 3]) close(boxes[index].left, 96 + (756 - boxes[index].width) / 2);
    console.log("Width allocation: real TeX positions passed");
  } else {
    console.log("Width allocation: real TeX positions skipped because pdflatex is unavailable");
  }
} finally {
  await rm(output, { recursive: true, force: true });
}
