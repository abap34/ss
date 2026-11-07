import assert from "node:assert/strict";

export async function exerciseSelectionClearing(browser, baseUrl, snapshot) {
  const page = await browser.newPage({ viewport: { width: 1200, height: 1000 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  try {
    await page.goto(`${baseUrl}/index.html`, { waitUntil: "networkidle" });
    await page.evaluate((value) => window.postMessage({
      type: "snapshot", revision: 1, documentVersion: 1, snapshot: value,
    }, "*"), snapshot);
    await page.locator('.page-entry[data-page-id="22"]').click();
    const target = page.locator('.object-hit[data-object-id="202"]');
    const sheet = page.locator(".object-sheet");
    const surface = page.locator('.page-shell[data-page-id="22"] .page-surface');
    const blankPoint = async () => {
      const box = await surface.boundingBox();
      return { x: box.x + box.width * 0.85, y: box.y + box.height * 0.5 };
    };
    const clickBlank = async (options) => {
      const point = await blankPoint();
      await page.mouse.click(point.x, point.y, options);
    };
    const assertSelected = async (message) => {
      assert.equal(await target.evaluate((node) => node.classList.contains("is-selected")), true, message);
      assert.equal(await sheet.count(), 1, message);
    };
    const assertCleared = async () => {
      assert.equal(await page.locator(".object-hit.is-selected").count(), 0,
        "clicking empty space retained the selection outline");
      assert.equal(await sheet.count(), 0, "clicking empty space retained object details");
      assert.equal(await page.locator(".constraint-layer").count(), 0,
        "clicking empty space retained constraints");
      assert.equal(await page.locator(".page-entry.is-active").getAttribute("data-page-id"), "22",
        "clearing an object selection changed the active page");
    };

    await target.click();
    await assertSelected("clicking an object must select it");
    await sheet.getByRole("button", { name: "Constraints", exact: true }).click();
    assert.equal(await page.locator(".constraint").count(), 3);
    await page.waitForFunction(() =>
      document.querySelector('.preview .ss-pdf')?.dataset.ssPdfRendered === "true"
    );
    await page.evaluate(() => {
      globalThis.__selectionPdfCanvas = document.querySelector(".preview .ss-pdf > canvas");
      const viewport = document.querySelector(".viewport");
      globalThis.__selectionScroll = { left: viewport.scrollLeft, top: viewport.scrollTop };
    });
    await clickBlank();
    await assertCleared();
    assert.equal(await page.evaluate(() =>
      globalThis.__selectionPdfCanvas === document.querySelector(".preview .ss-pdf > canvas")
    ), true, "clearing the selection recreated an unrelated PDF canvas");
    assert.equal(await page.evaluate(() => {
      const viewport = document.querySelector(".viewport");
      return viewport.scrollLeft === globalThis.__selectionScroll.left &&
        viewport.scrollTop === globalThis.__selectionScroll.top;
    }), true, "clearing the selection moved the viewport");

    await target.click();
    await page.locator(".viewport").click({ position: { x: 8, y: 8 } });
    await assertCleared();
    await clickBlank();
    await assertCleared();

    await page.getByRole("button", { name: "Outline", exact: true }).click();
    await target.click();
    const outlineTarget = page.locator('.outline-row[data-outline-id="202"]');
    assert.equal(await outlineTarget.evaluate((node) => node.classList.contains("is-active")), true);
    await clickBlank();
    assert.equal(await outlineTarget.evaluate((node) => node.classList.contains("is-active")), false,
      "clicking empty space retained the outline selection");
    assert.equal(await page.locator('.outline-row[data-outline-id="22"]').evaluate((node) =>
      node.classList.contains("is-active")), true, "clearing the selection changed the active page");
    await page.getByRole("button", { name: "Pages", exact: true }).click();
    await assertCleared();

    await target.click();
    await clickBlank({ button: "right" });
    await clickBlank({ button: "middle" });
    await assertSelected("secondary buttons must retain the selection");
    await page.getByRole("button", { name: "Pan view", exact: true }).click();
    await clickBlank();
    assert.equal(await sheet.count(), 1, "panning must retain object details");
    await page.getByRole("button", { name: "Select", exact: true }).click();
    await assertSelected("switching tools must retain the selection");
    await page.locator('.page-shell[data-page-id="22"] .page-source-button').click();
    await assertSelected("opening the page source must retain the selection");
    await sheet.getByRole("button", { name: "Position & size", exact: true }).click();
    await assertSelected("opening object details must retain the selection");

    const shapePicker = page.locator(".shape-picker");
    await shapePicker.locator("summary").click();
    await shapePicker.getByRole("button", { name: "Rectangle", exact: true }).click();
    const start = await blankPoint();
    await page.mouse.move(start.x, start.y);
    await page.mouse.down();
    assert.equal(await page.locator(".shape-placement-ghost").count(), 1,
      "drawing on empty space did not start placement");
    await assertSelected("drawing a shape must retain the selection");
    await page.mouse.move(start.x + 25, start.y + 25);
    await page.mouse.up();
    assert.equal(await page.evaluate(() => globalThis.__messages.filter((message) =>
      message.type === "insertShape").length), 1, "drawing did not submit a shape insertion");
    assert.deepEqual(errors, []);
  } finally {
    await page.close();
  }
}
