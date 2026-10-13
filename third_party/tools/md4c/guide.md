# Maintaining the MD4C fork

`third_party/md4c/` contains the complete MD4C repository, managed as a
Git subtree with squashed imports.
The initial import preserves the previously bundled 0.5.3 parser sources.
The fork is <https://github.com/abap34/md4c>, on branch `master`.

The ss maintenance files live under `third_party/tools/md4c/`.
The manifest is `third_party/tools/md4c/manifest.json`. Its top-level `upstream`,
`version`, `tag`, and `commit` identify the upstream baseline of the fork.
`fork.imported_commit` identifies the last fork commit imported by subtree.
The checksums cover the license and the two parser files compiled by ss,
including any local edits recorded in ss. Local edits do not change the last
imported commit. The original vendor description is preserved verbatim in
`third_party/tools/md4c/origin.md` as a record of the pre-subtree snapshot.

Keep ss-specific metadata, tools, and documentation outside the subtree so
that they are not exported to the fork. Keep imported upstream files,
including its README and tests, inside the subtree.

## Editing in ss

Edit the parser under `third_party/md4c/src/` and add parser regressions under
`third_party/md4c/test/`. Add ss integration tests under `tests/`.
Keep MD4C changes and ss integration changes in separate commits where
practical. Refresh the checksums after editing the parser:

```sh
python3 third_party/tools/md4c/metadata.py --refresh
```

Run the focused source-packaging check and the upstream MD4C tests from the
repository root:

```sh
python3 tests/release/release_tools_spec.py
python3 third_party/tools/md4c/test.py
```

The source-archive check uses committed `HEAD`, so run it again after
committing changes that affect the archive contents.
The MD4C runner requires CMake and a C compiler. It creates its build directory
under `.ss-cache/md4c/`, runs every upstream suite and the pathological-input
tests, and is also registered in ss CI.

## Importing a fork update

Git remotes are local configuration. Each new clone needs this once:

```sh
git remote add md4c-fork https://github.com/abap34/md4c.git
```

Fetch the fork, review the candidate commit, and merge its full object ID:

```sh
git fetch --no-tags md4c-fork master
git subtree merge --prefix=third_party/md4c --squash <reviewed-fork-commit>
python3 third_party/tools/md4c/metadata.py --refresh
```

Commit the refreshed ss manifest after resolving conflicts and testing.
Update the upstream baseline fields when the fork incorporates a new upstream
release. `--refresh` does not infer an upstream release from a custom fork.
Normal builds compile the bundled files directly and do not fetch the fork.

## Exporting changes to the fork

Commit MD4C changes in ss first, then extract only the subtree history:

```sh
git fetch --no-tags md4c-fork <last-imported-fork-commit>
git subtree split --prefix=third_party/md4c --branch=md4c-export
git log --oneline md4c-export
git diff <last-imported-fork-commit> md4c-export
```

The export branch must not already exist. The initial unchanged subtree splits
to the exact imported fork commit. Fetching that commit makes splitting work
in a fresh clone, because squash imports retain its tree and object ID but do
not retain the original upstream history.

After explicit approval to push, publish the reviewed export branch to the
fork's `master` branch. Integrate newer fork changes first if the push would
not be a fast-forward. Upstream updates follow the path from mity/md4c to the
fork and then to ss.
