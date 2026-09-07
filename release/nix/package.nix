{
  inputs,
  pkgs,
  self,
  systems,
}:

let
  lib = pkgs.lib;
  version = lib.removeSuffix "\n" (builtins.readFile ../VERSION);
  treeSitter = import ./sources.nix {
    inherit inputs;
    inherit lib;
  };
  # Environment the ss binary needs at runtime. The wrapped program and the
  # development shell (via passthru) both consume this single definition.
  runtimeEnv = {
    FONTCONFIG_FILE = "${pkgs.fontconfig.out}/etc/fonts/fonts.conf";
    GDK_PIXBUF_MODULE_FILE = "${pkgs.gdk-pixbuf.out}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache";
  };
in
pkgs.stdenv.mkDerivation {
  pname = "ss";
  inherit version;
  src = self;

  nativeBuildInputs = with pkgs; [
    makeWrapper
    pkg-config
    zig
  ];

  buildInputs = with pkgs; [
    cairo
    fontconfig
    gdk-pixbuf
    harfbuzz
    pango
    qpdf
    librsvg
  ];

  postPatch = ''
    mkdir -p .ss-cache/nix/tree-sitter-sources
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: source: ''ln -s ${source} ".ss-cache/nix/tree-sitter-sources/${name}"''
      ) treeSitter.sources
    )}
  '';

  # `zig build install` both compiles and installs, so there is no separate
  # build phase. The grammar checkouts come from flake inputs, so `zig build`
  # stages its tree-sitter bundle without needing network access.
  dontBuild = true;

  preInstall = ''
    export HOME="$TMPDIR/ss-home"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
  '';

  # `-Dversion` is only pinned for clean checkouts; a dirty tree keeps
  # build.zig's own `<version>-dev` default so the suffix policy stays in
  # build.zig.
  installPhase = ''
    runHook preInstall
    zig build \
      -Doptimize=ReleaseSafe \
      ${lib.optionalString (self ? rev) "-Dversion=${version}"} \
      -Dcommit=${self.shortRev or self.dirtyShortRev or "unknown"} \
      install --prefix "$out"
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/ss" --version
    runHook postInstallCheck
  '';

  postFixup = ''
    wrapProgram "$out/bin/ss" ${
      lib.concatStringsSep " " (
        lib.mapAttrsToList (name: value: ''--set-default ${name} "${value}"'') runtimeEnv
      )
    }
  '';

  passthru = {
    treeSitterSources = treeSitter.sources;
    inherit runtimeEnv;
  };

  meta = with pkgs.lib; {
    description = "Slide description language and CLI";
    homepage = "https://github.com/abap34/ss";
    license = licenses.asl20;
    mainProgram = "ss";
    platforms = systems;
  };
}
