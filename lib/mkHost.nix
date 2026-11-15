# Builds one machine: the common base, that host's own modules, and the app
# modules. This is the only place that knows how a NixOS configuration and its
# home-manager counterpart are assembled, so flake.nix only declares outputs.
#
# A host module list comes from hosts/<name>/default.nix. The flake modules
# below are the ones that have no other home: each is an input exposing a module
# the two configs need.
{
  inputs,
  pkgs,
  jail,
  kernel,
}:
{
  host,
  homeModules,
  systemModules,
}:
assert host ? system && host ? home;
{
  nixos = inputs.nixpkgs.lib.nixosSystem {
    inherit (pkgs) system;
    specialArgs = {
      inherit inputs jail;
      pkgs-unstable = pkgs.unstable;
      pkgs-fast-release = pkgs.fast-release;
      stableKernel = kernel;
    };
    modules = [
      ../base/system.nix
    ]
    ++ host.system
    ++ systemModules;
  };

  home = inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = pkgs.stable;
    modules = [
      ../base/home.nix
      inputs.niri.homeModules.config
      inputs.niri.homeModules.stylix
      inputs.stylix.homeModules.stylix
      inputs.zen-browser.homeModules.beta
    ]
    ++ host.home
    ++ homeModules;
    extraSpecialArgs = {
      inherit inputs jail;
      pkgs-unstable = pkgs.unstable;
      pkgs-unstable-small = pkgs.unstable-small;
    };
  };
}
