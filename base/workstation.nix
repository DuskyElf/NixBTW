# The desktop policy: everything here assumes a monitor, a keyboard, a battery,
# and a person sitting in front of it. It is a module a host opts into, so a
# headless box does not get NetworkManager, bluetooth, or the desktop packages.
# base/core.nix is the half every machine gets.
#
# The root helpers (power.sh and the daily update's nixos-switch.sh), the
# NOPASSWD rules, and the store-collection units moved to apps/power.nix and
# apps/daily-update/system.nix: they belong to the app that uses them, and a
# headless host runs the daily update too.
{
  lib,
  pkgs,
  jail,
  hostConfig,
  ...
}:
{
  config = {
    # NetworkManager is the desktop radio/wifi stack; a server uses
    # systemd-networkd and says so in its own system.nix.
    networking.networkmanager.enable = true;

    users.users.${hostConfig.user.name}.extraGroups = [
      "networkmanager"
    ];

    console.useXkbConfig = true;

    # Very bare bones setup for root, everything else is handled by
    # home-manager. A package that needs config of its own belongs in apps/
    # instead, so it stays findable by name. The core six are in
    # base/core.nix and must not be repeated here.
    programs.zsh.enable = true;
    programs.gpu-screen-recorder.enable = true;
    programs.thunderbird.enable = true;

    environment.systemPackages = [
      pkgs.gcc
      (jail "wget" pkgs.wget (
        c: with c; [
          network
          mount-cwd
        ]
      ))
      (jail "curl" pkgs.curl (
        c: with c; [
          network
          mount-cwd
        ]
      ))
      pkgs.brightnessctl

      pkgs.fzf
      pkgs.bat
      pkgs.dust
      pkgs.tealdeer

      pkgs.gpu-screen-recorder-gtk
      pkgs.wl-clipboard
      pkgs.libnotify
    ];

    environment.sessionVariables = {
      NIXOS_OZONE_WL = "1"; # wayland support for some chromium applications
    };

    # Read by the greeter and the tty, not by the stylix terminal config.
    fonts.packages = with pkgs; [
      nerd-fonts.jetbrains-mono
    ];

    services.blueman.enable = true;
    hardware.bluetooth.enable = true;

    # For better battery life the laptop stops charging at a set percentage.
    # A host without a battery skips the unit entirely.
    systemd.services.battery-threshold-control = lib.mkIf (hostConfig.hardware.battery != null) {
      script = ''
        echo "${toString hostConfig.hardware.battery.chargeLimit}" > /sys/class/power_supply/${hostConfig.hardware.battery.device}/charge_control_end_threshold
      '';
      wantedBy = [ "multi-user.target" ];
    };
  };
}
