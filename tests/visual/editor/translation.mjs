import assert from "node:assert/strict";

export async function exerciseTranslationLifecycle(page, current) {
  const target = page.locator(
    '.page-shell[data-page-id="22"] .object-hit[data-object-id="202"]',
  );
  const previewTarget = page.locator(
    '.page-shell[data-page-id="22"] .ss-item[data-ss-node-id="202"]',
  );
  const box = await target.boundingBox();
  const initialPreviewBox = await previewTarget.boundingBox();
  assert(box && box.width > 0 && box.height > 0,
    "movable object had no interactive bounds");
  assert(initialPreviewBox, "movable object had no rendered preview bounds");

  await page.keyboard.down("Shift");
  await drag(page, box, 14, 9);
  await page.keyboard.up("Shift");
  const translate = await lastMessage(page, "translate");
  assert.equal(translate.snapshotId, current.snapshot_id);
  assert.equal(translate.nodeId, 202);
  assert.equal(translate.pageId, 22);
  assert.equal(translate.mode, "relative");
  assert(Number.isSafeInteger(translate.requestId));
  assert(
    translate.toBounds.x > translate.fromBounds.x &&
      translate.toBounds.y > translate.fromBounds.y,
    `drag did not update both coordinates: ${JSON.stringify(translate)}`,
  );
  await page.waitForSelector(
    '.page-shell[data-page-id="22"] .ss-item[data-ss-node-id="202"]' +
      '[data-ss-pending-translation="true"]',
  );
  assert.equal(
    await previewTarget.evaluate((item) => item.style.transform),
    "scale(1)",
    "optimistic translation replaced the item's existing transform",
  );
  await settleLayout(page);
  const firstPreviewBox = await previewTarget.boundingBox();
  assert(
    firstPreviewBox.x > initialPreviewBox.x &&
      firstPreviewBox.y > initialPreviewBox.y,
    "the preview returned to its compiled position after pointer release",
  );

  const firstMessageCount = await messageCount(page, "translate");
  const movedTargetBox = await target.boundingBox();
  await drag(page, movedTargetBox, 10, 7);
  await settleLayout(page);
  assert.equal(
    await messageCount(page, "translate"),
    firstMessageCount,
    "a rapid follow-up drag queued another source edit before the first completed",
  );
  const secondOptimisticBox = await previewTarget.boundingBox();
  assert(
    secondOptimisticBox.x > firstPreviewBox.x &&
      secondOptimisticBox.y > firstPreviewBox.y,
    `a rapid follow-up drag did not update the optimistic position: ${
      JSON.stringify({ firstPreviewBox, secondOptimisticBox, movedTargetBox })
    }`,
  );

  await postEditResult(page, {
    type: "editResult",
    requestId: translate.requestId,
    status: "applied",
    documentVersion: 2,
  });
  const firstApplied = translatedSnapshot(
    current,
    translate.toBounds,
    "11-first-applied",
  );
  await postSnapshot(page, 101, firstApplied, 2);
  await page.waitForFunction(
    (count) => globalThis.__messages.filter((message) =>
      message.type === "translate"
    ).length > count,
    firstMessageCount,
  );
  const followUp = await lastMessage(page, "translate");
  assert.equal(followUp.snapshotId, firstApplied.snapshot_id);
  assert.equal(followUp.nodeId, 202);
  assert(Math.abs(followUp.fromBounds.x - translate.toBounds.x) < 0.001);
  assert(Math.abs(followUp.fromBounds.y - translate.toBounds.y) < 0.001);
  assert(followUp.toBounds.x > followUp.fromBounds.x);
  assert(followUp.toBounds.y > followUp.fromBounds.y);
  await settleLayout(page);
  const rebasedPreviewBox = await previewTarget.boundingBox();
  assert(
    Math.abs(rebasedPreviewBox.x - secondOptimisticBox.x) < 1 &&
      Math.abs(rebasedPreviewBox.y - secondOptimisticBox.y) < 1,
    "an intermediate compiled snapshot displaced the latest optimistic position",
  );

  await postEditResult(page, {
    type: "editResult",
    requestId: followUp.requestId,
    status: "applied",
    documentVersion: 3,
  });
  assert.equal(
    await page.locator(".toast--success").count(),
    0,
    "the source-edit acknowledgement reported success before the preview was verified",
  );
  const finalSnapshot = translatedSnapshot(
    firstApplied,
    followUp.toBounds,
    "12-second-applied",
  );
  await postSnapshot(page, 102, finalSnapshot, 3);
  await page.waitForFunction(() =>
    !document.querySelector("[data-ss-pending-translation]")
  );
  await page.waitForSelector(".toast--success");
  assert.equal(
    await page.locator(".toast--success").textContent(),
    "Position updated.",
    "a verified position update did not report success",
  );
  assert.equal(
    await page.locator(".toast--success").getAttribute("role"),
    "status",
    "a successful update used an error announcement role",
  );
  await settleLayout(page);
  const authoritativePreviewBox = await previewTarget.boundingBox();
  assert(
    Math.abs(authoritativePreviewBox.x - secondOptimisticBox.x) < 1 &&
      Math.abs(authoritativePreviewBox.y - secondOptimisticBox.y) < 1,
    "the authoritative snapshot changed the accepted optimistic position",
  );

  const staleRequestCount = await messageCount(page, "translate");
  await drag(page, await target.boundingBox(), 9, 6);
  const staleRequest = await lastMessage(page, "translate");
  await settleLayout(page);
  const staleDesiredBox = await previewTarget.boundingBox();
  await postEditResult(page, {
    type: "editResult",
    requestId: staleRequest.requestId,
    status: "stale",
    message: "The source changed before the edit was applied.",
  });
  const rebasedSnapshot = structuredClone(finalSnapshot);
  rebasedSnapshot.generation += 1;
  rebasedSnapshot.snapshot_id = "13-rebased";
  await postSnapshot(page, 103, rebasedSnapshot, 3);
  await page.waitForFunction(
    (count) => globalThis.__messages.filter((message) =>
      message.type === "translate"
    ).length > count,
    staleRequestCount + 1,
  );
  const rebasedRequest = await lastMessage(page, "translate");
  assert.equal(rebasedRequest.snapshotId, rebasedSnapshot.snapshot_id);
  assert.equal(rebasedRequest.nodeId, staleRequest.nodeId);
  assert(Math.abs(rebasedRequest.toBounds.x - staleRequest.toBounds.x) < 0.001);
  assert(Math.abs(rebasedRequest.toBounds.y - staleRequest.toBounds.y) < 0.001);
  await settleLayout(page);
  const retainedAfterRebase = await previewTarget.boundingBox();
  assert(
    Math.abs(retainedAfterRebase.x - staleDesiredBox.x) < 1 &&
      Math.abs(retainedAfterRebase.y - staleDesiredBox.y) < 1,
    "a stale source edit displaced its optimistic position while rebasing",
  );

  await postEditResult(page, {
    type: "editResult",
    requestId: rebasedRequest.requestId,
    status: "rejected",
    message: "The requested position conflicts with a fixed constraint.",
  });
  await page.waitForSelector(".toast--error");
  assert.equal(
    await page.locator(".toast--error").textContent(),
    "The requested position conflicts with a fixed constraint.",
  );
  assert.equal(
    await page.locator("[data-ss-pending-translation]").count(),
    0,
    "a rejected source edit retained its optimistic translation",
  );
  await settleLayout(page);
  const rolledBackPreviewBox = await previewTarget.boundingBox();
  assert(
    Math.abs(rolledBackPreviewBox.x - authoritativePreviewBox.x) < 1 &&
      Math.abs(rolledBackPreviewBox.y - authoritativePreviewBox.y) < 1,
    "a rejected source edit did not restore the authoritative position",
  );
  await postSnapshot(page, 104, finalSnapshot, 3);
  await page.waitForFunction(() => !document.querySelector(".toast--error"));

  await drag(page, await target.boundingBox(), 8, 5);
  const failedBuildRequest = await lastMessage(page, "translate");
  await postEditResult(page, {
    type: "editResult",
    requestId: failedBuildRequest.requestId,
    status: "applied",
    documentVersion: 4,
  });
  const failedBuild = structuredClone(finalSnapshot);
  failedBuild.stale = true;
  failedBuild.build_diagnostics = [{
    uri: "file:///workspace/slide.ss",
    range: {
      start: { line: 8, character: 0 },
      end: { line: 8, character: 4 },
    },
    code: "ConstraintConflict",
    message: "the generated source did not satisfy its constraints",
  }];
  await postSnapshot(page, 105, failedBuild, 4);
  await page.waitForSelector(".toast--error");
  assert.equal(
    await page.locator("[data-ss-pending-translation]").count(),
    0,
    "a failed rebuild retained an applied optimistic translation",
  );
  await settleLayout(page);
  const failedBuildBox = await previewTarget.boundingBox();
  assert(
    Math.abs(failedBuildBox.x - authoritativePreviewBox.x) < 1 &&
      Math.abs(failedBuildBox.y - authoritativePreviewBox.y) < 1,
    "a failed rebuild did not restore the last successful position",
  );
  await postSnapshot(page, 106, finalSnapshot, 5);
  await page.waitForFunction(() => !document.querySelector(".toast--error"));
  return finalSnapshot;
}

