# `dots`: audited system/home rebuilds for this repo.
#
# The binary is store-pinned on purpose. Its self-check refuses to run unless the
# executable and its embedded source are /nix/store paths owned by root that
# `nix store verify` accepts, and unless it is the copy /run/current-system
# ships. `dotfilesDir` is baked in as DOTS_DOTFILES: that is the checkout the
# binary audits by default. DOTS_POWER_SH carries scripts/power.sh into the test
# phase so the sandbox asserts the committed fixture still matches the real root
# helper; the release binary does not embed that text.
{
  lib,
  rustPlatform,
  dotfilesDir,
}:
let
  # `target/` must not enter the store copy; the rest of the crate is source,
  # Cargo.lock included, and the fixed cargoHash pins the vendor tree.
  source = lib.cleanSourceWith {
    src = ./.;
    filter =
      path: type:
      let
        base = baseNameOf (toString path);
      in
      base != "target" && lib.cleanSourceFilter path type;
  };
in
rustPlatform.buildRustPackage {
  pname = "dots";
  version = "0.1.0";
  src = source;

  cargoLock.lockFile = ./Cargo.lock;

  # The vendor tree is pinned by Cargo.lock through `importCargoLock`: every
  # crate is a fixed-output fetch keyed by the hashes in the lock, so the build
  # needs no network beyond those fetches. `cargoHash` is the pin the
  # vendor-directory mode (`fetchCargoVendor`) would need; nixpkgs ignores it
  # while `cargoLock` is set, so it is recorded here for that mode and not
  # consulted today.
  cargoHash = "sha256-MxxcHb//r2gs7bTdV9+3nc3ZiSQL8AumBVQBPcWvZwg=";

  DOTS_DOTFILES = dotfilesDir;
  DOTS_SOURCE = toString source;
  # Test-only: lets the sandbox compare tests/fixtures/power.sh with the real
  # helper instead of skipping. It is referenced only by `option_env!` in tests.
  DOTS_POWER_SH = builtins.readFile ../../scripts/power.sh;

  meta = {
    description = "Audited system/home rebuilds for the dotfiles repo";
    mainProgram = "dots";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
