# ss-lang for VS Code

VS Code language support for `ss` slide source files.

## Requirements

This extension does not bundle the `ss` CLI. Install `ss` first, then keep it on
`PATH` or set `ss.cli.path`.

See the
[installation guide](https://github.com/abap34/ss#installation)
in the project README.

## Project Files

Editor features use the same project discovery as the CLI. Put `ss.toml` at your
workspace or deck root:

```toml
[project]
entry = "slide.ss"
asset_base_dir = "."
```

`entry` is required. `asset_base_dir` defaults to the entry file's parent
directory when omitted.

Editor behavior can also be configured in `ss.toml`:

```toml
[editor.lsp]
enabled = true
debounce = 120
diagnostics = true
completion = true
hover = true
definition = true
document_symbols = true
folding_ranges = true
semantic_tokens = true
colors = true

[editor.lsp.inlay_hints]
enabled = true
arguments = true
positions = true

[editor.preview]
enabled = true
debounce = 350
open = "vscode"
reveal = true

[editor.preview.refresh]
edit = true
save = true
dependency = true

[editor.preview.render]
timeout = 30000
delete_snapshots = true
extra_args = []

[editor.preview.path]
output = ".ss-cache/vscode-preview"
snapshot = ".ss-cache/vscode-projects"

[editor.page_guide]
enabled = true
body_background = true
boundary = true
boundary_background = true
gutter_icon = true
overview_ruler = true
```

The repository ships a JSON Schema for `ss.toml` at
`schemas/ss-toml.schema.json`. TOML language servers such as Taplo can use it
for completion and validation. In a deck repository, add a Taplo rule like:

```toml
[[rule]]
include = ["**/ss.toml"]
schema.path = "schemas/ss-toml.schema.json"
```

## If `.ss` Opens As Scheme

Some VS Code setups already associate `.ss` with Scheme.

Add this to your workspace settings:

```json
{
  "files.associations": {
    "*.ss": "ss-slide"
  }
}
```

## Live Preview

Run `ss: Open Live Preview` from the command palette or the editor title button.
The preview asks the language server for `ss/projectInfo`, writes a snapshot of
open `.ss` buffers under `.ss-cache/vscode-projects/`, and refreshes a PDF with:

```sh
ss render <snapshot-entry> .ss-cache/vscode-preview/<file>.pdf --asset-base-dir <project-asset-base> --cache-id <project-entry>
```

With the default `[editor.preview].open = "vscode"`, the extension opens its own
PDF.js webview. The webview loads a loopback viewer page, and the extension
serves the generated PDF plus the bundled PDF.js assets from that local server
while the preview is open. Later renders update the registered PDF and send a
refresh message to the viewer, preserving the current page, zoom, and scroll
position where possible. Set `[editor.preview].open` to `external` in `ss.toml`
to open the generated PDF in the operating system's PDF application:

```toml
[editor.preview]
open = "external"
```
