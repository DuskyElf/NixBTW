# T3 Code built from upstream's latest stable release tag.
#
# Two nixpkgs instances meet here on purpose. The recipe is read from the
# nixpkgs tree passed as `recipeSrc`, because stable 26.05 still ships a t3code
# recipe for a 0.0.x tag (bun, electron_40) and 0.1.x needs the newer layout
# (pnpm, electron_44, the codex and resource monitor split). Every package the
# recipe calls for comes from `pkgs`, which callers set to the stable set,
# except codex: stable's is one T3 Code's model manifest distrusts, and T3 then
# quietly ignores the packaged one instead of failing (0.1.10 marks below 0.149
# broken and only trusts 0.156 and up), so callers hand in the cached codex from
# the channel they take the recipe from.
#
# That split is what keeps the daily build cheap: cache.nixos.org carries
# electron for the stable channel, while nixos-unstable-small does not build
# it. Under unstable-small an electron patch bump meant compiling Chromium from
# source on every daily update.
#
# The recipe rides the daily `nix flake update` of the unstable-small pin, while
# the packages stay on stable. A recipe that grows an argument or a package
# stable cannot supply breaks the home configuration's evaluation rather than
# the tag's hashes, and pkgs/t3code/update.sh reports it as a build
# failure with the pin in place, not as a bad tag. Revert the pin or vendor the
# recipe when that happens.
#
# The source is upstream's tag, so the three fixed-output hashes in ./lock.nix
# (repo tarball, pnpm store, cargo vendor) still move with the tag, and
# pkgs/t3code/update.sh rewrites them during the daily update.
{
  # The package set every dependency is taken from. Callers pass the stable
  # instance, the same one home-manager builds the app with.
  pkgs,
  # The nixpkgs tree carrying the t3code recipe, e.g. `pkgs-unstable-small.path`.
  # Only the recipe files are read from it; nothing it packages is used.
  recipeSrc,
  # Codex for the codex driver, required rather than defaulted to `pkgs.codex`:
  # the stable default is one the model manifest marks broken, and the app would
  # build and install happily while ignoring it.
  codex,
  lockPath ? ./lock.nix,
}:
let
  inherit (pkgs) lib;
  lock = import lockPath;
  inherit (lock) tag rev;
  version = lib.removePrefix "v" tag;

  src = pkgs.fetchFromGitHub {
    owner = "pingdotgg";
    repo = "t3code";
    inherit rev;
    hash = lock.srcHash;
  };

  base = pkgs.callPackage (recipeSrc + "/pkgs/by-name/t3/t3code/package.nix") { };

  unwrapped = base.unwrapped.overrideAttrs (old: {
    inherit version src;
    pnpmDeps = old.pnpmDeps.override {
      inherit src version;
      hash = lock.pnpmDepsHash;
    };
  });

  # Built from the same src, so its version and vendor hash track the stable tag too.
  resourceMonitor = base.resourceMonitor.overrideAttrs (old: {
    inherit version src;
    cargoHash = lock.cargoHash;
  });
in
base.override {
  inherit codex;
  t3code-unwrapped = unwrapped;
  t3code-resource-monitor = resourceMonitor;
}
