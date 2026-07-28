#!/usr/bin/env node
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { cpus } from "node:os";
import path from "node:path";
import process from "node:process";
import { performance } from "node:perf_hooks";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  applyProtocolEdits,
  editingTarget,
  previewBounds,
} from "../../runtime/editor/support.mjs";
import { withLspClient } from "../../runtime/harness.mjs";

const repository = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);
// runtime/harness.mjs treats argv[2] as the ss executable, so build.zig passes
// the executable before the optimization mode.
const ssArgument = process.argv[2] ?? process.env.SS_BIN;
const optimize =
  process.argv[3] ?? process.env.SS_WYSIWYG_BENCHMARK_OPTIMIZE;
const warmupCount = 5;
const retainedCount = 30;
const targetSpeedup = 3;
const maximumUnchangedPathRatio = 1.1;
const measurementRevision = 1;
const output = path.join(repository, ".ss-cache/wysiwyg-benchmark");
const project = path.join(output, "project");
const slide = path.join(project, "slide.ss");
const fixtureRelativePath =
  "tests/fixtures/render/parity/text/large/slide.ss";
const fixturePath = path.join(repository, fixtureRelativePath);
const baselinePath = process.env.SS_WYSIWYG_BENCHMARK_BASELINE;
const writeBaselinePath =
  process.env.SS_WYSIWYG_BENCHMARK_WRITE_BASELINE;
const expectedPageCount = 5;
const positionTolerance = 0.1;

assert(ssArgument, "WYSIWYG benchmark requires the ss binary as argv[2] or SS_BIN");
assert.equal(
  optimize,
  "ReleaseSafe",
  "WYSIWYG benchmark requires -Doptimize=ReleaseSafe",
);
assert(
  !(baselinePath && writeBaselinePath),
  "baseline comparison and baseline creation are mutually exclusive",
);

const fixtureSource = await readFile(fixturePath, "utf8");
const fixtureSha256 = createHash("sha256")
  .update(fixtureSource)
  .digest("hex");
const processor = cpus();
await prepareProject();

const metrics = {
  initial_snapshot: summarize(await measureInitialSnapshots()),
  text_update: summarize(await measureTextUpdates()),
  generated_position_edit: summarize(await measureGeneratedPositionEdits()),
};
const result = {
  schema: 1,
  measurement: {
    revision: measurementRevision,
    boundary: "lsp-editor-snapshot-response",
    excludes: [
      "language-server-process-start",
      "lsp-initialize",
      "webview-message-delivery",
      "dom-update",
      "paint",
    ],
  },
  optimize,
  platform: process.platform,
  architecture: process.arch,
  runtime: {
    node: process.version,
    cpu_model: processor[0]?.model ?? "unknown",
    logical_cpu_count: processor.length,
  },
  fixture: {
    path: fixtureRelativePath,
    sha256: `sha256:${fixtureSha256}`,
  },
  warmup_samples: warmupCount,
  retained_samples: retainedCount,
  metrics,
};

await writeFile(
  path.join(output, "result.json"),
  `${JSON.stringify(result, null, 2)}\n`,
  "utf8",
);
printResult(result);

if (writeBaselinePath) {
  const target = path.resolve(repository, writeBaselinePath);
  await mkdir(path.dirname(target), { recursive: true });
  await writeFile(target, `${JSON.stringify(result, null, 2)}\n`, "utf8");
  process.stdout.write(`baseline written to ${target}\n`);
}
if (baselinePath) {
  const baseline = JSON.parse(
    await readFile(path.resolve(repository, baselinePath), "utf8"),
  );
  compareToBaseline(result, baseline);
}

async function prepareProject() {
  await rm(output, { recursive: true, force: true });
  await mkdir(project, { recursive: true });
  await writeFile(slide, fixtureSource, "utf8");
  await writeFile(
    path.join(project, "ss.toml"),
    `[project]
entry = "slide.ss"

[editor.lsp]
debounce = 0

[editor.wysiwyg.refresh]
automatic = true
`,
    "utf8",
  );
}

async function measureInitialSnapshots() {
  const samples = [];
  const uri = pathToFileURL(slide).toString();
  for (let index = 0; index < warmupCount + retainedCount; index += 1) {
    const elapsed = await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const started = performance.now();
      client.openDocument({ uri, text: fixtureSource, version: 1 });
      const snapshot = await requestSnapshot(client, uri);
      const duration = performance.now() - started;
      assertFullSnapshot(snapshot, "initial snapshot", "ALPHA");
      return duration;
    });
    if (index >= warmupCount) samples.push(elapsed);
  }
  return samples;
}

