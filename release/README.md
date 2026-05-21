# Release Process

## Versioning

`release/VERSION` is the release version source. Keep these files in sync before tagging:

- `release/VERSION`
- `editor/vscode/package.json`
- `editor/vscode/package-lock.json`
- `editor/tree-sitter-ss/package.json`
- `editor/tree-sitter-ss/package-lock.json`
- `editor/tree-sitter-ss/tree-sitter.json`
- `release/CHANGELOG.md`

Run:

```sh
release/tools/preflight.py v0.1.0
```

## CLI Distribution

For v1, use GitHub Releases as the canonical artifact location. The Homebrew
workflow is the canonical GitHub Release creator: it attaches a source archive
named `ss-<version>.tar.gz` and renders a tap formula from
`release/homebrew/ss.rb.in`.

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

The render image and VS Code workflows wait for the GitHub Release created by
the Homebrew workflow, then update notes or upload artifacts. They do not create
the release themselves.

## Editor Release

The VS Code extension is packaged from `editor/vscode` and published under the
`abap34` Marketplace publisher when `VSCE_PAT` is present. The workflow always
uploads the VSIX to the GitHub Release.

## Changelog

`release/tools/changelog-section.py v0.1.0` extracts the matching changelog section for
GitHub Release notes.
