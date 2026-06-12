const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const schemaPath = path.join(root, "schemas", "ss-toml.schema.json");
const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));

const properties = schema.properties;
const editor = properties.editor.properties;
const lsp = editor.lsp.properties;
const inlayHints = lsp.inlay_hints;
const preview = editor.preview.properties;

assert.strictEqual(schema.$schema, "http://json-schema.org/draft-04/schema#");
assert.deepStrictEqual(properties.project.required, ["entry"]);
assert.strictEqual(properties.project.properties.entry.type, "string");

assert.strictEqual(inlayHints.type, "object");
assert.strictEqual(inlayHints.properties.enabled.type, "boolean");
assert.strictEqual(inlayHints.properties.arguments.type, "boolean");
assert.strictEqual(inlayHints.properties.positions.type, "boolean");
assert(!("inlay_hints" in lsp && lsp.inlay_hints.type === "boolean"), "inlay_hints must be a table in the schema");

assert.strictEqual(preview.debounce.type, "integer");
assert.strictEqual(preview.debounce.default, 350);
assert.deepStrictEqual(preview.open.enum, ["vscode", "external"]);
assert.strictEqual(preview.refresh.properties.dependency.type, "boolean");
assert.strictEqual(preview.render.properties.extra_args.items.type, "string");

