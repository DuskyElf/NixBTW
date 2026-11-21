# Builds one machine: the common base, that host's own modules, and the app
# modules the host imports. This is the only place that knows how a NixOS
# configuration and its home-manager counterpart are assembled, so flake.nix
# only declares outputs.
#
# A host module list comes from hosts/<name>/default.nix, and its identity from
# hosts/<name>/config.nix (schema in lib/host.nix). The identity is evaluated
# once here and reaches every module, base/ and apps/ alike, as `hostConfig`.
#
# A host imports each app module into the half it rebuilds. The list an import
# sits in is what puts it in the system configuration or the home one, and a
# split app names its halves `home.nix` and `system.nix`, so the import has to
# sit in the matching list. checkHalf fails eval on the mistake that would
# otherwise apply quietly: an import that works in either configuration, like the
# daily update's timer, landing in the wrong one.
#
# Evaluate a change before switching it:
#
#   nix eval --raw --no-write-lock-file .#nixosConfigurations.asus.config.system.build.toplevel.drvPath
#   nix eval --raw --no-write-lock-file '.#homeConfigurations."duskyelf@asus".config.home.activationPackage.drvPath'
#   nix eval --raw --no-write-lock-file .#nixosConfigurations.homelab.config.system.build.toplevel.drvPath
#   nix eval --raw --no-write-lock-file '.#homeConfigurations."duskyelf@homelab".config.home.activationPackage.drvPath'
#
# These read tracked files only, so git add a new Nix file before evaluating.
# The rebuild helpers read the live tree, untracked edits included.
{
  inputs,
  pkgs,
  jail,
  kernel,
}:
{
  host,
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

  # The half an app import declares, from its own name: `apps/x/home.nix` is a
  # home module and `apps/x/system.nix` is a system one. Anything else, an app
  # with a single file or a file outside apps/, declares nothing and passes.
  appsDir = "${toString ../apps}/";
  repoDir = "${toString ../.}/";

  halfOf =
    module:
    let
      path = if builtins.isPath module then toString module else "";
    in
    if lib.hasPrefix appsDir path then
      if lib.hasSuffix "/home.nix" path then
        "home"
      else if lib.hasSuffix "/system.nix" path then
        "system"
      else
        null
    else
      null;

  checkHalf =
    kind: modules:
    builtins.map (
      module:
      let
        half = halfOf module;
      in
      if half == null || half == kind then
        module
      else
        throw "${hostConfig.hostName}: ${lib.removePrefix repoDir (toString module)} is a ${half} module, imported into the ${kind} list"
    ) modules;

  # Two host mistakes evaluate clean and install nothing, so they fail here:
  # the old host.apps block, which nothing reads any more, and an ssh.aliases
  # entry on a host that does not import the module which renders it.
  opensshHome = ../apps/openssh/home.nix;

  host' =
    if host ? apps then
      throw "${hostConfig.hostName}: host.apps is gone; import each app module into the system or home list"
    else if hostConfig.ssh.aliases != { } && !builtins.elem opensshHome host.home then
      throw "${hostConfig.hostName}: ssh.aliases is set, so ${lib.removePrefix repoDir (toString opensshHome)} belongs in the home list"
    else
      host;
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
    ++ checkHalf "system" host'.system
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
    ++ checkHalf "home" host'.home;
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
