{ pkgs, ... }:

let
  bt = "${pkgs.brightnessctl}/bin/brightnessctl";
  tmp = "/tmp";

  dimIfLocked = pkgs.writeShellScriptBin "dimIfLocked" ''
    ${pkgs.procps}/bin/pidof swaylock >/dev/null || exit 0
    ${pkgs.systemd}/bin/systemctl --user stop break-timer.timer break-timer.service 2>/dev/null || true
    old=$(${bt} get 2>/dev/null) || exit 0
    [ -n "$old" ] || exit 0
    echo "$old" > ${tmp}/brightness.before.lock
    ${bt} set 0% >/dev/null 2>&1
    : > ${tmp}/dimmed.lock
  '';

  resumeIfDimmed = pkgs.writeShellScriptBin "resumeIfDimmed" ''
    [ -f ${tmp}/dimmed.lock ] || exit 0
    old=$(cat ${tmp}/brightness.before.lock 2>/dev/null) || old=$(${bt} max 2>/dev/null)
    [ -n "$old" ] && ${bt} set "$old" >/dev/null 2>&1
    rm -f ${tmp}/dimmed.lock ${tmp}/brightness.before.lock
    ${pkgs.systemd}/bin/systemctl --user restart break-timer.timer 2>/dev/null || true
  '';

  dimOnIdle = pkgs.writeShellScriptBin "dimOnIdle" ''
    # if already dimmed by lock dimmer, don't touch
    [ -f ${tmp}/dimmed.lock ] && exit 0
    old=$(${bt} get 2>/dev/null) || exit 0
    [ -n "$old" ] || exit 0
    echo "$old" > ${tmp}/brightness.before.idle
    ${bt} set 0% >/dev/null 2>&1
    : > ${tmp}/dimmed.idle
    ${pkgs.systemd}/bin/systemctl --user stop break-timer.timer break-timer.service 2>/dev/null || true
  '';

  resumeOnIdle = pkgs.writeShellScriptBin "resumeOnIdle" ''
    [ -f ${tmp}/dimmed.idle ] || exit 0
    old=$(cat ${tmp}/brightness.before.idle 2>/dev/null) || old=$(${bt} max 2>/dev/null)
    [ -n "$old" ] && ${bt} set "$old" >/dev/null 2>&1
    rm -f ${tmp}/dimmed.idle ${tmp}/brightness.before.idle
    ${pkgs.systemd}/bin/systemctl --user restart break-timer.timer 2>/dev/null || true
  '';

  breakTimer = pkgs.writeShellScriptBin "break-timer" ''
    ${pkgs.procps}/bin/pidof swaylock >/dev/null && exit 0

    sid=$(${pkgs.systemd}/bin/loginctl list-sessions --no-legend 2>/dev/null | ${pkgs.gawk}/bin/awk -v u="$(id -u)" '$3==u{print $1; exit}')
    [ -n "$sid" ] && ${pkgs.systemd}/bin/loginctl show-session "$sid" -p LockedHint 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q LockedHint=yes && exit 0

    exec 200>${tmp}/break-timer.lock
    ${pkgs.util-linux}/bin/flock -n 200 || exit 0

    NOTIFY_ID=$(${pkgs.libnotify}/bin/notify-send -p "Break Time!" "Look away for 20 seconds. Locking in 10s. Press Mod+B to skip." -u critical)
    echo "$NOTIFY_ID" > /tmp/break_timer_id
    echo "$NOTIFY_ID" > ${tmp}/break-timer-notify-id

    ${pkgs.playerctl}/bin/playerctl -a pause 2>/dev/null || true
    ${pkgs.pipewire}/bin/pw-play ${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/message-new-instant.oga >/dev/null 2>&1 &

    sleep 10
    ${pkgs.procps}/bin/pidof swaylock >/dev/null && exit 0
    ${pkgs.systemd}/bin/loginctl lock-session
  '';
in
{
  systemd.user.services.break-timer = {
    Unit = {
      Description = "Break timer action";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${breakTimer}/bin/break-timer";
    };
  };

  systemd.user.timers.break-timer = {
    Unit.Description = "Break timer (20min inactivity)";
    Timer = {
      OnBootSec = "20min";
      OnActiveSec = "20min";
      AccuracySec = "1s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  services.hypridle = {
    enable = true;
    settings = {
      general.lock_cmd = "pidof swaylock || ${pkgs.swaylock-effects}/bin/swaylock";
      listener = [
        {
          timeout = 60;
          on-timeout = "${dimIfLocked}/bin/dimIfLocked";
          on-resume = "${resumeIfDimmed}/bin/resumeIfDimmed";
        }
        {
          timeout = 120;
          on-timeout = "${dimOnIdle}/bin/dimOnIdle";
          on-resume = "${resumeOnIdle}/bin/resumeOnIdle";
        }
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