async function measureTextUpdates() {
  const samples = [];
  const uri = pathToFileURL(slide).toString();
  await withLspClient({ cwd: project }, async (client) => {
    await client.initialize();
    client.openDocument({ uri, text: fixtureSource, version: 1 });
    let source = fixtureSource;
    let version = 1;
    let snapshot = await requestSnapshot(client, uri);
    assertFullSnapshot(snapshot, "text benchmark initial snapshot", "ALPHA");

    for (let index = 0; index < warmupCount + retainedCount; index += 1) {
      const previousSnapshotId = snapshot.snapshot_id;
      const from = index % 2 === 0 ? "ALPHA" : "OMEGA";
      const to = index % 2 === 0 ? "OMEGA" : "ALPHA";
      assert(source.includes(from), `text benchmark source omitted ${from}`);
      source = source.replace(from, to);
      version += 1;
      const started = performance.now();
      client.changeDocument({ uri, version, text: source });
      snapshot = await requestSnapshot(client, uri, previousSnapshotId);
      const elapsed = performance.now() - started;
      assert.notEqual(
        snapshot.snapshot_id,
        previousSnapshotId,
        "text update retained the previous snapshot id",
      );
      assertFullSnapshot(snapshot, "text update", to);
      if (index >= warmupCount) samples.push(elapsed);
    }
  });
  return samples;
}

async function measureGeneratedPositionEdits() {
  const samples = [];
  const uri = pathToFileURL(slide).toString();
  await withLspClient({ cwd: project }, async (client) => {
    await client.initialize();
    client.openDocument({ uri, text: fixtureSource, version: 1 });
    let source = fixtureSource;
    let version = 1;
    let snapshot = await requestSnapshot(client, uri);
    assertFullSnapshot(
      snapshot,
      "position benchmark initial snapshot",
      "ALPHA",
    );

    for (let index = 0; index < warmupCount + retainedCount; index += 1) {
      const previousSnapshot = snapshot;
      const target = editingTarget(previousSnapshot, "heading");
      const from = previewBounds(previousSnapshot, target.node_id);
      const delta = index % 2 === 0 ? 4 : -4;
      const to = {
        ...from,
        x: from.x + delta,
        y: from.y + delta,
      };
      const started = performance.now();
      const edit = await client.request("ss/layoutEdit", {
        textDocument: { uri },
        snapshotId: previousSnapshot.snapshot_id,
        nodeId: target.node_id,
        pageId: target.page_id,
        mode: "absolute",
        fromBounds: from,
        toBounds: to,
      });
      assert.equal(
        edit.status,
        "ok",
        `generated position edit failed: ${JSON.stringify(edit)}`,
      );
      const edits = edit.workspaceEdit?.changes?.[uri] ?? [];
      assert(edits.length > 0, "generated position edit returned no source edits");
      const nextSource = applyProtocolEdits(source, edits);
      assert.notEqual(
        nextSource,
        source,
        "generated position edit left the source unchanged",
      );
      source = nextSource;
      version += 1;
      client.changeDocument({ uri, version, text: source });
      snapshot = await requestSnapshot(
        client,
        uri,
        previousSnapshot.snapshot_id,
      );
      const elapsed = performance.now() - started;
      assertTranslationPatch(snapshot, previousSnapshot, target.node_id, delta);
      assertPosition(snapshot, target.node_id, to);
      if (index === 0) {
        assert(
          source.includes("~!~ heading.left") &&
            source.includes("~!~ heading.top"),
          "generated position edit omitted authoritative constraint updates",
        );
      }
      if (index >= warmupCount) samples.push(elapsed);
    }
  });
  return samples;
}

function requestSnapshot(client, uri, baseSnapshotId) {
  const params = { textDocument: { uri } };
  if (baseSnapshotId) params.baseSnapshotId = baseSnapshotId;
  return client.request("ss/editorSnapshot", params);
}

