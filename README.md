# ss: yet another slide description language & system

<div align="center">

ss is a slide description language and system.

If you are a programmer who puts a lot of code on slides, a mathematics
enthusiast who uses plenty of unusual symbols, or a pitiful AI Agent forced to make slides, you will probably like it.

<p><sub>⚠️ WIP: ss is highly experimental software and still at a very early stage, so expect bugs and missing features. Breaking changes are also likely to continue arriving, especially in the user interface, including the syntax.</sub></p>

<figure>
    <br>
    <img src="assets/ssbird.png" alt="ss language logo" width="200" />
    <br>
    <figcaption><i> The world's smartest bird, the ssbird, usually perches on the shoulder of the smartest human, but here it is alone. </i></figcaption>
</figure>

<br>

<a href="https://github.com/abap34/ss/actions/workflows/ci.yml">
    <img alt="CI" src="https://github.com/abap34/ss/actions/workflows/ci.yml/badge.svg?branch=main">
</a>
<a href="https://github.com/abap34/ss/releases">
    <img alt="Release" src="https://img.shields.io/github/v/release/abap34/ss?sort=semver">
</a>
<a href="https://github.com/abap34/homebrew-ss">
    <img alt="Homebrew tap" src="https://img.shields.io/badge/Homebrew-abap34%2Fss-FBB040?logo=homebrew">
</a>
<a href="https://marketplace.visualstudio.com/items?itemName=abap34.ss-language-support">
    <img alt="VS Code" src="https://img.shields.io/visual-studio-marketplace/v/abap34.ss-language-support?label=VS%20Code&logo=visualstudiocode">
</a>
<a href="https://github.com/abap34/ss/blob/main/LICENSE">
    <img alt="License" src="https://img.shields.io/github/license/abap34/ss">
</a>

</div>

## Why ss?

### 1. Slide Components Are Not Just Content, But Also Dependencies

A slide deck is full of components and dependencies between them: code samples
and captions, repeated notation, page furniture, generated labels, shared
theme choices, and so on. ss lets you express those components and dependencies
with ordinary programming tools such as functions, constants, and definitions.
That makes it natural to group related pieces of a deck and to define one
component in terms of another.

Everyone has, at some point, edited a program on page 1 and forgotten to update the same program on page 2.
That should have just been a global constant!


Also, just to add, "slide theme" is just a library of functions.

### 2. Document-Wide Computation Can Be Expressed Inside the Language

In many slide description languages, defining something like a page number view
inside the language itself is hard. The computation has to inspect the
whole document after pages and objects have been created.

A page number helper can be written in ss and uses that
document-wide view of the deck like this:

```ss
import std:themes/default as *

fn add_pageno!() -> Void
  foreach(
    pages(docctx()),
    (p: Page) |->  place_on!(p, text(str(page_index(p))))
  )
end

document
add_pageno!()
end

page page1
text! "This is page 1."
end

page page2
text! "This is page 2."
end
```

ss-compiler analyzes dependencies across the whole program.
This enables ss to infer that `pagenos!()` depends on the page list,
so the function is evaluated only after the pages become available.

That means document-wide behavior such as adding a table of contents or page numbers can be defined in ss itself, not
bolted on from outside the language. Yes, this is directed at you (and me), the
person who hand-wrote a ToC and forgot to update it.

### 3. Layout Should Be Precise When You Need It

Layout relationships between components can be expressed precisely as
constraints:

```text
~ program.bottom == caption.top + 10
```

Precise layout constraints let you push slide quality as far as you want. ss
also has LSP and editor support: when something overflows, it will always warn
you, and the default layout still gives you a reasonable starting point when
you do not want to specify every constraint.

### 4. Math Should Be Real LaTeX

The author works in a field that uses unusual mathematical symbols every day.
MathJax and KaTeX are wonderful, but handling missing symbols and packages can
be painful.

