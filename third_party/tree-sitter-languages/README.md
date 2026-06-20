# Bundled tree-sitter languages

These pinned tree-sitter languages let `ss` highlight common code blocks
without per-project parser libraries.

The repository keeps lightweight highlight queries, upstream licenses, and the
manifest below. Generated parser C sources are materialized under
`.zig-cache/tree-sitter-languages` during the build so they do not inflate git
history.

Run this command to refresh tracked queries and materialize generated parser
sources from the pinned commits:

```sh
node scripts/update-tree-sitter-languages.mjs
```

Run this command to advance every bundled parser to the current upstream HEAD:

```sh
node scripts/update-tree-sitter-languages.mjs --latest
```

The scheduled GitHub Actions workflow runs the `--latest` form and opens a pull
request when upstream commits change tracked queries or licenses.

All listed parsers are MIT licensed. Each language directory keeps the upstream
`LICENSE` file.

Parsers are generated from the listed upstream commits with tree-sitter CLI
0.25.10 and kept compatible with tree-sitter language ABI 15.

Default highlighting is enabled for these code block language names:
`ss`, `bash`, `sh`, `shell`, `c`, `cpp`, `c++`, `cc`, `css`, `go`, `golang`, `html`, `java`, `javascript`, `js`, `json`, `julia`, `jl`, `python`, `py`, `rust`, `rs`, `toml`, `typescript`, `ts`, `tsx`, `yaml`, `yml`, `zig`.

| Language | Upstream | Commit |
| --- | --- | --- |
| Bash | https://github.com/tree-sitter/tree-sitter-bash | a06c2e4415e9bc0346c6b86d401879ffb44058f7 |
| C | https://github.com/tree-sitter/tree-sitter-c | b780e47fc780ddc8da13afa35a3f4ed5c157823d |
| C++ | https://github.com/tree-sitter/tree-sitter-cpp | 8b5b49eb196bec7040441bee33b2c9a4838d6967 |
| CSS | https://github.com/tree-sitter/tree-sitter-css | dda5cfc5722c429eaba1c910ca32c2c0c5bb1a3f |
| Go | https://github.com/tree-sitter/tree-sitter-go | 2346a3ab1bb3857b48b29d779a1ef9799a248cd7 |
| HTML | https://github.com/tree-sitter/tree-sitter-html | 73a3947324f6efddf9e17c0ea58d454843590cc0 |
| Java | https://github.com/tree-sitter/tree-sitter-java | e10607b45ff745f5f876bfa3e94fbcc6b44bdc11 |
| JavaScript | https://github.com/tree-sitter/tree-sitter-javascript | 58404d8cf191d69f2674a8fd507bd5776f46cb11 |
| JSON | https://github.com/tree-sitter/tree-sitter-json | 001c28d7a29832b06b0e831ec77845553c89b56d |
| Julia | https://github.com/tree-sitter/tree-sitter-julia | e0f9dcd180fdcfcfa8d79a3531e11d99e79321d3 |
| Python | https://github.com/tree-sitter/tree-sitter-python | 26855eabccb19c6abf499fbc5b8dc7cc9ab8bc64 |
| Rust | https://github.com/tree-sitter/tree-sitter-rust | 77a3747266f4d621d0757825e6b11edcbf991ca5 |
| TOML | https://github.com/tree-sitter-grammars/tree-sitter-toml | 64b56832c2cffe41758f28e05c756a3a98d16f41 |
| TypeScript | https://github.com/tree-sitter/tree-sitter-typescript | 75b3874edb2dc714fb1fd77a32013d0f8699989f |
| YAML | https://github.com/tree-sitter-grammars/tree-sitter-yaml | a1c4812a73ec5e089de8e441fdea3a921e8d5079 |
| Zig | https://github.com/tree-sitter-grammars/tree-sitter-zig | 6479aa13f32f701c383083d8b28360ebd682fb7d |