function assertSnapshotEnvelope(snapshot, label) {
  assert.equal(snapshot.kind, "ss-editor-snapshot", `${label} had the wrong kind`);
  assert.equal(snapshot.schema, 1, `${label} had the wrong schema`);
  assert.equal(
    snapshot.coordinate_space?.origin,
    "page-top-left",
    `${label} had the wrong coordinate space`,
  );
  assert.equal(
    snapshot.layout?.pages?.length,
    expectedPageCount,
    `${label} had the wrong page count`,
  );
  assert.equal(
    snapshot.layout?.failures?.length,
    0,
    `${label} contained layout failures`,
  );
  assert.equal(snapshot.stale, undefined, `${label} was stale`);
}

function assertFullSnapshot(snapshot, label, visibleToken) {
  assertSnapshotEnvelope(snapshot, label);
  assert.equal(snapshot.display?.schema, 2, `${label} was not a full display`);
  assert.equal(
    snapshot.display?.kind,
    undefined,
    `${label} unexpectedly contained a display patch`,
  );
  assert(
    snapshot.display.html.includes("class=\"ss-item ss-text\""),
    `${label} omitted positioned text HTML`,
  );
  assert(
    snapshot.display.html.includes(visibleToken),
    `${label} display omitted ${visibleToken}`,
  );
  assert(
    snapshot.display.css.includes(".ss-text"),
    `${label} omitted shared display CSS`,
  );
}

function assertTranslationPatch(
  snapshot,
  previousSnapshot,
  targetNodeId,
  delta,
) {
  assertSnapshotEnvelope(snapshot, "generated position snapshot");
  assert.notEqual(
    snapshot.snapshot_id,
    previousSnapshot.snapshot_id,
    "generated position edit retained the previous snapshot id",
  );
  assert.equal(
    snapshot.display?.schema,
    3,
    "generated position edit did not return a display patch",
  );
  assert.equal(
    snapshot.display?.kind,
    "translation_patch",
    "generated position edit returned the wrong display kind",
  );
  assert.equal(
    snapshot.display?.base_snapshot_id,
    previousSnapshot.snapshot_id,
    "generated position patch did not extend the visible snapshot",
  );
  assert(
    snapshot.display.translations.length > 0,
    "generated position patch contained no translations",
  );
  const translation = snapshot.display.translations.find(
    (item) => item.node_id === targetNodeId,
  );
  assert(translation, "generated position patch omitted the edited node");
  assertClose(
    translation.x,
    delta,
    "generated position patch horizontal translation",
  );
  assertClose(
    translation.y,
    delta,
    "generated position patch vertical translation",
  );
}

function assertPosition(snapshot, nodeId, expected) {
  const actual = previewBounds(snapshot, nodeId);
  assertClose(actual.x, expected.x, "generated position snapshot x");
  assertClose(actual.y, expected.y, "generated position snapshot y");
  assertClose(actual.width, expected.width, "generated position snapshot width");
  assertClose(
    actual.height,
    expected.height,
    "generated position snapshot height",
  );
}

function assertClose(actual, expected, label) {
  assert(
    Math.abs(actual - expected) <= positionTolerance,
    `${label} was ${actual}, expected ${expected}`,
  );
}

function summarize(samples) {
  assert.equal(
    samples.length,
    retainedCount,
    "benchmark retained the wrong number of samples",
  );
  const sorted = [...samples].sort((left, right) => left - right);
  return {
    median_ms: median(sorted),
    p95_ms: percentile(sorted, 0.95),
    min_ms: sorted[0],
    max_ms: sorted.at(-1),
    samples_ms: samples,
  };
}

function median(sorted) {
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0
    ? (sorted[middle - 1] + sorted[middle]) / 2
    : sorted[middle];
}

function percentile(sorted, quantile) {
  const index = Math.max(0, Math.ceil(sorted.length * quantile) - 1);
  return sorted[index];
}

function printResult(value) {
  for (const [name, metric] of Object.entries(value.metrics)) {
    process.stdout.write(
      `${name}: median=${metric.median_ms.toFixed(2)} ms, ` +
        `p95=${metric.p95_ms.toFixed(2)} ms, ` +
        `min=${metric.min_ms.toFixed(2)} ms, ` +
        `max=${metric.max_ms.toFixed(2)} ms\n`,
    );
  }
}

