import assert from "node:assert/strict";

export async function exerciseRestart(browser, baseUrl, snapshot) {
  const page = await browser.newPage({ viewport: { width: 1100, height: 800 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  try {
    await page.goto(`${baseUrl}/index.html`, { waitUntil: "networkidle" });
    await post(page, { type: "snapshot", revision: 1, documentVersion: 1, buildDurationMs: 1, snapshot });
    await page.waitForSelector(".page-shell");
    const restart = page.getByRole("button", { name: "Restart WYSIWYG language server", exact: true });
    assert.equal(await restart.locator("svg").count(), 1);
    await page.locator(".zoom-select").selectOption("actual");
    await restart.click();
    await page.waitForFunction(() => globalThis.__messages.some((message) => message.type === "restart"));
    await post(page, { type: "serverRestarting", revision: 2 });
    await page.waitForFunction(() => document.querySelector(".build-status-label")?.textContent === "Restarting…");
    assert.equal(await restart.isDisabled(), true);
    assert.equal(await page.locator(".page-shell").count(), 0);
    await post(page, { type: "snapshot", revision: 1, documentVersion: 1, buildDurationMs: 1, snapshot });
    assert.equal(await page.locator(".page-shell").count(), 0, "an old snapshot survived restart");
    await post(page, { type: "snapshot", revision: 3, documentVersion: 1, buildDurationMs: 1, snapshot });
    await page.waitForSelector(".page-shell");
    assert.equal(await restart.isEnabled(), true);
    assert.equal(await page.locator(".zoom-select").inputValue(), "actual");
    assert.equal(await page.locator(".build-status-label").textContent(), "Build complete");

    // Restart from the command palette must also cancel an active pointer drag.
    const target = page.locator('.object-hit[data-object-id="101"]');
    await target.scrollIntoViewIfNeeded();
    const box = await target.boundingBox();
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width / 2 + 20, box.y + box.height / 2 + 20);
    await post(page, { type: "serverRestarting", revision: 4 });
    await page.waitForFunction(() => document.querySelector(".build-status-label")?.textContent === "Restarting…");
    await page.mouse.up();
    assert.equal(await page.locator(".page-shell").count(), 0);
    assert.equal(await page.evaluate(() => globalThis.__messages.filter((message) => message.type === "translate").length), 0);
    await post(page, { type: "snapshot", revision: 5, documentVersion: 1, buildDurationMs: 1, snapshot });
    await page.waitForSelector(".page-shell");
    assert.deepEqual(errors, []);
  } finally {
    await page.close();
  }
}

async function post(page, message) {
  await page.evaluate((value) => window.postMessage(value, "*"), message);
}
