#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { cp, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { withBrowser } from "../render/capture.mjs";
import { pdfAsset } from "../render/assets.mjs";
import { editorSnapshot, testDocument } from "../editor/fixture.mjs";

const exec = promisify(execFile);
const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const ss = path.resolve(process.argv[2] ?? "zig-out/bin/ss");
const output = path.join(repository, ".ss-cache/presentation-test");
await mkdir(output, { recursive: true });
await writeFile(path.join(output, "asset.pdf"), pdfAsset());
await writeFile(path.join(output, "slide.ss"), `import std:themes/default as *
page first
text!("Presentation test")
end
page second
pdf!("asset.pdf", 1.0, 1)
end
`);
await writeFile(path.join(output, "ss.toml"), '[project]\nentry = "slide.ss"\n');
const run = (args, options = {}) => exec(ss, args, { cwd: output, timeout: 120_000, ...options });
assert.match((await run(["help", "present"])).stdout, /--no-open/);
for (const shell of ["bash", "zsh", "fish"]) {
  const completion = (await run(["completion", shell, "--print"])).stdout;
  assert.match(completion, /present/);
  assert.match(completion, /--no-open|no-open/);
}
const { stdout } = await run(["present", "--no-open", "--quiet", "--project", "."]);
const url = new URL(stdout.trim());
assert.equal(url.protocol, "file:");
assert.equal(url.search, "", "present must not require a query to survive the desktop file opener");
assert(fileURLToPath(url).startsWith(path.join(output, ".ss-cache/present/")));
assert.match(await readFile(fileURLToPath(url), "utf8"), /<html[^>]* data-ss-present[ >]/);
await run(["render", "slide.ss", "normal.html", "--format", "html", "--quiet"]);
assert.doesNotMatch(await readFile(path.join(output, "normal.html"), "utf8"), /<html[^>]* data-ss-present[ >]/);
const specialPath = path.join(output, "deck # % slides.html");
const special = await run(["present", "slide.ss", specialPath, "--no-open", "--quiet"]);
assert.equal(fileURLToPath(new URL(special.stdout.trim())), specialPath);
assert(!special.stdout.includes("#"), "file path changed the URL fragment");
await assert.rejects(run(["present", "slide.ss", "--format", "pdf", "--no-open"]), /requires HTML/);
const original = await readFile(path.join(output, "slide.ss"), "utf8");
await assert.rejects(run(["present", "slide.ss", "--output", "slide.ss", "--no-open"]));
assert.equal(await readFile(path.join(output, "slide.ss"), "utf8"), original);

// Capture the platform opener's argument without launching a desktop application.
const launcher = process.platform === "darwin" ? "open" : "xdg-open";
await mkdir(path.join(output, "bin"), { recursive: true });
await writeFile(path.join(output, "bin", launcher), '#!/bin/sh\nprintf "%s\\n" "$1" > opened-url.txt\n', { mode: 0o755 });
const opened = await run(["present", "slide.ss", "--quiet"], {
  env: { ...process.env, PATH: `${path.join(output, "bin")}:${process.env.PATH}` },
});
assert.equal(await readFile(path.join(output, "opened-url.txt"), "utf8"), opened.stdout);
await writeFile(path.join(output, "bin", launcher), '#!/bin/sh\nexit 1\n', { mode: 0o755 });
await assert.rejects(run(["present", "slide.ss", "--quiet"], {
  env: { ...process.env, PATH: `${path.join(output, "bin")}:${process.env.PATH}` },
}), /could not open the browser/);

await cp(path.join(repository, "editor/vscode/media"), path.join(output, "media"), { recursive: true });
await cp(path.join(repository, "editor/vscode/out"), path.join(output, "out"), { recursive: true });
await writeFile(path.join(output, "media/editor/index.html"), testDocument());
await cp(path.join(output, "asset.pdf"), path.join(output, "media/editor/asset.pdf"));

