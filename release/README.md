# Release Process

## Versioning

`release/VERSION` is the release version source. Keep these files in sync before tagging:

- `release/VERSION`
- `editor/vscode/package.json`
- `editor/vscode/package-lock.json`
- `editor/tree-sitter-ss/package.json`
- `editor/tree-sitter-ss/package-lock.json`
- `editor/tree-sitter-ss/tree-sitter.json`
- `editor/tree-sitter-ss/src/parser.c` when generation changes embedded version metadata
- `release/CHANGELOG.md`

Run, replacing `vX.Y.Z` with the release tag:

```sh
release/tools/preflight.py vX.Y.Z
release/tools/changelog-section.py vX.Y.Z
```

Patch releases for users staying on an older release use a SemVer pre-release
tag based on the release they stay on:

```text
vX.Y.Z-patch.N
```

For example, a patch release based on `v0.7.1` is tagged as
`v0.7.1-patch.1`. The SemVer version stored in metadata is
`0.7.1-patch.1`; the leading `v` is only part of the Git tag name. SemVer
orders a pre-release below the corresponding normal release, so distribution
uses exact tags and exact Homebrew formula names for patch releases.

## Release Checklist

The release tag must point to the final `chore: prepare vX.Y.Z release`
commit. Commit implementation, test, and documentation fixes before that
commit, and keep all release metadata and generated version metadata together
in the preparation commit.

If verification finds a fix after the preparation commit, edit or reorder the
unpublished commits so the fix precedes the final preparation commit. Amend
metadata corrections into the preparation commit. Rerun the release checks on
the resulting `HEAD`, and only then create or replace the unpublished local
tag. Before tagging, verify the preparation commit's subject and metadata-only
diff. Do not rewrite published history or replace a published tag without
explicit user approval.

### Review the complete release range

Identify the previous release tag and the final implementation commit. Review
every commit and its affected files between them, even when `Unreleased`
already contains entries. Use `git log --reverse --oneline` and `git diff --stat`
for the range, then inspect the relevant patches. PR titles and automatically
generated notes are drafts, not evidence that the changelog is complete.

Account for user-visible changes to syntax, static and dynamic semantics,
stdlib APIs, removed or renamed APIs, dump JSON, CLI behavior, editor controls,
rendering, performance, build requirements, and distribution. Group related
commits into concise entries; internal cleanup and test-only changes need not
be separate entries. Review direct commits as well as merged PRs. Reconcile PR
links and contributor credits using `release/NOTES.md`.

Update the changelog section that becomes the GitHub Release notes:

```md
## [X.Y.Z] - YYYY-MM-DD
```

### Review CI and verify the release candidate

Before declaring the candidate ready, collect the latest CI results for its
implementation commit and recent failed release workflows. Batch related `gh`
reads into one read-only collection script and save run metadata and failed-job
logs under `.agent-artifacts/release-review/`, creating that directory first.
For each relevant failure, record its run URL, commit SHA, failed step, cause,
and the corresponding fix and regression result. If logs have expired, report
that limit. Investigate failed or missing CI; do not infer success from a local
focused test or a different commit's green run.

Keep version metadata in sync and run the full release preflight in the
development environment used for builds and tests, with an explicit timeout:

```sh
timeout --kill-after=10s 30m release/tools/pre-release-check.sh vX.Y.Z
release/tools/preflight.py vX.Y.Z
release/tools/changelog-section.py vX.Y.Z
```

`pre-release-check.sh` runs the metadata checks, full Zig tests, project and LSP
smoke tests, editor package checks, Homebrew formula rendering, and direct
release-binary render and dump checks. It generates verification output under
`.test-tmp/pre-release-check/<tag>/`. Save the command, commit SHA, exit status,
and log. Do not tag a release until this script passes.

The final preparation commit normally contains only metadata. That fact alone
does not justify skipping source checks: inspect the changes since the previous
release. When that range includes implementation, test, dependency, build, or
workflow changes, the full check is required.

Also read `.github/workflows/ci.yml` and the publication workflows. Run relevant
checks outside `pre-release-check.sh`, including published Zed grammar-reference
verification, bundled tree-sitter and Font Awesome metadata checks, and bundled
MD4C tests:

```sh
timeout --kill-after=10s 2m python3 tests/editor/zed/reference/spec.py
timeout --kill-after=10s 3m python3 editor/zed/tools/check-grammar.py
timeout --kill-after=10s 2m node third_party/tree-sitter-languages/tools/update.mjs --check
timeout --kill-after=10s 2m python3 third_party/fontawesome-free/tools/update-categories.py --check
timeout --kill-after=10s 8m python3 third_party/tools/md4c/test.py
```

Run these in the same development environment with an explicit timeout. Use
the workflow's Zig, Node.js, Python, and native dependencies, including Python
packages from `third_party/fontawesome-free/tools/requirements.txt`;
check both the `qpdf` executable and native libraries. Normal CI has no TeX, so
TeX-dependent tests must probe availability. Include focused browser tests when
HTML or editor interactions changed. Record which environments and checks ran,
which were skipped, and why. Development-environment success and GitHub CI
success are separate results.

The metadata-only mode is for repeating verification after a metadata correction:

```sh
timeout --kill-after=10s 15m release/tools/pre-release-check.sh --release-metadata-only vX.Y.Z
```

