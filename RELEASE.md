# Release Process

## Versioning

`VERSION` is the release version source. Keep these files in sync before tagging:

- `VERSION`
- `editor/vscode/package.json`
- `editor/vscode/package-lock.json`
- `tree-sitter-ss/package.json`
- `tree-sitter-ss/package-lock.json`
- `tree-sitter-ss/tree-sitter.json`
- `CHANGELOG.md`

Run:

```sh
scripts/release-preflight.sh v0.1.0
```

## CLI Distribution

For v1, use GitHub Releases as the canonical artifact location. Attach release
binaries built with:

```sh
zig build -Doptimize=ReleaseSafe -Dversion=0.1.0 -Dcommit=<commit>
```

Recommended macOS install path is a dedicated Homebrew tap, for example:

```sh
brew tap abap34/ss
brew install ss
```

Keep the tap formula pointed at the GitHub Release source tarball or binary
archive and update its `sha256` for each tag. This keeps VS Code binary
distribution simple: the extension can continue to launch the configured
`ss.cli.path` without bundling platform-specific executables.

## Editor Release

The VS Code extension is packaged from `editor/vscode` and published under the
`abap34` Marketplace publisher when `VSCE_PAT` is present. The workflow always
uploads the VSIX to the GitHub Release.

## Changelog

`scripts/changelog-section.py v0.1.0` extracts the matching changelog section for
GitHub Release notes.
