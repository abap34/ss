#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { cp, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { withBrowser } from "../render/capture.mjs";
import { pdfAsset } from "../render/assets.mjs";
import { editorSnapshot, testDocument } from "../editor/fixture.mjs";
import { withLspClient } from "../../runtime/harness.mjs";
import { editorSnapshot as requestEditorSnapshot } from "../../runtime/editor/support.mjs";

const exec = promisify(execFile);
const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const ss = path.resolve(process.argv[2] ?? "zig-out/bin/ss");
const output = path.join(repository, ".test-tmp/presentation-test");
const firstNotes = 'Introduce the topic.\nThen explain "why". <script>window.noteExecuted = true</script>';
const secondNotes = "";
const canRenderLatex = await exec("pdflatex", ["--version"], { timeout: 10_000 }).then(() => true, () => false);
await mkdir(output, { recursive: true });
await writeFile(path.join(output, "asset.pdf"), pdfAsset());
await writeFile(path.join(output, "slide.ss"), `import std:themes/default as *
page first
pagectx().notes = <<
${firstNotes}
>>
text!("Presentation test")
text!("Regular **bold** and emoji 👋 🎉")
${canRenderLatex ? 'text!("Inline mathematics: $x_1^2 + \\alpha$.")' : ""}
end
page second
pagectx().notes = <<
${secondNotes}
>>
pdf!("font.pdf", AssetBlockStyle {} with { asset.scale = 0.5 })
end
`);
await writeFile(path.join(output, "ss.toml"), '[project]\nentry = "slide.ss"\n');
const run = (args, options = {}) => exec(ss, args, { cwd: output, timeout: 120_000, ...options });
await writeFile(path.join(output, "font.ss"), `import std:themes/default as *
page embedded_font
text!("Embedded **bold** font 0123456789")
end
`);
await run(["render", "font.ss", "font.pdf", "--quiet"]);
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
const previewSource = await readFile(path.join(repository, "tests/fixtures/presentation/notes/slide.ss"), "utf8");
await writeFile(path.join(output, "notes.ss"), previewSource.replace("\nend", `${canRenderLatex ? '\ntext!("Inline mathematics: $x_1^2 + \\alpha$.")' : ""}\nend`));
await run(["present", "notes.ss", "notes.html", "--no-open", "--quiet"]);
assert.doesNotMatch(await readFile(path.join(output, "normal.html"), "utf8"), /<html[^>]* data-ss-present[ >]/);
const specialPath = path.join(output, "deck # % slides.html");
const special = await run(["present", "slide.ss", specialPath, "--no-open", "--quiet"]);
assert.equal(fileURLToPath(new URL(special.stdout.trim())), specialPath);
assert(!special.stdout.includes("#"), "file path changed the URL fragment");
await assert.rejects(run(["present", "slide.ss", "--format", "pdf", "--no-open"]), /requires HTML/);
const original = await readFile(path.join(output, "slide.ss"), "utf8");
await withLspClient({ cwd: output }, async (client) => {
  await client.initialize();
  const uri = pathToFileURL(path.join(output, "slide.ss")).href;
  const diagnostics = client.waitForDiagnostics(uri);
  client.openDocument({ uri, text: original });
  assert.deepEqual((await diagnostics).params.diagnostics, []);
  const snapshot = await requestEditorSnapshot(client, uri);
  assert.equal(snapshot.layout.pages[0].notes, firstNotes);
  assert.equal(snapshot.layout.pages[1].notes, secondNotes);
});
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
    // A CLI-opened browser window can finish loading before it gains focus.
    await page.addInitScript(() => {
      let focused = false;
      Object.defineProperty(document, "hasFocus", { configurable: true, value: () => focused });
      globalThis.__focusPresenter = () => {
        focused = true;
        window.dispatchEvent(new Event("focus"));
      };
    });
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
        const snapshot = editorSnapshot();
        snapshot.layout.pages[0].notes = firstNotes;
        snapshot.layout.pages[1].notes = secondNotes;
        await page.evaluate((snapshot) => window.postMessage({ type: "snapshot", revision: 1, snapshot }, "*"), snapshot);
        await page.waitForSelector('.page-shell[data-page-id="11"]');
        await page.evaluate(() => window.postMessage({ type: "startPresentation" }, "*"));
      }
      await page.waitForSelector(".presentation-overlay", { timeout: 5000 });
      await exerciseControlsIntroduction(page, host, output);
      await exerciseSpeakerView(page, host);
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
        assert.equal(await controlsOpacity(page), 1, "restarting must show the controls again");
      }
      assert.deepEqual(errors, [], `${host}: browser errors`);
    } finally {
      await page.close();
    }
  }
  const preview = await browser.newPage({ viewport: { width: 1200, height: 800 } });
  try {
    await preview.goto(`${baseUrl}/notes.html`);
    await preview.waitForFunction(() => document.documentElement.dataset.ssReady === "true");
    await preview.keyboard.press("s");
    const popupPromise = preview.waitForEvent("popup");
    await preview.locator('[data-speaker-action="window"]').click();
    const popup = await popupPromise;
    await popup.locator(".speaker-notes").waitFor();
    assert.equal(await popup.locator(".speaker-notes").textContent(), "Introduce the problem.\nExplain what the audience should take away.");
    await popup.evaluate(() => document.fonts.ready);
    await waitForPdfPreview(popup);
    await assertPreviewRasterMatchesProjection(preview, popup);
    await popup.screenshot({ path: path.join(output, "notes-presenter.png") });
    await popup.locator('[data-speaker-action="theme"]').click();
    await popup.screenshot({ path: path.join(output, "notes-presenter-dark.png") });
    await preview.screenshot({ path: path.join(output, "notes-projection.png") });
    await popup.close();
  } finally {
    await preview.close();
  }
});
console.log("Presentation CLI and shared browser controls passed in standalone HTML and VS Code");

