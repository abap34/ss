# Changelog

All notable changes to `ss` are recorded here.

## [Unreleased]

## [0.1.0] - 2026-05-21

### Added

- Project contracts through `ss.toml`, shared by `ss check`, `ss dump`, `ss render`, and `ss lsp`.
- Compiler-backed stdio LSP server with diagnostics, completion, hover, definition, inlay hints, document symbols, semantic tokens, folding ranges, and color support.
- TypeScript VS Code language client that launches `ss lsp` and keeps live PDF preview in the extension.
- Standalone `tree-sitter-ss` grammar package with highlight, locals, folds, and corpus/query smoke tests.
- Helix language configuration, tree-sitter queries, and install script.
- Release workflows for validation, VSIX packaging, Marketplace publish, and GitHub Release upload.

### Changed

- Replaced `;; !root` editor discovery with `ss.toml`.
- Centralized release version metadata in `VERSION`.

### Known Limitations

- The VS Code extension does not bundle the `ss` binary in v1; configure `ss.cli.path` or put `ss` on `PATH`.
- Formatter, rename, code actions, and tree-sitter-powered VS Code runtime features are out of scope for v1.
- LSP rebuilds are full-project rebuilds.
