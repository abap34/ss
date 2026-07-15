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

[editor.wysiwyg]
enabled = true
debounce = 140

[editor.wysiwyg.refresh]
dependency = true

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

## WYSIWYG Editor

Run `ss: Open WYSIWYG Editor` from the command palette or the editor title
button. The editor uses the open VS Code buffers through the language server, so
unsaved source edits are reflected after the configured debounce interval.

The editor displays the drawing scene used by the native PDF renderer together
with the compiler's page structure and anchor relations. Pages and the document
outline are available from the activity rail. Use Single page or Continuous in
the toolbar to switch page presentation. Selecting an object opens its bounds
and constraints in the bottom sheet.

Objects backed by a binding in the current page can be dragged. A normal drag
replaces the page-local position constraints with page-relative `left` and
`top` constraints. Shift-drag keeps existing horizontal and vertical anchor
relations and changes their offsets. The language server recompiles the proposed
source before returning the workspace edit.