async function waitForPdfPreview(page, selector = ".speaker-preview .ss-pdf") {
  try {
    await page.waitForFunction((selector) => {
      for (const frame of document.querySelectorAll(".speaker-preview")) {
        const slide = frame.querySelector(":scope > .ss-page");
        if (slide && Math.abs(slide.getBoundingClientRect().width - frame.clientWidth) > 0.1) return false;
      }
      return [...document.querySelectorAll(selector)].every((container) => {
        const canvas = container.querySelector(":scope > canvas");
        const bounds = container.getBoundingClientRect();
        const scale = window.devicePixelRatio || 1;
        return container.dataset.ssPdfRendered === "true" &&
          !container.querySelector(":scope > img") && canvas &&
          canvas.width === Math.max(1, Math.round(bounds.width * scale)) &&
          canvas.height === Math.max(1, Math.round(bounds.height * scale));
      });
    }, selector, { timeout: 10_000 });
  } catch (error) {
    console.error(JSON.stringify(await page.evaluate((selector) => ({
      frames: [...document.querySelectorAll(".speaker-preview")].map((frame) => ({
        width: frame.clientWidth, slide: frame.firstElementChild?.getBoundingClientRect().width,
      })),
      pdfs: [...document.querySelectorAll(selector)].map((item) => ({
        bounds: item.getBoundingClientRect().toJSON(), canvas: [...item.querySelectorAll("canvas")].map((canvas) => [canvas.width, canvas.height]),
        error: item.dataset.error, rendered: item.dataset.ssPdfRendered,
      })),
    }), selector)));
    throw error;
  }
}

