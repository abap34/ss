# Resolves the tree-sitter checkouts that build.zig stages into its bundle.
#
# third_party/tree-sitter-languages/manifest.json is the single source of truth
# for which grammars exist and which commit each is pinned to. Flake inputs
# cannot be generated from a file, so instead every input is checked against the
# manifest here: a manifest bump that forgets flake.nix fails evaluation with a
# list of the offending grammars rather than silently building stale sources.
# The md4c pin gets the same guard, against scripts/setup-md4c.sh.
#
# Grammar inputs are named `tree-sitter-<language>`, matching the manifest's
# language names, so the mapping is derived rather than hand-maintained.
{ lib, inputs }:

let
  manifest = builtins.fromJSON (
    builtins.readFile ../../third_party/tree-sitter-languages/manifest.json
  );

  md4c_commit = builtins.head (
    builtins.match ''.*MD4C_COMMIT="([0-9a-f]+)".*'' (builtins.readFile ../../scripts/setup-md4c.sh)
  );

  languages =
    lib.mapAttrs' (name: source: lib.nameValuePair (lib.removePrefix "tree-sitter-" name) source)
      (
        lib.filterAttrs (name: _: lib.hasPrefix "tree-sitter-" name && name != "tree-sitter-runtime") inputs
      );

  # "<language>: manifest <commit> but flake input <rev>" for each disagreement,
  # including grammars the manifest names but flake.nix never declared.
  drift =
    lib.optional (
      inputs.tree-sitter-runtime.rev != manifest.runtime.commit
    ) "runtime: manifest ${manifest.runtime.commit} but flake input ${inputs.tree-sitter-runtime.rev}"
    ++ lib.optional (
      inputs.md4c.rev != md4c_commit
    ) "md4c: scripts/setup-md4c.sh ${md4c_commit} but flake input ${inputs.md4c.rev}"
    ++ lib.concatMap (
      language:
      let
        source = languages.${language.name} or null;
        rev = if source == null then "<missing input tree-sitter-${language.name}>" else source.rev;
      in
      lib.optional (
        rev != language.commit
      ) "${language.name}: manifest ${language.commit} but flake input ${rev}"
    ) manifest.languages;

  checked =
    if drift == [ ] then
      languages
    else
      throw ''
        flake.nix pins disagree with the repository's pinned sources:
          ${lib.concatStringsSep "\n  " drift}
        Update the flake inputs to the pinned commits, then refresh flake.lock.
      '';
in
{
  # `NAME=PATH` pairs for SS_TREE_SITTER_SOURCES, read by build.zig. Both the
  # package build and the development shell export this same value.
  environment = lib.concatStringsSep " " (
    [ "runtime=${inputs.tree-sitter-runtime}" ]
    ++ lib.mapAttrsToList (name: source: "${name}=${source}") checked
  );
}
