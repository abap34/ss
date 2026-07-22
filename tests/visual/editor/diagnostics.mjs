import assert from "node:assert/strict";

export async function exerciseBuildDiagnosticMessages(
  browser,
  baseUrl,
  successfulSnapshot,
) {
  const page = await browser.newPage({ viewport: { width: 560, height: 920 } });
  try {
    await page.goto(`${baseUrl}/index.html`, { waitUntil: "networkidle" });
    await page.waitForFunction(() =>
      globalThis.__messages?.some((message) => message.type === "ready")
    );

    const initialFailure = emptyFailedSnapshot(successfulSnapshot);
    await postSnapshot(page, 1, initialFailure, 1);
    await page.waitForSelector(".toast--error");
    assert.equal(
      await page.locator(".build-status-label").textContent(),
      "Build failed",
    );
    const initialMessage = await page.locator(".toast--error").textContent();
    assert(initialMessage.startsWith("Build failed. No preview is available yet."));
    assert(initialMessage.includes(
      "my slide.ss:4:5 [FirstError] first error with extra whitespace",
    ));
    assert(initialMessage.includes("theme.ss:8:2 [SecondError] second error"));
    assert(!initialMessage.includes("fifth error"));
    assert(!initialMessage.includes("sixth error"));
    assert(initialMessage.endsWith("2 more errors."));

    await postSnapshot(page, 2, successfulSnapshot, 2);
    await page.waitForFunction(() => !document.querySelector(".toast--error"));
    assert.equal(
      await page.locator(".build-status-label").textContent(),
      "Build complete",
    );

    const failedUpdate = structuredClone(successfulSnapshot);
    failedUpdate.stale = true;
    failedUpdate.build_diagnostics = [];
    await postSnapshot(page, 3, failedUpdate, 3);
    assert.equal(
      await page.locator(".toast--error").textContent(),
      "Build failed. The preview is showing the last successful result.",
      "failed build without a located diagnostic used an ambiguous message",
    );

    await postSnapshot(page, 4, successfulSnapshot, 4);
    await page.waitForFunction(() => !document.querySelector(".toast--error"));

    await page.evaluate(() => {
      window.postMessage({
        type: "error",
        revision: 5,
        buildDurationMs: 120,
        message: "Snapshot request failed with an internal compiler error.",
      }, "*");
    });
    await page.waitForSelector(".toast--error");
    await page.waitForTimeout(5_100);
    assert.equal(
      await page.locator(".toast--error").textContent(),
      "Snapshot request failed with an internal compiler error.",
      "an unrecovered build failure disappeared without a successful build",
    );
    await postSnapshot(page, 6, successfulSnapshot, 5);
    await page.waitForFunction(() => !document.querySelector(".toast--error"));
  } finally {
    await page.close();
  }
}

function emptyFailedSnapshot(source) {
  const result = structuredClone(source);
  result.snapshot_id = "";
  result.generation = 1;
  result.stale = true;
  result.layout = {
    pages: [],
    objects: [],
    anchors: [],
    relations: [],
    failures: [],
  };
  result.display = {
    schema: 2,
    html: "",
    css: "",
    has_pdf: false,
    assets: [],
  };
  result.outline = [];
  result.editing = [];
  result.build_diagnostics = [
    diagnostic("file:///workspace/my%20slide.ss", 3, 4, "FirstError",
      " first error\nwith   extra whitespace "),
    diagnostic("file:///workspace/theme.ss", 7, 1, "SecondError",
      "second error"),
    diagnostic("file:///workspace/data.ss", 0, 0, "ThirdError",
      "third error"),
    diagnostic("file:///workspace/font.ss", 1, 0, "FourthError",
      "fourth error"),
    diagnostic("file:///workspace/image.ss", 2, 0, "FifthError",
      "fifth error"),
    diagnostic("file:///workspace/math.ss", 3, 0, "SixthError",
      "sixth error"),
  ];
  return result;
}

function diagnostic(uri, line, character, code, message) {
  return {
    uri,
    range: {
      start: { line, character },
      end: { line, character: character + 1 },
    },
    code,
    message,
  };
}

async function postSnapshot(page, revision, snapshot, documentVersion) {
  await page.evaluate(({ value, deliveryRevision, version }) => {
    window.postMessage({
      type: "snapshot",
      revision: deliveryRevision,
      documentVersion: version,
      buildDurationMs: 875,
      snapshot: value,
    }, "*");
  }, { value: snapshot, deliveryRevision: revision, version: documentVersion });
}
