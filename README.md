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

In ss, this kind of computation can be written naturally:

```ss
import std:themes/default

fn add_pageno() -> void
  foreach(
    pages(docctx()),
    (page: page) |->
      new(page, str(page_index(page)), "body", "text")
  )
end

page page1
  text("This is page 1.")
end

document
  add_pageno()
end
```

ss analyzes dependencies across the whole program.
This enables ss to infer that `add_pageno()` depends on the page list,
so the function is evaluated only after the pages become available.

That means document-wide behavior suchas adding a table of contents or page numbers can be defined in ss itself, not
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

### 5. Design Goals

ss is also designed with careful attention to properties such as termination of
the render process, ease of analysis, extensibility, and performance. (Except
when relying on external processes, ss is guaranteed to terminate!)

This design makes it possible for compilation to support maximal parallelism
and incrementality while still providing rich editor support and extensibility
inside the language itself. More unique features will continue to arrive.

## Quick Start

Create an `ss.toml` at the root of your slide project:

```toml
[project]
entry = "slide.ss"
asset_base_dir = "."
```

Create `slide.ss`:

```text
import std:themes/default

document
pagenos()
end

page title
cover(
  "Hello, ss",
  "Write slides as programs.",
  "v0.1.2"
)
end

page body
let title = head "Why ss?"
let body = text <<
- Components are ordinary definitions.
- Layout can be constrained when needed.
- Math is rendered with real local LaTeX.
>>

~ body.top == title.bottom - 32
end
```

Then run:

```sh
ss render --project . --output deck.pdf
```

`entry` is required. `asset_base_dir` defaults to the entry file's parent
directory when omitted.

## Installation

### Homebrew

On macOS, Homebrew is the recommended install path:

```sh
brew tap abap34/ss
brew install ss
```

The formula builds ss from the GitHub Release source archive, installs the CLI,
and pulls the native rendering dependencies. LaTeX math rendering still needs a
TeX distribution such as MacTeX or BasicTeX.

### GitHub Release

GitHub Releases contain the source archive and VS Code VSIX:

- source archive: <https://github.com/abap34/ss/releases/latest>
- VSIX: <https://github.com/abap34/ss/releases/latest>

The VS Code extension does not bundle the `ss` CLI. Install the CLI first, then
keep `ss` on `PATH` or set the extension's `ss.cli.path` setting.

### Build From Source

Install Zig 0.16 and the native PDF dependencies, then build:

```sh
scripts/setup-md4c.sh
zig build -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseSafe install --prefix ~/.local
```

Useful macOS packages:

```sh
brew install zig pkgconf cairo pango librsvg qpdf poppler imagemagick
```

Useful Ubuntu/Debian packages:

```sh
sudo apt-get install -y \
  pkg-config libcairo2-dev libpango1.0-dev librsvg2-dev \
  qpdf poppler-utils imagemagick
```

Install a TeX distribution when you render LaTeX math.

### Container and GitHub Actions

For CI and GitHub Pages publishing, ss also ships a render image:

```text
ghcr.io/abap34/ss-render:v0
ghcr.io/abap34/ss-render:v0.1
ghcr.io/abap34/ss-render:v0.1.2
```

The repository includes a GitHub Action for rendering `.ss` files to PDFs and
uploading a Pages artifact:

```yaml
- uses: abap34/ss/release/actions/render-pages@v0.1.2
  with:
    image: ghcr.io/abap34/ss-render:v0
    input: "slides/**/*.ss"
    title: "Slides"
```

Use the CLI or Homebrew for local authoring; use the render image for automated
publishing.

## Usage

### Commands

| Command                                   | Purpose                                                          |
| ----------------------------------------- | ---------------------------------------------------------------- |
| `ss help`                                 | Show help.                                                       |
| `ss check [input.ss]`                     | Parse, load modules, and type-check a deck.                      |
| `ss dump [input.ss] [output.json]`        | Write compiler/IR metadata for tooling and debugging.            |
| `ss render [input.ss] [output.pdf]`       | Render a PDF.                                                    |
| `ss init [dir]`                           | Create an `ss.toml` and starter slide deck.                      |
| `ss doctor`                               | Check project discovery and render tool availability.            |
| `ss lsp`                                  | Run the stdio language server.                                   |
| `ss watch check [input.ss]`               | Re-run checks as project files change.                           |
| `ss watch render [input.ss] [output.pdf]` | Re-render a PDF as project files change.                         |
| `ss cache stats`                          | Show managed render cache file count, directory count, and size. |
| `ss cache clear`                          | Clear the managed render cache under `.ss-cache/render`.         |

Examples:

```sh
ss check slide.ss
ss init slides
ss doctor --project slides
ss dump --project . --output .ss-cache/deck.json
ss render --project . --output .ss-cache/deck.pdf
ss watch render slide.ss .ss-cache/deck.pdf
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

### Render Cache

ss stores generated render artifacts under `.ss-cache/render` so repeated
renders can reuse generated documents, math images, and converted assets.

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

### Tree-sitter

The standalone grammar package lives under `editor/tree-sitter-ss/`.

## Contributing

Contributions to ss are very welcome!

If you want to contribute, please open an issue or a pull request. For major changes, please open an issue first to discuss what you would like to change.
