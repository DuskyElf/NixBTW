{
  config,
  pkgs,
  ...
}:

let
  dim60 = pkgs.writeShellScriptBin "dim60" ''
    if pidof swaylock > /dev/null; then
      ${pkgs.brightnessctl}/bin/brightnessctl -s set 0%
      touch /tmp/dimmed_by_60
    fi
  '';
  resume60 = pkgs.writeShellScriptBin "resume60" ''
    if [ -f /tmp/dimmed_by_60 ]; then
      ${pkgs.brightnessctl}/bin/brightnessctl -r
      rm -f /tmp/dimmed_by_60
    fi
  '';
  dim120 = pkgs.writeShellScriptBin "dim120" ''
    if [ ! -f /tmp/dimmed_by_60 ]; then
      ${pkgs.brightnessctl}/bin/brightnessctl -s set 0%
      touch /tmp/dimmed_by_120
    fi
    ${pkgs.systemd}/bin/systemctl --user stop break-timer.service
  '';
  resume120 = pkgs.writeShellScriptBin "resume120" ''
    if [ -f /tmp/dimmed_by_120 ]; then
      ${pkgs.brightnessctl}/bin/brightnessctl -r
      rm -f /tmp/dimmed_by_120
    fi
    ${pkgs.systemd}/bin/systemctl --user start break-timer.service
  '';

  skipBreak = pkgs.writeShellScriptBin "skip-break" ''
    if [ -f /tmp/break_timer_id ]; then
      ${pkgs.mako}/bin/makoctl dismiss -n $(cat /tmp/break_timer_id) || true
      rm -f /tmp/break_timer_id
    fi
    # Restarting the service will kill the current sleep and start the 20m timer again
    ${pkgs.systemd}/bin/systemctl --user restart break-timer.service
  '';

  breakTimer = pkgs.writeShellScriptBin "break-timer" ''
    # Wait for 20 minutes (1200 seconds)
    sleep 1200

    # Notify and save the notification ID
    NOTIFY_ID=$(${pkgs.libnotify}/bin/notify-send -p "Break Time!" "Look away for 20 seconds. Locking in 10s. Press Mod+B to skip." -u critical)
    echo "$NOTIFY_ID" > /tmp/break_timer_id

    # Pause any running media
    ${pkgs.playerctl}/bin/playerctl -a pause || true

    # Play notification sound (runs in background so it doesn't delay locking)
    ${pkgs.pipewire}/bin/pw-play ${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/message-new-instant.oga &

    # Wait 10 seconds before locking
    sleep 10

    # Lock the screen via loginctl so swaylock isn't killed by systemd when the timer resets/stops
    ${pkgs.systemd}/bin/loginctl lock-session
  '';
in
{
  systemd.user.services.break-timer = {
    Unit = {
      Description = "20-minute break timer";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${breakTimer}/bin/break-timer";
      Restart = "always";
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };

  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "pidof swaylock || ${pkgs.swaylock-effects}/bin/swaylock";
      };

      listener = [
        # Listener 1: 60s - If locked, set brightness to 0
        {
          timeout = 60;
          on-timeout = "${dim60}/bin/dim60";
          on-resume = "${resume60}/bin/resume60";
        }
        # Listener 2: 2 minutes (120s) - If not already dimmed, set brightness to 0 and stop break timer
        {
          timeout = 120;
          on-timeout = "${dim120}/bin/dim120";
          on-resume = "${resume120}/bin/resume120";
        }
        # Listener 3: 3 minutes (180s) - Auto-lock
        {
          timeout = 180;
          on-timeout = "${pkgs.systemd}/bin/loginctl lock-session";
        }
      ];
    };
  };

  programs.swaylock = {
    enable = true;
    package = pkgs.swaylock-effects;
    settings = {
      screenshots = true;
      clock = true;
      indicator = true;
      effect-blur = "7x5";
      effect-vignette = "0.5:0.5";
      indicator-radius = 100;
      indicator-thickness = 7;
    };
  };
}
