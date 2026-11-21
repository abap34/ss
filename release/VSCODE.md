# Recover VS Code extension publication

To publish an existing normal release tag, run `Publish VS Code extension`
with `workflow_dispatch` on `main` and set its `tag` input to the release tag,
for example `v0.8.4`.

The workflow resolves that exact tag, checks its release metadata and grammar,
then builds and verifies the VSIX from the tagged sources. Zig and LSP checks
run in the regular CI workflow. Confirm that CI passed for the exact release
commit before publishing, following the release checklist in `release/README.md`.

The package keeps the tagged extension version. The workflow publishes it to
Marketplace when `VSCE_PAT` is configured and attaches the VSIX to the existing
GitHub Release. It does not move the tag or recreate the release. Inspect the
Marketplace step to distinguish successful publication from a missing-token
skip.
