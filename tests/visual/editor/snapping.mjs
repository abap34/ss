import assert from "node:assert/strict";
import { pressObject, rejectTranslation, settleLayout } from "./drag.mjs";

export async function exerciseSnapping(browser, baseUrl, snapshot, output) {
  let markerSize;
  for (const scale of [0.25, 1, 4]) {
    const page = await browser.newPage({
      viewport: { width: 1200, height: 1200 }, deviceScaleFactor: 2,
    });
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    try {
      await page.goto(`${baseUrl}/index.html`, { waitUntil: "networkidle" });
      await page.waitForFunction(() => globalThis.__messages?.some((message) => message.type === "ready"));
      await postSnapshot(page, snappingSnapshot(snapshot));
      await page.getByRole("combobox", { name: "Zoom", exact: true }).selectOption("actual");
      await page.locator(".viewport").evaluate((viewport, zoom) => {
        const bounds = viewport.getBoundingClientRect();
        viewport.dispatchEvent(new WheelEvent("wheel", {
          bubbles: true, cancelable: true, ctrlKey: true,
          deltaY: -Math.log(zoom) / 0.004,
          clientX: bounds.x + bounds.width / 2, clientY: bounds.y + bounds.height / 2,
        }));
      }, scale);
      await settleLayout(page);

      const target = page.locator('.object-hit[data-object-id="202"]');
      const preview = page.locator('.page-shell[data-page-id="22"] .preview-page [data-ss-node-id="202"]');
      const start = await pressObject(page, target);
      const original = await position(preview);
      const move = (offset) => page.mouse.move(start.x + 60 * scale + offset, start.y + 21);
      await move(5);
      await expectPosition(preview, original.x + 60 * scale + 5, original.y + 21);
      assert.equal(await page.locator(".snap-guide").count(), 0,
        "snapping captured beyond four screen pixels");
      await move(3);
      await expectPosition(preview, original.x + 60 * scale, original.y + 21);
      assert((await page.locator(".snap-guide").count()) >= 1);
      assert.equal(await page.locator(".snap-guide").getAttribute("x1"), "300");
      assert.equal(await page.locator(".snap-guide-layer").evaluate((node) => getComputedStyle(node).pointerEvents), "none");
      const marker = await page.locator(".snap-marker").first().boundingBox();
      markerSize ??= { width: marker.width, height: marker.height };
      assert(marker.width >= 6 && marker.height >= 6 &&
        Math.abs(marker.width - markerSize.width) < 0.1 &&
        Math.abs(marker.height - markerSize.height) < 0.1,
        `snap marker size changed at ${scale * 100}% zoom: ${JSON.stringify(marker)}`);
      if (scale === 1) await page.screenshot({ path: `${output}/snapping.png` });
      await move(6);
      await expectPosition(preview, original.x + 60 * scale, original.y + 21);
      await move(7);
      await expectPosition(preview, original.x + 60 * scale + 7, original.y + 21);
      assert.equal(await page.locator(".snap-guide").count(), 0,
        "released snapping retained a guide");
      await move(-3);
      await expectPosition(preview, original.x + 60 * scale, original.y + 21);
      await page.keyboard.down("Shift");
      await page.mouse.up();
      await page.keyboard.up("Shift");
      const edit = await lastTranslation(page);
      assert.equal(edit.mode, "relative");
      assert.equal(edit.toBounds.x, 300, "source edit used the uncorrected pointer position");
      assert(Math.abs(edit.toBounds.y - 130 - 21 / scale) < 0.01);
      assert.equal(await page.locator(".snap-guide-layer").count(), 0);

      await page.evaluate((requestId) => window.dispatchEvent(new MessageEvent("message", {
        data: { type: "editResult", requestId, status: "applied", documentVersion: 2 },
      })), edit.requestId);
      const applied = snappingSnapshot(snapshot, 300, edit.toBounds.y);
      applied.snapshot_id = "snapping-applied";
      await postSnapshot(page, applied, 101, 2);
      await page.waitForFunction(() => !document.querySelector("[data-ss-pending-translation]"));
      await expectPosition(preview, original.x + 60 * scale, original.y + 21);

      const cancelStart = await pressObject(page, target);
      await page.mouse.move(cancelStart.x + 3, cancelStart.y + 15);
      assert((await page.locator(".snap-guide").count()) >= 1);
      await page.keyboard.press("Escape");
      await page.mouse.up();
      await settleLayout(page);
      assert.equal(await page.locator(".snap-guide-layer").count(), 0);
      assert.equal(await translationCount(page), 1, "Escape committed a snapped drag");
      await expectPosition(preview, original.x + 60 * scale, original.y + 21);

      const pointerCancelStart = await pressObject(page, target);
      await page.mouse.move(pointerCancelStart.x - 3, pointerCancelStart.y + 15);
      await target.evaluate((node) => node.dispatchEvent(new PointerEvent("pointercancel", {
        bubbles: true, pointerId: 1, pointerType: "mouse",
      })));
      await page.mouse.up();
      await settleLayout(page);
      assert.equal(await page.locator(".snap-guide-layer").count(), 0);
      assert.equal(await translationCount(page), 1, "pointer cancellation committed a snapped drag");
      await expectPosition(preview, original.x + 60 * scale, original.y + 21);

      const absoluteStart = await pressObject(page, target);
      await page.mouse.move(absoluteStart.x + 3, absoluteStart.y + 15);
      await page.mouse.up();
      const absolute = await lastTranslation(page);
      assert.equal(absolute.mode, "absolute");
      assert.equal(absolute.toBounds.x, 300);
      await rejectTranslation(page, absolute);
      assert.deepEqual(errors, []);
    } finally {
      await page.close();
    }
  }
}

