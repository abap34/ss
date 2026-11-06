import assert from "node:assert/strict";

export async function exercisePageNavigation(browser, baseUrl, snapshot) {
  const page = await browser.newPage({ viewport: { width: 1100, height: 800 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const post = (message) => page.evaluate((value) => window.postMessage(value, "*"), message);
  const selected = () => page.locator(".page-entry.is-active").getAttribute("data-page-id");
  try {
    await page.goto(`${baseUrl}/index.html`, { waitUntil: "networkidle" });
    await post({ type: "snapshot", revision: 1, documentVersion: 1, snapshot });
    await page.waitForSelector('.page-shell[data-page-id="11"]');
    const source = page.locator('.page-shell[data-page-id="11"] .page-source-button');
    const sourceOpacity = () => source.evaluate((button) => getComputedStyle(button).opacity);
    await page.locator('.page-entry[data-page-id="11"]').hover();
    assert.equal(await sourceOpacity(), "0", "the page source action must be hidden by default");
    await page.locator('.page-shell[data-page-id="11"]').hover({ position: { x: 10, y: 10 } });
    assert.equal(await sourceOpacity(), "1", "hovering a slide must reveal its source action");
    await source.click();
    assert.deepEqual(await page.evaluate(() => globalThis.__messages.findLast((message) =>
      message.type === "revealSource")), {
      type: "revealSource", path: "/workspace/slide.ss", start: 0, end: 30,
    });
    await page.locator('.page-entry[data-page-id="11"]').hover();
    assert.equal(await sourceOpacity(), "0", "leaving a slide must hide its source action");
    await page.keyboard.press("Tab");
    await source.focus();
    assert.equal(await source.evaluate((button) => button.matches(":focus-visible")), true);
    assert.equal(await sourceOpacity(), "1", "keyboard focus must reveal the source action");
    await page.keyboard.press("Enter");
    assert.equal(await page.evaluate(() => globalThis.__messages.filter((message) =>
      message.type === "revealSource").length), 2, "keyboard activation must still jump to source");
    await source.evaluate((button) => button.blur());
    assert.equal(await sourceOpacity(), "0", "removing keyboard focus must hide the source action");
    await post({ type: "revealPage", snapshotId: snapshot.snapshot_id, revision: 1, pageId: 22 });
    await page.waitForFunction(() => document.querySelector('.page-entry.is-active')?.dataset.pageId === "22");
    await page.waitForFunction(() => {
      const box = document.querySelector('.page-shell[data-page-id="22"]')?.getBoundingClientRect();
      return box && box.top < innerHeight && box.bottom > 0;
    });

    await post({ type: "revealPage", snapshotId: "obsolete", revision: 0, pageId: 11 });
    assert.equal(await selected(), "22", "an old navigation request must not move the preview");

    // Navigation can arrive while a newer snapshot is deferred by an interaction.
    await post({ type: "revealPage", snapshotId: "next", revision: 2, pageId: 11 });
    assert.equal(await selected(), "22");
    await post({ type: "snapshot", revision: 2, documentVersion: 1, snapshot: { ...snapshot, snapshot_id: "next" } });
    await page.waitForFunction(() => document.querySelector('.page-entry.is-active')?.dataset.pageId === "11");
    assert.deepEqual(errors, []);
  } finally {
    await page.close();
  }
}
