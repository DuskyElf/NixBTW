# The wallpaper overlay: clock, photo caption, and a dim timer readout on empty
# workspaces. Source lives in apps/quickshell/, linked live by this module.
{
  config,
  hostConfig,
  pkgs,
  ...
}:
{
  systemd.user.services.quickshell = {
    Unit = {
      Description = "Wallpaper overlay shell";
      PartOf = [ "graphical-session.target" ];
      # Keep the pre-systemd ordering: awww up before the overlay renders.
      After = [ "awww-daemon.service" ];
    };
    Service = {
      Environment = "WAYLAND_DISPLAY=${hostConfig.waylandDisplay}";
      ExecStart = "${pkgs.quickshell}/bin/quickshell";
      Restart = "on-failure";
      RestartSec = "1s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  # The shell, the status scripts it runs, and timers.mjs. Linked live so an
  # edit reaches the running shell without a rebuild.
  xdg.configFile."quickshell" = {
    recursive = true;
    source = config.lib.file.mkOutOfStoreSymlink "${hostConfig.dotsDir}/apps/quickshell";
  };

  home.packages = [ pkgs.quickshell ];
}
