#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const geometrySource = await readFile(
  path.join(root, "editor", "vscode", "media", "editor", "geometry.js"),
  "utf8",
);
const geometry = await import(
  `data:text/javascript;base64,${Buffer.from(geometrySource).toString("base64")}`
);

testHorizontalConstraintGeometry();
testVerticalConstraintGeometry();
await testSharedHtmlPreview();
await testCompletionDefaults();

function testHorizontalConstraintGeometry() {
  const source = geometry.anchorSegment(
    { x: 0, y: 0, width: 640, height: 360 },
    "left",
  );
  const target = geometry.anchorSegment(
    { x: 180, y: 80, width: 120, height: 40 },
    "right",
  );
  const result = geometry.constraintGeometry(source, target, "horizontal");

  assertVertical(result.source, "horizontal source edge");
  assertVertical(result.target, "horizontal target edge");
  assertHorizontal(result.connector, "horizontal connector");
  assert(
    result.connector.y1 >= 80 && result.connector.y1 <= 120,
    `horizontal connector missed the target edge: ${JSON.stringify(result)}`,
  );
}

async function testSharedHtmlPreview() {
  const document = await readFile(
    path.join(root, "editor", "vscode", "media", "editor", "document.js"),
    "utf8",
  );
  const snapshot = await readFile(
    path.join(root, "src", "editor", "snapshot.zig"),
    "utf8",
  );
  assert(document.includes("snapshot.display.html"), "VS Code preview does not consume the shared HTML fragment");
  assert(!document.includes("item.type"), "VS Code preview still contains item-specific drawing branches");
  assert(!document.includes("application/pdf"), "VS Code preview still embeds PDF objects");
  assert(snapshot.includes('root.intField("schema", 2)'), "editor snapshot still exposes the legacy display schema");
  assert(!snapshot.includes('stringField("font_family"'), "editor snapshot still serializes legacy text drawing fields");
}

function testVerticalConstraintGeometry() {
  const source = geometry.anchorSegment(
    { x: 40, y: 30, width: 80, height: 40 },
    "bottom",
  );
  const target = geometry.anchorSegment(
    { x: 220, y: 180, width: 100, height: 60 },
    "top",
  );
  const result = geometry.constraintGeometry(source, target, "vertical");

  assertHorizontal(result.source, "vertical source edge");
  assertHorizontal(result.target, "vertical target edge");
  assertVertical(result.connector, "vertical connector");
  assert(
    result.connector.x1 > 120 && result.connector.x1 < 220,
    `vertical connector did not extend both disjoint edges: ${JSON.stringify(result)}`,
  );
}

async function testCompletionDefaults() {
  const manifest = JSON.parse(
    await readFile(path.join(root, "editor", "vscode", "package.json"), "utf8"),
  );
  const defaults = manifest.contributes?.configurationDefaults?.["[ss-slide]"];
  assert(
    defaults?.["editor.wordBasedSuggestions"] === "off",
    "VS Code word suggestions would be mixed into ss field completion",
  );
}

function assertHorizontal(segment, label) {
  assert(segment.y1 === segment.y2, `${label} is diagonal: ${JSON.stringify(segment)}`);
}

function assertVertical(segment, label) {
  assert(segment.x1 === segment.x2, `${label} is diagonal: ${JSON.stringify(segment)}`);
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