async function assertPreviewRasterMatchesProjection(projection, presenter) {
  const frame = presenter.locator(".speaker-current .speaker-preview");
  const width = await projection.locator(".presentation-content .ss-page").evaluate((page) => page.getBoundingClientRect().width);
  await frame.evaluate((element, width) => {
    element.style.width = `${width}px`;
    element.closest(".speaker-view").scrollTo(0, 0);
  }, width);
  try {
    await waitForPdfPreview(presenter);
    await waitForPdfPreview(projection, ".presentation-content .ss-pdf");
    const raster = (elements) => elements.map((canvas) => ({
      width: canvas.width, height: canvas.height, pixels: canvas.toDataURL(),
    }));
    const expected = await projection.locator(".presentation-content .ss-pdf > canvas").evaluateAll(raster);
    const actual = await presenter.locator(".speaker-current .ss-pdf > canvas").evaluateAll(raster);
    assert.equal(actual.length, expected.length, "presenter omitted PDF canvases");
    for (let index = 0; index < expected.length; index += 1) {
      assert.deepEqual([actual[index].width, actual[index].height], [expected[index].width, expected[index].height]);
      assert(actual[index].pixels === expected[index].pixels, "PDF pixels changed in the presenter window");
    }
  } finally {
    await frame.evaluate((element) => {
      element.style.removeProperty("width");
      element.closest(".speaker-view").scrollTo(0, 0);
    });
  }
}

async function exerciseSpeakerView(page, host) {
  await page.keyboard.press("Home");
  await page.keyboard.press("s");
  const view = page.locator(".speaker-view");
  await view.waitFor();
  assert.equal(await view.locator(".speaker-notes").textContent(), firstNotes);
  assert.equal(await page.evaluate(() => window.noteExecuted), undefined, "notes were interpreted as HTML");
  assert.equal(await view.locator(".speaker-preview > .ss-page").count(), 2);
  assert.equal(await view.getAttribute("data-theme"), "light");
  await view.locator('[data-speaker-action="theme"]').click();
  assert.equal(await view.getAttribute("data-theme"), "dark");
  await view.locator('[data-speaker-action="theme"]').click();
  assert.equal(await view.getAttribute("data-theme"), "light");
  await waitForPdfPreview(page);
  if (host === "standalone") {
    assert(await view.locator('.ss-text-run').evaluateAll((runs) => runs.some((run) =>
      Number(getComputedStyle(run).fontWeight) >= 700)), "presenter preview lost bold text");
    assert.match(await view.locator(".speaker-current").textContent(), /👋/);
    if (canRenderLatex) assert(await view.locator(".ss-latex").count() > 0);
  }
  assert.equal(await view.locator(".speaker-clock").textContent() === "", false);
  await view.locator('[data-speaker-action="pause"]').click();
  await view.locator('[data-speaker-action="reset"]').click();
  assert.equal(await view.locator(".speaker-elapsed").textContent(), "00:00:00");
  await page.waitForTimeout(1100);
  assert.equal(await view.locator(".speaker-elapsed").textContent(), "00:00:00", "paused timer kept running");
  await view.locator('[data-speaker-action="pause"]').click();
  await page.waitForFunction(() => document.querySelector(".speaker-elapsed").textContent !== "00:00:00");
  await view.locator('[data-speaker-action="next"]').click();
  assert.equal(await view.locator(".speaker-notes").textContent(), secondNotes);
  await waitForPdfPreview(page);
  assert.notEqual(await view.locator(".speaker-elapsed").textContent(), "00:00:00", "navigation reset the timer");
  assert.equal(await view.locator(".speaker-upcoming").textContent(), "End of presentation");
  await view.locator(".speaker-notes").focus();
  await page.keyboard.press("ArrowLeft");
  assert.equal(await view.locator(".speaker-counter").textContent(), "2 / 2", "reading notes navigated slides");
  await view.locator('[data-speaker-action="previous"]').click();
  if (host === "standalone") {
    await page.evaluate(() => {
      globalThis.__windowOpen = window.open;
      window.open = () => null;
    });
    await view.locator('[data-speaker-action="window"]').click();
    assert.match(await view.locator(".speaker-status").textContent(), /Allow pop-up windows/);
    await page.evaluate(() => { window.open = globalThis.__windowOpen; });
    const popupPromise = page.waitForEvent("popup");
    await view.locator('[data-speaker-action="window"]').click();
    const popup = await popupPromise;
    const errors = [];
    popup.on("pageerror", (error) => errors.push(error.message));
    try {
      await popup.locator(".speaker-view").waitFor();
      assert.equal(await popup.locator(".speaker-view").getAttribute("data-theme"), "light");
      await waitForPdfPreview(popup);
      assert.equal(await view.count(), 0, "opening presenter window did not restore projected slides");
      assert.equal(await popup.locator(".speaker-notes").textContent(), firstNotes);
      assert.equal(await page.locator(".presentation-content .ss-page").count(), 1);
      await popup.locator('[data-speaker-action="next"]').click();
      assert.equal(await page.locator(".presentation-counter").textContent(), "2 / 2");
      assert.equal(await popup.locator(".speaker-notes").textContent(), secondNotes);
      await popup.waitForSelector('.speaker-current .ss-pdf[data-ss-pdf-rendered="true"]');
      await waitForPdfPreview(popup);
      await assertPreviewRasterMatchesProjection(page, popup);
      await page.keyboard.press("Home");
      assert.equal(await popup.locator(".speaker-counter").textContent(), "1 / 2", "projection navigation did not update speaker view");
      await assertPreviewRasterMatchesProjection(page, popup);
      await popup.screenshot({ path: path.join(output, "speaker-window.png") });
      await popup.keyboard.press("End");
      assert.equal(await page.locator(".presentation-counter").textContent(), "2 / 2");
      assert.deepEqual(errors, []);
    } finally {
      await popup.close();
    }
    await page.keyboard.press("s");
    const reopenedPromise = page.waitForEvent("popup");
    await view.locator('[data-speaker-action="window"]').click();
    const reopened = await reopenedPromise;
    await reopened.locator(".speaker-view").waitFor();
    assert.equal(await reopened.locator(".speaker-counter").textContent(), "2 / 2");
    const closed = reopened.waitForEvent("close");
    await page.keyboard.press("Escape");
    await closed;
    await page.keyboard.press("p");
  } else {
    assert.equal(await view.locator('[data-speaker-action="window"]').count(), 0);
    await view.locator('[data-speaker-action="slides"]').click();
  }
  await page.keyboard.press("Home");
}

