# T3 Code built from the tip of pingdotgg/t3code main.
#
# nixpkgs ships the newest tagged release, so its recipe is reused here with the
# source swapped for a commit. A new commit moves three fixed-output hashes: the
# repo tarball, the pnpm store, and the resource monitor's cargo vendor tree.
# They live in ./t3code-main.lock.nix, which scripts/update-t3code-main.sh
# rewrites during the daily flake auto-update. `baseVersion` is cosmetic (it
# lands in `t3 --version` and the store path); bump it when upstream cuts a new
# minor, nothing breaks if you don't.
#
# The package is built twice per bump: once by the update script to validate the
# commit, once by the home-manager switch (a cache hit by then).
{
  pkgs,
  lockPath ? ./t3code-main.lock.nix,
}:
let
  inherit (pkgs) lib;
  lock = import lockPath;
  inherit (lock) rev;
  version = "0.1.10-main.${builtins.substring 0 7 rev}";

  src = pkgs.fetchFromGitHub {
    owner = "pingdotgg";
    repo = "t3code";
    inherit rev;
    hash = lock.srcHash;
  };

  # nixos-unstable-small at d63e5b96ca17 carries codex 0.167.0 without the
  # system-library inputs that nixpkgs 16b463698a added. codex replaces its
  # cargoDeps with overrideAttrs, which drops the default crate overrides, so
  # aws-lc-sys sees AWS_LC_SYS_USE_SYSTEM=1 and no system AWS-LC and fails the
  # build. Supply the missing inputs here; becomes a no-op once the pin ships
  # the fix. Drop this then.
  codex = pkgs.codex.overrideAttrs (
    old:
    lib.optionalAttrs (!lib.any (p: (p.pname or "") == "aws-lc") old.buildInputs) {
      buildInputs =
        old.buildInputs
        ++ (with pkgs; [
          aws-lc
          oniguruma
          sqlite
          zstd
        ]);
    }
  );

  base = pkgs.t3code;

  unwrapped = base.unwrapped.overrideAttrs (old: {
    inherit version src;
    pnpmDeps = old.pnpmDeps.override {
      inherit src version;
      hash = lock.pnpmDepsHash;
    };
  });

  # Built from the same src, so its version and vendor hash track main too.
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
