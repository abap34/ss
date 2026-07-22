#!/usr/bin/env node
import assert from "node:assert/strict";
import { cp, mkdir, readdir, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { pdfAsset } from "../render/assets.mjs";
import { withBrowser } from "../render/capture.mjs";
import { exerciseBuildDiagnosticMessages } from "./diagnostics.mjs";
import { editorSnapshot, testDocument } from "./fixture.mjs";
import { exerciseTranslationLifecycle } from "./translation.mjs";

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const source = path.join(repository, "editor/vscode/media/editor");
const output = path.join(repository, ".ss-cache/editor-ui-test");
const require = createRequire(import.meta.url);
const esbuild = require(path.join(repository, "editor/vscode/node_modules/esbuild"));

await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
for (const entry of await readdir(source, { withFileTypes: true })) {
  await cp(path.join(source, entry.name), path.join(output, entry.name), { recursive: entry.isDirectory() });
}
await mkdir(path.join(output, "out/render"), { recursive: true });
await mkdir(path.join(output, "out/pdfjs"), { recursive: true });
const pdfSourceRoot = path.join(repository, "src/render/html/pdf");
await esbuild.build({
  entryPoints: [path.join(pdfSourceRoot, "index.js")],
  bundle: true,
  outfile: path.join(output, "out/render/pdf.js"),
  format: "esm",
  platform: "browser",
  target: "chrome120",
  plugins: [{
    name: "ss-pdf-runtime-imports",
    setup(build) {
      build.onResolve({ filter: /^@ss\/pdf\/[^/]+$/ }, (args) => ({
        path: path.join(pdfSourceRoot, `${args.path.slice("@ss/pdf/".length)}.js`),
      }));
    },
  }],
});
await cp(path.join(repository, "src/render/html/text.js"), path.join(output, "out/render/text.js"));
await cp(path.join(repository, "third_party/pdfjs/pdf.mjs"), path.join(output, "out/pdfjs/pdf.mjs"));
await cp(path.join(repository, "third_party/pdfjs/pdf.worker.mjs"), path.join(output, "out/pdfjs/pdf.worker.mjs"));
await writeFile(path.join(output, "asset.pdf"), pdfAsset());
await writeFile(path.join(output, "index.html"), testDocument(), "utf8");

await withBrowser(output, async (browser, baseUrl) => {
  await exerciseBuildDiagnosticMessages(browser, baseUrl, editorSnapshot());
  const page = await browser.newPage({ viewport: { width: 560, height: 920 } });
  let releasePdfRequest;
  try {
    let pdfRequests = 0;
    const pdfRequestGate = new Promise((resolve) => {
      releasePdfRequest = resolve;
    });
    await page.route("**/asset.pdf", async (route) => {
      await pdfRequestGate;
      await route.continue();
    });
    page.on("request", (request) => {
      if (new URL(request.url()).pathname.endsWith("/asset.pdf")) pdfRequests += 1;
    });
    await page.goto(`${baseUrl}/index.html`, { waitUntil: "networkidle" });
    await page.waitForFunction(() => globalThis.__messages?.some((message) => message.type === "ready"));
    await expectBuildStatus(page, "starting", "Starting…");
    await postBuildStatus(page, 100, "building");
    await expectBuildStatus(page, "building", "Building…");
    const current = editorSnapshot();
    await postSnapshot(page, 100, current);
    await expectBuildStatus(page, "complete", "Build complete");
    assert.equal(await page.locator(".build-status-duration").textContent(), "1.2 s");
    assert.equal(
      await page.locator(".build-status-duration").getAttribute("title"),
      "Build time: 1.2 s",
    );
    await page.waitForSelector('.page-shell[data-page-id="11"]');
    await page.waitForFunction(() => document.getElementById("app")?.dataset.ssTextAligned === "true");
    assert.match(
      await page.locator(".ss-text-run[data-ss-baseline-y]").first().getAttribute("style"),
      /top:\s*calc\(/,
      "editor preview did not align an HTML text run to its IR baseline",
    );
    assert.equal(await page.locator(".ss-pdf > canvas").count(), 0,
      "editor exposed an empty PDF canvas while the source was loading");
    releasePdfRequest();
    await page.waitForFunction(() => {
      const placements = [...document.querySelectorAll(".ss-pdf")];
      return placements.length === 2 && placements.every((placement) =>
        placement.dataset.ssPdfRendered === "true" || placement.dataset.error
      );
    });
    const pdfErrors = await page.locator(".ss-pdf[data-error]").evaluateAll((placements) =>
      placements.map((placement) => placement.dataset.error)
    );
    assert.deepEqual(pdfErrors, [], `editor PDF rendering failed: ${pdfErrors.join("; ")}`);
    assert.equal(await page.locator(".ss-pdf[data-ss-pdf-rendered='true']").count(), 2,
      "editor PDF rendering did not complete");

    assert.equal(await page.locator(".page-entry").count(), 2, "page sidebar omitted a page");
    assert.equal(await page.locator(".page-thumbnail .ss-page").count(), 2, "page thumbnails did not reuse shared HTML pages");
    assert.equal(await page.locator(".page-shell").count(), 1, "single-page mode displayed more than one page");
    const firstPageSource = page.locator('.page-shell[data-page-id="11"] .page-source-button');
    assert.equal(await firstPageSource.textContent(), "Open in Editor");
    await firstPageSource.click();
    assert.deepEqual(await lastMessage(page, "revealSource"), {
      type: "revealSource",
      path: "/workspace/slide.ss",
      start: 0,
      end: 30,
    });
    assert.equal(await page.locator('.page-shell[data-page-id="11"] .ss-item[data-ss-node-id="101"]').count(), 1,
      "central preview did not reuse the shared HTML item");
    assert.equal(pdfRequests, 1, "central preview and thumbnail loaded the same PDF more than once");
    assert.equal(await page.locator(".page-thumbnail .ss-pdf .textLayer").count(), 0,
      "PDF thumbnail created a text layer");
    assert.equal(await page.locator('.page-shell[data-page-id="11"] .ss-pdf .textLayer').count(), 0,
      "central editor preview created an unreachable PDF text layer");
    const mainCanvasWidth = await page.locator('.page-shell[data-page-id="11"] .ss-pdf > canvas').evaluate((canvas) => canvas.width);
    const thumbnailCanvasWidth = await page.locator('.page-thumbnail .ss-pdf > canvas').evaluate((canvas) => canvas.width);
    assert(thumbnailCanvasWidth < mainCanvasWidth, "PDF thumbnail rendered at the central preview resolution");
    await page.setViewportSize({ width: 1200, height: 920 });
    await page.waitForFunction(() =>
      !document.querySelector(".viewport")?.classList.contains("viewport--rulers-hidden")
    );
    assert(!((await page.locator(".ruler-tick small").allTextContents()).includes("0")), "rulers displayed a zero label");
    const verticalRulerPositions = await page.locator(".ruler--vertical small").evaluateAll((labels) =>
      Object.fromEntries(labels.map((label) => [
        label.textContent,
        label.parentElement.getBoundingClientRect().top,
      ]))
    );
    assert(verticalRulerPositions[100] > verticalRulerPositions[700],
      "vertical ruler values did not increase upward from the page bottom");

    const selectTool = page.getByRole("button", { name: "Select" });
    const zoom = page.locator('.zoom-select[aria-label="Zoom"]');
    const shell = page.locator('.page-shell[data-page-id="11"]');
    assert.equal(await zoom.inputValue(), "fit",
      "the editor did not start in fit zoom mode");
    assert.match(await zoom.locator('option[value="fit"]').textContent(), /^Fit \d+%$/,
      "fit zoom did not report its current percentage");
    const fitScale = await shell.evaluate((node) =>
      Number(node.style.getPropertyValue("--preview-scale"))
    );
    const fitWidth = (await shell.boundingBox()).width;
    assert.equal(await page.getByRole("button", { name: /Zoom (in|out)/ }).count(), 0,
      "the toolbar retained button-based zoom controls");
    await dispatchPinch(page, -120);
    await page.waitForFunction((previousScale) =>
      Number(document.querySelector('.page-shell[data-page-id="11"]')
        ?.style.getPropertyValue("--preview-scale")) > previousScale,
    fitScale);
    const enlargedScale = await shell.evaluate((node) =>
      Number(node.style.getPropertyValue("--preview-scale"))
    );
    assert.equal(await zoom.inputValue(), "manual",
      "zooming in did not switch to a manual percentage");
    assert(enlargedScale > fitScale,
      "pinching out did not enlarge the page");
    await dispatchPinch(page, 120);
    await page.waitForFunction((previousScale) =>
      Number(document.querySelector('.page-shell[data-page-id="11"]')
        ?.style.getPropertyValue("--preview-scale")) < previousScale,
    enlargedScale);
    assert(Math.abs((await shell.boundingBox()).width - fitWidth) < 2,
      "pinching in did not reverse the previous pinch");
    await zoom.selectOption("actual");
    await page.waitForFunction(() =>
      document.querySelector('.page-shell[data-page-id="11"]')
        ?.style.getPropertyValue("--preview-scale") === "1"
    );
    assert(Math.abs((await shell.boundingBox()).width - 1280) < 1,
      "100% zoom did not map one page point to one CSS pixel");
    const centerBeforeZoom = await horizontalViewportCenterRatio(page);
    await dispatchPinch(page, -90);
    const centerAfterZoom = await horizontalViewportCenterRatio(page);
    assert(Math.abs(centerAfterZoom - centerBeforeZoom) < 0.01,
      "pinch zoom changed the horizontal point under its anchor");

    const panTool = page.getByRole("button", { name: "Pan view" });
    await panTool.click();
    assert.equal(await panTool.getAttribute("aria-pressed"), "true",
      "the view movement mode did not activate");
    assert.equal(await page.locator(".object-hit").count(), 0,
      "view movement mode retained object editing hit targets");
    const viewport = page.locator(".viewport");
    const panStart = await viewport.evaluate((node) => {
      node.scrollLeft = Math.max(0, node.scrollWidth - node.clientWidth) * 0.25;
      node.scrollTop = Math.max(0, node.scrollHeight - node.clientHeight) * 0.25;
      return { left: node.scrollLeft, top: node.scrollTop };
    });
    const viewportBox = await viewport.boundingBox();
    assert(viewportBox, "the editor viewport had no interactive bounds");
    await page.mouse.move(
      viewportBox.x + viewportBox.width * 0.55,
      viewportBox.y + viewportBox.height * 0.55,
    );
    await page.mouse.down();
    await page.mouse.move(
      viewportBox.x + viewportBox.width * 0.55 - 70,
      viewportBox.y + viewportBox.height * 0.55 - 55,
      { steps: 3 },
    );
    await page.mouse.up();
    const panEnd = await viewport.evaluate((node) => ({
      left: node.scrollLeft,
      top: node.scrollTop,
    }));
    assert(panEnd.left > panStart.left && panEnd.top > panStart.top,
      `dragging in view movement mode did not move the viewpoint: ${JSON.stringify({ panStart, panEnd })}`);
    await selectTool.click();
    assert((await page.locator(".object-hit").count()) > 0,
      "selection mode did not restore object editing hit targets");
    await zoom.selectOption("fit");
    await page.waitForFunction((expectedScale) =>
      Math.abs(Number(document.querySelector('.page-shell[data-page-id="11"]')
        ?.style.getPropertyValue("--preview-scale")) - expectedScale) < 0.001,
    fitScale);

    assert.equal(await page.locator(".toolbar > .shape-style-controls").count(), 0,
      "selection mode displayed shape or icon color controls");
    await zoom.focus();
    await page.keyboard.press("l");
    assert.equal(await selectTool.getAttribute("aria-pressed"), "true",
      "the line shortcut activated while a form control had focus");

    const shapePicker = page.locator(".shape-picker");
    await shapePicker.locator("summary").click();
    assert.equal(await page.locator(".shape-picker-panel").isVisible(), true,
      "shape gallery did not open from the toolbar");
    assert.deepEqual(
      await shapePicker.locator(".shape-picker-section > strong").allTextContents(),
      ["Lines", "Basic shapes"],
      "shape gallery did not separate line and basic shape tools",
    );
    assert.equal(
      await shapePicker.getByRole("button", { name: "Block arrow" }).count(),
      1,
      "the block arrow tool was not distinguished from a line arrow",
    );
    assert.equal(
      await shapePicker.getByRole("button", { name: "Line" })
        .locator(".shape-choice-shortcut").textContent(),
      "L",
      "the line shortcut was not discoverable from the gallery",
    );
    const rectangleTool = shapePicker.getByRole("button", { name: "Rectangle" });
    assert.equal(await rectangleTool.isEnabled(), true,
      "an editable page disabled its rectangle tool");
    const rectangleTile = await rectangleTool.boundingBox();
    assert(rectangleTile?.width >= 70 && rectangleTile?.height >= 70,
      `shape gallery tile was too small: ${JSON.stringify(rectangleTile)}`);
    await rectangleTool.click();
    const insertionStrokeStyle = page.locator(
      ".toolbar > .shape-style-controls .stroke-style-picker",
    );
    await insertionStrokeStyle.locator("summary").click();
    await insertionStrokeStyle.getByRole("button", { name: "Dotted" }).click();
    const placement = page.locator('.page-shell[data-page-id="11"] .shape-placement-hit');
    const placementBox = await placement.boundingBox();
    assert(placementBox, "shape placement layer was not rendered");
    const startX = placementBox.x + placementBox.width * 0.2;
    const startY = placementBox.y + placementBox.height * 0.25;
    const endX = placementBox.x + placementBox.width * 0.42;
    const endY = placementBox.y + placementBox.height * 0.48;
    await page.mouse.move(startX, startY);
    await page.mouse.down();
    await page.mouse.move(endX, endY, { steps: 3 });
    assert.equal(await page.locator(".shape-placement-ghost").count(), 1,
      "shape drag did not display its provisional bounds");
    await page.mouse.up();
    const inserted = await lastMessage(page, "insertShape");
    assert(inserted, "shape placement did not send an insertion request");
    assert.equal(inserted.pageId, 11);
    assert.equal(inserted.kind, "rectangle");
    assert(inserted.bounds.width > 4 && inserted.bounds.height > 4,
      `shape placement sent invalid bounds: ${JSON.stringify(inserted.bounds)}`);
    assert.deepEqual(inserted.fill, {
      enabled: true,
      color: "#e8f1ff",
      opacity: 1,
    });
    assert.deepEqual(inserted.stroke, {
      enabled: true,
      color: "#2563eb",
      width: 1.6,
      style: "dotted",
    });
    const provisional = page.locator(".shape-placement-preview");
    assert.equal(await provisional.count(), 1,
      "the provisional shape disappeared before the source edit was reflected");
    assert.equal(await provisional.evaluate((node) => getComputedStyle(node).fill), "rgb(232, 241, 255)",
      "the provisional shape did not use the requested fill color");
    assert.match(await provisional.evaluate((node) => getComputedStyle(node).strokeDasharray), /1\.6px.*4px/,
      "the provisional shape did not use the requested dotted stroke");
    await shapePicker.locator("summary").click();
    assert.equal(await shapePicker.getByRole("button", { name: "Circle" }).isEnabled(), false,
      "drawing tools remained enabled while an insertion was pending");
    await postShapeEditResult(page, {
      requestId: inserted.requestId,
      operation: "insert",
      status: "stale",
    });
    await page.waitForFunction(() =>
      document.querySelector('.shape-tool[aria-label="Select"]')
        ?.getAttribute("aria-pressed") === "true"
    );
    assert.equal(await page.locator(".shape-placement-preview").count(), 0,
      "a rejected provisional shape remained on the page");

    const iconPicker = page.locator(".icon-picker");
    assert.equal(await iconPicker.locator(".icon-picker-placeholder").count(), 1,
      "the icon picker header did not use its neutral collection marker");
    await iconPicker.locator("summary").click();
    assert.equal(await page.locator(".icon-picker-panel").isVisible(), true,
      "icon gallery did not open from the toolbar");
    assert.deepEqual(
      await iconPicker.locator(".icon-style-tab").allTextContents(),
      ["All", "Solid", "Regular", "Brands"],
      "icon gallery did not expose its style filters",
    );
    await page.waitForFunction(() =>
      globalThis.__messages.some((message) => message.type === "queryIcons")
    );
    const initialIconQuery = await lastMessage(page, "queryIcons");
    assert(initialIconQuery, "opening the icon gallery did not request the catalog");
    assert.equal(initialIconQuery.query, "");
    assert.equal(initialIconQuery.style, "all");
    assert.equal(initialIconQuery.category, "all");
    assert.equal(initialIconQuery.offset, 0);
    await postIconCatalogError(page, initialIconQuery.requestId,
      "Icon catalog is temporarily unavailable.");
    const retryIcons = iconPicker.getByRole("button", { name: "Retry" });
    await retryIcons.waitFor();
    assert.match(await iconPicker.locator(".icon-catalog-status").textContent(),
      /temporarily unavailable/,
      "icon catalog failure was not shown inside the picker");
    await retryIcons.click();
    await page.waitForFunction((previousRequestId) =>
      globalThis.__messages.some((message) =>
        message.type === "queryIcons" && message.requestId > previousRequestId
      ), initialIconQuery.requestId);
    const retriedIconQuery = await lastMessage(page, "queryIcons");
    assert.equal(retriedIconQuery.offset, 0);
    const iconSearch = iconPicker.getByRole("searchbox", { name: "Search icon names" });
    await iconSearch.fill("star");
    await page.waitForFunction((previousRequestId) =>
      globalThis.__messages.some((message) =>
        message.type === "queryIcons" &&
        message.requestId > previousRequestId &&
        message.query === "star" &&
        message.style === "all"
      ), retriedIconQuery.requestId);
    const searchedIconQuery = await lastMessage(page, "queryIcons");
    assert.equal(searchedIconQuery.offset, 0);
    assert.equal(searchedIconQuery.category, "all");
    const starIcon = {
      id: "fa-solid:star",
      name: "star",
      style: "solid",
      svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><path fill="currentColor" d="M256 32L320 192L480 192L352 288L400 448L256 352L112 448L160 288L32 192L192 192Z"/></svg>',
    };
    await postIconCatalog(page, searchedIconQuery.requestId, {
      schema: 1,
      collection: "fontawesome-free",
      version: "7.2.0",
      query: "star",
      style: "all",
      category: "all",
      offset: 0,
      total_available: 2141,
      total_matches: 61,
      has_more: true,
      categories: [
        { id: "animals", label: "Animals" },
        { id: "shapes", label: "Shapes" },
      ],
      icons: [
        starIcon,
        ...Array.from({ length: 59 }, (_, index) => ({
          id: `fa-solid:test-icon-${index}`,
          name: `test-icon-${index}`,
          style: "solid",
          svg: starIcon.svg,
        })),
      ],
    });
    await page.waitForFunction(() =>
      document.querySelector(".icon-catalog-status")?.textContent === "60 of 61 icons"
    );
    const starPreview = iconPicker.getByRole("button", { name: "star, solid" })
      .locator(".icon-choice-preview");
    assert.equal(await starPreview.evaluate((node) => getComputedStyle(node).color),
      "rgb(55, 65, 81)",
      "icon previews did not start with the dark gray default color");
    assert.equal(await iconPicker.getByRole("button", { name: "Load more" }).count(), 0,
      "the icon gallery retained a manual pagination button");
    await iconPicker.locator(".icon-picker-gallery").evaluate((gallery) => {
      gallery.scrollTop = gallery.scrollHeight;
      gallery.dispatchEvent(new Event("scroll"));
    });
    await page.waitForFunction((previousRequestId) =>
      globalThis.__messages.some((message) =>
        message.type === "queryIcons" &&
        message.requestId > previousRequestId &&
        message.query === "star" &&
        message.style === "all" &&
        message.category === "all" &&
        message.offset === 60
      ), searchedIconQuery.requestId);
    const moreIconQuery = await lastMessage(page, "queryIcons");
    const regularStar = {
      id: "fa-regular:star",
      name: "star",
      style: "regular",
      svg: starIcon.svg,
    };
    await postIconCatalog(page, moreIconQuery.requestId, {
      schema: 1,
      collection: "fontawesome-free",
      version: "7.2.0",
      query: "star",
      style: "all",
      category: "all",
      offset: 60,
      total_available: 2141,
      total_matches: 61,
      has_more: false,
      categories: [
        { id: "animals", label: "Animals" },
        { id: "shapes", label: "Shapes" },
      ],
      icons: [regularStar],
    });
    await page.waitForFunction(() =>
      document.querySelector(".icon-catalog-status")?.textContent === "61 of 61 icons"
    );
    assert.equal(await iconPicker.locator(".icon-choice").count(), 61,
      "loading more icons replaced the first catalog page");
    const iconCategory = iconPicker.getByRole("combobox", { name: "Icon category" });
    await iconCategory.selectOption("shapes");
    await page.waitForFunction((previousRequestId) =>
      globalThis.__messages.some((message) =>
        message.type === "queryIcons" &&
        message.requestId > previousRequestId &&
        message.query === "star" &&
        message.style === "all" &&
        message.category === "shapes" &&
        message.offset === 0
      ), moreIconQuery.requestId);
    const categoryIconQuery = await lastMessage(page, "queryIcons");
    await postIconCatalog(page, categoryIconQuery.requestId, {
      schema: 1,
      collection: "fontawesome-free",
      version: "7.2.0",
      query: "star",
      style: "all",
      category: "shapes",
      offset: 0,
      total_available: 2141,
      total_matches: 1,
      has_more: false,
      categories: [
        { id: "animals", label: "Animals" },
        { id: "shapes", label: "Shapes" },
      ],
      icons: [starIcon],
    });
    await page.waitForFunction(() =>
      document.querySelector(".icon-catalog-status")?.textContent === "1 of 1 icons"
    );
    const starTool = iconPicker.getByRole("button", { name: "star, solid" });
    assert.equal(await starTool.isEnabled(), true,
      "an editable page disabled its icon choice");
    assert.equal(await starTool.locator("svg").count(), 1,
      "icon catalog omitted the SVG preview");
    await starTool.click();
    assert.equal(await iconPicker.locator("summary").getAttribute("aria-pressed"), "true",
      "selecting an icon did not activate icon placement");
    const iconColor = page.locator(
      '.toolbar > .icon-style-controls input[aria-label="Icon color"]',
    );
    assert.equal(await iconColor.inputValue(), "#374151",
      "icon placement did not use the dark gray default color");
    await iconColor.fill("#f59e0b");
    await iconColor.evaluate((input) => input.dispatchEvent(new Event("change", { bubbles: true })));
    const iconPlacement = page.locator(
      '.page-shell[data-page-id="11"] .shape-placement-hit',
    );
    const iconPlacementBox = await iconPlacement.boundingBox();
    assert(iconPlacementBox, "icon placement layer was not rendered");
    await page.mouse.click(
      iconPlacementBox.x + iconPlacementBox.width * 0.62,
      iconPlacementBox.y + iconPlacementBox.height * 0.34,
    );
    const insertedIcon = await lastMessage(page, "insertIcon");
    assert(insertedIcon, "icon placement did not send an insertion request");
    assert.equal(insertedIcon.pageId, 11);
    assert.equal(insertedIcon.source, "fa-solid:star");
    assert.equal(insertedIcon.color, "#f59e0b");
    assert.equal(insertedIcon.bounds.width, 72);
    assert.equal(insertedIcon.bounds.height, 72);
    const provisionalIcon = page.locator("image.icon-placement-ghost.shape-placement-preview");
    assert.equal(await provisionalIcon.count(), 1,
      "the provisional icon disappeared before the source edit was reflected");
    assert.match(await provisionalIcon.getAttribute("href"), /^data:image\/svg\+xml,/,
      "the provisional icon did not embed its SVG preview");
    assert.match(await provisionalIcon.getAttribute("href"), /%23f59e0b/,
      "the provisional icon did not use the selected color");
    await postIconEditResult(page, {
      requestId: insertedIcon.requestId,
      status: "stale",
    });
    await page.waitForFunction(() =>
      document.querySelector('.shape-tool[aria-label="Select"]')
        ?.getAttribute("aria-pressed") === "true"
    );
    assert.equal(await provisionalIcon.count(), 0,
      "a rejected provisional icon remained on the page");

    const closedShapeStroke = page.locator(
      '.toolbar > .shape-style-controls label.style-toggle',
    ).filter({ hasText: "Stroke" }).locator(
      'input[type="checkbox"]',
    );
    await closedShapeStroke.uncheck();
    await page.keyboard.press("l");
    assert.equal(await shapePicker.locator("summary").getAttribute("aria-pressed"), "true");
    assert.match(await shapePicker.locator("summary").textContent(), /Line/,
      "the L shortcut did not activate the line tool");
    const lineControls = page.locator(
      ".toolbar > .shape-style-controls--line",
    );
    assert.equal(await lineControls.locator('input[aria-label="Fill color"]').count(), 0,
      "the line tool displayed fill controls");
    assert.equal(await lineControls.locator('input[aria-label="Line color"]').count(), 1,
      "the line tool omitted its color control");
    assert.equal(await lineControls.locator('input[aria-label="Line weight"]').count(), 1,
      "the line tool omitted its weight control");

    const linePlacement = page.locator(
      '.page-shell[data-page-id="11"] .shape-placement-hit',
    );
    const linePlacementBox = await linePlacement.boundingBox();
    assert(linePlacementBox, "line placement layer was not rendered");
    const lineStartX = linePlacementBox.x + linePlacementBox.width * 0.72;
    const lineStartY = linePlacementBox.y + linePlacementBox.height * 0.2;
    const lineEndX = linePlacementBox.x + linePlacementBox.width * 0.37;
    const lineEndY = linePlacementBox.y + linePlacementBox.height * 0.61;
    await page.mouse.move(lineStartX, lineStartY);
    await page.mouse.down();
    await page.keyboard.down("Shift");
    await page.mouse.move(lineEndX, lineEndY, { steps: 3 });
    const lineGhost = page.locator("line.shape-placement-ghost");
    assert.equal(await lineGhost.count(), 1,
      "line drag did not render an SVG line ghost");
    assert.equal(
      await lineGhost.evaluate((node) => getComputedStyle(node).stroke),
      "rgb(37, 99, 235)",
      "line ghost did not use the selected line color",
    );
    assert.match(
      await lineGhost.evaluate((node) => getComputedStyle(node).strokeDasharray),
      /1\.6px.*4px/,
      "line ghost did not use the selected dotted style",
    );
    await page.mouse.up();
    await page.keyboard.up("Shift");
    const insertedLine = await lastMessage(page, "insertShape");
    assert.equal(insertedLine.kind, "line");
    assert.equal(Object.hasOwn(insertedLine, "bounds"), false,
      "line insertion was collapsed into unordered bounds");
    assert.equal(Object.hasOwn(insertedLine, "fill"), false,
      "line insertion sent an inapplicable fill style");
    assert.equal(insertedLine.stroke.enabled, true,
      "line insertion inherited the hidden closed-shape stroke toggle");
    assert(insertedLine.start.x > insertedLine.end.x &&
      insertedLine.start.y < insertedLine.end.y,
    `line insertion lost endpoint order: ${JSON.stringify(insertedLine)}`);
    const snappedAngle = Math.atan2(
      insertedLine.end.y - insertedLine.start.y,
      insertedLine.end.x - insertedLine.start.x,
    ) / (Math.PI / 12);
    assert(Math.abs(snappedAngle - Math.round(snappedAngle)) < 0.001,
      `Shift did not snap the line to 15 degree increments: ${snappedAngle}`);
    assert.equal(await page.locator("line.shape-placement-preview").count(), 1,
      "pending line did not retain its SVG preview");
    await postShapeEditResult(page, {
      requestId: insertedLine.requestId,
      operation: "insert",
      status: "stale",
    });
    await page.waitForFunction(() =>
      document.querySelector('.shape-tool[aria-label="Select"]')
        ?.getAttribute("aria-pressed") === "true"
    );

    await page.keyboard.press("l");
    const clickPlacementBox = await page.locator(
      '.page-shell[data-page-id="11"] .shape-placement-hit',
    ).boundingBox();
    assert(clickPlacementBox, "line click placement layer was not rendered");
    await page.mouse.click(
      clickPlacementBox.x + clickPlacementBox.width * 0.25,
      clickPlacementBox.y + clickPlacementBox.height * 0.72,
    );
    const defaultLine = await lastMessage(page, "insertShape");
    assert.equal(defaultLine.kind, "line");
    assert(Math.abs(defaultLine.end.y - defaultLine.start.y) < 0.001,
      `a short gesture did not create a horizontal line: ${JSON.stringify(defaultLine)}`);
    assert(Math.abs(Math.abs(defaultLine.end.x - defaultLine.start.x) - 160) < 0.1,
      `a short gesture used the wrong default line length: ${JSON.stringify(defaultLine)}`);
    await postShapeEditResult(page, {
      requestId: defaultLine.requestId,
      operation: "insert",
      status: "stale",
    });
    await page.waitForFunction(() =>
      document.querySelector('.shape-tool[aria-label="Select"]')
        ?.getAttribute("aria-pressed") === "true"
    );

    await page.keyboard.press("l");
    const edgePlacementBox = await page.locator(
      '.page-shell[data-page-id="11"] .shape-placement-hit',
    ).boundingBox();
    assert(edgePlacementBox, "right-edge line placement layer was not rendered");
    await page.mouse.click(
      edgePlacementBox.x + edgePlacementBox.width * (1270 / 1280),
      edgePlacementBox.y + edgePlacementBox.height * 0.4,
    );
    const edgeLine = await lastMessage(page, "insertShape");
    assert(edgeLine.start.x > edgeLine.end.x,
      `a right-edge click did not choose the side with room: ${JSON.stringify(edgeLine)}`);
    assert(Math.abs(edgeLine.start.x - edgeLine.end.x - 160) < 0.1,
      `a right-edge click produced a truncated line: ${JSON.stringify(edgeLine)}`);
    await postShapeEditResult(page, {
      requestId: edgeLine.requestId,
      operation: "insert",
      status: "stale",
    });
    await page.waitForFunction(() =>
      document.querySelector('.shape-tool[aria-label="Select"]')
        ?.getAttribute("aria-pressed") === "true"
    );

    await shapePicker.locator("summary").click();
    await shapePicker.getByRole("button", { name: "Circle" }).click();
    assert.equal(await shapePicker.locator("summary").getAttribute("aria-pressed"), "true");
    assert.match(await shapePicker.locator("summary").textContent(), /Circle/,
      "shape picker did not reflect the active drawing tool");
    assert.equal(
      await page.locator(
        '.toolbar > .shape-style-controls label.style-toggle',
      ).filter({ hasText: "Stroke" }).locator(
        'input[type="checkbox"]',
      ).isChecked(),
      false,
      "using the line tool changed the closed-shape stroke preference",
    );
    await page.keyboard.press("Escape");
    assert.equal(
      await page.getByRole("button", { name: "Select" }).getAttribute("aria-pressed"),
      "true",
      "Escape did not return the drawing tool to selection mode",
    );

    await page.locator('.page-shell[data-page-id="11"] .object-hit[data-object-id="101"]').click();
    await page.waitForSelector(".shape-style-editor");
    const shapeStrokeStyle = page.locator(
      ".shape-style-editor .shape-stroke-style-select select",
    );
    await shapeStrokeStyle.selectOption("dashed");
    const styleEdit = await lastMessage(page, "editShapeStyle");
    assert(styleEdit, "shape details did not send a style edit");
    assert.equal(styleEdit.nodeId, 101);
    assert.equal(styleEdit.stroke.style, "dashed");
    await postShapeEditResult(page, {
      requestId: styleEdit.requestId,
      operation: "style",
      status: "stale",
    });
    await page.getByRole("button", { name: "Lock object" }).click();
    assert.equal(
      await page.locator(".shape-style-editor input, .shape-style-editor select")
        .evaluateAll((controls) => controls.every((control) => control.disabled)),
      true,
      "locking a shape left its style controls enabled",
    );
    await page.getByRole("button", { name: "Unlock object" }).click();
    await page.locator(".close-button").click();

    const existingLineHit = page.locator(
      '.page-shell[data-page-id="11"] .object-hit[data-object-id="102"] .object-hit-line',
    );
    assert.equal(await existingLineHit.getAttribute("x1"), "760");
    assert.equal(await existingLineHit.getAttribute("y1"), "170");
    assert.equal(await existingLineHit.getAttribute("x2"), "520");
    assert.equal(await existingLineHit.getAttribute("y2"), "290");
    assert.equal(
      await existingLineHit.evaluate((node) => getComputedStyle(node).strokeWidth),
      "12px",
      "line hit target was not widened independently of its visible stroke",
    );
    await existingLineHit.click();
    await page.waitForSelector(".shape-style-editor");
    const lineHandles = page.locator(
      '.page-shell[data-page-id="11"] .object-hit[data-object-id="102"] .line-endpoint-handle',
    );
    assert.equal(await lineHandles.count(), 2,
      "selecting a line did not expose both ordered endpoint handles");
    assert.equal(await existingLineHit.count(), 1,
      "endpoint handles replaced the widened line hit target");
    const startHandleNode = page.locator(
      '.line-endpoint-handle[data-endpoint="start"]',
    );
    assert.equal(await startHandleNode.getAttribute("aria-disabled"), "false",
      "the selected line exposed a disabled start handle");
    await page.evaluate(() => new Promise((resolve) =>
      requestAnimationFrame(() => requestAnimationFrame(resolve))
    ));
    const startHandleBox = await startHandleNode.locator(
      ".line-endpoint-hit",
    ).boundingBox();
    assert(startHandleBox, "the line start handle had no interactive bounds");
    const endpointHitClass = await page.evaluate(({ x, y }) =>
      document.elementFromPoint(x, y)?.getAttribute("class"), {
      x: startHandleBox.x + startHandleBox.width / 2,
      y: startHandleBox.y + startHandleBox.height / 2,
    });
    await page.mouse.move(
      startHandleBox.x + startHandleBox.width / 2,
      startHandleBox.y + startHandleBox.height / 2,
    );
    await page.mouse.down();
    await page.keyboard.down("Shift");
    await page.mouse.move(
      startHandleBox.x + startHandleBox.width / 2 + 55,
      startHandleBox.y + startHandleBox.height / 2 - 23,
      { steps: 3 },
    );
    assert.equal(
      await page.locator('.object-hit[data-object-id="102"]')
        .evaluate((node) => node.classList.contains("is-editing-line-geometry")),
      true,
      `endpoint dragging did not show provisional line geometry; hit ${endpointHitClass}`,
    );
    await page.mouse.up();
    await page.keyboard.up("Shift");
    const geometryEdit = await lastMessage(page, "editLineGeometry");
    assert.equal(geometryEdit.nodeId, 102);
    assert.deepEqual(geometryEdit.end, { x: 520, y: 290 },
      "dragging the start handle changed or reordered the end point");
    assert.notDeepEqual(geometryEdit.start, { x: 760, y: 170 },
      "dragging the start handle retained the old start point");
    const geometryAngle = Math.atan2(
      geometryEdit.start.y - geometryEdit.end.y,
      geometryEdit.start.x - geometryEdit.end.x,
    ) / (Math.PI / 12);
    assert(Math.abs(geometryAngle - Math.round(geometryAngle)) < 0.001,
      `Shift did not snap endpoint editing to 15 degree increments: ${geometryAngle}`);
    const provisionalLine = page.locator(
      '.object-hit[data-object-id="102"] .object-hit-line-outline',
    );
    assert.equal(Number(await provisionalLine.getAttribute("x1")), geometryEdit.start.x);
    assert.equal(Number(await provisionalLine.getAttribute("y1")), geometryEdit.start.y);
    assert.equal(Number(await provisionalLine.getAttribute("x2")), geometryEdit.end.x);
    assert.equal(Number(await provisionalLine.getAttribute("y2")), geometryEdit.end.y);
    assert.equal(
      await page.locator('.line-endpoint-handle[data-endpoint="start"]')
        .getAttribute("aria-disabled"),
      "true",
      "pending line geometry left its endpoint handles interactive",
    );
    await postShapeEditResult(page, {
      requestId: geometryEdit.requestId,
      operation: "geometry",
      status: "stale",
    });
    await page.waitForFunction(() =>
      document.querySelector('.line-endpoint-handle[data-endpoint="start"]')
        ?.getAttribute("aria-disabled") === "false"
    );
    assert.equal(await page.locator(".shape-style-editor h2").textContent(), "Line style");
    assert.equal(
      await page.locator('.shape-style-editor input[aria-label="Fill color"]').count(),
      0,
      "selected line displayed fill controls",
    );
    const selectedLineStyle = page.locator(
      '.shape-style-editor select[aria-label="Line style"]',
    );
    await selectedLineStyle.selectOption("dotted");
    const lineStyleEdit = await lastMessage(page, "editShapeStyle");
    assert.equal(lineStyleEdit.nodeId, 102);
    assert.equal(lineStyleEdit.kind, "line");
    assert.equal(lineStyleEdit.stroke.style, "dotted");
    assert.equal(Object.hasOwn(lineStyleEdit, "fill"), false,
      "line style edit sent an inapplicable fill style");
    await postShapeEditResult(page, {
      requestId: lineStyleEdit.requestId,
      operation: "style",
      status: "stale",
    });
    await page.getByRole("button", { name: "Lock object" }).click();
    assert.equal(
      await page.locator(".shape-style-editor input, .shape-style-editor select")
        .evaluateAll((controls) => controls.every((control) => control.disabled)),
      true,
      "locking a line left its style controls enabled",
    );
    assert.equal(
      await page.locator('.line-endpoint-handle[data-endpoint="start"]')
        .getAttribute("aria-disabled"),
      "true",
      "locking a line left its endpoint handles enabled",
    );
    const geometryMessageCount = await messageCount(page, "editLineGeometry");
    const lockedHandleBox = await page.locator(
      '.line-endpoint-handle[data-endpoint="start"] .line-endpoint-hit',
    ).boundingBox();
    assert(lockedHandleBox, "the locked line handle disappeared");
    await page.mouse.move(
      lockedHandleBox.x + lockedHandleBox.width / 2,
      lockedHandleBox.y + lockedHandleBox.height / 2,
    );
    await page.mouse.down();
    await page.mouse.move(lockedHandleBox.x + lockedHandleBox.width / 2 + 30,
      lockedHandleBox.y + lockedHandleBox.height / 2 + 20);
    await page.mouse.up();
    assert.equal(await messageCount(page, "editLineGeometry"), geometryMessageCount,
      "a locked line accepted an endpoint edit");
    await page.getByRole("button", { name: "Unlock object" }).click();
    await page.locator(".close-button").click();

    await page.setViewportSize({ width: 480, height: 560 });
    await page.waitForFunction(() =>
      document.querySelector(".viewport")?.classList.contains("viewport--rulers-hidden")
    );
    assert.equal(await page.locator(".ruler--vertical").isVisible(), false,
      "rulers remained visible at a scale where their fixed labels obscure the page");
    const narrowToolbarBox = await page.locator(".toolbar").boundingBox();
    const narrowZoomBox = await page.locator(".zoom-controls").boundingBox();
    assert(narrowToolbarBox && narrowZoomBox &&
      narrowZoomBox.x >= narrowToolbarBox.x &&
      narrowZoomBox.y >= narrowToolbarBox.y &&
      narrowZoomBox.x + narrowZoomBox.width <= narrowToolbarBox.x + narrowToolbarBox.width &&
      narrowZoomBox.y + narrowZoomBox.height <= narrowToolbarBox.y + narrowToolbarBox.height,
    "narrow editor placed zoom controls outside the toolbar");
    assert.equal(await page.locator(".shape-style-popover").count(), 0,
      "selection mode displayed the compact shape style controls");
    await shapePicker.locator("summary").click();
    await shapePicker.getByRole("button", { name: "Rectangle" }).click();
    const stylePopover = page.locator(".shape-style-popover");
    assert.equal(await stylePopover.isVisible(), true,
      "narrow drawing toolbar omitted its style popover");
    await stylePopover.locator(":scope > summary").click();
    assert.equal(await page.locator(".shape-style-popover-panel").isVisible(), true,
      "narrow drawing toolbar did not open its style controls");
    const narrowMarginRatio = await horizontalPageMarginRatio(page);
    assert(Math.abs(narrowMarginRatio - 0.04) < 0.005,
      `narrow editor margin was not proportional to its viewport: ${narrowMarginRatio}`);
    await page.setViewportSize({ width: 400, height: 560 });
    const narrowerMarginRatio = await horizontalPageMarginRatio(page);
    assert(Math.abs(narrowerMarginRatio - narrowMarginRatio) < 0.005,
      "editor margin occupied a growing proportion of a narrower viewport");
    await page.keyboard.press("Escape");
    await page.setViewportSize({ width: 560, height: 920 });
    await page.evaluate(() => {
      globalThis.__retiringPdfRoots = [
        ...document.querySelectorAll("[data-ss-pdf-render-root='true']"),
      ];
    });

    await page.setViewportSize({ width: 560, height: 110 });
    const pageListScrollTop = await page.locator(".sidebar").evaluate((sidebar) => {
      sidebar.scrollTop = sidebar.scrollHeight;
      return sidebar.scrollTop;
    });
    assert(pageListScrollTop > 0,
      "page sidebar fixture did not produce a scrollable page list");
    await page.locator(".page-entry").nth(1).evaluate((button) => button.click());
    await page.evaluate(() => new Promise((resolve) =>
      requestAnimationFrame(() => requestAnimationFrame(resolve))
    ));
    const pageListAfterSelection = await page.locator(".sidebar").evaluate((sidebar) => ({
      top: sidebar.scrollTop,
      maximum: Math.max(0, sidebar.scrollHeight - sidebar.clientHeight),
    }));
    assert.equal(
      pageListAfterSelection.top,
      Math.min(pageListScrollTop, pageListAfterSelection.maximum),
      "selecting a page changed its position in the page list",
    );
    await page.setViewportSize({ width: 560, height: 920 });
    await page.waitForSelector('.page-shell[data-page-id="22"]');
    assert.equal(await page.locator('.page-entry.is-active small').textContent(), "Details");

    await zoom.focus();
    await page.keyboard.press("ArrowUp");
    assert.equal(await page.locator('.page-entry.is-active small').textContent(), "Details",
      "an arrow key changed pages while a form control had focus");
    await page.evaluate(() => document.activeElement?.blur());
    await page.keyboard.press("ArrowUp");
    await page.waitForSelector('.page-shell[data-page-id="11"]');
    assert.equal(await page.locator('.page-entry.is-active small').textContent(), "Overview",
      "ArrowUp did not select the previous page");
    await page.keyboard.press("ArrowDown");
    await page.waitForSelector('.page-shell[data-page-id="22"]');
    assert.equal(await page.locator('.page-entry.is-active small').textContent(), "Details",
      "ArrowDown did not select the next page");

    await page.locator("select.page-mode").selectOption("continuous");
    await page.waitForFunction(() => document.querySelectorAll(".page-shell").length === 2);
    assert.deepEqual(await page.locator(".page-caption").allTextContents(), ["Overview", "Details"]);
    await page.locator('.page-shell[data-page-id="22"] .page-source-button').click();
    assert.deepEqual(await lastMessage(page, "revealSource"), {
      type: "revealSource",
      path: "/workspace/slide.ss",
      start: 31,
      end: 90,
    });
    assert(Math.abs(await horizontalPageMarginRatio(page) - 0.04) < 0.005,
      "continuous editor margin was not proportional to its viewport");
    await zoom.selectOption("actual");
    await page.waitForFunction(() => [...document.querySelectorAll(".page-shell")].every((shell) =>
      shell.style.getPropertyValue("--preview-scale") === "1"
    ));
    assert.equal(
      await page.locator(".page-shell").evaluateAll((shells) =>
        shells.every((shell) => Math.abs(shell.getBoundingClientRect().width - 1280) < 1)
      ),
      true,
      "100% zoom was not applied to every page in continuous display",
    );
    await zoom.selectOption("fit");
    await page.waitForFunction(() => [...document.querySelectorAll(".page-shell")].every((shell) =>
      Number(shell.style.getPropertyValue("--preview-scale")) < 1
    ));
    await page.setViewportSize({ width: 560, height: 420 });
    await page.evaluate(() => new Promise((resolve) =>
      requestAnimationFrame(() => requestAnimationFrame(resolve))
    ));
    await page.keyboard.press("ArrowUp");
    await page.waitForFunction(() =>
      document.querySelector(".page-entry.is-active small")?.textContent === "Overview"
    );
    const previousPageScrollTop = await page.locator(".viewport").evaluate((viewport) =>
      viewport.scrollTop
    );
    await page.keyboard.press("ArrowDown");
    await page.waitForFunction(() =>
      document.querySelector(".page-entry.is-active small")?.textContent === "Details"
    );
    await page.evaluate(() => new Promise((resolve) =>
      requestAnimationFrame(() => requestAnimationFrame(resolve))
    ));
    const nextPageScrollTop = await page.locator(".viewport").evaluate((viewport) =>
      viewport.scrollTop
    );
    assert(
      nextPageScrollTop > previousPageScrollTop,
      `ArrowDown did not reveal the next page in continuous display: ${previousPageScrollTop} -> ${nextPageScrollTop}`,
    );
    await page.waitForFunction(() => {
      const shells = [...document.querySelectorAll(".page-shell")];
      if (shells.length !== 2) return false;
      const first = shells[0].getBoundingClientRect();
      const second = shells[1].getBoundingClientRect();
      return second.top - first.bottom >= 45;
    });
    const pageSelectionScrollTop = await page.locator(".viewport").evaluate((viewport) => {
      viewport.scrollTop = Math.min(37, viewport.scrollHeight - viewport.clientHeight);
      return viewport.scrollTop;
    });
    assert(pageSelectionScrollTop > 0, "editor fixture did not produce a scrollable viewport");
    await page.locator(".page-entry").first().click();
    await page.evaluate(() => new Promise((resolve) =>
      requestAnimationFrame(() => requestAnimationFrame(resolve))
    ));
    assert.equal(
      await page.locator(".viewport").evaluate((viewport) => viewport.scrollTop),
      pageSelectionScrollTop,
      "selecting a page from the sidebar forcibly scrolled the preview",
    );
    await page.setViewportSize({ width: 560, height: 920 });
    await page.waitForTimeout(100);
    await page.locator('.page-shell[data-page-id="11"] .ss-pdf > canvas').evaluate((canvas) => {
      canvas.dataset.identity = "retained";
    });

    await page.locator('.page-shell[data-page-id="22"] .object-hit[data-object-id="201"]').click();
    await page.waitForSelector(".object-sheet");
    assert.equal(
      await page.locator(".sheet-heading strong").textContent(),
      "label",
      "an object without a source edit target could not be selected",
    );
    assert.equal(
      await page.locator(".close-button").evaluate((button) =>
        button.parentElement?.classList.contains("object-sheet")
      ),
      true,
      "details close button remained part of the title section",
    );
    const closePlacement = await page.locator(".object-sheet").evaluate((sheet) => {
      const button = sheet.querySelector(":scope > .close-button");
      const sheetRect = sheet.getBoundingClientRect();
      const buttonRect = button.getBoundingClientRect();
      return {
        top: buttonRect.top - sheetRect.top,
        right: sheetRect.right - buttonRect.right,
      };
    });
    assert(closePlacement.top <= 10 && closePlacement.right <= 10,
      "details close button was not placed at the modal's top-right corner");
    await page.locator(".close-button").click();

    await page.locator('.page-shell[data-page-id="22"] .object-hit[data-object-id="202"]').click();
    await page.waitForSelector(".object-sheet");
    assert.equal(
      await page.locator('.page-shell[data-page-id="11"] .ss-pdf > canvas').getAttribute("data-identity"),
      "retained",
      "object selection recreated an unrelated PDF canvas",
    );
    assert.equal(await page.locator(".relation-row").count(), 3, "object details omitted explicit or fallback constraints");
    assert.equal(await page.locator(".relation-row--fallback").count(), 1, "fallback constraint was not marked");
    assert.equal(await page.locator(".relation-icon--absolute").count(), 2, "absolute constraints did not use their icon");
    assert.equal(await page.locator(".relation-icon--relative").count(), 1, "relative constraint did not use its icon");
    assert.equal(await page.locator('.page-shell[data-page-id="11"] .constraint').count(), 0,
      "selected-page constraints leaked onto another page");
    assert.equal(await page.locator('.page-shell[data-page-id="22"] .constraint').count(), 3,
      "selected-page constraints were not drawn");

    await page.locator(".object-sheet .source-button").click();
    const reveal = await lastMessage(page, "revealSource");
    assert.deepEqual(reveal, {
      type: "revealSource",
      path: "/workspace/slide.ss",
      start: 40,
      end: 75,
    });

    const detailTarget = page.locator(
      '.page-shell[data-page-id="22"] .object-hit[data-object-id="202"]',
    );
    const detailPreview = page.locator(
      '.page-shell[data-page-id="22"] .ss-item[data-ss-node-id="202"]',
    );
    const detailBeforeLock = await detailPreview.boundingBox();
    const translationsBeforeLock = await page.evaluate(() =>
      globalThis.__messages.filter((message) => message.type === "translate").length
    );
    await page.getByRole("button", { name: "Lock object" }).click();
    assert.equal(await detailTarget.getAttribute("data-object-locked"), "true",
      "locking an object did not mark its canvas target");
    assert.equal(
      await page.evaluate(() => globalThis.__persisted.objectLocks?.keys.length),
      1,
      "object locks were not persisted in the webview state",
    );
    const lockedBox = await detailTarget.boundingBox();
    await page.mouse.move(lockedBox.x + lockedBox.width / 2, lockedBox.y + lockedBox.height / 2);
    await page.mouse.down();
    await page.mouse.move(lockedBox.x + lockedBox.width / 2 + 18, lockedBox.y + lockedBox.height / 2 + 12);
    await page.mouse.up();
    assert.equal(
      await page.evaluate(() =>
        globalThis.__messages.filter((message) => message.type === "translate").length
      ),
      translationsBeforeLock,
      "dragging a locked object sent a source translation",
    );
    assert.deepEqual(await detailPreview.boundingBox(), detailBeforeLock,
      "dragging a locked object moved its preview");
    await page.getByRole("button", { name: "Unlock object" }).click();
    assert.equal(await detailTarget.getAttribute("data-object-locked"), null,
      "unlocking an object left its canvas target locked");

    const outOfOrder = structuredClone(current);
    outOfOrder.generation = current.generation + 1;
    outOfOrder.snapshot_id = "out-of-order";
    outOfOrder.layout.pages = [outOfOrder.layout.pages[0]];
    await postSnapshot(page, 99, outOfOrder);
    await page.evaluate(() => new Promise((resolve) =>
      requestAnimationFrame(() => requestAnimationFrame(resolve))
    ));
    assert.equal(await page.locator(".page-shell").count(), 2, "an older snapshot replaced the current editor view");
    assert.equal(await page.locator(".object-sheet").count(), 1, "an older snapshot cleared the current selection");

    const finalSnapshot = await exerciseTranslationLifecycle(page, current);

    await page.waitForFunction(() =>
      document.querySelector('.page-shell[data-page-id="11"] .ss-pdf')
        ?.dataset.ssPdfRendered === "true"
    );
    await page.locator('.page-shell[data-page-id="11"] .ss-pdf > canvas').evaluate((canvas) => {
      canvas.dataset.identity = "retained-after-update";
    });
    await page.locator(".close-button").click();
    assert.equal(await page.locator(".object-sheet").count(), 0, "details sheet did not close");
    await page.locator(".activity-theme").click();
    assert.equal(await page.locator("html").getAttribute("data-theme"), "light");
    assert.equal(await page.evaluate(() => globalThis.__persisted.theme), "light");
    assert.equal(
      await page.locator('.page-shell[data-page-id="11"] .ss-pdf > canvas').getAttribute("data-identity"),
      "retained-after-update",
      "theme change recreated a rendered PDF canvas",
    );

    const failed = structuredClone(finalSnapshot);
    failed.stale = true;
    failed.build_diagnostics = [
      {
        uri: "file:///workspace/slide.ss",
        range: {
          start: { line: 11, character: 3 },
          end: { line: 11, character: 8 },
        },
        code: "ExpectedExpression",
        message: "expected an expression after '='",
      },
    ];
    await postSnapshot(page, 108, failed, 6);
    await page.waitForSelector(".toast--error");
    await expectBuildStatus(page, "failed", "Build failed");
    assert.equal(
      await page.locator(".toast--error").textContent(),
      "Build failed. The preview is showing the last successful result.\n" +
        "slide.ss:12:4 [ExpectedExpression] expected an expression after '='",
      "stale preview did not explain its build failure",
    );
    await postSnapshot(page, 109, failed, 6);
    assert.equal(
      await page.locator(".toast--error").count(),
      1,
      "a repeated failed build cleared its diagnostic message",
    );
    await postBuildStatus(page, 110, "building");
    await page.waitForFunction(() => !document.querySelector(".toast--error"));
    await expectBuildStatus(page, "building", "Building…");
    assert.equal(await page.locator(".build-status-duration").count(), 0,
      "a new build retained the previous build duration");
    await postSnapshot(page, 110, finalSnapshot, 7);
    await page.waitForFunction(() => !document.querySelector(".toast--error"));
    await expectBuildStatus(page, "complete", "Build complete");

    await page.evaluate(() => {
      window.postMessage({
        type: "error",
        revision: 111,
        buildDurationMs: 456,
        message: "WYSIWYG preview update failed.",
      }, "*");
    });
    await page.waitForSelector(".toast--error");
    await expectBuildStatus(page, "failed", "Build failed");
    assert.equal(await page.locator(".build-status-duration").textContent(), "456 ms");
    await postSnapshot(page, 112, finalSnapshot, 7);
    await page.waitForFunction(() => !document.querySelector(".toast--error"));
    await expectBuildStatus(page, "complete", "Build complete");
    await page.locator('.page-shell[data-page-id="11"] .ss-pdf > canvas')
      .evaluate((canvas) => {
        canvas.dataset.identity = "retained-through-status";
      });
    assert.equal(
      await page.locator(".toast--error").count(),
      0,
      "a successful recovery retained the previous preview error",
    );

    await page.evaluate(() => {
      window.postMessage({
        type: "error",
        revision: 111,
        buildDurationMs: 1,
        message: "obsolete preview failure",
      }, "*");
    });
    await page.waitForTimeout(50);
    assert.equal(
      await page.locator(".toast--error").count(),
      0,
      "an obsolete preview error replaced a newer snapshot",
    );

    await postBuildStatus(page, 113, "building");
    await expectBuildStatus(page, "building", "Building…");
    await postBuildStatus(page, 113, "unavailable");
    await expectBuildStatus(
      page,
      "unavailable",
      "Language server unavailable",
    );
    await postBuildStatus(page, 112, "building");
    await expectBuildStatus(
      page,
      "unavailable",
      "Language server unavailable",
    );
    assert.equal(
      await page.locator('.page-shell[data-page-id="11"] .ss-pdf > canvas')
        .getAttribute("data-identity"),
      "retained-through-status",
      "build status changes recreated the rendered preview",
    );

    await page.getByRole("button", { name: "Pages" }).click();
    assert.equal(await page.locator("aside.sidebar").count(), 0, "active sidebar did not close through its activity button");
    await page.getByRole("button", { name: "Outline" }).click();
    assert.equal(await page.locator(".sidebar-title").textContent(), "Outline");
    assert(await page.locator(".outline-row").count() >= 4, "outline sidebar omitted document structure");
    const outlineLock = page.getByRole("button", { name: "Lock Detail" });
    await outlineLock.click();
    assert.equal(
      await page.locator('.object-hit[data-object-id="202"]').first()
        .getAttribute("data-object-locked"),
      "true",
      "the outline lock did not affect the canvas object",
    );
    await page.getByRole("button", { name: "Unlock Detail" }).click();

    const restarted = structuredClone(finalSnapshot);
    restarted.generation = 1;
    restarted.snapshot_id = "1-restarted";
    restarted.layout.pages[1].name = "Restarted";
    await postBuildStatus(page, 114, "building");
    await expectBuildStatus(page, "building", "Building…");
    await postSnapshot(page, 114, restarted, 7);
    await expectBuildStatus(page, "complete", "Build complete");
    await page.waitForFunction(() => [...document.querySelectorAll(".page-caption")]
      .some((caption) => caption.textContent === "Restarted"));
    assert.equal(await page.evaluate(() => globalThis.__retiringPdfRoots.every((root) =>
      !root.isConnected && root.dataset.ssPdfRenderRoot === undefined
    )), true, "snapshot replacement retained PDF controllers from the old snapshot");

    const lifecycle = await page.evaluate(async () => {
      const pdf = await import("./pdf.js");
      const emptied = document.createElement("div");
      emptied.innerHTML = '<div class="ss-pdf"></div>';
      document.body.append(emptied);
      const obsolete = pdf.renderPdfItems(emptied);
      emptied.replaceChildren();
      await pdf.renderPdfItems(emptied);
      await obsolete;

      const pending = document.createElement("div");
      pending.innerHTML = '<div class="ss-pdf"></div>';
      document.body.append(pending);
      const starting = pdf.renderPdfItems(pending);
      await pdf.disposePdfRuntime();
      await starting;
      return {
        emptied: emptied.dataset.ssPdfRenderRoot,
        pending: pending.dataset.ssPdfRenderRoot,
      };
    });
    assert.equal(lifecycle.emptied, undefined,
      "removing every PDF item retained the old editor mount");
    assert.equal(lifecycle.pending, undefined,
      "editor PDF runtime disposal retained an in-flight mount");
  } finally {
    releasePdfRequest?.();
    await page.close();
  }
});

async function postSnapshot(page, revision, value, documentVersion = 1) {
  await page.evaluate(({ deliveryRevision, snapshotValue, version }) => {
    window.postMessage({
      type: "snapshot",
      revision: deliveryRevision,
      documentVersion: version,
      buildDurationMs: 1234,
      snapshot: snapshotValue,
    }, "*");
  }, { deliveryRevision: revision, snapshotValue: value, version: documentVersion });
}

async function postBuildStatus(page, revision, status) {
  await page.evaluate((message) => window.postMessage(message, "*"), {
    type: "buildStatus",
    revision,
    status,
  });
}

async function postShapeEditResult(page, result) {
  await page.evaluate((message) => window.postMessage({
    type: "shapeEditResult",
    ...message,
  }, "*"), result);
}

async function postIconCatalog(page, requestId, result) {
  await page.evaluate(({ catalogRequestId, catalogResult }) => window.postMessage({
    type: "iconCatalog",
    requestId: catalogRequestId,
    result: catalogResult,
  }, "*"), { catalogRequestId: requestId, catalogResult: result });
}

async function postIconCatalogError(page, requestId, message) {
  await page.evaluate((error) => window.postMessage({
    type: "iconCatalogError",
    requestId: error.requestId,
    message: error.message,
  }, "*"), { requestId, message });
}

async function postIconEditResult(page, result) {
  await page.evaluate((message) => window.postMessage({
    type: "iconEditResult",
    ...message,
  }, "*"), result);
}

async function horizontalViewportCenterRatio(page) {
  return page.locator(".viewport").evaluate((viewport) =>
    (viewport.scrollLeft + viewport.clientWidth / 2) / viewport.scrollWidth
  );
}

async function dispatchPinch(page, deltaY) {
  const viewport = page.locator(".viewport");
  const box = await viewport.boundingBox();
  assert(box, "the editor viewport had no bounds for pinch zoom");
  await viewport.dispatchEvent("wheel", {
    ctrlKey: true,
    deltaMode: 0,
    deltaY,
    clientX: box.x + box.width / 2,
    clientY: box.y + box.height / 2,
  });
}

async function expectBuildStatus(page, status, label) {
  await page.waitForFunction(({ expectedStatus, expectedLabel }) => {
    const node = document.querySelector(".build-status");
    return node?.classList.contains(`build-status--${expectedStatus}`) &&
      node.querySelector(".build-status-label")?.textContent === expectedLabel;
  }, { expectedStatus: status, expectedLabel: label });
  const node = page.locator(".build-status");
  assert.equal(await node.getAttribute("role"), "status");
  assert.equal(await node.getAttribute("title"), label);
}

async function horizontalPageMarginRatio(page) {
  await page.waitForFunction(() => {
    const viewport = document.querySelector(".viewport");
    const surface = document.querySelector(".page-surface");
    if (!viewport || !surface) return false;
    const viewportRect = viewport.getBoundingClientRect();
    const surfaceRect = surface.getBoundingClientRect();
    const expectedMargin = viewportRect.width * 0.04;
    return Math.abs(surfaceRect.left - viewportRect.left - expectedMargin) < 1;
  });
  return await page.evaluate(() => {
    const viewportRect = document.querySelector(".viewport").getBoundingClientRect();
    const surfaceRect = document.querySelector(".page-surface").getBoundingClientRect();
    return (surfaceRect.left - viewportRect.left) / viewportRect.width;
  });
}

async function lastMessage(page, type) {
  return await page.evaluate((messageType) => {
    const values = globalThis.__messages.filter((message) => message.type === messageType);
    return values.at(-1) ?? null;
  }, type);
}

async function messageCount(page, type) {
  return await page.evaluate(
    (messageType) => globalThis.__messages.filter((message) =>
      message.type === messageType
    ).length,
    type,
  );
}
