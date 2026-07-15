# Test Boundary

The Zig tests in this directory live under subsystem and topic directories.
Leaf test files use `spec_tests.zig` names because they assert behavior that
should be treated as part of the language or compiler contract.

They intentionally assert:

- surface syntax and parse diagnostics under `tests/syntax/parser/`;
- language-level type and registry rules under `tests/language/type/` and
  `tests/language/registry/`;
- document-state ownership and graph operations under
  `tests/core/document_state/`;
- page-local layout graph semantics, constraint classification, and axis state
  reconciliation under `tests/layout/graph/`;
- rendering-IR ownership，document compilation，PDF backend behavior，and static
  HTML generation under `tests/render/ir/`，`tests/render/compile/`，
  `tests/render/pdf/`，and `tests/render/html/`;
- compiler, project, render, LSP, watch, and utility contracts under their
  matching subsystem and topic directories;
- smoke-check acceptance for stdlib, themes, and demo decks through
  `zig build test`.
- focused CLI，render，and LSP regressions through spec files under
  `tests/runtime/` subsystem directories，also wired into `zig build test`.

PDF and HTML visual parity is a local test boundary under `tests/visual/`．It
uses the same in-memory `render.Ir` for both outputs，then renders both with the
pinned Chromium and PDF.js versions．Run `zig build test-render-parity` for the
normal set and `zig build test-render-parity-full` to include structured
mathematics．These steps are intentionally outside normal CI and do not use
Poppler，ImageMagick，or TeX．

CLI and editor smoke tests live under `tests/smoke/`. They should stay thin:
each script verifies a user-visible workflow end to end, not every bug fix that
has ever touched that subsystem.

- `tests/smoke/project.sh` exercises explicit input, `--project`, discovered
  `ss.toml`, basic CLI errors, and dump equivalence against
  `tests/fixtures/project-basic`.
- `tests/smoke/lsp.mjs` spawns `ss lsp` and checks initialize, diagnostics,
  one global completion, hover, definition, and one ranged edit cycle.
- Language semantics, static semantics, and detailed runtime/editor regressions
  belong in the matching subsystem/topic directory, a subsystem directory under
  `tests/runtime/`, or a focused regression fixture before being considered for
  smoke coverage.

They intentionally avoid asserting behavior that is still an implementation
detail or underspecified:

- byte-for-byte dump JSON layout;
- allocator ownership of every AST leaf while parser ownership is still being
  clarified;
- exact generated internal page names beyond their reserved prefix and
  source-sensitive uniqueness;
- ordering of diagnostics unless that order is part of the user
  surface.