async function drag(page, box, dx, dy) {
  assert(box && box.width > 0 && box.height > 0,
    "movable object disappeared before a drag");
  const x = box.x + box.width / 2;
  const y = box.y + box.height / 2;
  await page.mouse.move(x, y);
  await page.mouse.down();
  await page.mouse.move(x + dx, y + dy, { steps: 3 });
  await page.mouse.up();
}

async function settleLayout(page) {
  await page.evaluate(() => new Promise((resolve) =>
    requestAnimationFrame(() => requestAnimationFrame(resolve))
  ));
}

async function postSnapshot(page, revision, snapshot, documentVersion) {
  await page.evaluate(({ value, deliveryRevision, version }) => {
    window.postMessage({
      type: "snapshot",
      revision: deliveryRevision,
      documentVersion: version,
      snapshot: value,
    }, "*");
  }, { value: snapshot, deliveryRevision: revision, version: documentVersion });
}

async function postEditResult(page, message) {
  await page.evaluate((value) => window.postMessage(value, "*"), message);
}

async function lastMessage(page, type) {
  return await page.evaluate((messageType) => {
    const values = globalThis.__messages.filter((message) =>
      message.type === messageType
    );
    return values.at(-1) ?? null;
  }, type);
}

async function messageCount(page, type) {
  return await page.evaluate((messageType) =>
    globalThis.__messages.filter((message) =>
      message.type === messageType
    ).length,
  type);
}

function translatedSnapshot(source, frame, snapshotId) {
  const result = structuredClone(source);
  result.generation += 1;
  result.snapshot_id = snapshotId;
  const page = result.layout.pages.find((candidate) => candidate.id === 22);
  const object = result.layout.objects.find((candidate) => candidate.id === 202);
  object.x = frame.x;
  object.y = page.height - frame.y - object.height;
  result.display.html = result.display.html.replace(
    /(data-ss-node-id="202" style="[^\"]*left:)[^;]+(;top:)[^;]+/,
    `$1${frame.x}pt$2${frame.y}pt`,
  );
  return result;
}
