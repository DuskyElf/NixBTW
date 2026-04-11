{
  config,
  pkgs,
  ...
}:

let
  breakTimer = pkgs.writeShellScriptBin "break-timer" ''
    # Wait for 20 minutes (1200 seconds)
    sleep 1200

    # Notify
    ${pkgs.libnotify}/bin/notify-send "Break Time!" "Look away for 20 seconds. Locking in 10s." -u critical

    # Pause any running media
    ${pkgs.playerctl}/bin/playerctl -a pause || true

    # Play notification sound (runs in background so it doesn't delay locking)
    ${pkgs.pipewire}/bin/pw-play ${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/message-new-instant.oga &

    # Save brightness and dim
    CURRENT_BRIGHTNESS=$(${pkgs.brightnessctl}/bin/brightnessctl get)
    ${pkgs.brightnessctl}/bin/brightnessctl set 1%-

    # Wait 10 seconds before locking
    sleep 10

    # Lock the screen
    ${pkgs.swaylock-effects}/bin/swaylock

    # Restore brightness
    ${pkgs.brightnessctl}/bin/brightnessctl set $CURRENT_BRIGHTNESS
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
        # Listener 1: 2 minutes (120s) - Stop break timer and dim screen
        {
          timeout = 120;
          on-timeout = "${pkgs.bash}/bin/bash -c '${pkgs.brightnessctl}/bin/brightnessctl -s set 10%- && ${pkgs.systemd}/bin/systemctl --user stop break-timer.service'";
          on-resume = "${pkgs.bash}/bin/bash -c '${pkgs.brightnessctl}/bin/brightnessctl -r && ${pkgs.systemd}/bin/systemctl --user start break-timer.service'";
        }
        # Listener 2: 3 minutes (180s) - Auto-lock
        {
          timeout = 180;
          on-timeout = "pidof swaylock || ${pkgs.swaylock-effects}/bin/swaylock";
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
