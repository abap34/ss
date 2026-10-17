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
text!("**Literal**", current_theme() with { body.text.parse = TextParseMode.plain })
text!("**Formatted**")
text("Unplaced")
h3!("Third level")
end
`);
  const raw = literal.nodes.find(n => n.content === '**Literal**');
  const formatted = literal.nodes.find(n => n.content === '**Formatted**');
  assert(raw && formatted);
  assert(raw.width > 20 && raw.height > 10, "Literal text must have rendered dimensions");
  assert.match(raw.fields.text, /"case":"plain"/);
  assert.match(formatted.fields.text, /"case":"block"/);
  assert(!literal.nodes.some(n => n.content === 'Unplaced'));
  const headingSemantics = JSON.parse(literal.nodes.find(n => n.content === 'Third level').fields.semantics);
  assert.equal(headingSemantics.fields.find(f => f.name === 'heading_level').value.value, 3);

  const nested = await dump(`page nested
text!("**Styled**", current_theme() with {
  body.text.markdown.code.size = 17
  body.text.markdown.code.chrome.pad_x = 21
  body.text.markdown.code.colors.keyword = c"#123456"
  body.text.markdown.table.cell_pad_x = 13
  body.text.markdown.quote.pad_y = 11
  body.text.math.scale = 1.4
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

  const parts = await dump(`page diagram
let drawing = rectangle(200, 80)
let illustration = figure_parts(drawing, "Caption")
let framed = box_parts(illustration.root, ChromeStyle { pad_x = 12 pad_y = 10 })
~ drawing.left == page.left + 180
~ drawing.top == page.top - 180
place!(framed.root)
end
`);
  assert.equal(parts.nodes.filter(n => n.content === 'Caption').length, 1);
  assert.equal(parts.nodes.filter(n => n.role === 'panel').length, 1);
  const caption = parts.nodes.find(n => n.content === 'Caption');
  const captionSemantics = JSON.parse(caption.fields.semantics);
  assert.equal(captionSemantics.fields.find(f => f.name === 'role').value.case, 'caption');
  const shape = parts.nodes.find(n => n.role === 'vector_path');
  assert(shape);
  assert(Math.abs(shape.y - (caption.y + caption.height) - 12) < 0.01);

  const contents = await dump(`page contents
toc!("Contents")
end
page section
h1!("Section")
end
`);
  assert(!contents.nodes.some(n => n.role === 'pageno'));
  assert(contents.nodes.some(n => n.content === 'Contents'));

  const sharedStyles = await dump(`import std:themes/default as base
document
set_theme(base::default_theme() with { head.title.text.size = 29 })
end
page title
 title!("Document title", current_theme().h1 with { text.size = 33 })
 byline!("Document author", current_theme().byline with { text.size = 17 })
end
page heading
head!("Slide title")
end
page contents
toc!("Contents title")
end
page references
citation!(1, "Reference", current_theme().citation with { text.size = 11 })
end
`);
  for (const [content, size, role] of [
    ['Document title', 33, 'title'],
    ['Document author', 17, 'byline'],
    ['Slide title', 29, 'title'],
    ['Contents title', 36, 'label'],
    ['[1] Reference', 11, 'citation'],
  ]) {
    const node = sharedStyles.nodes.find(n => n.content === content);
    assert(node, `Missing styled object: ${content}`);
    assert.equal(node.render.text.font_size, size, content);
    assert.equal(node.role, role, content);
  }
  assert.equal(sharedStyles.nodes.filter(n => n.role === 'rule').length, 1);

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
pagenos!()
footers!("Footer")
watermark!("Draft")
end
page first
text!("First")
end
page second
text!("Second")
end
`);
  const localNumbers = localPageNumbers.nodes.filter(n => n.role === 'pageno');
  const documentNumbers = documentPageNumbers.nodes.filter(n => n.role === 'pageno');
  assert.equal(localNumbers.length, 2);
  assert.equal(documentNumbers.length, 2);
  assert.deepEqual(localNumbers.map(n => n.display_content), ['1/2', '2/2']);
  assert.deepEqual(documentNumbers.map(n => n.display_content), ['1/2', '2/2']);
  for (let index = 0; index < 2; index++) {
    for (const key of ['x', 'y', 'width', 'height']) {
      assert(Math.abs(localNumbers[index][key] - documentNumbers[index][key]) < 0.01,
        `Page number ${index + 1} ${key} differs between page and document registration`);
    }
  }
  assert.equal(documentPageNumbers.nodes.filter(n => n.role === 'footer').length, 2);
  assert.equal(documentPageNumbers.nodes.filter(n => n.role === 'watermark').length, 2);

  for (const name of ['default', 'academic', 'pop']) {
    const themed = await dump(`import std:themes/${name} as chosen
 document
 set_theme(chosen::default_theme() with { body.text.size = 27 })
 end
 page theme
 text!("Default style")
 text!("Local style", current_theme() with { body.text.size = 19 })
 end
 `);
    assert.equal(themed.nodes.find(n => n.content === 'Default style').render.text.font_size, 27);
    assert.equal(themed.nodes.find(n => n.content === 'Local style').render.text.font_size, 19);
  }
} finally {
  await rm(project, { recursive: true, force: true });
}
