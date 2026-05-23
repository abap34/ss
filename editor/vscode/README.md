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