function compareToBaseline(current, baseline) {
  assert.equal(baseline.schema, current.schema, "benchmark baseline schema differs");
  assert.equal(
    baseline.measurement?.revision ?? measurementRevision,
    current.measurement.revision,
    "benchmark measurement revision differs",
  );
  assert.equal(
    baseline.optimize,
    current.optimize,
    "benchmark baseline optimization mode differs",
  );
  assert.equal(
    baseline.platform,
    current.platform,
    "benchmark baseline operating system differs",
  );
  assert.equal(
    baseline.architecture,
    current.architecture,
    "benchmark baseline architecture differs",
  );
  assert.deepEqual(
    baseline.fixture,
    current.fixture,
    "benchmark baseline fixture differs",
  );
  if (baseline.runtime) {
    assert.deepEqual(
      baseline.runtime,
      current.runtime,
      "benchmark runtime environment differs",
    );
  }
  assert(
    baseline.warmup_samples >= warmupCount,
    "benchmark baseline has too few warmup samples",
  );
  assert(
    baseline.retained_samples >= retainedCount,
    "benchmark baseline has too few retained samples",
  );

  const metricNames = [
    "initial_snapshot",
    "text_update",
    "generated_position_edit",
  ];
  for (const name of metricNames) {
    const actual = current.metrics[name];
    const expected = baseline.metrics?.[name];
    validateMetric(actual, `${name} current metric`, current.retained_samples);
    validateMetric(
      expected,
      `${name} baseline metric`,
      baseline.retained_samples,
    );
  }

  for (const name of ["initial_snapshot", "text_update"]) {
    const actual = current.metrics[name];
    const expected = baseline.metrics[name];
    for (const statistic of ["median_ms", "p95_ms"]) {
      const ratio = actual[statistic] / expected[statistic];
      assert(
        ratio <= maximumUnchangedPathRatio,
        `${name} ${statistic} regressed to ${ratio.toFixed(2)}x ` +
          `(${actual[statistic].toFixed(2)} ms, limit ` +
          `${(expected[statistic] * maximumUnchangedPathRatio).toFixed(2)} ms)`,
      );
      process.stdout.write(
        `${name} ${statistic}: ${ratio.toFixed(2)}x of baseline\n`,
      );
    }
  }

  {
    const name = "generated_position_edit";
    const actual = current.metrics[name];
    const expected = baseline.metrics[name];
    for (const statistic of ["median_ms", "p95_ms"]) {
      const target = expected[statistic] / targetSpeedup;
      const speedup = expected[statistic] / actual[statistic];
      assert(
        actual[statistic] <= target,
        `${name} ${statistic} reached ${speedup.toFixed(2)}x, ` +
          `expected at least ${targetSpeedup.toFixed(2)}x ` +
          `(${actual[statistic].toFixed(2)} ms, target ${target.toFixed(2)} ms)`,
      );
      process.stdout.write(
        `${name} ${statistic}: ${speedup.toFixed(2)}x faster than baseline\n`,
      );
    }
  }
  process.stdout.write(
    "Generated WYSIWYG position edits reached the recorded threefold " +
      "snapshot-latency targets without regressions in monitored paths\n",
  );
}

function validateMetric(metric, label, sampleCount) {
  assert(metric, `${label} is missing`);
  assert.equal(
    metric.samples_ms?.length,
    sampleCount,
    `${label} has the wrong sample count`,
  );
  for (const [index, sample] of metric.samples_ms.entries()) {
    assert(
      Number.isFinite(sample) && sample >= 0,
      `${label} has an invalid sample at index ${index}`,
    );
  }
  for (const key of ["median_ms", "p95_ms", "min_ms", "max_ms"]) {
    assert(
      Number.isFinite(metric[key]) && metric[key] >= 0,
      `${label} has an invalid ${key}`,
    );
  }
  assert(metric.min_ms <= metric.median_ms, `${label} median is below its minimum`);
  assert(metric.median_ms <= metric.p95_ms, `${label} p95 is below its median`);
  assert(metric.p95_ms <= metric.max_ms, `${label} p95 exceeds its maximum`);
  const sorted = [...metric.samples_ms].sort((left, right) => left - right);
  const recomputed = {
    median_ms: median(sorted),
    p95_ms: percentile(sorted, 0.95),
    min_ms: sorted[0],
    max_ms: sorted.at(-1),
  };
  for (const key of ["median_ms", "p95_ms", "min_ms", "max_ms"]) {
    const tolerance = Number.EPSILON *
      Math.max(1, Math.abs(metric[key]), Math.abs(recomputed[key])) * 8;
    assert(
      Math.abs(metric[key] - recomputed[key]) <= tolerance,
      `${label} ${key} does not match its raw samples`,
    );
  }
}
