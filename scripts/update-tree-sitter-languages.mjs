#!/usr/bin/env node
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import fs from "node:fs/promises";
import path from "node:path";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const bundleRoot = path.join(repoRoot, "third_party", "tree-sitter-languages");
const manifestPath = path.join(bundleRoot, "manifest.json");
const readmePath = path.join(bundleRoot, "README.md");
const cacheRoot = path.join(repoRoot, ".ss-cache", "tree-sitter-languages");
const generatedRoot = path.join(repoRoot, ".zig-cache", "tree-sitter-languages");

const args = new Set(process.argv.slice(2));
const checkOnly = args.has("--check");
const updateLatest = args.has("--latest");
const prepareBuild = args.has("--prepare-build");
const allowedArgs = new Set(["--check", "--latest", "--prepare-build"]);
for (const arg of args) {
  if (!allowedArgs.has(arg)) {
    throw new Error(`unknown argument: ${arg}`);
  }
}
if ([checkOnly, updateLatest, prepareBuild].filter(Boolean).length > 1) {
  throw new Error("--check, --latest, and --prepare-build cannot be combined");
}

const manifest = await readManifest();
validateManifest(manifest);

if (checkOnly) {
  await checkManifestFiles(manifest);
  await checkReadme(manifest);
  process.exit(0);
}

if (prepareBuild) {
  await syncLanguages(manifest, { copyTracked: false, copyGenerated: true });
  process.exit(0);
}

if (updateLatest) {
  await updateManifestToLatest(manifest);
  await writeManifest(manifest);
}

await syncLanguages(manifest, { copyTracked: true, copyGenerated: true });
await fs.writeFile(readmePath, renderReadme(manifest), "utf8");

async function readManifest() {
  const text = await fs.readFile(manifestPath, "utf8");
  return JSON.parse(text);
}

async function writeManifest(manifest) {
  await fs.writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
}

function validateManifest(manifest) {
  if (manifest.schema !== 1) throw new Error("unsupported tree-sitter language manifest schema");
  if (!Number.isInteger(manifest.language_abi)) throw new Error("manifest language_abi must be an integer");
  if (!Array.isArray(manifest.languages) || manifest.languages.length === 0) {
    throw new Error("manifest languages must be a non-empty array");
  }
  const names = new Set();
  for (const language of manifest.languages) {
    for (const field of ["name", "display_name", "repo", "commit"]) {
      if (typeof language[field] !== "string" || language[field].length === 0) {
        throw new Error(`language entry is missing ${field}`);
      }
    }
    if (!/^[a-z0-9_-]+$/.test(language.name)) throw new Error(`invalid language name: ${language.name}`);
    if (names.has(language.name)) throw new Error(`duplicate language name: ${language.name}`);
    names.add(language.name);
    if (!/^[0-9a-f]{40}$/.test(language.commit)) throw new Error(`invalid commit for ${language.name}`);
    if (!Array.isArray(language.aliases) || language.aliases.length === 0) {
      throw new Error(`language ${language.name} must declare aliases`);
    }
    if (!Array.isArray(language.files) || language.files.length === 0) {
      throw new Error(`language ${language.name} must declare files`);
    }
    if (language.generate !== undefined && !Array.isArray(language.generate)) {
      throw new Error(`language ${language.name} generate must be an array`);
    }
    for (const dir of language.generate ?? ["."]) {
      if (typeof dir !== "string") throw new Error(`language ${language.name} has an invalid generate entry`);
      rejectUnsafePath(dir, `${language.name} generate path`);
    }
    for (const file of language.files) {
      if (typeof file.from !== "string" || typeof file.to !== "string") {
        throw new Error(`language ${language.name} has an invalid file entry`);
      }
      rejectUnsafePath(file.from, `${language.name} source path`);
      rejectUnsafePath(file.to, `${language.name} destination path`);
    }
  }
}

function rejectUnsafePath(value, label) {
  if (path.isAbsolute(value) || value.split(/[\\/]/).includes("..")) {
    throw new Error(`${label} must be relative and stay inside its root: ${value}`);
  }
}

async function checkManifestFiles(manifest) {
  for (const language of manifest.languages) {
    const destRoot = path.join(bundleRoot, language.name);
    for (const file of language.files) {
      if (isGeneratedFile(file.to)) continue;
      const dest = path.join(destRoot, file.to);
      try {
        await fs.access(dest);
      } catch {
        throw new Error(`missing bundled tree-sitter file: ${path.relative(repoRoot, dest)}`);
      }
    }
  }
}

async function checkReadme(manifest) {
  const expected = renderReadme(manifest);
  const actual = await fs.readFile(readmePath, "utf8");
  if (actual !== expected) {
    throw new Error("third_party/tree-sitter-languages/README.md is out of sync; run scripts/update-tree-sitter-languages.mjs");
  }
}

async function updateManifestToLatest(manifest) {
  for (const language of manifest.languages) {
    const latest = latestCommit(language.repo);
    if (latest !== language.commit) {
      console.log(`${language.name}: ${language.commit} -> ${latest}`);
      language.commit = latest;
    } else {
      console.log(`${language.name}: already at ${latest}`);
    }
  }
}

function latestCommit(repo) {
  const output = execFileSync("git", ["ls-remote", repo, "HEAD"], { encoding: "utf8" }).trim();
  const [commit] = output.split(/\s+/);
  if (!/^[0-9a-f]{40}$/.test(commit)) throw new Error(`could not resolve HEAD for ${repo}`);
  return commit;
}

