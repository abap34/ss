# Test Boundary

The tests in this directory are named `*_spec_tests.zig` because they assert
behavior that should be treated as part of the language or compiler contract.

They intentionally assert:

- surface syntax and parse diagnostics that users can rely on;
- static type acceptance rules exposed by `language/type.zig`;
- IR ownership and graph operations used across compiler stages;
- page-local layout graph semantics, constraint classification, and axis state
  reconciliation;
- smoke-check acceptance for stdlib, themes, and demo decks through
  `zig build test`.

They intentionally avoid asserting behavior that is still an implementation
detail or underspecified:

- byte-for-byte dump JSON layout;
- allocator ownership of every AST leaf while parser ownership is still being
  clarified;
- exact generated internal page names beyond their reserved prefix and
  source-sensitive uniqueness;
- ordering of diagnostics or metadata unless that order is part of the user
  surface.

