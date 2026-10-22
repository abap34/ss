import assert from "node:assert/strict";

export async function exerciseThumbnails(browser, baseUrl, snapshot) {
  const page = await browser.newPage({ viewport: { width: 600, height: 800 } });
  const pdfRequests = [];
  const errors = [];
  page.on("request", (request) => {
    if (new URL(request.url()).pathname.endsWith(".pdf")) pdfRequests.push(request.url());
  });
  page.on("pageerror", (error) => errors.push(error.message));
  try {
    await page.goto(`${baseUrl}/thumbnails.html`);
    const result = await page.evaluate(async (snapshot) => {
      const { renderPage, applyDisplayTranslationPatch, disposePages } = await import("./document.js");
      const style = document.createElement("style");
      style.textContent = snapshot.display.css;
      document.head.append(style);
      const template = document.createElement("template");
      template.innerHTML = snapshot.display.html;
      const source = template.content.querySelector(".ss-page");
      const text = source.querySelector(".ss-text");
      text.dataset.ssNodeId = "301";
      text.style.transform = "rotate(5deg)";
      text.style.clipPath = "inset(0)";
      const run = text.querySelector(".ss-text-run");
      run.style.cssText = "left:0;top:0;width:200pt;height:30pt;font:20pt/30pt ExampleFont;color:#286254";
      run.replaceChildren();
      for (let index = 0; index < 600; index += 1) {
        const cluster = document.createElement("span");
        cluster.className = "ss-text-cluster";
        cluster.textContent = "x";
        run.append(cluster);
      }
      source.querySelector(".ss-pdf").dataset.ssNodeId = "401";
      source.insertAdjacentHTML("beforeend", '<div class="ss-semantic-layer">Accessible text</div><a class="ss-link">Link</a>');
      const pages = [];
      const html = [];
      for (let index = 0; index < 16; index += 1) {
        const id = 100 + index;
        pages.push({ ...snapshot.layout.pages[0], id, index: index + 1 });
        source.dataset.ssPageId = String(id);
        html.push(source.outerHTML);
      }
      snapshot.layout.pages = pages;
      snapshot.display.html = html.join("");
      snapshot.display.translations = [{ node_id: 101, x: 10, y: 20 }];
      const sidebar = document.createElement("div");
      sidebar.className = "sidebar";
      sidebar.style.cssText = "width:200px;height:760px;overflow:auto";
      document.body.append(sidebar);
      for (const model of pages) {
        const frame = document.createElement("div");
        frame.className = "page-thumbnail";
        frame.style.cssText = "width:180px;margin:10px";
        frame.append(renderPage(snapshot, model.id, true));
        sidebar.append(frame);
      }
      await frame();
      await frame();
      const first = sidebar.querySelector(".ss-page");
      await waitFor(() => first.querySelector(".ss-pdf > img"));
      const firstImageSource = first.querySelector(".ss-pdf > img").src;
      const line = first.querySelector(".thumbnail-text-line");
      const shape = first.querySelector('[data-ss-node-id="101"]');
      const initialTranslation = shape.style.translate;
      applyDisplayTranslationPatch(snapshot.display, [
        { node_id: 101, x: 12, y: 24 },
        { node_id: 301, x: 3, y: 4 },
        { node_id: 401, x: 5, y: 6 },
      ]);
      const beforeScroll = first.getBoundingClientRect().width;
      sidebar.scrollTop = sidebar.scrollHeight;
      await waitFor(() => sidebar.lastElementChild.querySelector(".ss-pdf > img"));
      const result = {
        pages: sidebar.querySelectorAll(".ss-page").length,
        clusters: sidebar.querySelectorAll(".ss-text-cluster, .ss-text-run").length,
        lines: sidebar.querySelectorAll(".thumbnail-text-line").length,
        pdfContainers: sidebar.querySelectorAll(".ss-pdf").length,
        pdfCanvases: sidebar.querySelectorAll("canvas").length,
        firstImageSource,
        lastImageSource: sidebar.lastElementChild.querySelector(".ss-pdf > img").src,
        semanticNodes: sidebar.querySelectorAll(".ss-semantic-layer, .ss-link").length,
        text: sidebar.textContent,
        shapeColor: getComputedStyle(shape).backgroundColor,
        lineColor: getComputedStyle(line).backgroundColor,
        lineWidth: line.style.width,
        fontFamily: line.style.fontFamily,
        svgLines: sidebar.querySelectorAll("svg line").length,
        transform: first.querySelector('[data-ss-node-id="301"]').style.transform,
        clip: first.querySelector('[data-ss-node-id="301"]').style.clipPath,
        initialTranslation,
        translations: [101, 301, 401].map((id) =>
          first.querySelector(`[data-ss-node-id="${id}"]`).style.translate),
        width: beforeScroll,
        domNodes: sidebar.querySelectorAll("*").length,
        retained: renderPage(snapshot, 100, true) === first.parentElement,
      };
      await new Promise((resolve) => setTimeout(resolve, 100));
      disposePages(snapshot);
      sidebar.remove();
      return result;

      function frame() {
        return new Promise((resolve) => requestAnimationFrame(resolve));
      }

      async function waitFor(predicate) {
        const deadline = performance.now() + 5000;
        while (!predicate()) {
          if (performance.now() > deadline) throw new Error("thumbnail image timed out");
          await frame();
        }
      }
    }, snapshot);
    assert.equal(result.pages, 16);
    assert.equal(result.clusters, 0, "thumbnail cloned individual text glyphs");
    assert.equal(result.lines, 16, "thumbnail omitted the text outline");
    assert.equal(result.pdfContainers, 16, "thumbnail omitted a PDF image placement");
    assert.equal(result.pdfCanvases, 0, "thumbnail retained a PDF canvas");
    assert.match(result.firstImageSource, /^data:image\/png;base64,/);
    assert.equal(result.firstImageSource, result.lastImageSource,
      "identical PDF placements did not share a fixed image");
    assert.equal(result.semanticNodes, 0, "thumbnail duplicated semantic text or links");
    assert.equal(result.text, "", "thumbnail retained text that requires font layout");
    assert.equal(result.shapeColor, "rgb(183, 216, 208)");
    assert.equal(result.lineColor, "rgb(40, 98, 84)");
    assert.equal(result.lineWidth, "200pt");
    assert.equal(result.fontFamily, "sans-serif", "thumbnail retained an embedded font dependency");
    assert.equal(result.svgLines, 16, "thumbnail discarded vector graphics");
    assert.equal(result.transform, "rotate(5deg)");
    assert.equal(result.clip, "inset(0px)");
    assert.equal(result.initialTranslation, "10pt 20pt");
    assert.deepEqual(result.translations, ["22pt 44pt", "3pt 4pt", "5pt 6pt"],
      "thumbnail positions did not follow document translation patches");
    assert(result.width > 170 && result.width < 190, "thumbnail did not fit its sidebar frame");
    assert(result.domNodes < 250, "thumbnail duplicated the source's 9600 text glyphs");
    assert.equal(result.retained, true, "thumbnail was rebuilt without a display change");
    assert.equal(pdfRequests.length, 1, "scrolling the page list reloaded the same PDF");
    assert.deepEqual(errors, []);
  } finally {
    await page.close();
  }
}