await withBrowser(output, async (browser, baseUrl) => {
  for (const host of ["standalone", "vscode"]) {
    const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    page.on("console", (message) => {
      if (message.type() === "error") errors.push(message.text());
    });
    try {
      if (host === "standalone") {
        // Desktop file openers may discard URL queries before launching a browser.
        const openedUrl = new URL(url);
        openedUrl.search = "";
        await page.goto(openedUrl.href);
        await page.waitForFunction(() => document.documentElement.dataset.ssReady === "true");
      } else {
        await page.goto(`${baseUrl}/media/editor/index.html`);
        await page.waitForFunction(() => globalThis.__messages?.some((message) => message.type === "ready"));
        await page.evaluate((snapshot) => window.postMessage({ type: "snapshot", revision: 1, snapshot }, "*"), editorSnapshot());
        await page.waitForSelector('.page-shell[data-page-id="11"]');
        await page.evaluate(() => window.postMessage({ type: "startPresentation" }, "*"));
      }
      await page.waitForSelector(".presentation-overlay", { timeout: 5000 });
      const counter = page.locator(".presentation-counter");
      assert.equal(await counter.textContent(), "1 / 2");
      await page.keyboard.press("ArrowRight");
      assert.equal(await counter.textContent(), "2 / 2", `${host}: one key advanced more than one slide`);
      await page.keyboard.press("ArrowRight");
      assert.equal(await counter.textContent(), "2 / 2");
      await page.keyboard.press("Home");
      assert.equal(await counter.textContent(), "1 / 2");
      await page.locator('[data-control-kind="pen"]').click({ force: true });
      const bounds = await page.locator(".presentation-page").boundingBox();
      assert(bounds.width > 100 && bounds.height > 100);
      await page.mouse.move(bounds.x + 80, bounds.y + 80);
      await page.mouse.down();
      await page.mouse.move(bounds.x + 150, bounds.y + 130, { steps: 5 });
      await page.mouse.up();
      assert.equal(await page.locator(".presentation-ink-stroke").count(), 1);
      await page.keyboard.press("End");
      assert.equal(await page.locator(".presentation-ink-stroke").count(), 0);
      await page.keyboard.press("Home");
      assert.equal(await page.locator(".presentation-ink-stroke").count(), 1);
      await page.keyboard.press("Control+z");
      assert.equal(await page.locator(".presentation-ink-stroke").count(), 0);
      await page.locator('[data-control-kind="laser"]').click({ force: true });
      await page.mouse.move(400, 300);
      assert.equal(await page.locator(".presentation-laser-dot").isVisible(), true);
      await page.locator(".presentation-stage").dispatchEvent("wheel", { ctrlKey: true, deltaY: -100, clientX: 500, clientY: 400 });
      const zoomed = await page.locator(".presentation-page").boundingBox();
      assert(zoomed.width > bounds.width, `${host}: pinch zoom had no effect`);
      if (host === "standalone") {
        await page.keyboard.press("End");
        await page.waitForSelector('.presentation-content .ss-pdf[data-ss-pdf-rendered="true"]');
        await page.evaluate(() => globalThis.ssDocument.prepareForPrint());
        assert.equal(await page.locator(".ss-document > .ss-page").count(), 2);
        assert.equal(await page.locator(".presentation-overlay").isVisible(), false);
        await page.evaluate(() => globalThis.ssDocument.finishPrint());
        assert.equal(await counter.textContent(), "2 / 2");
        await page.evaluate(() => window.dispatchEvent(new Event("beforeprint")));
        assert.equal(await page.locator(".ss-document > .ss-page").count(), 2);
        await page.evaluate(() => window.dispatchEvent(new Event("afterprint")));
        assert.equal(await page.locator(".presentation-content .ss-page").count(), 1);
        await page.keyboard.press("f");
        await page.waitForFunction(() => document.fullscreenElement !== null);
        await page.keyboard.press("f");
        await page.waitForFunction(() => document.fullscreenElement === null);
        await page.screenshot({ path: path.join(output, "presenter.png") });
      }
      await page.keyboard.press("Escape");
      assert.equal(await page.locator(".presentation-overlay").count(), 0);
      if (host === "standalone") {
        assert.equal(await page.locator(".ss-document > .ss-page").count(), 2);
        await page.keyboard.press("p");
        assert.equal(await counter.textContent(), "2 / 2");
      }
      assert.deepEqual(errors, [], `${host}: browser errors`);
    } finally {
      await page.close();
    }
  }
});
console.log("Presentation CLI and shared browser controls passed in standalone HTML and VS Code");