ss uses real local LaTeX for math rendering, so uncommon notation should not be
a problem. Use `\lightning` as much as you want.

### 5. Carefully Designed for Analysis, Extensibility, and Performance

ss is also designed with attention to properties such as termination of
the render process, ease of analysis, extensibility, and performance. (Except
when relying on external processes, ss is guaranteed to terminate!)

This design makes it possible for compilation to support maximal parallelism
and incrementality while still providing rich editor support and extensibility
inside the language itself. More unique features will continue to arrive.

## Quick Start

Create an `ss.toml` at the root of your slide project:

```toml
#:schema https://raw.githubusercontent.com/abap34/ss/main/schemas/ss-toml.schema.json

[project]
entry = "slide.ss"
asset_base_dir = "."
```

Create `slide.ss`:

```ss
import std:themes/default as *

document
vflow_doc(LayoutPolicy.center)
pagenos!()
end

page title
h1! "Hello, ss!"
end

page body
let title = head! "Why ss?"
let body = text! <<
- Components are ordinary definitions.
- Layout can be constrained when needed.
- Math is rendered with real local LaTeX.
>>

~ body.top == title.bottom - 36
end
```

Then run:

```sh
ss render --project . --output slide.pdf
```

`entry` is required. `asset_base_dir` defaults to the entry file's parent
directory when omitted.

The JSON Schema for `ss.toml` lives at `schemas/ss-toml.schema.json`. TOML
language servers such as Taplo can use it for completion and validation.

## Installation

### Homebrew

On macOS, Homebrew is the recommended install path:

```sh
brew tap abap34/ss
brew install ss
```

The Homebrew formula installs the dependencies **without** `pdflatex`.
LaTeX math rendering still needs a TeX distribution.

### Build From Source

ss has the following dependencies:

| Dependency | Purpose |
| ---------- | ------- |
| Cairo headers and library | Native PDF drawing. |
| Pango headers and library | Text shaping and layout. |
| librsvg headers and library | SVG rendering. |
| `qpdf` | PDF assembly and normalization. |
| `magick` | Raster image conversion, when raster assets need conversion or resizing. |
| `pdftocairo` | PDF/vector asset conversion, including rendered LaTeX math conversion. |
| `pdflatex` | LaTeX math rendering, when math objects are used. |

Run `ss doctor` to check the tools available in the current environment.


Install Zig 0.16 and the Cairo/Pango/librsvg development files listed above,
set up MD4C, and build:

```sh
scripts/setup-md4c.sh
zig build -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSafe install --prefix ~/.local
```

Example Homebrew command for the non-TeX dependencies:

```sh
brew install pkgconf cairo pango librsvg qpdf poppler imagemagick
```

Example apt command for the non-TeX dependencies on Ubuntu/Debian:

```sh
sudo apt-get install -y \
  pkg-config libcairo2-dev libpango1.0-dev librsvg2-dev \
  qpdf poppler-utils imagemagick
```

### Container and GitHub Actions

ss ships a Docker image with the CLI, render toolchain,
and Debian's complete `texlive-full` package installed:

```text
ghcr.io/abap34/ss-render:v0
ghcr.io/abap34/ss-render:v0.5
ghcr.io/abap34/ss-render:v0.5.3
```

Mount the current directory as `/workspace` and pass normal `ss` subcommands:

```sh
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$PWD:/workspace" \
  -w /workspace \
  ghcr.io/abap34/ss-render:v0 \
  check slides/deck.ss

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$PWD:/workspace" \
  -w /workspace \
  ghcr.io/abap34/ss-render:v0 \
  render slides/deck.ss slides/deck.pdf
```

The repository also includes a GitHub Action for rendering matching `.ss` files
to PDFs with the same Docker image:

```yaml
- uses: abap34/ss/release/actions/render@v0.5.3
  with:
    image: ghcr.io/abap34/ss-render:v0
    input: "slides/**/*.ss"
    out-dir: dist
```

