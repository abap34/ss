#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { root, ssBin, withLspClient } from "../../harness.mjs";

const fixture = await mkdtemp(path.join(os.tmpdir(), "ss-project-settings-"));
try {
  const projectFile = path.join(fixture, "ss.toml");
  const slide = path.join(fixture, "main.ss");
  await writeFile(slide, "page example\nend\n");
  const schema = JSON.parse(await readFile(path.join(root, "schemas/ss-toml.schema.json"), "utf8"));
  await withLspClient({ cwd: fixture }, async (client) => {
    await client.initialize();
    const defaults = await client.request("ss/projectSettings", {});
    assert.equal(defaults.schema, 1);
    assert.equal(defaults.entryPath, null);
    for (const [section, property] of Object.entries(schema.properties.editor.properties)) {
      const target = defaults.settings[camel(section)];
      for (const [key, value] of Object.entries(property.properties)) {
        if (key === "refresh") {
          assert.equal(target.refreshAutomatically, value.properties.automatic.default);
          assert.equal(target.refreshOnDependencyChange, value.properties.dependency.default);
        } else {
          const name = key === "debounce" ? "debounceMs" : key === "max_wait" ? "maxWaitMs" : camel(key);
          assert.equal(target[name], value.default, `default differs from the schema: ${section}.${key}`);
        }
      }
    }

    const valid = `project.entry = "\\u006dain.ss"
editor.lsp = { debounce = 0x19, completion = false }
editor.wysiwyg = { debounce = 0o62, max_wait = 3_25, refresh = { automatic = false, dependency = false } }
editor.page_guide.enabled = false
cli.jobs = 0b10
`;
    await writeFile(projectFile, valid);
    const normalized = await client.request("ss/projectSettings", { projectFile });
    assert.equal(normalized.entryPath, slide);
    assert.equal(normalized.error, undefined);
    assert.deepEqual(normalized.settings, {
      lsp: { ...defaults.settings.lsp, debounceMs: 25, completion: false },
      wysiwyg: { enabled: true, debounceMs: 50, maxWaitMs: 325, refreshAutomatically: false, refreshOnDependencyChange: false },
      pageGuide: { ...defaults.settings.pageGuide, enabled: false },
    });
    checkCli(projectFile);

    for (const [configuration, code] of [
      ["project.entry = 'main.ss'\nproject.entry = 'other.ss'", "InvalidToml"],
      ["project.entry = 'main.ss'\neditor.lsp.enabled = false\neditor.lsp.debounce = 1.0", "InvalidEditorSetting"],
      ["project.entry = 'main.ss'\neditor.wysiwyg.max_wait = 2147483648", "InvalidEditorSetting"],
      ["project.entry = 'main.ss'\ncli.diagnostic_level = true", "InvalidDiagnosticLevel"],
      ["project.entry = 'main.ss'\neditor.page_guide = []", "InvalidConfigTable"],
      ["project.entry = 'main.ss'\neditor.wysiwyg.unknown = false", "UnknownConfigKey"],
      ["project.asset_base_dir = '.'", "MissingProjectEntry"],
    ]) {
      await writeFile(projectFile, configuration);
      const rejected = await client.request("ss/projectSettings", { projectFile });
      assert.equal(rejected.error?.code, code);
      assert.equal(rejected.entryPath, null);
      assert.deepEqual(rejected.settings, defaults.settings, "invalid configuration exposed partial settings");
      checkCli(projectFile, code);
    }

    await writeFile(projectFile, "project.entry = 'not-present.ss'\neditor.wysiwyg.enabled = false\n");
    const withoutDocument = await client.request("ss/projectSettings", { projectFile });
    assert.equal(withoutDocument.entryPath, path.join(fixture, "not-present.ss"));
    assert.equal(withoutDocument.settings.wysiwyg.enabled, false);
    assert.equal(withoutDocument.error, undefined, "settings lookup attempted to load the slide entry");
    assert.deepEqual(await client.request("ss/projectInfo", {}), {}, "settings lookup created an analysis snapshot");

    await assert.rejects(client.request("ss/projectSettings", { projectFile: 12 }), (error) => error.message === "-32602: Invalid params");
    await assert.rejects(client.request("ss/projectSettings", { projectFile: "relative/ss.toml" }), (error) => error.message === "-32602: Invalid params");
    const missing = await client.request("ss/projectSettings", { projectFile: path.join(fixture, "absent.toml") });
    assert.equal(missing.error?.code, "FileNotFound");
    await writeFile(projectFile, valid);
    assert.deepEqual(await client.request("ss/projectSettings", { projectFile }), normalized);
  });
} finally {
  await rm(fixture, { recursive: true, force: true });
}
console.log("Project settings: native normalization, CLI parity, schema defaults, invalid input and recovery passed");

function camel(name) {
  return name.replace(/_([a-z])/g, (_, letter) => letter.toUpperCase());
}

function checkCli(projectFile, code) {
  const result = spawnSync(ssBin, ["check", "--project", projectFile], { encoding: "utf8", timeout: 10000 });
  assert.ifError(result.error);
  if (code) {
    assert.notEqual(result.status, 0);
    assert.ok(`${result.stdout}${result.stderr}`.includes(`${code}:`));
  } else {
    assert.equal(result.status, 0, `${result.stdout}${result.stderr}`);
  }
}
