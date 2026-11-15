# Colour temperature: wl-gammarelay owns the gamma LUT, a one-shot service sets
# the startup temperature, and apps/niri/binds.nix nudges it on Alt+scroll.
{ pkgs, ... }:
let
  setStartupTemperature = pkgs.writeShellScriptBin "set-startup-temperature" ''
    BUSCTL=${pkgs.systemd}/bin/busctl
    # Wait for the gamma daemon's D-Bus name (systemd reports a simple-type
    # service "started" before the name registers), then set the startup
    # color temperature. Signature is q (uint16), NOT n: a wrong signature
    # panics the daemon, killing gamma control until the session restarts.
    i=0
    while ! $BUSCTL --user get-property rs.wl-gammarelay / rs.wl.gammarelay Temperature > /dev/null 2>&1; do
      i=$((i + 1))
      [ "$i" -ge 50 ] && exit 1
      sleep 0.1
    done
    $BUSCTL --user set-property rs.wl-gammarelay / rs.wl.gammarelay Temperature q 5700
  '';
in
{
  systemd.user.services.wl-gammarelay = {
    Unit = {
      Description = "Wayland color temperature daemon";
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Environment = "WAYLAND_DISPLAY=wayland-1";
      ExecStart = "${pkgs.wl-gammarelay-rs}/bin/wl-gammarelay-rs";
      Restart = "on-failure";
      RestartSec = "1s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  # One-shot bootstrap: wait for the gamma daemon's D-Bus name (simple-type
  # service is "started" before the name registers), then set the startup color
  # temperature. Signature is q (uint16), NOT n: a wrong signature panics the
  # daemon, killing gamma control until the session restarts.
  systemd.user.services.gamma-temperature = {
    Unit = {
      Description = "Set startup color temperature";
      PartOf = [ "graphical-session.target" ];
      After = [ "wl-gammarelay.service" ];
    };
    Service = {
      Type = "oneshot";
      Environment = "WAYLAND_DISPLAY=wayland-1";
      ExecStart = "${setStartupTemperature}/bin/set-startup-temperature";
      Restart = "on-failure";
      RestartSec = "1s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  home.packages = [ pkgs.wl-gammarelay-rs ];
}
