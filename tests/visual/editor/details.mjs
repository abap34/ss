import assert from "node:assert/strict";
import path from "node:path";

export async function exerciseObjectDetails(browser, baseUrl, snapshot, output) {
  const page = await browser.newPage({ viewport: { width: 1024, height: 760 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  try {
    await page.goto(`${baseUrl}/index.html`, { waitUntil: "networkidle" });
    await page.waitForFunction(() => globalThis.__messages?.some((message) => message.type === "ready"));
    await page.evaluate((value) => window.dispatchEvent(new MessageEvent("message", {
      data: { type: "snapshot", revision: 100, snapshot: value, documentVersion: 1 },
    })), snapshot);
    await assertPageListLayout(page);
    await exercisePageCaptions(page, output);
    await page.locator(".page-entry").nth(1).click();
    await page.locator('.object-hit[data-object-id="202"]').click();
    const sheet = page.locator(".object-sheet");
    const bounds = sheet.getByRole("button", { name: "Position & size", exact: true });
    const constraints = sheet.getByRole("button", { name: "Constraints", exact: true });
    assert.equal(await bounds.getAttribute("aria-expanded"), "false");
    assert.equal(await constraints.getAttribute("aria-expanded"), "false");
    assert.equal(await sheet.locator(".bounds").isVisible(), false);
    assert.equal(await sheet.locator(".relation-details").isVisible(), false);
    assert.equal(await page.locator(".constraint").count(), 0);
    const compactBar = await sheet.boundingBox();
    assert(compactBar.height <= 30 && compactBar.width <= 120,
      `collapsed selection bar is too large: ${JSON.stringify(compactBar)}`);
    const spacing = await sheet.locator(".sheet-heading").evaluate((bar) => ({
      gap: Number.parseFloat(getComputedStyle(bar).gap),
      buttons: [...bar.querySelectorAll("button")].map((button) => {
        const control = button.getBoundingClientRect();
        const icon = button.querySelector("svg").getBoundingClientRect();
        return { width: control.width, height: control.height,
          insetX: (control.width - icon.width) / 2,
          insetY: (control.height - icon.height) / 2 };
      }),
    }));
    assert(spacing.gap >= 4 && spacing.buttons.every((button) =>
      button.width >= 24 && button.height >= 24 && button.insetX >= 5 && button.insetY >= 5
    ), `selection icons need room inside each button: ${JSON.stringify(spacing)}`);
    assert.equal(await sheet.locator(".sheet-heading").innerText(), "",
      "selection actions must use icons with accessible names");
    await assertSelectionPosition(page);
    await page.getByRole("combobox", { name: "Zoom" }).selectOption("actual");
    await assertSelectionPosition(page);
    await page.getByRole("combobox", { name: "Zoom" }).selectOption("fit");
    await assertSelectionPosition(page);
    await page.screenshot({ path: path.join(output, "selection-compact.png") });

    await exerciseLockPersistence(page);

    await bounds.click();
    assert.equal(await sheet.getByRole("spinbutton", { name: "Component width" }).inputValue(), "380");
    assert.equal(await bounds.evaluate((node) => document.activeElement === node), true,
      "opening details lost keyboard focus");
    await constraints.click();
    assert.equal(await sheet.locator(".relation-details").isVisible(), true);
    assert.equal(await page.locator(".constraint").count(), 3);

    await page.evaluate((value) => window.dispatchEvent(new MessageEvent("message", {
      data: { type: "snapshot", revision: 101, snapshot: value, documentVersion: 2 },
    })), { ...snapshot, snapshot_id: "details-refresh", generation: 11 });
    assert.equal(await bounds.getAttribute("aria-expanded"), "false");
    assert.equal(await constraints.getAttribute("aria-expanded"), "true");
    await constraints.click();
    assert.equal(await page.locator(".constraint").count(), 0);
    await page.keyboard.down("Shift");
    assert.equal(await page.locator(".constraint").count(), 3,
      "relative adjustment must show its constraints temporarily");
    await page.keyboard.up("Shift");
    assert.equal(await page.locator(".constraint").count(), 0);

    await page.setViewportSize({ width: 560, height: 920 });
    await assertPageListLayout(page);
    await assertSelectionPosition(page);
    const frame = await sheet.boundingBox();
    assert(frame.height <= 30 && frame.x >= 0 && frame.x + frame.width <= 560,
      "compact selection bar does not fit a narrow window");
    await page.screenshot({ path: path.join(output, "selection-compact-narrow.png") });
    await constraints.click();
    const panel = await sheet.locator(".sheet-panel:not([hidden])").boundingBox();
    assert(panel.x >= 0 && panel.x + panel.width <= 560 && panel.y >= 0 && panel.y + panel.height <= 920);
    await page.screenshot({ path: path.join(output, "selection-constraints-narrow.png") });
    await sheet.getByRole("button", { name: "Close details", exact: true }).click();
    assert.equal(await sheet.count(), 1, "closing a detail panel must retain the selection");
    await sheet.getByRole("button", { name: "Lock object", exact: true }).click();
    await sheet.getByRole("button", { name: "Unlock object", exact: true }).click();
    await sheet.getByRole("button", { name: "Open in Editor" }).click();
    assert(await page.evaluate(() => globalThis.__messages.some((message) => message.type === "revealSource")));
    await page.locator(".viewport").evaluate((viewport) => { viewport.scrollTop -= 25; });
    await assertSelectionPosition(page);
    const selected = page.locator('.object-hit[data-object-id="202"] > .object-hit-rect');
    const selectedBox = await selected.boundingBox();
    const start = { x: selectedBox.x + selectedBox.width / 2, y: selectedBox.y + selectedBox.height / 2 };
    await page.mouse.move(start.x, start.y);
    await page.mouse.down();
    await page.mouse.move(start.x + 25, start.y + 30, { steps: 3 });
    await assertSelectionPosition(page);
    await page.mouse.up();
    await assertSelectionPosition(page);
    assert.deepEqual(errors, []);
  } finally {
    await page.close();
  }
}

async function assertPageListLayout(page) {
  await page.waitForFunction(() => [...document.querySelectorAll(".page-thumbnail")].every((thumbnail) => {
    const preview = thumbnail.querySelector(".ss-page");
    return preview && Math.abs(preview.getBoundingClientRect().width - thumbnail.clientWidth) < 1;
  }));
  const entries = await page.locator(".page-entry").evaluateAll((rows) => rows.map((row) => {
    const number = row.querySelector("strong").getBoundingClientRect();
    const preview = row.querySelector(".page-thumbnail").getBoundingClientRect();
    const name = row.querySelector("small").getBoundingClientRect();
    return { numberRight: number.right, previewLeft: preview.left,
      previewRight: preview.right, rowRight: row.getBoundingClientRect().right,
      nameTop: name.top, previewBottom: preview.bottom, previewWidth: preview.width };
  }));
  assert(entries.every((item) => item.numberRight < item.previewLeft &&
    item.nameTop >= item.previewBottom && item.previewRight <= item.rowRight && item.previewWidth >= 80),
  `page numbers must sit left of previews with names below: ${JSON.stringify(entries)}`);
}

async function exercisePageCaptions(page, output) {
  const zoom = page.getByRole("combobox", { name: "Zoom" });
  const caption = page.locator(".page-caption").first();
  await zoom.selectOption("actual");
  assert.equal(await caption.isVisible(), true);
  for (const scale of [0.51, 0.49]) {
    await zoom.selectOption("actual");
    await page.locator(".viewport").evaluate((viewport, scale) => viewport.dispatchEvent(
      new WheelEvent("wheel", { bubbles: true, cancelable: true, ctrlKey: true,
        deltaY: -Math.log(scale) / 0.004 }),
    ), scale);
    assert.equal(await caption.isVisible(), scale > 0.5,
      "canvas names must disappear when displayed pages shrink below 640 by 360 pixels");
  }
  const gap = await page.locator(".page-shell").evaluateAll((shells) =>
    shells[1].getBoundingClientRect().top - shells[0].getBoundingClientRect().bottom
  );
  assert.equal(gap, 20, "hidden page names still reserved a large gap");
  assert.equal(await page.locator(".page-entry-label small").first().textContent(), "Overview",
    "hiding canvas names removed sidebar navigation labels");
  await page.screenshot({ path: path.join(output, "small-pages.png") });
  await zoom.selectOption("actual");
  assert.equal(await caption.isVisible(), true, "enlarging pages did not restore their names");
  await zoom.selectOption("fit");
  await page.setViewportSize({ width: 500, height: 760 });
  await page.waitForFunction(() => document.querySelector(".page-caption")?.hidden === true);
  await page.setViewportSize({ width: 1024, height: 760 });
  await page.waitForFunction(() => document.querySelector(".page-caption")?.hidden === false);
}

async function exerciseLockPersistence(page) {
  const sheet = page.locator(".object-sheet");
  const bounds = sheet.getByRole("button", { name: "Position & size", exact: true });
  await bounds.click();
  const retained = await sheet.elementHandle();
  const lock = await sheet.locator(".object-lock-button").elementHandle();
  const width = await sheet.getByRole("spinbutton", { name: "Component width" }).elementHandle();
  const viewport = await page.locator(".viewport").elementHandle();
  const canvas = await page.locator(".page-shell .ss-pdf > canvas").first().elementHandle();
  for (const locked of [true, false, true, false]) {
    await lock.click();
    assert.equal(await retained.evaluate((node) => node.isConnected &&
      getComputedStyle(node).visibility === "visible"), true,
    "toggling a lock removed or hid the selection toolbar");
    assert.equal(await lock.evaluate((node) => document.activeElement === node), true,
      "toggling a lock lost keyboard focus");
    assert.equal(await width.evaluate((node) => node.isConnected && node.disabled), locked);
    assert.equal(await width.evaluate((node) => node.isConnected), true,
      "toggling a lock replaced the open detail controls");
    assert.equal(await bounds.getAttribute("aria-expanded"), "true");
    assert.equal(await viewport.evaluate((node) => node.isConnected), true,
      "toggling a lock replaced the viewport");
    assert.equal(await canvas.evaluate((node) => node.isConnected), true,
      "toggling a lock recreated an unrelated PDF canvas");
  }
  await page.getByRole("button", { name: "Outline", exact: true }).click();
  await page.waitForFunction(() =>
    getComputedStyle(document.querySelector(".object-sheet")).visibility === "visible"
  );
  const outlineSheet = await sheet.elementHandle();
  const outlineLock = page.getByRole("button", { name: "Lock Detail", exact: true });
  await outlineLock.click();
  assert.equal(await outlineSheet.evaluate((node) => node.isConnected), true,
    "locking from the outline replaced the selected object's controls");
  assert.equal(await sheet.getByRole("button", { name: "Unlock object", exact: true })
    .getAttribute("aria-pressed"), "true");
  assert.equal(await page.getByRole("button", { name: "Unlock Detail", exact: true })
    .getAttribute("aria-pressed"), "true");
  await sheet.getByRole("button", { name: "Unlock object", exact: true }).click();
  assert.equal(await outlineLock.getAttribute("aria-pressed"), "false",
    "unlocking from the toolbar did not refresh the outline");
  await bounds.click();
  await page.getByRole("button", { name: "Pages", exact: true }).click();
}

async function assertSelectionPosition(page) {
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const geometry = await page.locator(".object-sheet").evaluate((sheet) => {
    const bar = sheet.getBoundingClientRect();
    const object = document.querySelector(`.object-hit[data-object-id="${sheet.dataset.objectId}"] > .object-hit-rect`).getBoundingClientRect();
    const view = document.querySelector(".viewport").getBoundingClientRect();
    return { bar: bar.toJSON(), object: object.toJSON(), view: view.toJSON() };
  });
  const { bar, object, view } = geometry;
  assert(bar.left >= view.left && bar.right <= view.right && bar.top >= view.top && bar.bottom <= view.bottom,
    `selection toolbar escaped the viewport: ${JSON.stringify(geometry)}`);
  if (object.top - 8 - bar.height >= view.top + 8) {
    assert(Math.abs(bar.bottom + 8 - object.top) < 2, `toolbar did not stay above the selection: ${JSON.stringify(geometry)}`);
  }
}
