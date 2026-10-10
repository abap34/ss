# Release note credits

Write concise change descriptions under `Added`, `Changed`, and `Fixed`.
Include the relevant PR number in each description, such as `(#16)`.
Split a description when a contributor implemented only part of the change.
Several related PRs may share one description, such as `(#15, #17, #18)`.

`release/tools/release_notes.py` links those references, adds the human PR
authors to the corresponding descriptions, and thanks every human PR author
once. Bot PRs receive links without mentions or thanks. Existing author
mentions and acknowledgments are preserved. Human PRs without a matching
description are reported for editorial review; the tool does not guess
correspondences from similar wording.

## Collect and review locally

The collector uses paginated GitHub `GET` requests. It selects merged PRs
whose merge commits occur between the specified tag and implementation commit.
The command writes only to standard output; it does not generate or publish
anything on GitHub.

```sh
mkdir -p .ss-cache/release-notes
python3 release/tools/release_notes.py \
  --previous-tag v0.8.2 --base v0.8.3 --collect \
  > .ss-cache/release-notes/pull-requests.json
```

Write the reviewed body to `.ss-cache/release-notes/body.md`, including the
corresponding PR references, then generate the finished Markdown locally:

```sh
python3 release/tools/release_notes.py \
  --previous-tag v0.8.2 --base v0.8.3 \
  --pull-requests .ss-cache/release-notes/pull-requests.json \
  --body .ss-cache/release-notes/body.md \
  > .ss-cache/release-notes/preview.md
```

Omit `--body` to draft descriptions from commit subjects and PR titles.
Use `--pull-requests` to reuse a saved snapshot without GitHub access.

## Prepare a new release

`prepare-release.py` automatically collects PRs and credits the descriptions
in `Unreleased`, or drafts descriptions if that section is empty.
`--notes-file` supplies a reviewed body instead of `Unreleased`;
`--pull-requests` reuses a saved snapshot. Both paths receive the same inline
credits and acknowledgments. The resulting `CHANGELOG.md` section is the
complete release body, ready for review before publication.

For a patch release, PRs are selected from the original cherry-picked commit
hashes rather than all changes since the old release. The current collector
recognizes complete PR merges, squash merges, and the final commit of rebase
merges. A backport of an individual commit from inside a larger PR needs an
explicit manually reviewed attribution in its change description.

The publication workflow continues to extract the completed changelog section.
