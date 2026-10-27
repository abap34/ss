import assert from "node:assert/strict";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { statistics } from "../../session.mjs";

export const protocolVersion = 2;

export async function run(profile) {
  const { result, settings } = profile;
  await profile.measure("pdf_cold", () => profile.render(), { beforeEach: () => profile.clearProjectCache() });
  await profile.clearProjectCache();
  await profile.render();
  await profile.measure("pdf_warm", () => profile.render());
  result.boundaries = {
    pdf: "CLI process creation through exit; project cache preparation is excluded",
    cache: "cold clears project .ss-cache; warm primes it with one untimed render; OS/font/tool caches are unchanged",
  };
  if (settings.record) {
    await profile.clearProjectCache();
    result.instrumented_measurements = {
      pdf_cold_wall_ms: (await profile.render({ recording: "render-cold" })).elapsed_ms,
      pdf_warm_wall_ms: (await profile.render({ recording: "render-warm" })).elapsed_ms,
    };
  }
  if (profile.workload.definition.editor) {
    await primeEditor(profile);
    result.measurements.lsp = await editorMeasurements(profile);
    if (settings.record) {
      await primeEditor(profile);
      result.instrumented_measurements.lsp = await editorMeasurements(profile, "lsp");
    }
  }
}

async function primeEditor(profile) {
  await profile.clearProjectCache();
  await profile.validate();
}

async function editorMeasurements(profile, recording = null) {
  const { definition: workload, source, edits } = profile.workload;
  const { samples, warmups, timeout_ms: timeoutMs } = profile.settings;
  const client = await profile.editor({ recording });
  const uri = pathToFileURL(path.join(profile.project, workload.entry)).href;
  const metrics = {
    boundary: "didOpen/didChange through ss/editorSnapshot response",
    excludes: ["server startup", "initialize", "webview", "DOM", "paint"],
    cache: "project artifacts primed by an untimed dump; fresh LSP process",
  };
  const snapshot = async () => {
    const response = await client.startRequest("ss/editorSnapshot", { textDocument: { uri } }, timeoutMs).promise;
    assert.equal(response.layout?.pages?.length, workload.expect.pages);
    assert.equal(response.stale, undefined);
    return response;
  };
  let version = 1;
  const started = performance.now();
  client.openDocument({ uri, text: source, version });
  const initial = await snapshot();
  let previousGeneration = initial.generation;
  metrics.initial_snapshot_ms = performance.now() - started;
  for (const edit of workload.editor.edits) {
    const values = [];
    for (let index = 0; index < warmups + samples; index++) {
      const next = index % 2 === 0 ? edits.get(edit.id) : source;
      const before = performance.now();
      client.changeDocument({ uri, version: ++version, text: next });
      const response = await snapshot();
      assert(response.generation > previousGeneration, "edit returned an unchanged generation");
      previousGeneration = response.generation;
      if (index >= warmups) values.push(performance.now() - before);
    }
    metrics[`text_${edit.id}`] = statistics(values);
    client.changeDocument({ uri, version: ++version, text: source });
    await snapshot();
    if (recording) await client.startRequest("ss/profile", {}, timeoutMs).promise;
  }
  const rapid = performance.now();
  const requests = [];
  for (const [index, id] of workload.editor.burst.entries()) {
    client.changeDocument({ uri, version: ++version, text: edits.get(id) });
    const request = client.startRequest("ss/editorSnapshot", { textDocument: { uri } }, timeoutMs);
    requests.push(request.promise.then(() => "completed", (error) => {
      if (/-32800|-32801/.test(error.message)) return "canceled_or_superseded";
      throw error;
    }));
    if (index + 1 < workload.editor.burst.length) client.cancelRequest(request.id);
  }
  const outcomes = Promise.all(requests);
  outcomes.catch(() => {});
  const final = await snapshot();
  assert(final.generation > previousGeneration, "burst returned an unchanged generation");
  metrics.rapid_edits = { wall_ms: performance.now() - rapid, outcomes: await outcomes };
  if (recording) await client.startRequest("ss/profile", {}, timeoutMs).promise;
  await client.close();
  return metrics;
}
