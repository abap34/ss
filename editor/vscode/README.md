# VS Code support for `ss`

This extension is a thin VS Code language client for `ss`.

Included:

- TextMate syntax highlighting
- snippets and comment configuration
- compiler-backed diagnostics, completion, hover, definition, inlay hints, document symbols, folding ranges, semantic tokens, and color decorators through `ss lsp`
- live PDF preview owned by the extension
- a sample task that runs `ss check`

The extension does not bundle an `ss` binary in v1. Set `ss.cli.path` when `ss`
is not on `PATH`.

Install the CLI from the project GitHub Release, from source with
`zig build -Doptimize=ReleaseSafe install --prefix ~/.local`, or through the
planned Homebrew tap once it is published.

## Project Files

Editor features use the same project discovery as the CLI. Put `ss.toml` at the
workspace or deck root:

```toml
[project]
entry = "slide.ss"
asset_base_dir = "."
```

`entry` is required. `asset_base_dir` defaults to the entry file's parent
directory when omitted.

The old `;; !root` marker is no longer used.

## If `.ss` Opens As Scheme

Some VS Code setups already associate `.ss` with Scheme.

Copy `settings.sample.json` to your workspace as `.vscode/settings.json`, or add:

```json
{
  "files.associations": {
    "*.ss": "ss-slide"
  }
}
```

## Local Install

```sh
cd editor/vscode
npm ci
npm run compile
```

Then run `Developer: Install Extension from Location...` and choose this
`editor/vscode` directory.

## Language Server

When an `ss` file opens, the extension starts:

```sh
ss lsp
```

The LSP server owns diagnostics and semantic editor features. Configure tracing
with:

```json
{
  "ss.lsp.trace.server": "messages"
}
```

Use `ss: Check Current File` from the command palette to save the active file
and force the language client to refresh.

## Live Preview

Run `ss: Open Live Preview` from the command palette or the editor title button.
The preview asks the language server for `ss/projectInfo`, writes a snapshot of
open `.ss` buffers under `.ss-cache/vscode-projects/`, and refreshes a PDF with:

```sh
ss render <snapshot-entry> .ss-cache/vscode-preview/<file>.pdf --asset-base-dir <project-asset-base>
```

The extension opens the preview PDF once, then updates that same file on later
renders. Set `ss.livePreview.openMode` to `external` to open the generated PDF in
the operating system's PDF application:

```json
{
  "ss.livePreview.openMode": "external"
}
```

## Packaging

```sh
npm run package
```

The Marketplace publisher is `abap34`. Release CI checks version metadata,
publishes with `VSCE_PAT` when that secret is present, and always uploads the
VSIX to the GitHub Release.
