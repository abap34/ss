import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { root, ssBin } from '../../harness.mjs';

const probe = spawnSync('pdflatex', ['--version'], { timeout: 10000 });
if (probe.error?.code !== 'ENOENT') {
  assert.equal(probe.status, 0, 'pdflatex availability probe failed');
  await testSizing();
}

async function testSizing() {
  const scratch = path.join(root, '.ss-cache/tests/math-sizing');
  await mkdir(scratch, { recursive: true });
  const project = await mkdtemp(path.join(scratch, 'project-'));
  const aligned = String.raw`\begin{aligned}x&=\frac{a}{b}\end{aligned}`;
  const rows = String.raw`\begin{aligned}x&=\frac{a}{b}\\x&=\frac{a}{b}\end{aligned}`;
  const cases = [
    { name: 'inline', content: '$x$' },
    { name: 'display', content: '$$x$$' },
    { name: 'aligned', formula: aligned },
    { name: 'rows', formula: rows },
    { name: 'formatted_rows', formula: rows.replaceAll('\\\\', '\\\\\n') },
    { name: 'matrix_two', formula: String.raw`\begin{matrix}x\\x\end{matrix}` },
    { name: 'matrix_three', formula: String.raw`\begin{matrix}x\\x\\x\end{matrix}` },
    { name: 'wide', formula: 'x+x+x+x' },
    { name: 'overflow', formula: 'x+x+x+x', width: 30 },
    { name: 'shrink', formula: 'x+x+x+x', width: 30, style: 'body.text.display_math_fit = MathFit.shrink' },
    { name: 'shrink_short', content: '$$x$$', style: 'body.text.display_math_fit = MathFit.shrink' },
    { name: 'double_size', content: '$$x$$', style: 'body.text.size = 48' },
    { name: 'scaled', content: '$$x$$', style: 'body.text.math_scale = 1.5' },
    { name: 'zero_gap', formula: aligned, style: 'body.text.display_math_gap = 0' },
    { name: 'large_gap', formula: aligned, style: 'body.text.display_math_gap = 1' },
  ];
  const source = 'import std:themes/default as *\n' + cases.map(c => `
page ${c.name}
  let body = text! <<
${c.content ?? `$$\n${c.formula}\n$$`}
>>
  body.text.size = 24
  body.text.math_scale = 1
  ${c.style ?? ''}
  ~ body.width == ${c.width ?? 500}
  ~ body.left == page.left + 100
  ~ body.top == page.top - 100
  let following = text! "After ${c.name}"
  body // following
end
`).join('\n');
  const run = args => {
    const result = spawnSync(ssBin, args, { cwd: project, encoding: 'utf8', timeout: 60000 });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
    return result;
  };
  try {
    await writeFile(path.join(project, 'slide.ss'), source);
    run(['render', '--format', 'html', 'slide.ss', 'out.html', '--diagnostics-json', 'diagnostics.json']);
    const html = await readFile(path.join(project, 'out.html'), 'utf8');
    const boxes = [...html.matchAll(/<(?:span|div) class="ss-item ss-latex ss-pdf"[^>]*style="([^"]*)"/g)].map(m => {
      const result = {};
      for (const key of ['width', 'height', 'top']) {
        const value = new RegExp(`(?:^|;)${key}:([-0-9.]+)pt(?:;|$)`).exec(m[1]);
        assert(value, m[1]);
        result[key] = Number(value[1]);
      }
      return result;
    });
    assert.equal(boxes.length, cases.length);
    const byName = Object.fromEntries(cases.map((c, i) => [c.name, boxes[i]]));
    const near = (a, b) => assert(Math.abs(a - b) < 0.08, `${a} != ${b}`);
    near(byName.inline.width, byName.display.width);
    near(byName.aligned.width, byName.rows.width);
    assert(byName.rows.height > byName.aligned.height * 1.8, 'Extra aligned rows did not grow the block');
    near(byName.rows.height, byName.formatted_rows.height);
    near(byName.rows.width, byName.formatted_rows.width);
    near(byName.matrix_two.width, byName.matrix_three.width);
    assert(byName.matrix_three.height > byName.matrix_two.height * 1.3, 'Matrix rows shrank their letters');
    near(byName.wide.width, byName.overflow.width);
    near(byName.wide.height, byName.overflow.height);
    near(byName.shrink.width, 30);
    assert(byName.shrink.height < byName.overflow.height, 'Explicit shrink was ignored');
    near(byName.shrink_short.width, byName.display.width);
    near(byName.double_size.width, byName.display.width * 2);
    near(byName.double_size.height, byName.display.height * 2);
    near(byName.scaled.width, byName.display.width * 1.5);
    near(byName.large_gap.height, byName.zero_gap.height);
    near(byName.large_gap.top - byName.zero_gap.top, 24);

    const diagnostics = JSON.parse(await readFile(path.join(project, 'diagnostics.json'), 'utf8')).diagnostics;
    assert.equal(diagnostics.filter(d => d.code === 'FrameTooSmall').length, 1, JSON.stringify(diagnostics));
    assert.equal(diagnostics.length, 1, JSON.stringify(diagnostics));

    run(['dump', 'slide.ss', 'dump.json']);
    const dump = JSON.parse(await readFile(path.join(project, 'dump.json'), 'utf8'));
    const following = name => dump.nodes.find(n => n.content === `After ${name}`);
    assert(following('rows').y < following('aligned').y, 'Following object did not move after math grew');
    near(following('zero_gap').y - following('large_gap').y, 48);

    // Reuse the same on-disk caches after a style-only change.
    await writeFile(path.join(project, 'slide.ss'), source.replace('body.text.math_scale = 1.5', 'body.text.math_scale = 2'));
    run(['render', 'slide.ss', 'out.pdf']);
    run(['render', '--format', 'html', 'slide.ss', 'updated.html']);
    const updated = await readFile(path.join(project, 'updated.html'), 'utf8');
    const widths = [...updated.matchAll(/<(?:span|div) class="ss-item ss-latex ss-pdf"[^>]*style="[^"]*?width:([-0-9.]+)pt/g)].map(m => Number(m[1]));
    near(widths[cases.findIndex(c => c.name === 'scaled')], byName.display.width * 2);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}