async function controlsOpacity(page) {
  return page.locator(".presentation-controls").evaluate((bar) => Number(getComputedStyle(bar).opacity));
}

async function exerciseControlsIntroduction(page, host, output) {
  const bar = page.locator(".presentation-controls");
  // Wait past the entire introduction while the browser is not yet focused.
  await page.waitForTimeout(3100);
  await page.evaluate(() => globalThis.__focusPresenter());
  assert.equal(await controlsOpacity(page), 1, `${host}: controls faded before the window gained focus`);
  const bounds = await bar.boundingBox();
  assert(Math.abs(bounds.x + bounds.width / 2 - 600) < 1, `${host}: controls are not horizontally centered`);
  assert(Math.abs(bounds.y + bounds.height - 782) < 1, `${host}: controls are not at the bottom`);
  await page.screenshot({ path: path.join(output, `${host}-controls-intro.png`) });
  // Rebuilding the overlay must keep the original introduction's progress.
  await page.waitForTimeout(700);
  await page.keyboard.press("ArrowRight");
  assert.equal(await controlsOpacity(page), 1, `${host}: navigation hid the controls during the introduction`);
  await page.waitForFunction(() => {
    const opacity = Number(getComputedStyle(document.querySelector(".presentation-controls")).opacity);
    return opacity > 0 && opacity < 1;
  }, null, { timeout: 2500 });
  await page.waitForFunction(() => getComputedStyle(document.querySelector(".presentation-controls")).opacity === "0", null, { timeout: 1500 });
  await page.keyboard.press("Home");
  assert.equal(await controlsOpacity(page), 0, `${host}: navigation restarted the introduction`);
  await page.mouse.move(100, 100);
  assert.equal(await controlsOpacity(page), 1, `${host}: moving the pointer did not reveal the controls`);
  await bar.hover();
  await page.waitForFunction(() => getComputedStyle(document.querySelector(".presentation-controls")).opacity === "1");
  await page.mouse.move(10, 10);
}
