#!/usr/bin/env node
import { spawn } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { assert, ssBin } from "./harness.mjs";

const pdflatexAvailable = await commandSucceeds("pdflatex", ["--version"]);
const lualatexAvailable = await commandSucceeds("lualatex", ["--version"]);
const pdftotextAvailable = await commandSucceeds("pdftotext", ["-v"]);

if (pdflatexAvailable && pdftotextAvailable) {
  await testInlineMathRemainsSelectable();
  await testLiteralLatexBodySupportsTextModeEnvironments();
  await testMarkdownMathUsesPreambleFallback();
  if (await commandSucceeds("kpsewhich", ["algorithm2e.sty"])) {
    await testAlgorithm2eRemainsSelectable();
  }
}
if (pdflatexAvailable && process.platform !== "win32") {
  await testExplicitLatexBodiesShareOneEngineProcess();
  await testMarkdownAndExplicitLatexShareOneEngineProcess();
  await testLatexPreambleScopesCreateSeparateEngineProcesses();
  await testLatexArtifactCacheIsReusedAndInvalidated();
}
if (
  lualatexAvailable &&
  await commandSucceeds("kpsewhich", ["luatexja-fontspec.sty"]) &&
  await commandSucceeds("kpsewhich", ["HaranoAjiMincho-Regular.otf"])
) {
  await testLuaLaTeXRendersJapaneseText();
}

