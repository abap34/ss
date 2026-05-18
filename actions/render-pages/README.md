# Render ss Slides for GitHub Pages

This action renders `.ss` slide decks to PDF with the prebuilt `ss` render
container, generates an `index.html`, and uploads the directory as a GitHub
Pages artifact.

## Usage

```yaml
name: Deploy slides

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: yuchi/ss/actions/render-pages@v0
        with:
          input: "slides/**/*.ss"
          title: "Slides"

  deploy:
    needs: build
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pages: write
      id-token: write
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - id: deployment
        uses: actions/deploy-pages@v4
```

Set the repository's Pages source to **GitHub Actions** before the first deploy.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `image` | `ghcr.io/yuchi/ss-render:v0` | Prebuilt render image. |
| `input` | `slides/**/*.ss` | Newline- or comma-separated `.ss` glob patterns. |
| `out-dir` | `_site` | Directory uploaded as the Pages artifact. |
| `pdf-dir` | `slides` | Directory under `out-dir` for rendered PDFs. |
| `title` | `Slides` | Generated `index.html` title. |
| `asset-base-dir` | empty | Optional `--asset-base-dir` passed to `ss`. |
| `clean` | `true` | Remove `out-dir` before rendering. |
| `check` | `true` | Run `ss check` before each render. |
| `write-dump` | `false` | Write dump JSON files next to PDFs. |
| `configure-pages` | `true` | Run `actions/configure-pages` before upload. |
| `upload-artifact` | `true` | Run `actions/upload-pages-artifact`. |

## Direct Container Use

```sh
docker run --rm \
  -v "$PWD:/workspace" \
  -w /workspace \
  -e SS_INPUT='slides/**/*.ss' \
  -e SS_OUT_DIR='_site' \
  ghcr.io/yuchi/ss-render:v0
```
