#!/usr/bin/env node
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, withLspClient } from "../../harness.mjs";
import {
  applyProtocolEdits,
  assertBounds,
  editingTarget,
  editorSnapshot,
  previewBounds,
  requestEdit,
} from "../support.mjs";

const fixtureRoot = path.resolve("tests/fixtures/runtime/editor/relations");

await testInheritedRelativeEditAddsCallerUpdates();
await testSymbolicRelativeEditKeepsExpressions();
await testMultilineRelativeEditPreservesTrivia();
await testRelativeEditsCompleteMovedAxes();

async function testInheritedRelativeEditAddsCallerUpdates() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-relative-inherited-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = await readFile(path.join(fixtureRoot, "inherited", "slide.ss"), "utf8");
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      let diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source });
      assert(
        (await diagnosticsPromise).params.diagnostics.length === 0,
        "inherited relative fixture produced diagnostics",
      );

      const snapshot = await editorSnapshot(client, uri);
      const target = editingTarget(snapshot, "item");
      const fromBounds = previewBounds(snapshot, target.node_id);
      const toBounds = {
        ...fromBounds,
        x: fromBounds.x + 28,
        y: fromBounds.y + 24,
      };
      const edit = await requestEdit(
        client,
        uri,
        snapshot,
        target,
        fromBounds,
        toBounds,
        "relative",
        target.page_id,
      );
      assert(
        edit.status === "ok",
        `inherited relative edit was rejected: ${JSON.stringify(edit)}`,
      );
      const updated = applyProtocolEdits(
        source,
        edit.workspaceEdit?.changes?.[uri] ?? [],
      );
      assert(
        updated.includes("~ result.left == guide.right + left_offset") &&
          updated.includes("~ result.top == guide.bottom - 24"),
        `inherited constraints were modified: ${updated}`,
      );
      assert(
        updated.includes("~!~ item.left == guide.right + 100") &&
          updated.includes("~!~ item.top == guide.bottom - 48"),
        `caller updates were not appended: ${updated}`,
      );

      diagnosticsPromise = client.waitForDiagnostics(uri);
      client.changeDocument({ uri, version: 2, text: updated });
      assert(
        (await diagnosticsPromise).params.diagnostics.length === 0,
        "inherited relative edit produced diagnostics",
      );
      const after = await editorSnapshot(client, uri);
      assertBounds(
        previewBounds(after, editingTarget(after, "item").node_id),
        toBounds.x,
        toBounds.y,
        "inherited relative edit",
      );
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testSymbolicRelativeEditKeepsExpressions() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-relative-symbolic-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = await readFile(path.join(fixtureRoot, "symbolic", "slide.ss"), "utf8");
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      let diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source });
      assert(
        (await diagnosticsPromise).params.diagnostics.length === 0,
        "symbolic relative fixture produced diagnostics",
      );

      const snapshot = await editorSnapshot(client, uri);
      const target = editingTarget(snapshot, "item");
      const fromBounds = previewBounds(snapshot, target.node_id);
      const toBounds = {
        ...fromBounds,
        x: fromBounds.x + 35,
        y: fromBounds.y + 25,
      };
      const firstEdit = await requestEdit(
        client,
        uri,
        snapshot,
        target,
        fromBounds,
        toBounds,
        "relative",
        target.page_id,
      );
      assert(
        firstEdit.status === "ok",
        `symbolic relative edit was rejected: ${JSON.stringify(firstEdit)}`,
      );
      let updated = applyProtocolEdits(
        source,
        firstEdit.workspaceEdit?.changes?.[uri] ?? [],
      );
      assert(
        updated.includes("~ item.center_x == guide.right + (horizontal_gap) + 35") &&
          updated.includes("~ item.bottom == guide.top + (-(vertical_gap)) - 25"),
        `symbolic offsets were not preserved: ${updated}`,
      );

      diagnosticsPromise = client.waitForDiagnostics(uri);
      client.changeDocument({ uri, version: 2, text: updated });
      assert(
        (await diagnosticsPromise).params.diagnostics.length === 0,
        "symbolic relative edit produced diagnostics",
      );
      const afterFirst = await editorSnapshot(client, uri);
      const afterFirstTarget = editingTarget(afterFirst, "item");
      const afterFirstBounds = previewBounds(afterFirst, afterFirstTarget.node_id);
      assertBounds(afterFirstBounds, toBounds.x, toBounds.y, "symbolic relative edit");

      const secondBounds = {
        ...afterFirstBounds,
        x: afterFirstBounds.x + 5,
        y: afterFirstBounds.y + 5,
      };
      const secondEdit = await requestEdit(
        client,
        uri,
        afterFirst,
        afterFirstTarget,
        afterFirstBounds,
        secondBounds,
        "relative",
        afterFirstTarget.page_id,
      );
      assert(
        secondEdit.status === "ok",
        `repeated symbolic relative edit was rejected: ${JSON.stringify(secondEdit)}`,
      );
      updated = applyProtocolEdits(
        updated,
        secondEdit.workspaceEdit?.changes?.[uri] ?? [],
      );
      assert(
        updated.includes("~ item.center_x == guide.right + (horizontal_gap) + 40") &&
          updated.includes("~ item.bottom == guide.top + (-(vertical_gap)) - 30") &&
          !updated.includes("((horizontal_gap))"),
        `repeated symbolic edit accumulated malformed expressions: ${updated}`,
      );

      diagnosticsPromise = client.waitForDiagnostics(uri);
      client.changeDocument({ uri, version: 3, text: updated });
      assert(
        (await diagnosticsPromise).params.diagnostics.length === 0,
        "repeated symbolic relative edit produced diagnostics",
      );
      const afterSecond = await editorSnapshot(client, uri);
      assertBounds(
        previewBounds(afterSecond, editingTarget(afterSecond, "item").node_id),
        secondBounds.x,
        secondBounds.y,
        "repeated symbolic relative edit",
      );
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testMultilineRelativeEditPreservesTrivia() {
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-relative-multiline-"));
  try {
    const slide = path.join(project, "slide.ss");
    const uri = pathToFileURL(slide).toString();
    const source = await readFile(path.join(fixtureRoot, "multiline", "slide.ss"), "utf8");
    await writeFile(slide, source, "utf8");

    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      const diagnosticsPromise = client.waitForDiagnostics(uri);
      client.openDocument({ uri, text: source });
      assert(
        (await diagnosticsPromise).params.diagnostics.length === 0,
        "multiline relative fixture produced diagnostics",
      );

      const snapshot = await editorSnapshot(client, uri);
      const target = editingTarget(snapshot, "item");
      const fromBounds = previewBounds(snapshot, target.node_id);
      const toBounds = { ...fromBounds, x: fromBounds.x + 15, y: fromBounds.y + 10 };
      const result = await requestEdit(
        client,
        uri,
        snapshot,
        target,
        fromBounds,
        toBounds,
        "relative",
        target.page_id,
      );
      assert(result.status === "ok", `multiline relative edit was rejected: ${JSON.stringify(result)}`);
      const updated = applyProtocolEdits(source, result.workspaceEdit?.changes?.[uri] ?? []);
      assert(
        updated.includes("# Keep horizontal context.\n  + (horizontal_gap) + 15") &&
          updated.includes("# Keep vertical context.\n  + (-(vertical_gap)) - 10"),
        `multiline relation trivia was not preserved: ${updated}`,
      );
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testRelativeEditsCompleteMovedAxes() {
  const cases = [
    {
      name: "horizontal-only",
      body: '~ item.left == guide.right + 32',
      dx: 25, dy: 0,
      verify: (updated) => {
        assert(updated.includes("~ item.left == guide.right + 57"), updated);
        assert(!updated.includes("~!~"), `unchanged vertical axis was pinned: ${updated}`);
      },
    },
    {
      name: "vertical-only",
      body: '~ item.top == guide.bottom - 32',
      dx: 0, dy: 25,
      verify: (updated) => {
        assert(updated.includes("~ item.top == guide.bottom - 57"), updated);
        assert(!updated.includes("~!~"), `unchanged horizontal axis was pinned: ${updated}`);
      },
    },
    { name: "horizontal-and-automatic", body: '~ item.left == guide.right + 32' },
    { name: "vertical-and-automatic", body: '~ item.top == guide.bottom - 32' },
    { name: "automatic", body: '' },
    {
      name: "anonymous-reference",
      body: '',
      guide: 'text!("Guide")',
      verify: (updated) => assert(updated.includes("~!~ item.top == page.top"), updated),
    },
    ...["||", "|=|", "//", "/=/"].flatMap((operator) => [
      {
        name: `composition-right-${operator}`,
        body: `guide ${operator} item`,
        verify: operator === "||" ? (updated) => {
          assert(updated.includes("~!~ item.left == guide.right + 57"), updated);
          assert(updated.includes("~!~ item.top == guide.top - 20"), updated);
        } : undefined,
      },
      { name: `composition-left-${operator}`, body: `item ${operator} guide`, fixGuide: false },
    ]),
    ...["||", "|=|"].map((operator) => ({
      name: `image-${operator}`,
      body: `guide ${operator} item`,
      item: 'let item = image!("figure.svg", 0.9)',
      guide: 'let guide = text!("A sufficiently wide guide for this image")',
      header: 'head! "Monte Carlo"',
      policy: 'hflow(LayoutPolicy.center)',
      fixGuide: false,
    })),
    {
      name: "centered-reference-chain",
      body: 'let bridge = text!("Bridge")\n~ bridge.left == guide.right + 24\n~ bridge.top == guide.top\n~ item.left == bridge.right + 32\n~ item.top == bridge.top',
      policy: 'hflow(LayoutPolicy.center)',
      fixGuide: false,
    },
    {
      name: "center-alignment",
      body: 'guide || item',
      policy: 'vflow(LayoutPolicy.center)',
      verify: (updated) => assert(updated.includes("~!~ item.center_y == guide.center_y - 20"), updated),
    },
  ];
  const project = await mkdtemp(path.join(os.tmpdir(), "ss-lsp-relative-axes-"));
  try {
    await writeFile(path.join(project, "figure.svg"), '<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256"><circle cx="128" cy="128" r="100"/></svg>');
    await withLspClient({ cwd: project }, async (client) => {
      await client.initialize();
      for (const [index, scenario] of cases.entries()) {
        const slide = path.join(project, `axes-${index}.ss`);
        const uri = pathToFileURL(slide).toString();
        const source = `import std:themes/default as *
page demo
${scenario.policy ?? "vflow(LayoutPolicy.top)"}
${scenario.header ?? ""}
${scenario.guide ?? 'let guide = text!("Guide")'}
${scenario.item ?? 'let item = text!("Move me")'}
${scenario.fixGuide === false || scenario.guide ? "" : "~ guide.left == page.left + 100\n~ guide.top == page.top - 100"}
${scenario.body}
end
`;
        await writeFile(slide, source, "utf8");
        let diagnostics = client.waitForDiagnostics(uri);
        client.openDocument({ uri, text: source });
        const initialProblems = (await diagnostics).params.diagnostics;
        assert(initialProblems.length === 0, `${scenario.name}: initial diagnostics ${JSON.stringify(initialProblems)}`);
        let snapshot = await editorSnapshot(client, uri);
        let updated = source;
        const guideBefore = scenario.name === "image-||" || scenario.name === "centered-reference-chain"
          ? previewBounds(snapshot, editingTarget(snapshot, "guide").node_id)
          : null;
        for (let step = 0; step < 2; step += 1) {
          const target = editingTarget(snapshot, "item");
          const from = previewBounds(snapshot, target.node_id);
          const to = { ...from, x: from.x + (scenario.dx ?? 25), y: from.y + (scenario.dy ?? 20) };
          const edit = await requestEdit(client, uri, snapshot, target, from, to, "relative", target.page_id);
          assert(edit.status === "ok", `${scenario.name}: ${JSON.stringify(edit)}`);
          updated = applyProtocolEdits(updated, edit.workspaceEdit?.changes?.[uri] ?? []);
          if (step === 0) scenario.verify?.(updated);
          diagnostics = client.waitForDiagnostics(uri);
          client.changeDocument({ uri, version: step + 2, text: updated });
          const problems = (await diagnostics).params.diagnostics;
          assert(problems.length === 0, `${scenario.name}: ${JSON.stringify(problems)}\n${updated}`);
          snapshot = await editorSnapshot(client, uri);
          assertBounds(previewBounds(snapshot, editingTarget(snapshot, "item").node_id), to.x, to.y, `${scenario.name} step ${step}\n${updated}`);
          if (guideBefore) assertBounds(previewBounds(snapshot, editingTarget(snapshot, "guide").node_id), guideBefore.x, guideBefore.y, `${scenario.name}: reference moved`);
        }
      }
    });
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}
