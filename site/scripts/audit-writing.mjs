import { readFile } from 'node:fs/promises';
import { readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, '..');

const checks = [
  { name: '予告文', pattern: /このページ|この章|この節|ここでは|見ていきます|説明していきます|まず|This page/g },
  { name: '評価語', pattern: /強力|柔軟|簡単|直感|高度|モダン|シームレス|いい感じ|重要です/g },
  { name: '否定対比', pattern: /単なる|だけではなく|ではなく|not just|Not just|not only|Not only/g },
  { name: '抽象的な強調', pattern: /本質|世界|可能性|全体像|価値|体験/g },
  { name: '確認の連発', pattern: /確認してください/g },
  { name: '英語圏の型', pattern: /serves as|boasts|showcases|seamless|robust|comprehensive|pivotal|crucial|Furthermore|Moreover|Additionally|LLM-oriented/g },
  { name: 'em dash', pattern: /[—–]/g },
];

async function collectDocs(dir, prefix = '') {
  const entries = await readdir(dir, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const relative = path.join(prefix, entry.name);
    const absolute = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await collectDocs(absolute, relative)));
    } else if (entry.isFile() && /\.(md|mdx)$/.test(entry.name)) {
      files.push(relative);
    }
  }
  return files;
}

const ignored = new Set(['_writing-style.md', '_request-checklist.md', '_writing-plan.md']);
const files = (await collectDocs(path.join(root, 'docs'))).filter((file) => !ignored.has(file));

let total = 0;
for (const file of files.sort()) {
  const text = await readFile(path.join(root, 'docs', file), 'utf8');
  const lines = text.split('\n');
  for (const [index, line] of lines.entries()) {
    if (file.startsWith('en/') && /[ぁ-んァ-ン一-龯]/.test(line)) {
      total += 1;
      console.log(`docs/${file}:${index + 1}: 英語ページの日本語: ${line.match(/[ぁ-んァ-ン一-龯]+/)?.[0] ?? ''}`);
    }
    for (const check of checks) {
      const matches = line.match(check.pattern);
      if (!matches) continue;
      total += matches.length;
      console.log(`docs/${file}:${index + 1}: ${check.name}: ${matches.join(', ')}`);
    }
  }
}

if (total > 0) {
  console.error(`writing audit found ${total} issue(s)`);
  process.exitCode = 1;
}
