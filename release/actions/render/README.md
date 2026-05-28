# Render ss Slides

This action renders `.ss` slide decks to PDF with the prebuilt `ss` render
container.

## Usage

```yaml
name: Render slides

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

jobs:
  render:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: abap34/ss/release/actions/render@v0
        with:
          input: "slides/**/*.ss"
          out-dir: dist
      - uses: actions/upload-artifact@v4
        with:
          name: slides
          path: dist
```

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `image` | `ghcr.io/abap34/ss-render:v0` | Prebuilt render image. |
| `input` | `slides/**/*.ss` | Newline- or comma-separated `.ss` glob patterns. |
| `out-dir` | `dist` | Directory populated with rendered PDFs. |
| `pdf-dir` | empty | Optional directory under `out-dir` for rendered PDFs. |
| `asset-base-dir` | empty | Optional `--asset-base-dir` passed to `ss`. |
| `clean` | `true` | Remove `out-dir` before rendering. |
| `check` | `true` | Run `ss check` before each render. |
| `write-dump` | `false` | Write dump JSON files next to PDFs. |

## Direct Container Use

```sh
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$PWD:/workspace" \
  -w /workspace \
  ghcr.io/abap34/ss-render:v0 \
  render slides/deck.ss dist/deck.pdf
```
