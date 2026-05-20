# Helix support for `ss`

This directory contains the Helix integration for `ss`.

It configures:

- `.ss` file detection as language `ss`
- tree-sitter highlighting/folding/locals from `tree-sitter-ss`
- Helix indent, textobject, tags, and rainbow queries
- compiler-backed LSP through `ss lsp`

Install or refresh the local Helix config from the repository root:

```sh
scripts/install-helix.sh
```

The installer writes a managed block into `~/.config/helix/languages.toml`,
copies query files into `~/.config/helix/runtime/queries/ss/`, and runs:

```sh
hx --grammar build ss
```

It does not overwrite the rest of your Helix config. Re-run it after changing
the tree-sitter grammar or query files.

Use `SS_BIN=/path/to/ss scripts/install-helix.sh` when the desired `ss` binary is
not the one found on `PATH`.
