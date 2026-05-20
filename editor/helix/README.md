# Helix support for `ss`

This directory contains the Helix integration for `ss`.

It configures:

- `.ss` file detection as language `ss`
- tree-sitter highlighting/folding/locals from `editor/tree-sitter-ss`
- Helix indent, textobject, tags, and rainbow queries
- compiler-backed LSP through `ss lsp`

Copy the language entry from `languages.toml` into your Helix
`languages.toml`, then copy the query files into:

```text
~/.config/helix/runtime/queries/ss/
```

After changing the tree-sitter grammar or query files, run:

```sh
hx --grammar build ss
```

Set `[language-server.ss].command` to the `ss` binary you want Helix to use.
