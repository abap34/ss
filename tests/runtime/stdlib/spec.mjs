import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import path from 'node:path';
import { root, ssBin } from '../harness.mjs';

const scratch = path.join(root, '.ss-cache/tests/stdlib');
await mkdir(scratch, { recursive: true });
const project = await mkdtemp(path.join(scratch, 'api-'));
async function dump(source) {
  await writeFile(path.join(project, 'slide.ss'), source);
  const result = spawnSync(ssBin, ['dump', '--quiet', 'slide.ss', 'dump.json'], { cwd: project, encoding: 'utf8', timeout: 30000 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(await readFile(path.join(project, 'dump.json'), 'utf8'));
}
try {
  const literal = await dump(`page text
text!("**Literal**", current_theme().body with { text.parse = TextParseMode.plain })
text!("**Formatted**")
text("Unplaced")
h3!("Third level")
end
`);
  const raw = literal.nodes.find(n => n.content === '**Literal**');
  const formatted = literal.nodes.find(n => n.content === '**Formatted**');
  assert(raw && formatted);
  assert(raw.width > 20 && raw.height > 10, "Literal text must have rendered dimensions");
  assert.equal(raw.placement.input.type.name, 'Text');
  assert.equal(raw.placement.input.fields.find(f => f.name === 'style').value.fields.find(f => f.name === 'text').value.fields.find(f => f.name === 'parse').value.case, 'plain');
  assert.equal(formatted.placement.input.fields.find(f => f.name === 'style').value.fields.find(f => f.name === 'text').value.fields.find(f => f.name === 'parse').value.case, 'block');
  assert(!literal.nodes.some(n => n.content === 'Unplaced'));
  const headingSemantics = JSON.parse(literal.nodes.find(n => n.content === 'Third level').fields.semantics);
  assert.equal(headingSemantics.fields.find(f => f.name === 'heading_level').value.value, 3);

  const nested = await dump(`page nested
text!("**Styled**", default_text_style with {
  text.markdown.code.size = 17
  text.markdown.code.chrome.pad_x = 21
  text.markdown.code.colors.keyword = c"#123456"
  text.markdown.table.cell_pad_x = 13
  text.markdown.quote.pad_y = 11
  text.math.scale = 1.4
})
text!("Default")
end
`);
  const customPaint = nested.nodes.find(n => n.content === '**Styled**').render.text;
  assert.equal(customPaint.markdown_code_font_size, 17);
  assert.equal(customPaint.markdown_code_pad_x, 21);
  assert.deepEqual(customPaint.markdown_code_keyword_color, [18 / 255, 52 / 255, 86 / 255].map(v => Math.round(v * 10000) / 10000));
  assert.equal(customPaint.markdown_table_cell_pad_x, 13);
  assert.equal(customPaint.markdown_quote.pad_y, 11);
  assert.equal(customPaint.math_scale, 1.4);
  assert.equal(nested.nodes.find(n => n.content === 'Default').render.text.markdown_code_pad_x, 12);

  const parts = await dump(`import std:text as text_api
type Illustration { body: PathShape caption: String }
fn display(self: Placed<Illustration>) -> Group<PathShape, text_api::Text>
  return (self.value.body // text_api::Text { content = self.value.caption }) with { gap = 12 }
end
page diagram
let drawing = rectangle(200, 80)
let illustration = place!(Illustration { body = drawing caption = "Caption" })
~ illustration.left == page.left + 180
~ illustration.top == page.top - 180
end
`);
  assert.equal(parts.nodes.filter(n => n.content === 'Caption').length, 1);
  assert.equal(parts.nodes.filter(n => n.placement?.input.type?.name === 'Illustration').length, 1);
  const caption = parts.nodes.find(n => n.content === 'Caption');
  const shape = parts.nodes.find(n => n.placement?.display.kind === 'path_shape');
  assert(shape);
  assert.equal(shape.placement.page, caption.placement.page);
  assert.equal(shape.role, null);
  assert.equal(caption.role, null);

  const contents = await dump(`page contents
toc!("Contents")
end
page section
heading!("Section")
end
`);
  assert(!contents.nodes.some(n => n.role === 'pageno'));
  assert(contents.nodes.some(n => n.content === 'Contents'));

  const sharedStyles = await dump(`import std:themes/default as base
const theme: Theme = base::default_theme()
page title
 text!("Document title", theme.h1 with { text.size = 33 })
 text!("Document author", theme.byline with { text.size = 17 })
end
page heading
 heading!("Slide title", 1, theme.h1 with { text.size = 29 })
end
page contents
 toc!("Contents title", theme.toc)
end
page references
 text!("[1] Reference", theme.citation with { text.size = 11 })
end
`);
  for (const [content, size] of [
    ['Document title', 33],
    ['Document author', 17],
    ['Slide title', 29],
    ['Contents title', 36],
    ['[1] Reference', 11],
  ]) {
    const node = sharedStyles.nodes.find(n => n.content === content);
    assert(node, `Missing styled text: ${content}`);
    assert.equal(node.render.text.font_size, size, content);
    assert.equal(node.role, null, content);
  }

  const localPageNumbers = await dump(`page first
text!("First")
pageno!()
end
page second
text!("Second")
pageno!()
end
`);
  const documentPageNumbers = await dump(`document
foreach(pages(docctx()), (p: Page) |-> place_on!(p, pageno()))
end
page first
text!("First")
end
page second
text!("Second")
end
`);
  for (const document of [localPageNumbers, documentPageNumbers]) {
    const numbers = document.nodes.filter(n => n.placement?.input.type.name === 'PageNumber');
    assert.equal(numbers.length, 2);
    assert.deepEqual(numbers.map(n => document.nodes.find(child => child.id === n.placement.children[0]).content), ['1/2', '2/2']);
    for (const number of numbers) assert.equal(number.role, null);
  }

  for (const name of ['default', 'academic', 'pop']) {
    const themed = await dump(`import std:themes/${name} as chosen
 document
 set_theme(chosen::default_theme() with { body.text.size = 27 })
 end
 page theme
 text!("Default style", current_theme().body)
 text!("Local style", current_theme().body with { text.size = 19 })
 end
 `);
    assert.equal(themed.nodes.find(n => n.content === 'Default style').render.text.font_size, 27);
    assert.equal(themed.nodes.find(n => n.content === 'Local style').render.text.font_size, 19);
  }
} finally {
  await rm(project, { recursive: true, force: true });
}
