const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const schemaPath = path.join(root, "schemas", "ss-toml.schema.json");
const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));

const properties = schema.properties;
const editor = properties.editor.properties;
const lsp = editor.lsp.properties;
const wysiwyg = editor.wysiwyg.properties;

assert.strictEqual(schema.$schema, "http://json-schema.org/draft-04/schema#");
assert.deepStrictEqual(properties.project.required, ["entry"]);
assert.strictEqual(properties.project.properties.entry.type, "string");
assert(!("inlay_hints" in lsp), "inlay hints must not be configurable");

assert.strictEqual(wysiwyg.debounce.type, "integer");
assert.strictEqual(wysiwyg.debounce.default, 140);
assert.strictEqual(wysiwyg.max_wait.type, "integer");
assert.strictEqual(wysiwyg.max_wait.default, 700);
assert.strictEqual(wysiwyg.refresh.properties.automatic.type, "boolean");
assert.strictEqual(wysiwyg.refresh.properties.automatic.default, true);
assert.strictEqual(wysiwyg.refresh.properties.dependency.type, "boolean");
