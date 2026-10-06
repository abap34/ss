import assert from "node:assert/strict";
import path from "node:path";

export async function exerciseRelativeAdjustment(browser, baseUrl, snapshot, output) {
  const page = await browser.newPage({ viewport: { width: 1024, height: 760 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  try {
    await page.goto(`${baseUrl}/index.html`, { waitUntil: "networkidle" });
    await page.waitForFunction(() => globalThis.__messages?.some((message) => message.type === "ready"));
    await page.evaluate((value) => window.dispatchEvent(new MessageEvent("message", {
      data: { type: "snapshot", revision: 100, snapshot: value, documentVersion: 1 },
    })), snapshot);
    await page.locator(".page-entry").nth(1).click();
    const target = page.locator('.object-hit[data-object-id="202"]');
    await target.click();
    const workspace = page.locator(".workspace");
    const indicator = page.locator(".relative-adjustment-status");
    const reference = page.locator('.constraint-reference[data-object-id="201"]');
    const connector = page.locator(".constraint--object .constraint-connector");
    const outline = target.locator(":scope > .object-hit-rect");
    await expectMode(page, false);
    assert.equal(await indicator.isVisible(), false);
    assert.equal(await reference.isVisible(), false);
    const normalStroke = await outline.evaluate((node) => getComputedStyle(node).stroke);
    await target.evaluate((node) => { node.dataset.modifierIdentity = "retained"; });

    for (const theme of ["dark", "light"]) {
      if (theme === "light") await page.getByRole("button", { name: "Use light theme" }).click();
      await page.keyboard.down("Shift");
      await expectMode(page, true);
      assert.equal(await indicator.isVisible(), true);
      assert.equal(await reference.isVisible(), true);
      assert.equal(await page.locator(".constraint-reference").count(), 1,
        "the same constraint source was outlined more than once");
      assert.equal(await connector.evaluate((node) => getComputedStyle(node).strokeDasharray), "none");
      assert.notEqual(await outline.evaluate((node) => getComputedStyle(node).stroke), normalStroke);
      if (output) await page.screenshot({ path: path.join(output, `relative-adjustment-${theme}.png`) });
      await page.keyboard.up("Shift");
      await expectMode(page, false);
      assert.equal(await indicator.isVisible(), false);
      assert.equal(await reference.isVisible(), false);
      assert.notEqual(await connector.evaluate((node) => getComputedStyle(node).strokeDasharray), "none");
      if (theme === "dark") assert.equal(await target.getAttribute("data-modifier-identity"), "retained",
        "changing the modifier rebuilt the captured interaction target");
    }

    await page.keyboard.down("ShiftLeft");
    await page.keyboard.down("ShiftRight");
    await page.keyboard.up("ShiftLeft");
    await expectMode(page, true);
    await page.keyboard.up("ShiftRight");
    await expectMode(page, false);

    await page.keyboard.down("Shift");
    await page.evaluate(() => window.dispatchEvent(new Event("blur")));
    await expectMode(page, false);
    await page.keyboard.up("Shift");

    await page.getByRole("button", { name: "Pan view" }).click();
    await page.keyboard.down("Shift");
    await expectMode(page, false);
    await page.keyboard.up("Shift");
    await page.getByRole("button", { name: "Select" }).click();
    await target.click();

    const width = page.getByRole("spinbutton", { name: "Component width" });
    await width.focus();
    await page.keyboard.down("Shift");
    await expectMode(page, false);
    await page.keyboard.up("Shift");
    await width.evaluate((node) => node.blur());

    await page.setViewportSize({ width: 560, height: 920 });
    await page.keyboard.down("Shift");
    await expectMode(page, true);
    const badgeBounds = await indicator.boundingBox();
    const sheetBounds = await page.locator(".object-sheet").boundingBox();
    assert(badgeBounds && sheetBounds && badgeBounds.x >= sheetBounds.x &&
      badgeBounds.x + badgeBounds.width <= sheetBounds.x + sheetBounds.width,
      "the relative mode label overflowed the narrow object sheet");
    await page.keyboard.up("Shift");
    await page.setViewportSize({ width: 1024, height: 760 });

    await page.locator(".object-sheet .close-button").click();
    await page.keyboard.down("Shift");
    await expectMode(page, false);
    const bounds = await outline.boundingBox();
    assert(bounds, "relative adjustment fixture lost its target");
    const x = bounds.x + bounds.width / 2;
    const y = bounds.y + bounds.height / 2;
    await page.mouse.move(x, y);
    await page.mouse.down();
    await expectMode(page, true);
    assert.equal(await reference.isVisible(), true,
      "dragging an unselected object did not show its constraint sources");
    await page.mouse.move(x + 20, y + 12);
    const connectorEnd = await connector.getAttribute("x2");
    assert(Number(connectorEnd) > 240, "the constraint connector did not follow the active drag");
    await page.keyboard.up("Shift");
    await expectMode(page, false);
    assert.equal(await target.evaluate((node) => node.classList.contains("is-dragging")), true,
      "releasing Shift interrupted the active drag");
    await page.mouse.up();
    assert.equal(await lastTranslationMode(page), "absolute",
      "releasing Shift without another pointer move submitted a relative edit");

    await page.evaluate(() => {
      const request = globalThis.__messages.filter((message) => message.type === "translate").at(-1);
      window.dispatchEvent(new MessageEvent("message", { data: {
        type: "editResult", requestId: request.requestId,
        status: "rejected", message: "Reset the modifier fixture",
      } }));
    });
    await page.waitForFunction(() => !document.querySelector("[data-ss-pending-translation]"));

    const moved = await outline.boundingBox();
    await page.mouse.move(moved.x + moved.width / 2, moved.y + moved.height / 2);
    await page.mouse.down();
    await page.mouse.move(moved.x + moved.width / 2 + 10, moved.y + moved.height / 2 + 6);
    await page.keyboard.down("Shift");
    await expectMode(page, true);
    await page.mouse.up();
    assert.equal(await lastTranslationMode(page), "relative",
      "pressing Shift during a drag did not submit a relative edit");
    await page.evaluate(() => window.dispatchEvent(new Event("blur")));
    await expectMode(page, false);
    await page.keyboard.up("Shift");
    assert.equal(await workspace.count(), 1);
    assert.deepEqual(errors, []);
  } finally {
    await page.close();
  }
}

async function expectMode(page, active) {
  await page.waitForFunction((expected) =>
    document.querySelector(".workspace")?.classList.contains("is-adjusting-relative") === expected,
  active);
}

async function lastTranslationMode(page) {
  return page.evaluate(() => globalThis.__messages.filter((message) => message.type === "translate").at(-1)?.mode);
}
