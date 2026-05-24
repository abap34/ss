# Changelog

All notable changes to `ss` are recorded here.

## [Unreleased]

## [0.1.5] - 2026-05-24

### Added

- Added dependency-based document-wide computation so helpers such as page numbering can be expressed in ss itself.
- Added first-class function values, void-returning functions, and multiline lambda expressions.
- Added a local pre-release check script that validates release metadata, editor packages, Homebrew formula rendering, smoke tests, and the render Docker image before tagging.

### Changed

- Replaced pass execution with dependency scheduling for document computations.
- Shortened stdlib API and object class names, and updated stdlib code to use member property syntax.
- Replaced unmarked layout equality statements with `~`-marked constraint statements.
- Cleaned up builtin registry definitions and made generated policies explicit.
- Refreshed README examples, VS Code language support, LSP keyword handling, and tree-sitter grammar for the current syntax.

## [0.1.4] - 2026-05-24

### Changed

- Use the ssbird logo as the VS Code extension icon.

### Fixed

- Fixed the render Docker image smoke test so an installed `ss-render-smoke` script checks the render cache under its working directory.

## [0.1.3] - 2026-05-23

### Added

- Metadata facts for staged markers, including stdlib selector helpers for document/page markers.
- Compiler semantics regression tests outside the smoke-test suite.

### Changed

- Tightened staged component ownership, callback effects, default-argument checking, and runtime value cloning.
- Refreshed editor grammar, LSP preview/watch behavior, project path handling, and CLI diagnostics.
- Improved layout dependency solving, bounds diagnostics, render numeric handling, and render cache recovery.

### Fixed

- Rejected invalid project paths, constraints, and duplicate declarations more consistently.
- Removed hidden one-pixel object reliance for marker metadata now that metadata facts are available.

## [0.1.2] - 2026-05-22

### Added

- `ss init` for creating a new `ss.toml` project and starter slide deck.
- `ss doctor` for checking project discovery and render tool availability.

## [0.1.1] - 2026-05-21

### Added

- `ss cache stats` for inspecting the managed render cache file count, directory count, and total size.

### Changed

- `ss cache clear` now succeeds when the managed render cache does not exist.
- Documented the release checklist so version bumps, release notes, tagging, and workflow verification are kept together.

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
- Centralized release version metadata in `release/VERSION`.

### Known Limitations

- The VS Code extension does not bundle the `ss` binary in v1; configure `ss.cli.path` or put `ss` on `PATH`.
- Formatter, rename, code actions, and tree-sitter-powered VS Code runtime features are out of scope for v1.
- LSP rebuilds are full-project rebuilds.
