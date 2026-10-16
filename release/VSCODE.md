# Recover VS Code extension publication

To publish an existing normal release tag, run `Publish VS Code extension`
with `workflow_dispatch` on `main` and set its `tag` input to the release tag,
for example `v0.8.4`.

The workflow resolves that exact tag and builds its sources. It retains only
the current completion test and its harness during validation: these tests
allow incomplete LSP responses while requiring complete, correct candidates
within five seconds. The full Zig test suite still runs. Before building the
release binary and packaging the extension, the workflow restores both test
files to the tag and requires a clean tracked working tree.

The package keeps the tagged extension version. The workflow publishes it to
Marketplace when `VSCE_PAT` is configured and attaches the VSIX to the existing
GitHub Release. It does not move the tag or recreate the release. Inspect the
Marketplace step to distinguish successful publication from a missing-token
skip.
