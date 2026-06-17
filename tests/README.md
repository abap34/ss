# Test Boundary

The tests in this directory are named `*_spec_tests.zig` because they assert
behavior that should be treated as part of the language or compiler contract.

They intentionally assert:

- surface syntax and parse diagnostics that users can rely on;
- static type acceptance rules exposed by `language/type.zig`;
- IR ownership and graph operations used across compiler stages;
- page-local layout graph semantics, constraint classification, and axis state
  reconciliation;
- smoke-check acceptance for stdlib, themes, and fixture projects through
  `zig build test`.
- focused LSP editor regressions through `tests/lsp_*_runtime_spec.mjs`, also
  wired into `zig build test`.

CLI and editor smoke tests live under `tests/smoke/`. They should stay thin:
each script verifies a user-visible workflow end to end, not every bug fix that
has ever touched that subsystem.

- `tests/smoke/project.sh` exercises explicit input, `--project`, discovered
  `ss.toml`, basic CLI errors, and dump equivalence against
  `tests/fixtures/project-basic`.
- `tests/smoke/lsp.mjs` spawns `ss lsp` and checks initialize, diagnostics,
  one global completion, hover, definition, and one ranged edit cycle.
- Language semantics, static semantics, and detailed editor regressions belong
  in `*_spec_tests.zig`, `tests/lsp_*_runtime_spec.mjs`, or a focused
  regression fixture before being considered for smoke coverage.

They intentionally avoid asserting behavior that is still an implementation
detail or underspecified:

- byte-for-byte dump JSON layout;
- allocator ownership of every AST leaf while parser ownership is still being
  clarified;
- exact generated internal page names beyond their reserved prefix and
  source-sensitive uniqueness;
- ordering of diagnostics unless that order is part of the user
  surface.