function snappingSnapshot(source, x = 240, top = 130) {
  const snapshot = structuredClone(source);
  snapshot.layout.pages = snapshot.layout.pages.filter((page) => page.id === 22);
  snapshot.layout.objects = snapshot.layout.objects.filter((object) => object.page_id === 22);
  Object.assign(snapshot.layout.objects[0], { x: 300, y: 260, width: 200, height: 60 });
  Object.assign(snapshot.layout.objects[1], { x, y: 720 - top - 120, width: 200 });
  snapshot.outline = snapshot.outline.filter((item) => item.page_id === 22);
  snapshot.editing = snapshot.editing.filter((item) => item.page_id === 22);
  snapshot.display.has_pdf = false;
  snapshot.display.html = `<section class="ss-page" data-ss-page-id="22" style="width:1280pt;height:720pt"><div class="ss-item ss-box" data-ss-node-id="201" style="left:300pt;top:400pt;width:200pt;height:60pt"></div><div class="ss-item ss-box" data-ss-node-id="202" style="left:${x}pt;top:${top}pt;width:200pt;height:120pt"></div></section>`;
  return snapshot;
}

async function postSnapshot(page, snapshot, revision = 100, documentVersion = 1) {
  await page.evaluate((data) => window.dispatchEvent(new MessageEvent("message", { data })), {
    type: "snapshot", snapshot, revision, documentVersion,
  });
  await settleLayout(page);
}

async function position(preview) {
  return preview.evaluate((node) => {
    const bounds = node.getBoundingClientRect();
    const surface = node.closest(".page-surface").getBoundingClientRect();
    return { x: bounds.x - surface.x, y: bounds.y - surface.y };
  });
}

async function expectPosition(preview, x, y) {
  const actual = await position(preview);
  assert(Math.abs(actual.x - x) < 0.15 && Math.abs(actual.y - y) < 0.15,
    `unexpected snapped position: ${JSON.stringify({ actual, expected: { x, y } })}`);
}

async function lastTranslation(page) {
  return page.evaluate(() => globalThis.__messages.filter((message) => message.type === "translate").at(-1));
}

async function translationCount(page) {
  return page.evaluate(() => globalThis.__messages.filter((message) => message.type === "translate").length);
}