Use it only when the full check already passed for the same implementation
base, the saved result identifies that commit, and every subsequent change is
release metadata or generated version metadata. Compare the verified commit
with the new candidate to establish this. Any later source, fixture, test,
lockfile, build, or workflow change requires the full check again. Resolve
relevant CI failures before using this shortcut. `--base` verifies the parent;
it does not prove that tests passed. This mode still rebuilds and packages the
release, but skips Zig tests and smoke checks.

### Publish the verified commit

After development-environment verification, record the final preparation SHA
and create the local tag:

```sh
release_commit=$(git rev-parse HEAD)
git tag -a vX.Y.Z -m "ss vX.Y.Z"
```

Push and publication require explicit user approval. For a current-tip release,
push `main` first:

```sh
git push origin main
```

Wait for the `CI` workflow from `.github/workflows/ci.yml` to finish successfully
for exactly `$release_commit`, including its required platform jobs. Check
`headSha`, conclusion, and the run URL; a queued, missing, canceled, or failed
run does not satisfy this requirement. If `main` or the candidate changes,
verify the new intended release commit. Do not push `main` and the release tag
together. A tag push starts publication before the branch's CI can finish.

Only after that CI succeeds, confirm that the local tag still resolves to the
verified preparation commit, then push it within the approved release scope:

```sh
git rev-parse 'vX.Y.Z^{commit}'
git push origin vX.Y.Z
```

For a non-tip or older-tag patch release, validate the exact release commit
through a supported CI path. If the configured workflows cannot run for that
revision, resolve that validation step before publication. A newer `main` run
does not validate an older release. Do not create a PR or dispatch a workflow
without authorization.

The tag triggers Homebrew/GitHub Release and VS Code publication. Report
publication as triggered until its results have been checked. A workflow's
success can include skipped Marketplace or tap publication when credentials
are absent; inspect those steps before claiming distribution completed.

## Releasing From a Non-Tip Commit

When the release should stop at a commit that is not the current branch tip,
prepare the release metadata from that commit in an isolated worktree:

```sh
release/tools/prepare-release.py --base <commit> \
  --worktree .agent-artifacts/release-worktrees/vX.Y.Z vX.Y.Z
cd .agent-artifacts/release-worktrees/vX.Y.Z
git rev-parse HEAD^
timeout --kill-after=10s 30m release/tools/pre-release-check.sh vX.Y.Z
git tag -a vX.Y.Z -m "ss vX.Y.Z"
```

`prepare-release.py` creates `release/vX.Y.Z` by default, updates the release
metadata files, drafts the changelog section from commits since the previous
tag when `Unreleased` is empty, runs metadata checks, and creates the release
preparation commit. Confirm that `HEAD^` is the intended implementation commit
before tagging. Pass `--detached` to create a detached worktree instead of a
branch; keep that worktree until the tag is created. Run full verification in
that worktree before its first tag. For a later metadata-only correction that
meets all conditions above, include the parent-commit check when supported:

```sh
timeout --kill-after=10s 15m release/tools/pre-release-check.sh --release-metadata-only --base <commit> vX.Y.Z
```

The same approval and exact-commit CI requirements apply before pushing the tag.
After publication starts, inspect the release workflows when asked to monitor
them. Verify the GitHub Release assets, Marketplace publish, and tap update
before calling the release complete; otherwise report only the observed state.

## Releasing a Patch From an Older Tag

When a fix should be shipped to users of an older release without including the
later release train, prepare the release from that tag and cherry-pick only the
selected implementation commits:

```sh
release/tools/prepare-release.py \
  --from-tag v0.7.1 \
  --cherry-pick 1b52cb25ef9e9eee5e5b73268a12a39920dabfee \
  --worktree .agent-artifacts/release-worktrees/v0.7.1-patch.1 \
  v0.7.1-patch.1
cd .agent-artifacts/release-worktrees/v0.7.1-patch.1
git log --oneline v0.7.1..HEAD
timeout --kill-after=10s 30m release/tools/pre-release-check.sh v0.7.1-patch.1
git tag -a v0.7.1-patch.1 -m "ss v0.7.1-patch.1"
```

The expected history from the source tag to the release tag is:

```text
v0.7.1 -> selected cherry-pick commit(s) -> chore: prepare v0.7.1-patch.1 release
```

Patch releases update a versioned Homebrew formula named after the exact patch
version. Users can install that release with:

```sh
brew tap abap34/ss
brew install abap34/ss/ss@0.7.1-patch.1
ss --version
```

The VS Code Marketplace workflow is limited to normal releases, so patch
releases do not publish a Marketplace extension version automatically.

## CLI Distribution

For v1, use GitHub Releases as the canonical artifact location. The Homebrew
workflow is the canonical GitHub Release creator: it attaches a source archive
named `ss-<version>.tar.gz` and renders a tap formula from
`release/homebrew/ss.rb.in`.

To build the CLI in the development environment:

```sh
timeout --kill-after=10s 10m zig build
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

The formula builds from source with Zig and uses the MD4C sources included in
the ss source archive. This keeps VS Code binary distribution simple: the
extension can continue to launch the configured `ss.cli.path` without bundling
platform-specific executables.

The VS Code workflow waits for the GitHub Release created by the Homebrew
workflow, then uploads its artifact. It does not create the release itself.

## Editor Release

The VS Code extension is packaged from `editor/vscode` and published under the
`abap34` Marketplace publisher when `VSCE_PAT` is present. The workflow always
uploads the VSIX to the GitHub Release.

## Changelog

`release/tools/changelog-section.py vX.Y.Z` extracts the matching changelog section for
GitHub Release notes.
