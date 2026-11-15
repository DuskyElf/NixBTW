# Builds one machine: the common base, that host's own modules, and the app
# modules. This is the only place that knows how a NixOS configuration and its
# home-manager counterpart are assembled, so flake.nix only declares outputs.
#
# A host module list comes from hosts/<name>/default.nix, and its identity from
# hosts/<name>/config.nix (schema in lib/host.nix). The identity is evaluated
# once here and reaches every module, base/ and apps/ alike, as `hostConfig`.
#
# The flake modules below are the ones that have no other home: each is an input
# exposing a module the two configs need.
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
assert host ? config && host ? system && host ? home;
let
  lib = inputs.nixpkgs.lib;
  hostConfig = (import ./host.nix { inherit lib; }).load host.config;
  brightness = import ./brightness.nix {
    pkgs = pkgs.stable;
    backlight = hostConfig.hardware.backlight;
  };
in
{
  # flake.nix names its outputs from these.
  inherit hostConfig;

  nixos = lib.nixosSystem {
    inherit (pkgs) system;
    specialArgs = {
      inherit
        inputs
        jail
        hostConfig
        ;
      pkgs-unstable = pkgs.unstable;
      pkgs-fast-release = pkgs.fast-release;
      stableKernel = kernel;
    };
    modules = [
      # One nixpkgs instance for the whole flake (lib/pkgs.nix), so the platform
      # comes from there. Without this, nixpkgs.hostPlatform has no value and
      # modules that read it fail; lib/pkgs.nix is the single source.
      { nixpkgs.hostPlatform = pkgs.system; }
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
      inherit
        inputs
        jail
        hostConfig
        brightness
        ;
      pkgs-unstable = pkgs.unstable;
      pkgs-unstable-small = pkgs.unstable-small;
    };
  };
}
