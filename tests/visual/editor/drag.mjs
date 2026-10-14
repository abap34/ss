import assert from "node:assert/strict";

export async function exerciseObjectDrag(browser, baseUrl, snapshot) {
  // Keep free-movement checks away from object and page snap candidates.
  snapshot = structuredClone(snapshot);
  snapshot.layout.objects.find((object) => object.id === 202).width = 240;
  snapshot.layout.objects.find((object) => object.id === 201).y = 260;
  snapshot.display.html = snapshot.display.html.replace("width:380pt;height:120pt", "width:240pt;height:120pt");
  snapshot.display.html = snapshot.display.html.replace("left:60pt;top:130pt;width:120pt", "left:60pt;top:400pt;width:120pt");
  for (const scale of [0.25, 1, 4]) {
    const page = await browser.newPage({
      viewport: { width: 1200, height: 1200 },
      deviceScaleFactor: 2,
    });
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    try {
      await page.goto(`${baseUrl}/index.html`, { waitUntil: "networkidle" });
      await page.waitForFunction(() => globalThis.__messages?.some((message) =>
        message.type === "ready"
      ));
      await page.evaluate((value) => window.dispatchEvent(new MessageEvent("message", {
        data: { type: "snapshot", revision: 100, snapshot: value, documentVersion: 1 },
      })), snapshot);
      await page.locator(".page-entry").nth(1).click();
      await page.getByRole("combobox", { name: "Zoom", exact: true }).selectOption("actual");
      await page.locator(".viewport").evaluate((viewport, zoom) => {
        const bounds = viewport.getBoundingClientRect();
        viewport.dispatchEvent(new WheelEvent("wheel", {
          bubbles: true,
          cancelable: true,
          ctrlKey: true,
          deltaY: -Math.log(zoom) / 0.004,
          clientX: bounds.x + bounds.width / 2,
          clientY: bounds.y + bounds.height / 2,
        }));
      }, scale);
      await settleLayout(page);

      const target = page.locator('.object-hit[data-object-id="202"]');
      const preview = page.locator('.page-shell[data-page-id="22"] .ss-item[data-ss-node-id="202"]');
      const start = await pressObject(page, target);
      const original = await previewState(preview);
      for (const [dx, dy] of [[0, 0], [3, 3], [-3, -3], [4.5, 0], [0, 4.5]]) {
        await page.mouse.move(start.x + dx, start.y + dy);
        assert.deepEqual(await previewState(preview), original,
          `click jitter moved the preview at ${scale * 100}% zoom`);
        assert.equal(await target.evaluate((node) => node.classList.contains("is-dragging")), false,
          "click jitter activated the drag cursor");
      }
      await page.mouse.up();
      assert.equal((await translations(page)).length, 0,
        "click jitter sent a source translation");
      assert.deepEqual(await previewState(preview), original);
      assert.equal(await page.locator(".object-sheet").count(), 1,
        "click jitter did not select the object");
      await page.locator(".object-sheet .source-button").click();
      assert.deepEqual(await lastReveal(page), {
        type: "revealSource", path: "/workspace/slide.ss", start: 40, end: 75,
      });

      const revealsBeforeDoubleClick = await page.evaluate(() =>
        globalThis.__messages.filter((message) => message.type === "revealSource").length
      );
      const doubleStart = await pressObject(page, target);
      await page.mouse.move(doubleStart.x + 2, doubleStart.y + 1);
      await page.mouse.up();
      await page.mouse.down({ clickCount: 2 });
      await page.mouse.move(doubleStart.x + 1, doubleStart.y + 2);
      await page.mouse.up({ clickCount: 2 });
      assert.equal(await page.evaluate(() =>
        globalThis.__messages.filter((message) => message.type === "revealSource").length
      ), revealsBeforeDoubleClick + 1, `double-click jitter prevented source navigation at ${scale * 100}% zoom`);
      assert.equal((await translations(page)).length, 0);

      const returnStart = await pressObject(page, target);
      await page.mouse.move(returnStart.x + 3, returnStart.y + 4);
      assert.equal(await target.evaluate((node) => node.classList.contains("is-dragging")), true,
        "movement at the five-pixel distance did not activate dragging");
      await page.mouse.move(returnStart.x, returnStart.y);
      await page.mouse.up();
      await settleLayout(page);
      assert.equal((await translations(page)).length, 0,
        "returning to the original position sent a source translation");
      assert.deepEqual(await previewState(preview), original);

      const dragStart = await pressObject(page, target);
      await page.mouse.move(dragStart.x + 12, dragStart.y + 8);
      assert.equal(await target.evaluate((node) => node.classList.contains("is-dragging")), true,
        "deliberate pointer movement did not activate dragging");
      const moved = await previewState(preview);
      assert(Math.abs(moved.x - original.x - 12) < 0.1 &&
        Math.abs(moved.y - original.y - 8) < 0.1,
      "dragging did not include the movement before the activation threshold");
      await page.mouse.up();
      const [edit] = await translations(page);
      assert(edit, "deliberate dragging did not send a source translation");
      assert.equal(edit.mode, "absolute");
      assert(Math.abs(edit.toBounds.x - edit.fromBounds.x - 12 / scale) < 0.01 &&
        Math.abs(edit.toBounds.y - edit.fromBounds.y - 8 / scale) < 0.01,
      "dragging used screen pixels as document coordinates");
      await rejectTranslation(page, edit);

      const preciseStart = await pressObject(page, target);
      await page.mouse.move(preciseStart.x + 12, preciseStart.y);
      await page.mouse.move(preciseStart.x + 2, preciseStart.y + 1);
      assert.equal(await target.evaluate((node) => node.classList.contains("is-dragging")), true,
        "returning inside the threshold canceled an active drag");
      await page.keyboard.down("Shift");
      await page.mouse.up();
      await page.keyboard.up("Shift");
      const precise = (await translations(page)).at(-1);
      assert.equal((await translations(page)).length, 2,
        "an activated drag could not finish with a small adjustment");
      assert.equal(precise.mode, "relative");
      assert(Math.abs(precise.toBounds.x - precise.fromBounds.x - 2 / scale) < 0.01,
        "the activation threshold prevented a fine adjustment");
      await rejectTranslation(page, precise);

      const cancelStart = await pressObject(page, target);
      await page.mouse.move(cancelStart.x + 12, cancelStart.y + 8);
      await target.evaluate((node) => node.dispatchEvent(new PointerEvent("pointercancel", {
        bubbles: true, pointerId: 1, pointerType: "mouse",
      })));
      await page.mouse.up();
      await settleLayout(page);
      assert.equal((await translations(page)).length, 2,
        "canceling a drag sent a source translation");
      assert.deepEqual(await previewState(preview), original,
        "canceling a drag retained provisional movement");
      assert.deepEqual(errors, []);
    } finally {
      await page.close();
    }
  }
}

