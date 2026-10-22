import assert from "node:assert/strict";

export async function exercisePageWindow(browser, baseUrl, snapshot) {
  const page = await browser.newPage({ viewport: { width: 1000, height: 800 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  try {
    await page.goto(`${baseUrl}/index.html`);
    await page.waitForFunction(() => globalThis.__messages?.some((message) => message.type === "ready"));
    await page.evaluate((snapshot) => {
      const template = document.createElement("template");
      template.innerHTML = snapshot.display.html;
      const source = template.content.querySelector(".ss-page");
      const run = source.querySelector(".ss-text-run");
      run.replaceChildren();
      for (let index = 0; index < 500; index++) {
        const glyph = document.createElement("span");
        glyph.className = "ss-text-cluster";
        glyph.textContent = "x";
        run.append(glyph);
      }
      const html = [];
      const pages = [];
      const objects = [];
      for (let index = 0; index < 80; index++) {
        const id = index + 100;
        const clone = source.cloneNode(true);
        clone.dataset.ssPageId = String(id);
        for (const node of clone.querySelectorAll("[data-ss-node-id]")) {
          node.dataset.ssNodeId = String(Number(node.dataset.ssNodeId) + index * 1000);
        }
        pages.push({ ...snapshot.layout.pages[0], id, index: index + 1, name: `Page ${index + 1}` });
        objects.push(...snapshot.layout.objects.filter((item) => item.page_id === 11)
          .map((item) => ({ ...item, id: item.id + index * 1000, page_id: id })));
        html.push(clone.outerHTML);
      }
      snapshot.layout = { ...snapshot.layout, pages, objects, anchors: [], relations: [] };
      snapshot.display.html = html.join("");
      snapshot.outline = pages.map((p) => ({ id: p.id, page_id: p.id, parent_id: null, kind: "page", label: p.name }));
      snapshot.editing = [];
      snapshot.shape_editing = [];
      snapshot.page_editing = [];
      globalThis.__largeSnapshot = snapshot;
      window.postMessage({ type: "snapshot", revision: 100, snapshot }, "*");
    }, snapshot);
    await page.waitForSelector('.page-shell[data-page-id="100"] .ss-pdf > canvas');
    await assertWindow(page);
    await page.evaluate(() => {
      globalThis.__firstPreview = document.querySelector('.page-shell[data-page-id="100"] .preview');
    });
    await page.locator('.page-shell[data-page-id="100"] .object-hit').first().click();
    assert.equal(await page.evaluate(() => __firstPreview ===
      document.querySelector('.page-shell[data-page-id="100"] .preview')), true,
    "selecting an object rebuilt the page preview");
    await page.evaluate(() => {
      const next = structuredClone(__largeSnapshot);
      next.snapshot_id = "11-offscreen-translation";
      next.generation++;
      const object = next.layout.objects.find((item) => item.id === 79101);
      object.x += 12;
      object.y -= 8;
      next.display = {
        kind: "translation_patch", base_snapshot_id: __largeSnapshot.snapshot_id,
        translations: [{ node_id: 79101, x: 12, y: 8 }],
      };
      window.postMessage({ type: "snapshot", revision: 101, snapshot: next }, "*");
    });
    await page.waitForFunction(() => __messages.some((message) =>
      message.type === "snapshotResources" && message.observedSnapshotId === "11-offscreen-translation"));
    assert.equal(await page.evaluate(() => __firstPreview ===
      document.querySelector('.page-shell[data-page-id="100"] .preview')), true,
    "an offscreen translation rebuilt the visible page");
    for (const id of [179, 140, 100, 179, 100]) {
      await page.locator(`.page-shell[data-page-id="${id}"]`).evaluate((shell) => shell.scrollIntoView());
      await page.waitForSelector(`.page-shell[data-page-id="${id}"] .ss-pdf > canvas`);
      await assertWindow(page);
      if (id === 179) {
        assert.equal(await page.locator('.page-shell[data-page-id="179"] [data-ss-node-id="79101"]')
          .evaluate((node) => node.style.translate), "12pt 8pt",
        "a page mounted with obsolete object positions");
      }
    }
    assert.deepEqual(errors, []);
  } finally {
    await page.close();
  }
}

async function assertWindow(page) {
  await page.waitForFunction(() => document.querySelectorAll(".page-shell .preview").length <= 12);
  const counts = await page.evaluate(() => ({
    shells: document.querySelectorAll(".page-shell").length,
    previews: document.querySelectorAll(".page-shell .preview").length,
    glyphs: document.querySelectorAll(".page-shell .ss-text-cluster").length,
    errors: [...document.querySelectorAll("[data-error]")].map((node) => node.dataset.error),
  }));
  assert.equal(counts.shells, 80, "scroll geometry omitted offscreen pages");
  assert(counts.previews > 0 && counts.previews <= 12, "page DOM grew with the document length");
  assert(counts.glyphs < 6500, "offscreen text glyphs remained mounted");
  assert.deepEqual(counts.errors, []);
}