## Usage

### Commands

| Command                                   | Purpose                                                          |
| ----------------------------------------- | ---------------------------------------------------------------- |
| `ss help`                                 | Show help.                                                       |
| `ss check [input.ss]`                     | Parse, load modules, and type-check a deck.                      |
| `ss dump [input.ss] [output.json]`        | Write compiler/IR metadata for tooling and debugging.            |
| `ss render [input.ss] [output]`           | Render a PDF or static HTML.                                     |
| `ss init [dir]`                           | Create an `ss.toml` and starter slide deck.                      |
| `ss doctor`                               | Check project discovery and render tool availability.            |
| `ss lsp`                                  | Run the stdio language server.                                   |
| `ss watch check [input.ss]`               | Re-run checks as project files change.                           |
| `ss watch render [input.ss] [output]`     | Re-render a PDF or static HTML as project files change.           |
| `ss cache stats`                          | Show managed render cache file count, directory count, and size. |
| `ss cache clear`                          | Clear the managed render cache under `.ss-cache/render`.         |

Examples:

```sh
ss check slide.ss
ss init slides
ss doctor --project slides
ss dump --project . --output .ss-cache/deck.json
ss render --project . --output slide.pdf
ss render --project . --format html --output slide.html
ss watch render slide.ss slide.pdf
ss cache stats
```

### Project Discovery

`ss check`, `ss dump`, and `ss render` all use the same project discovery:

- an explicit input path is treated as the entrypoint
- `--project FILE_OR_DIR` loads that `ss.toml`
- without an input path, ss searches upward from the current directory for the
  nearest `ss.toml`

`ss lsp` discovers the project from the `.ss` file opened by the editor,
searching upward from that file's directory for the nearest `ss.toml`.

`ss render` selects PDF by default. An output ending in `.html` or `.htm`
selects static HTML, and `--format pdf|html` overrides extension-based
selection.

### Render Cache

ss stores generated render artifacts under `.ss-cache/render`. Converted assets
and math images live under `artifacts/`; the renderer keeps only the latest page
generation for each deck under `decks/`.

Preview tools that render temporary snapshots can pass `--cache-id ID` to reuse
the same deck generation across changing snapshot paths.

Environment knobs:

| Variable                  | Meaning                            |
| ------------------------- | ---------------------------------- |
| `SS_RENDER_JOBS=4`        | Override the render worker count.  |
| `SS_RENDER_JOBS=off`      | Disable parallel cache generation. |
| `SS_CACHE_MAX_BYTES=512M` | Override the managed cache budget. |
| `SS_CACHE_MAX_BYTES=off`  | Disable cache pruning.             |

## Editor Support

### VS Code

The VS Code extension is published as
[ss-lang for VS Code](https://marketplace.visualstudio.com/items?itemName=abap34.ss-language-support).

The extension does not bundle `ss`. Install the CLI first.

If `.ss` files don't open as the ss language, add this to your workspace
settings:

```json
{
  "files.associations": {
    "*.ss": "ss-slide"
  }
}
```

### Helix

An example of Helix integration lives under `editor/helix/`. It wires `.ss` files to:

- the `ss` tree-sitter queries
- highlighting, folding, locals, textobjects, and rainbow queries

Copy the language entry and query files into your Helix runtime, then set the
`ss` language server command to the `ss` binary you want to use.

### Zed

A local Zed extension lives under `editor/zed/`. It wires `.ss` files to:

- the `ss` tree-sitter grammar and queries
- compiler-backed LSP through `ss lsp`

Install it from Zed with `zed: install dev extension`, then select
`editor/zed/`. Make sure `ss` is available on `PATH` for the Zed process.

### Tree-sitter

The standalone grammar package lives under `editor/tree-sitter-ss/`.

## Contributing

Contributions to ss are very welcome!

If you want to contribute, please open an issue or a pull request. For major changes, please open an issue first to discuss what you would like to change.
