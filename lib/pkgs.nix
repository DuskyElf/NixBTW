# The nixpkgs instances this flake needs, one per role. The mix is deliberate:
# each one follows the nixpkgs its packages are built against.
{ inputs }:
let
  system = "x86_64-linux";

  # `overlays` is a top level argument to `import`, not a config key: inside
  # `config` it is ignored without a warning.
  overlays = [ (import ./overlays/perl-cpants.nix) ];

  # What this machine's own packages get.
  config = {
    allowUnfree = true;
  };

  # The kernel toolchain's config on purpose: no overlays. A new perl5
  # derivation here would change the kernel derivation, the signed cache would
  # miss, and the laptop would compile a kernel for two hours.
  kernelConfig = {
    allowUnfree = true;
  };
in
{
  inherit system;

  stable = import inputs.nixpkgs {
    inherit system overlays config;
  };

  fast-release = import inputs.nixpkgs-fast-release {
    inherit system;
    config = kernelConfig;
  };

  # niri and zen-browser build against unstable. legacyPackages is their own
  # flake output, so it carries nixpkgs' flake defaults instead of `config`.
  unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
  unstable-small = inputs.nixpkgs-unstable-small.legacyPackages.${system};
}
