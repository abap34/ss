# Changelog

All notable changes to `ss` are recorded here.

## [Unreleased]

## [0.4.2] - 2026-06-10

### Added

- Added PDF link annotations for Markdown links, including URI links and
  internal destinations from object `link_id` properties.

### Changed

- Moved remaining Zig regression tests out of `src/` and into `tests/`.

## [0.4.1] - 2026-06-09

### Changed

- Installed stdlib `.ss` sources under `share/ss/stdlib` so editor features can
  open stdlib definitions from installed binaries.

### Fixed

- Improved the bare-name parse diagnostic so it points at the full identifier
  and explains how to call or place the value.
- Fixed LSP go-to-definition for stdlib functions such as `cover!` when the
  language server is started outside the `ss` repository.

## [0.4.0] - 2026-06-09

### Added

- Added explicit object placement APIs with `place_on!` and `place!`, while
  making `new` and `group` generate objects without placing them.
- Added `fn/!` syntax for defining paired generating and placing functions.
- Added unplaced object warnings across `check`, `dump`, `render`, and LSP
  diagnostics, with `let _ = ...` as an explicit discard form.

### Changed

- Refactored stdlib components and themes to expose paired generating and
  placing functions through `fn/!`.
- Updated demos, fixtures, starter templates, tree-sitter grammar, Helix
  queries, and VS Code grammar for `!`-marked placing calls.

### Fixed

- Fixed LSP go-to-definition for `!`-marked functions across imported files and
  stdlib modules.

## [0.3.1] - 2026-06-08

### Changed

- Resolved enum cases during static analysis so enum values are checked before
  elaboration and dump output carries the resolved case information.
- Moved value-domain contract checks into elaboration, keeping runtime value
  validation at the stage boundary.
- Preserved document block source order during parsing, source dumps, and
  document evaluation.
- Validated page-only primitive use through primitive descriptors.
- Refreshed README guidance for the current command surface.

## [0.3.0] - 2026-06-05

### Added

- Added math alignment controls for individual objects and document-wide
  defaults.

### Changed

- Simplified static type handling around a unified `Type` model, enum values,
  optional values, and typed object properties.
- Removed the standalone render smoke test and its GitHub Actions workflow.
- Clarified README installation dependency guidance.

## [0.2.0] - 2026-06-01

### Added

- Added object class annotation coverage for ordinary values, selections,
  default arguments, and unknown type diagnostics.

### Changed

- Renamed internal and dump value-kind terminology from semantic sort to value
  tag.
- Removed the residual `Code`, `Fragment`, and `List` type/value constructs
  from the core type system and elaboration pipeline.

### Fixed

- Fixed enlarged text layout metrics so scaled text contributes its actual
  bounds during layout.

## [0.1.10] - 2026-06-01

### Changed

- Simplified the default theme and increased the default vertical spacing used
  by flow, body, code, math, figures, and framed components.
- Centered Markdown display math blocks and made their layout and rendering use
  the same font-size-based height target.

### Fixed

- Accounted for chrome padding when computing group bounds.
- Clipped rendered PDF object contents to their frames.
- Preserved code block indentation and aligned code block drawing with its
  measured frame.
- Fixed Markdown table block placement so header rows are not clipped and
  following paragraphs start below the table.

## [0.1.9] - 2026-05-31

### Changed

- Switched surface type notation to uppercase constructors, including parser
  acceptance, type formatting labels, stdlib signatures, fixtures, tests, and
  README examples.
- Reserved grammar keywords as invalid identifiers in the surface parser and
  added a syntax regression test for the restriction.

## [0.1.8] - 2026-05-29

### Changed

- Simplified the native PDF backend dependency setup by using the bundled
  Cairo/Pango/librsvg shim package configuration.

### Fixed

- Preserved imported source locations in diagnostics so errors from imported
  files point back to their original source spans.

## [0.1.7] - 2026-05-28

### Changed

- Made the render Docker image expose the normal `ss` CLI directly.
- Installed Debian's complete `texlive-full` package in the render Docker
  image.
- Removed the Docker-specific batch renderer and the generated `index.html` and
  `manifest.json` files.

## [0.1.6] - 2026-05-24

### Changed

- Scheduled document statements independently so document-level computations can be evaluated without relying on source order.
- Refreshed README release and usage notes.

### Fixed

- Fixed native PDF emoji spacing so emoji glyphs no longer overlap the following text in paragraphs, tables, or code blocks.
- Fixed Font Awesome icon runs so parsed `fa` sources render as SVG-backed icons instead of fallback placeholder text.

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
