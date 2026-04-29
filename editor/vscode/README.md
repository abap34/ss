# VS Code support for `ss`

This directory contains a minimal VS Code language package for `ss`.

Included:

- syntax highlighting
- comment configuration for `;;`
- snippets
- a sample task that runs `ss check-file` and surfaces diagnostics
- inlay hints for argument names and solved width/height

## If `.ss` opens as Scheme

Some VS Code setups already associate `.ss` with Scheme.

Copy [settings.sample.json](/Users/yuchi/Desktop/ss/editor/vscode/settings.sample.json) to your workspace as `.vscode/settings.json`, or add:

```json
{
  "files.associations": {
    "*.ss": "ss-slide"
  }
}
```

## Local install

1. Open this folder in VS Code.
2. Run `Developer: Install Extension from Location...`
3. Choose this `editor/vscode` directory.

## Diagnostics task

Copy `tasks.sample.json` to `.vscode/tasks.json` in your workspace if you want a simple save/check task.

The task expects this command to work:

```sh
zig build run -- check-file path/to/file.ss
```

The CLI emits diagnostics in:

```text
/abs/path/file.ss:12:3: error: unknown function: foo
```

so the task can attach them to the current file.

## Inlay hints

The extension asks the local CLI for editor metadata with:

```sh
zig build run -- editor-info-file path/to/file.ss
```

This currently shows:

- parameter-name style hints
- solved `width×height` hints

The hints refresh while editing with a short debounce, and also refresh immediately on save.

It works only when the file is opened inside the `ss` workspace, because the extension runs `zig build` from the workspace root.

## Debugging

If hints do not appear, open `View: Output` and select `ss-slide` in the output-channel picker.

The extension logs:

- the `zig build run -- editor-info-file ...` command
- the working directory
- stderr from the CLI
- JSON parse failures
- the final hint count
