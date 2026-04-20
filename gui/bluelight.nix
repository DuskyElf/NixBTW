{ pkgs, ... }:
{
  systemd.user.services.night-color-temperature = {
    Unit = {
      Description = "Set night color temperature via wl-gammarelay";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/busctl --user set-property rs.wl-gammarelay / rs.wl.gammarelay Temperature q 2700";
    };
  };

  systemd.user.timers.night-color-temperature = {
    Unit = {
      Description = "Timer to set night color temperature at 19:00";
    };
    Timer = {
      OnCalendar = "19:00";
      Persistent = true;
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };

  systemd.user.services.day-color-temperature = {
    Unit = {
      Description = "Set day color temperature via wl-gammarelay";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/busctl --user set-property rs.wl-gammarelay / rs.wl.gammarelay Temperature q 4500";
    };
  };

  systemd.user.timers.day-color-temperature = {
    Unit = {
      Description = "Timer to set day color temperature at 07:00";
    };
    Timer = {
      OnCalendar = "07:00";
      Persistent = true;
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
