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

Run, replacing `vX.Y.Z` with the release tag:

```sh
release/tools/preflight.py vX.Y.Z
release/tools/changelog-section.py vX.Y.Z
```

## Release Checklist

Before tagging, update the changelog section that becomes the GitHub Release
notes:

```md
## [X.Y.Z] - YYYY-MM-DD
```

Then keep all version metadata in sync and run the release preflight:

```sh
release/tools/pre-release-check.sh vX.Y.Z
release/tools/preflight.py vX.Y.Z
release/tools/changelog-section.py vX.Y.Z
```

`pre-release-check.sh` runs the metadata checks, Zig tests, project and LSP
smoke tests, editor package checks, Homebrew formula rendering, and the render
Docker image build with one direct CLI render check. Do not tag a release until
this script passes locally.

When the release preparation commit changes only release metadata and generated
version metadata, use the faster guarded path:

```sh
release/tools/pre-release-check.sh --release-metadata-only vX.Y.Z
```

This mode verifies that `HEAD` only touches the release metadata files, then
skips the Zig tests and smoke checks. It still checks release metadata, builds
the release binary, checks `ss --version`, validates tree-sitter and VS Code
packaging, renders the Homebrew formula, and runs Docker checks unless
`--skip-docker` is also passed.

After local and CI validation pass, create and push the tag:

```sh
git tag -a vX.Y.Z -m "ss vX.Y.Z"
git push origin vX.Y.Z
```

Watch the release workflows:

```sh
gh run list --repo abap34/ss --limit 10
gh release view vX.Y.Z --repo abap34/ss
```

Verify the GitHub Release assets, VS Code Marketplace publish, render image,
and Homebrew tap update before considering the release complete.

## CLI Distribution

For v1, use GitHub Releases as the canonical artifact location. The Homebrew
workflow is the canonical GitHub Release creator: it attaches a source archive
named `ss-<version>.tar.gz` and renders a tap formula from
`release/homebrew/ss.rb.in`.

Release binaries can also be attached manually when needed. Build them with:

```sh
zig build -Doptimize=ReleaseSafe -Dversion=<version> -Dcommit=<commit>
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

`release/tools/changelog-section.py vX.Y.Z` extracts the matching changelog section for
GitHub Release notes.
