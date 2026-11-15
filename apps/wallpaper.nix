# The wallpaper stack: Guardian rotates the pool, awww draws it. The quickshell
# overlay sits on top of it and is a separate app.
{
  inputs,
  hostConfig,
  pkgs,
  ...
}:
{
  imports = [ inputs.wallpaper-guardian.homeManagerModules.default ];

  services.wallpaper-guardian = {
    enable = true;
    waylandDisplay = hostConfig.waylandDisplay;
  };

  # Daemons that niri used to spawn at startup, now owned by systemd so they
  # start/stop with the graphical session and restart independently of niri.
  systemd.user.services.awww-daemon = {
    Unit = {
      Description = "Wallpaper daemon";
      PartOf = [ "graphical-session.target" ];
      # Cap a deterministic panic loop without punishing honest starts: the
      # limit counts manual and session starts too, so a short window keeps a
      # niri restart from leaving the wallpaper dead for an hour. With the
      # backoff below a panic loop burns about six attempts in half a minute.
      StartLimitIntervalSec = "10min";
      StartLimitBurst = 10;
    };
    Service = {
      # Pinned on purpose. niri does export WAYLAND_DISPLAY to the user manager
      # (systemctl --user show-environment), but the socket has to exist before
      # awww starts: connecting to a missing socket panics (wayland.rs:60), and
      # awww binds its own control socket first, so a dead instance leaves that
      # socket behind and the next start panics on EADDRINUSE (main.rs:717).
      # Wait for the Wayland socket, then clear the control socket only when no
      # daemon owns it.
      Environment = "WAYLAND_DISPLAY=${hostConfig.waylandDisplay}";
      ExecStartPre = pkgs.writeShellScript "awww-wait-wayland" ''
        i=0
        while [ "$i" -lt 100 ]; do
          [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && break
          ${pkgs.coreutils}/bin/sleep 0.1
          i=$((i + 1))
        done
        if [ ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
          echo "awww-daemon: Wayland socket $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY did not appear" >&2
          exit 1
        fi
        control="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY-awww-daemon.sock"
        # Match the full command line, not comm: the running process shows up
        # as .awww-daemon-wrapped, so pgrep -x awww-daemon never matches. The
        # anchored pattern keeps unrelated shells that merely mention the name
        # out of the guard.
        if [ -e "$control" ] && ! ${pkgs.procps}/bin/pgrep -f 'bin/awww-daemon($| )' >/dev/null; then
          ${pkgs.coreutils}/bin/rm -f "$control"
        fi
      '';
      ExecStart = "${pkgs.awww}/bin/awww-daemon";
      Restart = "on-failure";
      # Exponential backoff (systemd 260): 1s, 2s, 4s, 8s, 16s, then 30s.
      RestartSec = "1s";
      RestartSteps = 5;
      RestartMaxDelaySec = "30s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  home.packages = [ pkgs.awww ];
}