async function testLuaLaTeXRendersJapaneseText() {
  const project = await mkdtempProject("ss-lualatex-japanese-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

document
  latex_engine(LatexEngine.pdflatex)
  latex_preamble("\\usepackage{luatexja-fontspec}")
  latex_preamble("\\setmainjfont{HaranoAjiMincho-Regular}")
end

page formula
page_latex_engine(LatexEngine.lualatex)
latex!("\u65e5\u672c\u8a9e\u3092\u542b\u3080\u6570\u5f0f $x^2$")
end
`,
      "utf8",
    );

    const render = await spawnCollect(ssBin, ["render", "slide.ss", "out.pdf"], project);
    assert(render.code === 0, `LuaLaTeX render failed:\n${combinedOutput(render)}`);
    const pdf = await readFile(path.join(project, "out.pdf"));
    assert(pdf.subarray(0, 5).toString("ascii") === "%PDF-", "LuaLaTeX render did not produce a PDF");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testMarkdownMathUsesPreambleFallback() {
  const project = await mkdtempProject("ss-markdown-math-preamble-");
  try {
    await writeFile(path.join(project, "preamble.tex"), "\\newcommand{\\ArchiveMacro}{\\text{MacroToken42}}\n", "utf8");
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page formula
text!("Inline $\\ArchiveMacro$ fallback")
end

document
  latex_preamble_file("preamble.tex")
end
`,
      "utf8",
    );

    await renderAndExtract(project);
    const text = await readFile(path.join(project, "out.txt"), "utf8");
    assert(text.replace(/\s+/g, "").includes("MacroToken42"), `Markdown math did not preserve the LaTeX preamble:\n${text}`);
    const htmlRender = await spawnCollect(ssBin, ["render", "--format", "html", "slide.ss", "out.html"], project);
    assert(htmlRender.code === 0, `HTML render failed:\n${combinedOutput(htmlRender)}`);
    const html = await readFile(path.join(project, "out.html"), "utf8");
    assert(html.includes('class="ss-item ss-latex ss-pdf"'), "Markdown math did not use the LaTeX PDF renderer");
    assert(html.includes('role="math" aria-label="\\ArchiveMacro"'), "Markdown math did not preserve its LaTeX semantics");
    assert(
      /<span[^>]*role="math" aria-label="\\ArchiveMacro"[^>]*>[^<]*<\/span>/.test(html),
      "raw Markdown math emitted mismatched semantic tags",
    );
    assert(html.includes('data-pdf-src="ss-resource:latex_pdf:'), "Markdown math did not reference its embedded PDF");
    assert(html.includes('data-media-type="application/pdf"'), "raw Markdown math PDF was not embedded in the HTML file");
    assert(html.includes("data:text/javascript;charset=utf-8;base64,"), "raw Markdown math omitted its embedded PDF.js runtime");
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testInlineMathRemainsSelectable() {
  const project = await mkdtempProject("ss-math-pdf-selectable-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page formula
let formula = latex!("$\\mathrm{SelectableMathToken}$")
~ formula.left == page.left + 120
~ formula.top == page.top - 180
end
`,
      "utf8",
    );

    await renderAndExtract(project);
    const text = await readFile(path.join(project, "out.txt"), "utf8");
    assert(text.includes("SelectableMathToken"), `LaTeX math text was not selectable:\n${text}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testLiteralLatexBodySupportsTextModeEnvironments() {
  const project = await mkdtempProject("ss-latex-body-environment-");
  try {
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page body
latex! <<
\\begin{tabular}{ll}
LiteralBodyToken & PlainTextToken \\\\
\\end{tabular}
>>
end
`,
      "utf8",
    );

    await renderAndExtract(project);
    const text = await readFile(path.join(project, "out.txt"), "utf8");
    assert(text.includes("LiteralBodyToken"), `literal LaTeX body omitted its first text cell:\n${text}`);
    assert(text.includes("PlainTextToken"), `literal LaTeX body omitted its second text cell:\n${text}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testAlgorithm2eRemainsSelectable() {
  const project = await mkdtempProject("ss-algorithm2e-pdf-selectable-");
  try {
    await writeFile(path.join(project, "preamble.tex"), "\\usepackage[ruled,vlined]{algorithm2e}\n", "utf8");
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page algorithm
let algorithm = latex! <<
\\DontPrintSemicolon
\\begin{algorithm}[H]
  \\KwData{SelectableAlgorithmInput}
  \\KwResult{SelectableAlgorithmResult}
  \\While{condition}{update state\\;}
\\end{algorithm}
>>
~ algorithm.left == page.left + 120
~ algorithm.right == page.right - 120
~ algorithm.top == page.top - 100
~ algorithm.bottom == page.bottom + 100
end

document
  latex_preamble_file("preamble.tex")
end
`,
      "utf8",
    );

    await renderAndExtract(project);
    const text = await readFile(path.join(project, "out.txt"), "utf8");
    assert(text.includes("SelectableAlgorithmInput"), `algorithm2e input text was not selectable:\n${text}`);
    assert(text.includes("SelectableAlgorithmResult"), `algorithm2e result text was not selectable:\n${text}`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testExplicitLatexBodiesShareOneEngineProcess() {
  const project = await mkdtempProject("ss-latex-batch-");
  try {
    const instrumented = await instrumentPdflatex(project);
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page formulas
latex!("$x + y$")
latex!("$a + b$")
end
`,
      "utf8",
    );

    const render = await spawnCollect(ssBin, ["render", "slide.ss", "out.pdf"], project, 30000, instrumented.env);
    assert(render.code === 0, `batched LaTeX render failed:\n${combinedOutput(render)}`);
    const runs = await pdflatexRunCount(instrumented.counter);
    assert(runs === 1, `two explicit latex bodies started pdflatex ${runs} times instead of once`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testMarkdownAndExplicitLatexShareOneEngineProcess() {
  const project = await mkdtempProject("ss-latex-shared-pipeline-");
  try {
    const instrumented = await instrumentPdflatex(project);
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page formulas
text!("Inline $x + y$")
text! <<
$$a + b$$
>>
latex!("$c + d$")
end
`,
      "utf8",
    );

    const render = await spawnCollect(ssBin, ["render", "slide.ss", "out.pdf"], project, 30000, instrumented.env);
    assert(render.code === 0, `shared Markdown and explicit LaTeX render failed:\n${combinedOutput(render)}`);
    const runs = await pdflatexRunCount(instrumented.counter);
    assert(runs === 1, `Markdown and explicit LaTeX started pdflatex ${runs} times instead of sharing one process`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testLatexPreambleScopesCreateSeparateEngineProcesses() {
  const project = await mkdtempProject("ss-latex-preamble-groups-");
  try {
    const instrumented = await instrumentPdflatex(project);
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

page first
page_latex_preamble("\\newcommand{\\ScopedToken}{First}")
latex!("$\\ScopedToken$")
end

page second
page_latex_preamble("\\newcommand{\\ScopedToken}{Second}")
latex!("$\\ScopedToken$")
end
`,
      "utf8",
    );

    const render = await spawnCollect(ssBin, ["render", "slide.ss", "out.pdf"], project, 30000, instrumented.env);
    assert(render.code === 0, `scoped LaTeX preamble render failed:\n${combinedOutput(render)}`);
    const runs = await pdflatexRunCount(instrumented.counter);
    assert(runs === 2, `two distinct LaTeX preambles started pdflatex ${runs} times instead of twice`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function testLatexArtifactCacheIsReusedAndInvalidated() {
  const project = await mkdtempProject("ss-latex-artifact-cache-");
  try {
    const instrumented = await instrumentPdflatex(project);
    await writeFile(path.join(project, "preamble.tex"), "\\newcommand{\\CacheToken}{First}\n", "utf8");
    await writeFile(
      path.join(project, "slide.ss"),
      `import std:themes/default as *

document
latex_preamble_file("preamble.tex")
end

page formula
text!("Markdown $\\CacheToken$")
latex!("$\\CacheToken$")
end
`,
      "utf8",
    );

    const pdfRender = await spawnCollect(ssBin, ["render", "slide.ss", "out.pdf"], project, 30000, instrumented.env);
    assert(pdfRender.code === 0, `initial cached LaTeX render failed:\n${combinedOutput(pdfRender)}`);
    assert(await pdflatexRunCount(instrumented.counter) === 1, "initial LaTeX render did not use one batched process");

    const htmlRender = await spawnCollect(ssBin, ["render", "--format", "html", "slide.ss", "out.html"], project, 30000, instrumented.env);
    assert(htmlRender.code === 0, `cached HTML LaTeX render failed:\n${combinedOutput(htmlRender)}`);
    assert(await pdflatexRunCount(instrumented.counter) === 1, "HTML render did not reuse PDF-rendered LaTeX artifacts");

    await writeFile(path.join(project, "preamble.tex"), "\\newcommand{\\CacheToken}{Second}\n", "utf8");
    const changedRender = await spawnCollect(ssBin, ["render", "--format", "html", "slide.ss", "changed.html"], project, 30000, instrumented.env);
    assert(changedRender.code === 0, `changed-preamble LaTeX render failed:\n${combinedOutput(changedRender)}`);
    const runs = await pdflatexRunCount(instrumented.counter);
    assert(runs === 2, `changing a LaTeX preamble file produced ${runs} pdflatex runs instead of invalidating once`);
  } finally {
    await rm(project, { recursive: true, force: true });
  }
}

async function renderAndExtract(project) {
  const render = await spawnCollect(ssBin, ["render", "slide.ss", "out.pdf"], project);
  assert(render.code === 0, `render failed:\n${combinedOutput(render)}`);
  const extraction = await spawnCollect("pdftotext", ["out.pdf", "out.txt"], project);
  assert(extraction.code === 0, `pdftotext failed:\n${combinedOutput(extraction)}`);
}

function mkdtempProject(prefix) {
  return mkdtemp(path.join(os.tmpdir(), prefix));
}

async function commandSucceeds(command, args) {
  try {
    const result = await spawnCollect(command, args, process.cwd(), 10000);
    return result.code === 0;
  } catch {
    return false;
  }
}

async function instrumentPdflatex(project) {
  const lookup = await spawnCollect("sh", ["-lc", "command -v pdflatex"], process.cwd(), 10000);
  assert(lookup.code === 0, `could not locate pdflatex:\n${combinedOutput(lookup)}`);
  const realPdflatex = lookup.stdout.trim();
  assert(realPdflatex.length > 0, "pdflatex lookup returned an empty path");

  const binDir = path.join(project, "bin");
  const wrapper = path.join(binDir, "pdflatex");
  const counter = path.join(project, "pdflatex-runs.txt");
  await mkdir(binDir);
  await writeFile(
    wrapper,
    `#!/bin/sh\nprintf 'run\\n' >> ${shellQuote(counter)}\nexec ${shellQuote(realPdflatex)} "$@"\n`,
    "utf8",
  );
  await chmod(wrapper, 0o755);
  return {
    counter,
    env: { ...process.env, PATH: `${binDir}${path.delimiter}${process.env.PATH ?? ""}` },
  };
}

async function pdflatexRunCount(counter) {
  return (await readFile(counter, "utf8")).trim().split(/\r?\n/).filter(Boolean).length;
}

function spawnCollect(command, args, cwd, timeoutMs = 30000, env = process.env) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, env });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => child.kill("SIGTERM"), timeoutMs);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal, stdout, stderr });
    });
  });
}

function shellQuote(value) {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

function combinedOutput(result) {
  return `${result.stdout}${result.stderr}`;
}
