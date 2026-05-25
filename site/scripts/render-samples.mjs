import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { createCssVariablesTheme, createHighlighter } from 'shiki';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const siteRoot = path.resolve(scriptDir, '..');
const repoRoot = path.resolve(siteRoot, '..');
const samplesDir = path.join(siteRoot, 'samples');
const publicDir = path.join(siteRoot, 'docs', 'public', 'generated', 'samples');
const generatedDir = path.join(siteRoot, 'generated');
const manifestPath = path.join(generatedDir, 'samples.json');

const ssBin = process.env.SS_BIN || path.join(repoRoot, 'zig-out', 'bin', 'ss');
const ssCommand = existsSync(ssBin) ? ssBin : 'ss';
const pdftoppm = process.env.PDFTOPPM || 'pdftoppm';
const ssLanguagePath = path.join(repoRoot, 'editor', 'vscode', 'syntaxes', 'ss.tmLanguage.json');
const ssLanguage = JSON.parse(await readFile(ssLanguagePath, 'utf8'));
const shikiTheme = createCssVariablesTheme({
  name: 'css-variables',
  variablePrefix: '--shiki-',
  variableDefaults: {},
  fontStyle: true,
});
const highlighter = await createHighlighter({
  themes: [shikiTheme],
  langs: [ssLanguage],
});

function run(command, args, options = {}) {
  execFileSync(command, args, {
    cwd: repoRoot,
    stdio: 'inherit',
    ...options,
  });
}

function readVersion() {
  try {
    return execFileSync(ssCommand, ['--version'], {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch {
    return 'ss version unknown';
  }
}

function sampleTitle(name) {
  return name
    .split('-')
    .map((part) => part.slice(0, 1).toUpperCase() + part.slice(1))
    .join(' ');
}

await mkdir(publicDir, { recursive: true });
await mkdir(generatedDir, { recursive: true });

const ssVersion = readVersion();
const files = (await readdir(samplesDir)).filter((file) => file.endsWith('.ss')).sort();
const manifest = {};

for (const file of files) {
  const name = path.basename(file, '.ss');
  const sourcePath = path.join(samplesDir, file);
  const source = await readFile(sourcePath, 'utf8');
  const hash = createHash('sha256')
    .update(source)
    .update('\0')
    .update(ssVersion)
    .digest('hex')
    .slice(0, 12);

  const pdfName = `${name}-${hash}.pdf`;
  const imageName = `${name}-${hash}.png`;
  const pdfPath = path.join(publicDir, pdfName);
  const imagePath = path.join(publicDir, imageName);
  const imageBase = imagePath.slice(0, -'.png'.length);

  if (!existsSync(pdfPath) || !existsSync(imagePath)) {
    run(ssCommand, ['render', sourcePath, pdfPath]);
    run(pdftoppm, ['-png', '-f', '1', '-l', '1', '-singlefile', pdfPath, imageBase]);
  }

  manifest[name] = {
    title: sampleTitle(name),
    source,
    highlightedSource: highlighter.codeToHtml(source, {
      lang: 'ss',
      theme: 'css-variables',
    }),
    sourcePath: `samples/${file}`,
    pdf: `/generated/samples/${pdfName}`,
    image: `/generated/samples/${imageName}`,
    ssVersion,
  };
}

await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
