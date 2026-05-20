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
tools/release/preflight.py v0.1.0
```

## CLI Distribution

For v1, use GitHub Releases as the canonical artifact location. The Homebrew
workflow attaches a source archive named `ss-<version>.tar.gz` and renders a tap
formula from `packaging/homebrew/ss.rb.in`.

Release binaries can also be attached manually when needed. Build them with:

```sh
zig build -Doptimize=ReleaseSafe -Dversion=0.1.0 -Dcommit=<commit>
```

Recommended macOS install path is a dedicated Homebrew tap, for example:

```sh
brew tap abap34/ss
brew install ss
```

Set `HOMEBREW_TAP_TOKEN` with write access to `abap34/homebrew-ss` to let
`.github/workflows/publish-homebrew-tap.yml` update `Formula/ss.rb`
automatically. If the secret is absent, the workflow still uploads the rendered
formula as an artifact.

The formula builds from source with Zig and stages MD4C as a pinned Homebrew
resource. This keeps VS Code binary distribution simple: the extension can
continue to launch the configured `ss.cli.path` without bundling
platform-specific executables.

## Editor Release

The VS Code extension is packaged from `editor/vscode` and published under the
`abap34` Marketplace publisher when `VSCE_PAT` is present. The workflow always
uploads the VSIX to the GitHub Release.

## Changelog

`tools/release/changelog-section.py v0.1.0` extracts the matching changelog section for
GitHub Release notes.
