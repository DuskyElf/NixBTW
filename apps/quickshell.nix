# The wallpaper overlay: clock, photo caption, and a dim timer readout on empty
# workspaces. Source lives in quickshell/, linked live by apps/sh.nix.
{ pkgs, ... }:
{
  systemd.user.services.quickshell = {
    Unit = {
      Description = "Wallpaper overlay shell";
      PartOf = [ "graphical-session.target" ];
      # Keep the pre-systemd ordering: awww up before the overlay renders.
      After = [ "awww-daemon.service" ];
    };
    Service = {
      Environment = "WAYLAND_DISPLAY=wayland-1";
      ExecStart = "${pkgs.quickshell}/bin/quickshell";
      Restart = "on-failure";
      RestartSec = "1s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  home.packages = [ pkgs.quickshell ];
}
