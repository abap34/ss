# VS Code support for `ss`

This directory contains a minimal VS Code language package for `ss`.

Included:

- syntax highlighting
- comment configuration for `;;`
- snippets
- editor diagnostics for errors and warnings from `ss check`
- a live PDF preview command
- a sample task that runs `ss check`
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

## Diagnostics

The extension runs:

```sh
zig build run -- check path/to/file.ss
```

and publishes both `ERROR:` and `WARNING:` output as VS Code diagnostics. It checks the current buffer through a temporary snapshot next to the source file, so unsaved edits are reflected while relative assets and local themes still resolve from the source directory.

Use `ss: Check Current File` from the command palette to force a check.

## Live preview

Run `ss: Open Live Preview` from the command palette or the editor title button. The preview renders the current buffer with:

```sh
zig build run -- render path/to/file.ss .ss-cache/vscode-preview/<file>.pdf
```

It refreshes the generated PDF after edits with a short debounce. The extension opens the preview PDF once, then updates that same file on later renders. By default the extension opens that PDF through VS Code's normal `vscode.open` command, so rendering is handled by the user's installed PDF support instead of a custom webview.

Set `ss.livePreview.openMode` to `external` to open the generated PDF in the operating system's PDF application instead:

```json
{
  "ss.livePreview.openMode": "external"
}
```

## Diagnostics task

Copy `tasks.sample.json` to `.vscode/tasks.json` in your workspace if you want a simple save/check task.

The task expects this command to work:

```sh
zig build run -- check path/to/file.ss
```

The current CLI emits diagnostics in:

```text
ERROR: /abs/path/file.ss:12:3: unknown function: foo
WARNING: /abs/path/file.ss:13:3: custom warning
```

so the task can attach them to the current file.

## Inlay hints

The extension asks the local CLI for IR JSON with:

```sh
zig build run -- dump path/to/file.ss
```

This currently shows:

- parameter-name style hints
- solved `width×height` hints

The hints refresh while editing with a short debounce, and also refresh immediately on save.

It works only when the file is opened inside the `ss` workspace, because the extension runs `zig build` from the workspace root.

## Debugging

If hints do not appear, open `View: Output` and select `ss-slide` in the output-channel picker.

The extension logs:

- the `zig build run -- dump ...` command
- the `zig build run -- check ...` command
- the `zig build run -- render ...` command
- the working directory
- stderr from the CLI
- JSON parse failures
- the final hint count
