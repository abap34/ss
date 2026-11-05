#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { withBrowser } from "../capture.mjs";

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../..");
const ss = path.resolve(repository, process.argv[2] ?? "zig-out/bin/ss");
const parent = path.join(repository, ".test-tmp/render-links");
await mkdir(parent, { recursive: true });
const output = await mkdtemp(path.join(parent, "run-"));
const target = "https://example.invalid/reference?a=1&b=2";
await writeFile(path.join(output, "slide.ss"), `import std:themes/default as *
page links
let body = text!("[A long link that wraps across several lines](${target})")
~ body.left == page.left + 96
~ body.right == body.left + 240
~ body.top == page.top - 96
end
`);
execFileSync(ss, ["render", "--quiet", "--format", "html", "slide.ss", "links.html"], {
  cwd: output, timeout: 60_000,
});
execFileSync(ss, ["present", "--no-open", "--quiet", "slide.ss", "present.html"], {
  cwd: output, timeout: 60_000,
});

await withBrowser(output, async (browser, baseUrl) => {
  const urls = ["links.html", "present.html"].flatMap((file) => [
    `${baseUrl}/${file}`, pathToFileURL(path.join(output, file)).href,
  ]);
  for (const url of urls) {
    const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
    try {
      page.setDefaultTimeout(10_000);
      await page.route("https://example.invalid/**", (route) => route.fulfill({
        contentType: "text/html", body: "<title>Link destination</title>",
      }));
      await page.goto(url);
      await page.waitForFunction(() => document.documentElement.dataset.ssReady === "true");
      const links = page.locator(".ss-link");
      const count = await links.count();
      assert(count >= 2, "the fixture must wrap its link across multiple rectangles");
      if (url.includes("/present.html")) await exerciseTools(page, links.first(), url);
      for (let index = 0; index < count; index += 1) {
        if (index > 0) {
          await page.goto(url);
          await page.waitForFunction(() => document.documentElement.dataset.ssReady === "true");
        }
        const link = links.nth(index);
        assert.equal(await link.getAttribute("href"), target);
        const bounds = await link.boundingBox();
        assert(bounds?.width > 0 && bounds.height > 0, "a link has no clickable rectangle");
        await link.hover();
        assert.equal(await link.evaluate((element) => getComputedStyle(element).cursor), "pointer");
        await link.click();
        await page.waitForURL(target);
        assert.equal(await page.title(), "Link destination");
      }
    } finally {
      await page.close();
    }
  }
});
console.log("HTML and presentation links: every wrapped rectangle navigates over HTTP and file URLs");

async function exerciseTools(page, link, url) {
  for (const tool of ["pen", "laser"]) {
    const button = page.locator(`[data-control-kind="${tool}"]`);
    await button.click();
    assert.equal(await link.evaluate((element) => getComputedStyle(element).pointerEvents), "none");
    const bounds = await link.boundingBox();
    const x = bounds.x + bounds.width / 2;
    const y = bounds.y + bounds.height / 2;
    await page.mouse.move(x, y);
    await page.mouse.down();
    await page.mouse.move(x + 20, y + 10, { steps: 5 });
    await page.mouse.up();
    assert.equal(page.url(), url, `${tool}: a link navigated while a presentation tool was active`);
    if (tool === "pen") assert.equal(await page.locator(".presentation-ink-stroke").count(), 1);
    else assert(await page.locator(".presentation-laser-dot").isVisible());
    await button.click();
    assert.equal(await link.evaluate((element) => getComputedStyle(element).pointerEvents), "auto");
  }
}
