import { defineConfig } from '@rspress/core';
import { bundledLanguagesInfo } from 'shiki';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { LanguageRegistration } from 'shiki';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ssLanguage = JSON.parse(
  readFileSync(path.join(__dirname, '..', 'editor/vscode/syntaxes/ss.tmLanguage.json'), 'utf8'),
) as LanguageRegistration;
const bundledLanguageIds = bundledLanguagesInfo.map((language) => language.id);

export default defineConfig({
  root: 'docs',
  title: 'ss',
  description: 'A staged slide description language and renderer.',
  lang: 'en',
  logo: '/logo.png',
  logoText: 'ss',
  locales: [
    {
      lang: 'en',
      label: 'English',
      title: 'ss',
      description: 'A staged slide description language and renderer.',
    },
    {
      lang: 'ja',
      label: '日本語',
      title: 'ss',
      description: 'スライドを記述し，PDF を生成するための小さな言語です．',
    },
  ],
  llms: true,
  languageParity: {
    enabled: true,
  },
  globalUIComponents: [path.join(__dirname, 'components/FlowchartRenderer.tsx')],
  globalStyles: path.join(__dirname, 'styles/global.css'),
  markdown: {
    shiki: {
      langs: [...bundledLanguageIds, ssLanguage],
    },
  },
  themeConfig: {
    socialLinks: [
      {
        icon: 'github',
        mode: 'link',
        content: 'https://github.com/abap34/ss',
      },
    ],
    enableContentAnimation: true,
    llmsUI: {
      placement: 'outline',
      viewOptions: ['markdownLink', 'chatgpt', 'claude'],
    },
  },
});