export async function pressObject(page, target) {
  const outline = target.locator(":scope > .object-hit-rect");
  await outline.scrollIntoViewIfNeeded();
  await settleLayout(page);
  const start = await outline.evaluate((node) => {
    const bounds = node.getBoundingClientRect();
    const viewport = node.closest(".viewport").getBoundingClientRect();
    const left = Math.max(bounds.left, viewport.left);
    const right = Math.min(bounds.right, viewport.right);
    const top = Math.max(bounds.top, viewport.top);
    const bottom = Math.min(bounds.bottom, viewport.bottom);
    for (const xRatio of [0.5, 0.25, 0.75]) {
      for (const yRatio of [0.5, 0.25, 0.75]) {
        const x = left + (right - left) * xRatio;
        const y = top + (bottom - top) * yRatio;
        if (document.elementFromPoint(x, y) === node) return { x, y };
      }
    }
    return null;
  });
  assert(start, "drag fixture had no unobstructed target point: " + JSON.stringify(await outline.evaluate((node) => ({
    bounds: node.getBoundingClientRect().toJSON(),
    viewport: node.closest(".viewport").getBoundingClientRect().toJSON(),
    sheet: document.querySelector(".object-sheet")?.getBoundingClientRect().toJSON(),
  }))));
  await page.mouse.move(start.x, start.y);
  await page.mouse.down();
  return start;
}

async function previewState(preview) {
  return preview.evaluate((node) => {
    const bounds = node.getBoundingClientRect();
    const surface = node.closest(".page-surface").getBoundingClientRect();
    return {
      x: bounds.x - surface.x, y: bounds.y - surface.y,
      translate: node.style.translate,
      pending: node.dataset.ssPendingTranslation ?? null,
    };
  });
}

async function translations(page) {
  return page.evaluate(() => globalThis.__messages.filter((message) => message.type === "translate"));
}

async function lastReveal(page) {
  return page.evaluate(() => globalThis.__messages.filter((message) => message.type === "revealSource").at(-1));
}

export async function rejectTranslation(page, edit) {
  await page.evaluate((requestId) => window.dispatchEvent(new MessageEvent("message", {
    data: { type: "editResult", requestId, status: "rejected", message: "Reset the drag fixture" },
  })), edit.requestId);
  await page.waitForFunction(() => !document.querySelector("[data-ss-pending-translation]"));
  await settleLayout(page);
}

export async function settleLayout(page) {
  await page.evaluate(() => new Promise((resolve) =>
    requestAnimationFrame(() => requestAnimationFrame(resolve))
  ));
}
