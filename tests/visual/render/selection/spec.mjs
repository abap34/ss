#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { withBrowser } from "../capture.mjs";

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../..");
const ss = path.resolve(repository, process.argv[2] ?? "zig-out/bin/ss");
const parent = path.join(repository, ".test-tmp/render-selection");
await mkdir(parent, { recursive: true });
const output = await mkdtemp(path.join(parent, "run-"));
await writeFile(path.join(output, "slide.ss"), `import std:themes/default as *
page selection
let plain = text!("Plain selection target with AV pairs and office ligatures")
~ plain.left == page.left + 96
~ plain.right == page.right - 96
~ plain.top == page.top - 96
let linked = text!("[A long link that wraps across several lines](https://example.invalid/target)")
~ linked.left == page.left + 96
~ linked.right == linked.left + 240
~ linked.top == page.top - 200
let mixed = text!("Normal **bold** and *italic* text")
~ mixed.left == page.left + 96
~ mixed.right == page.right - 96
~ mixed.top == page.top - 360
let unicode = text!("日本語の文字列を選択できます")
~ unicode.left == page.left + 96
~ unicode.right == page.right - 96
~ unicode.top == page.top - 450
end
`);
for (const [command, file] of [["render", "normal.html"], ["present", "present.html"]]) {
  const options = command === "present" ? ["--no-open"] : ["--format", "html"];
  execFileSync(ss, [command, "--quiet", ...options, "slide.ss", file], { cwd: output, timeout: 60_000 });
}