async function syncLanguages(manifest, options) {
  await fs.rm(cacheRoot, { recursive: true, force: true });
  await fs.mkdir(cacheRoot, { recursive: true });
  if (options.copyGenerated) {
    await fs.mkdir(generatedRoot, { recursive: true });
  }
  const treeSitter = await resolveTreeSitterCommand(manifest);
  for (const language of manifest.languages) {
    console.log(`sync ${language.name} ${language.commit}`);
    const checkout = path.join(cacheRoot, language.name);
    await checkoutCommit(language.repo, language.commit, checkout);
    await installGrammarDependencies(checkout);
    generateLanguage(treeSitter, checkout, language);
    if (options.copyTracked) {
      await fs.rm(path.join(bundleRoot, language.name), { recursive: true, force: true });
    }
    if (options.copyGenerated) {
      await fs.rm(path.join(generatedRoot, language.name), { recursive: true, force: true });
    }
    for (const file of language.files) {
      const source = path.join(checkout, file.from);
      const generated = isGeneratedFile(file.to);
      if (generated && !options.copyGenerated) continue;
      if (!generated && !options.copyTracked) continue;
      const root = generated ? generatedRoot : bundleRoot;
      const dest = path.join(root, language.name, file.to);
      await fs.mkdir(path.dirname(dest), { recursive: true });
      await fs.copyFile(source, dest);
    }
  }
}

function isGeneratedFile(relativePath) {
  return relativePath.startsWith("src/") || relativePath.startsWith("common/") || relativePath.includes("/src/");
}

async function resolveTreeSitterCommand(manifest) {
  const localTreeSitter = path.join(repoRoot, "editor", "tree-sitter-ss", "node_modules", ".bin", process.platform === "win32" ? "tree-sitter.cmd" : "tree-sitter");
  if (!(await fileExists(localTreeSitter))) {
    run("npm", ["ci", "--prefix", path.join(repoRoot, "editor", "tree-sitter-ss")]);
  }

  const candidates = [];
  if (process.env.TREE_SITTER_CLI) candidates.push(process.env.TREE_SITTER_CLI);
  candidates.push(localTreeSitter);
  candidates.push("tree-sitter");

  for (const command of candidates) {
    if (command !== "tree-sitter") {
      try {
        await fs.access(command);
      } catch {
        continue;
      }
    }
    const version = commandOutput(command, ["--version"]).trim();
    if (!version.includes(manifest.tree_sitter_cli)) {
      throw new Error(`tree-sitter CLI version ${manifest.tree_sitter_cli} is required, got: ${version}`);
    }
    return command;
  }

  throw new Error("tree-sitter CLI is missing; run `npm ci` in editor/tree-sitter-ss or set TREE_SITTER_CLI");
}

async function fileExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function installGrammarDependencies(checkout) {
  try {
    await fs.access(path.join(checkout, "package.json"));
  } catch {
    return;
  }
  run("npm", [
    "install",
    "--ignore-scripts",
    "--no-audit",
    "--no-fund",
    "--cache",
    path.join(cacheRoot, "npm-cache"),
  ], { cwd: checkout });
}

function generateLanguage(treeSitter, checkout, language) {
  for (const dir of language.generate ?? ["."]) {
    run(treeSitter, ["generate"], { cwd: path.join(checkout, dir) });
  }
}

async function checkoutCommit(repo, commit, dest) {
  await fs.mkdir(dest, { recursive: true });
  run("git", ["init", "-q"], { cwd: dest });
  run("git", ["remote", "add", "origin", repo], { cwd: dest });
  run("git", ["fetch", "--depth=1", "origin", commit], { cwd: dest });
  run("git", ["checkout", "-q", "--detach", "FETCH_HEAD"], { cwd: dest });
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? repoRoot,
    stdio: "inherit",
    env: process.env,
  });
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} failed with status ${result.status}`);
  }
}

function commandOutput(command, args) {
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    env: process.env,
  });
  if (result.status !== 0) return "";
  return `${result.stdout}${result.stderr}`;
}

function renderReadme(manifest) {
  const aliases = ["ss", ...manifest.languages.flatMap((language) => language.aliases)];
  const table = manifest.languages
    .map((language) => `| ${language.display_name} | ${language.repo} | ${language.commit} |`)
    .join("\n");
  return `# Bundled tree-sitter languages

These pinned tree-sitter languages let \`ss\` highlight common code blocks
without per-project parser libraries.

The repository keeps lightweight highlight queries, upstream licenses, and the
manifest below. Generated parser C sources are materialized under
\`.zig-cache/tree-sitter-languages\` during the build so they do not inflate git
history.

Run this command to refresh tracked queries and materialize generated parser
sources from the pinned commits:

\`\`\`sh
node scripts/update-tree-sitter-languages.mjs
\`\`\`

Run this command to advance every bundled parser to the current upstream HEAD:

\`\`\`sh
node scripts/update-tree-sitter-languages.mjs --latest
\`\`\`

The scheduled GitHub Actions workflow runs the \`--latest\` form and opens a pull
request when upstream commits change tracked queries or licenses.

All listed parsers are MIT licensed. Each language directory keeps the upstream
\`LICENSE\` file.

Parsers are generated from the listed upstream commits with tree-sitter CLI
${manifest.tree_sitter_cli} and kept compatible with tree-sitter language ABI ${manifest.language_abi}.

Default highlighting is enabled for these code block language names:
\`${aliases.join("`, `")}\`.

| Language | Upstream | Commit |
| --- | --- | --- |
${table}
`;
}
