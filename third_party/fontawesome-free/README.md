# Font Awesome Free

This directory contains the SVG sprites and license from Font Awesome Free
7.2.0. The files were copied without modification from the official release at
`https://github.com/FortAwesome/Font-Awesome/releases/tag/7.2.0`.

The repository keeps `sprites/{solid,regular,brands}.svg`, the generated
`metadata/categories.zig`, and `LICENSE.txt`. The sprites and category metadata
are embedded in the `ss` executable, and `ss` extracts requested icons from
them at render time.

`embed.zig` derives the bundled version from the sprite header. The editor
catalog derives icon names and counts by enumerating the embedded `symbol`
elements, so an update does not require copied version, count, or featured-icon
constants.

`metadata/categories.zig` is generated from the same release's official
`metadata/categories.yml`. The generator validates the upstream schema and
keeps only names present in the bundled Free sprites. It provides the editor's
finer semantic filters without duplicating icon geometry or depending on a
network request during a normal build or at runtime.

CI installs PyYAML and runs
`python scripts/update-fontawesome-categories.py --check`. The script derives
the version from all three sprites, downloads the official YAML for that exact
version, regenerates the Zig catalog, and verifies that it matches the checked-in
file. Run the script without `--check` when refreshing the dependency.
