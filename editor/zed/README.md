# Zed support for `ss`

This directory contains a local Zed extension for `ss`.

It configures:

- `.ss` file detection as language `ss`
- tree-sitter highlighting, outline, bracket matching, and indentation
- compiler-backed LSP through `ss lsp`

Install it in Zed with `zed: install dev extension`, selecting this directory.
The language server command is resolved from the worktree `PATH`; install the
`ss` CLI first or make sure the intended binary is available as `ss`.