await withBrowser(output, async (browser, baseUrl) => {
  for (const file of ["normal.html", "present.html"]) {
    for (const protocol of ["http", "file"]) {
      const url = protocol === "http" ? `${baseUrl}/${file}` : pathToFileURL(path.join(output, file)).href;
      const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
      try {
        page.setDefaultTimeout(10_000);
        await page.route("https://example.invalid/**", (route) => route.fulfill({ body: "destination" }));
        await page.goto(url);
        await page.waitForFunction(() => document.documentElement.dataset.ssReady === "true");
        const runs = page.locator(".ss-text-run");
        const count = await runs.count();
        assert(count > 5, "the fixture must include wrapping and changes of font");
        for (let index = 0; index < count; index += 1) {
          const run = runs.nth(index);
          const selection = run.locator(".ss-text-select");
          const expected = await selection.textContent();
          if (!expected.trim()) continue;
          const bounds = await paintedBounds(run);
          for (const fraction of [0.25, 0.5, 0.75]) {
            for (const reverse of [false, true]) {
              const actual = await drag(page, bounds.first.x + 0.1, bounds.last.x + bounds.last.width - 0.1,
                bounds.first.y + bounds.first.height * fraction, reverse);
              assert.equal(actual.trim(), expected.trim(), `${file} ${protocol} run ${index}: drag at ${fraction}, reverse=${reverse}`);
              assert.equal(page.url(), url, "selecting linked text must not navigate");
            }
          }
        }

        const groups = await page.locator(".ss-text[data-ss-node-id]").evaluateAll((items) => {
          const groups = new Map();
          for (const item of items) {
            const id = item.dataset.ssNodeId;
            groups.set(id, (groups.get(id) ?? "") + [...item.querySelectorAll(".ss-text-select")].map((run) => run.textContent).join(""));
          }
          return [...groups].map(([id, text]) => ({ id, text }));
        });
        for (const expected of ["Normal bold and italic text", "日本語の文字列を選択できます"]) {
          const group = groups.find((group) => group.text === expected);
          assert(group, `missing text group: ${expected}`);
          const groupRuns = page.locator(`.ss-text[data-ss-node-id="${group.id}"] .ss-text-run`);
          const first = (await paintedBounds(groupRuns.first())).first;
          const last = (await paintedBounds(groupRuns.last())).last;
          for (const reverse of [false, true]) {
            assert.equal(await drag(page, first.x + 0.1, last.x + last.width - 0.1,
              first.y + first.height / 2, reverse), expected, "selection across adjacent text fragments lost text or duplicated it");
          }
        }

        const word = (await paintedBounds(runs.first())).boxes[10];
        await page.mouse.dblclick(word.x + word.width / 2, word.y + word.height / 2);
        assert.equal(await page.evaluate(() => getSelection().toString()), "selection", "double click must select the visible word");

        const links = page.locator(".ss-text-select.ss-link");
        assert(await links.count() >= 2, "linked selection must wrap across lines");
        for (const link of await links.all()) {
          assert.equal(await link.getAttribute("draggable"), "false");
          assert((await link.textContent()).length > 0, "a text link must contain its selectable text");
        }

        const firstLink = await paintedBounds(links.first().locator(".."));
        const lastLink = await paintedBounds(links.last().locator(".."));
        await page.evaluate(() => getSelection().removeAllRanges());
        await page.mouse.move(firstLink.first.x + 0.1, firstLink.first.y + firstLink.first.height / 2);
        await page.mouse.down();
        await page.mouse.move(lastLink.last.x + lastLink.last.width - 0.1,
          lastLink.last.y + lastLink.last.height / 2, { steps: 20 });
        await page.mouse.up();
        const linkedSelection = await page.evaluate(() => getSelection().toString());
        assert.equal(linkedSelection.replace(/\s+/g, " ").trim(), "A long link that wraps across several lines");

        if (file === "present.html") {
          const bounds = await paintedBounds(runs.first());
          for (const tool of ["pen", "laser"]) {
            const button = page.locator(`[data-control-kind="${tool}"]`);
            await button.click();
            assert.equal(await drag(page, bounds.first.x + 1, bounds.last.x + bounds.last.width - 1,
              bounds.first.y + bounds.first.height / 2, false), "", `${tool}: text was selected while drawing`);
            await button.click();
          }
        }

        await page.evaluate(() => getSelection().removeAllRanges());
        const slide = page.locator(".ss-page").first();
        const before = await slide.screenshot();
        await page.addStyleTag({ content: ".ss-text-select { visibility: hidden !important; }" });
        const after = await slide.screenshot();
        assert(before.equals(after), "the selection layer changed the painted slide");

        await page.goto(url);
        await page.waitForFunction(() => document.documentElement.dataset.ssReady === "true");
        const selectedLink = await paintedBounds(page.locator(".ss-text-run:has(.ss-link)").first());
        await drag(page, selectedLink.first.x + 0.1, selectedLink.last.x + selectedLink.last.width - 0.1,
          selectedLink.first.y + selectedLink.first.height / 2, false);
        await page.locator(".ss-text-select.ss-link").first().click();
        await page.waitForURL("https://example.invalid/target");
      } finally {
        await page.close();
      }
    }
  }
});
console.log("HTML and presentation text: native dragging selects plain, linked, styled, and Unicode text without changing pixels");

async function paintedBounds(run) {
  return run.locator(".ss-text-paint").evaluate((element) => {
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    const boxes = [];
    while (walker.nextNode()) {
      const node = walker.currentNode;
      for (let offset = 0; offset < node.length; offset += 1) {
        const range = document.createRange();
        range.setStart(node, offset);
        range.setEnd(node, offset + 1);
        const box = range.getBoundingClientRect();
        boxes.push({ text: node.data[offset], x: box.x, y: box.y, width: box.width, height: box.height });
      }
    }
    const visible = boxes.filter((box) => box.text.trim().length > 0);
    return { first: visible[0], last: visible.at(-1), boxes };
  });
}

async function drag(page, left, right, y, reverse) {
  await page.evaluate(() => getSelection().removeAllRanges());
  await page.mouse.move(reverse ? right : left, y);
  await page.mouse.down();
  await page.mouse.move(reverse ? left : right, y, { steps: 12 });
  await page.mouse.up();
  return page.evaluate(() => getSelection().toString());
}
