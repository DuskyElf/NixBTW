# Builds one machine: the common base, that host's own modules, and the app
# modules the host names. This is the only place that knows how a NixOS
# configuration and its home-manager counterpart are assembled, so flake.nix
# only declares outputs.
#
# A host module list comes from hosts/<name>/default.nix, and its identity from
# hosts/<name>/config.nix (schema in lib/host.nix). The identity is evaluated
# once here and reaches every module, base/ and apps/ alike, as `hostConfig`.
#
# Apps are names into the registry in apps/default.nix, not module paths, so a
# host says what it wants and this file decides which configuration each part
# belongs to.
{
  inputs,
  pkgs,
  jail,
  kernel,
}:
{
  host,
  apps,
  ...
}:
assert host ? config && host ? system && host ? home;
let
  lib = inputs.nixpkgs.lib;
  hostConfig = (import ./host.nix { inherit lib; }).load host.config;
  brightness = import ./brightness.nix {
    pkgs = pkgs.stable;
    backlight = hostConfig.hardware.backlight;
  };

  # Names a host lists are checked against the registry. A typo, or a name
  # listed on the side the app does not fill, is a mistake in the host file;
  # failing eval names the host and the app instead of quietly dropping it.
  # `host.apps` may be absent entirely, which is a host with no apps.
  select =
    kind: names:
    builtins.concatMap (
      name:
      let
        app =
          apps.${name}
            or (throw "${hostConfig.hostName}: unknown app \"${name}\"; add it to apps/default.nix");
      in
      app.${kind} or (throw "${hostConfig.hostName}: app \"${name}\" has no ${kind} modules")
    ) names;
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
      ../base/core.nix
    ]
    ++ host.system
    ++ select "system" (host.apps.system or [ ])
    # The installer layout lives in the host file because only an install reads
    # it; a host without one is already installed and must not carry a module
    # that would want to format something.
    ++ lib.optionals (host ? disko) [
      inputs.disko.nixosModules.disko
      host.disko
    ];
  };

  home = inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = pkgs.stable;
    modules = [
      ../base/home.nix
    ]
    ++ host.home
    ++ select "home" (host.apps.home or [ ]);
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
