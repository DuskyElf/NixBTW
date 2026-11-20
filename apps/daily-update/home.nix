# The user half of the daily update: one timer that runs
# apps/daily-update/daily-update.sh as the login account. This module states the
# schedule; which steps the run takes is host data (lib/host.nix `dailyUpdate`)
# passed to the script as flags, and the same group decides the unit's shape
# (PartOf on a desktop, linger on a headless box).
#
# The system half is apps/daily-update/system.nix.
{
  lib,
  hostConfig,
  ...
}:
let
  daily = hostConfig.dailyUpdate;

  # The run's steps that are not part of every host. The unit states them both
  # ways instead of relying on the script's defaults, so the command line is the
  # one place to read what this machine's run does.
  flag = on: name: if on then "--${name}" else "--no-${name}";

  args = [
    # The marker the system path unit watches, and the store-pinned helper the
    # NOPASSWD rule names. Both are hostConfig values, so the two halves of each
    # pair cannot drift onto separate paths.
    hostConfig.gcRequest
    hostConfig.systemSwitchPath
    # The home switch the run calls after the system one. Passed rather than
    # derived so the unit names the whole command it runs.
    "--home-switch"
    "${hostConfig.dotsDir}/apps/home-switch/hm-switch.sh"
    (flag daily.t3 "t3")
    (flag daily.devshells "devshells")
    (flag daily.collect "collect")
    "--wrapper-inputs"
    (lib.concatStringsSep " " daily.wrapperInputs)
  ]
  # A host whose kernel comes from its own CI names the substituter that has to
  # hold it before the switch; the alternative is compiling a kernel on the
  # machine overnight. Null is the flag that turns the check off.
  ++ (
    if daily.kernelCache == null then
      [ "--no-kernel-cache" ]
    else
      [
        "--kernel-cache"
        daily.kernelCache
      ]
  );
in
{
  # One daily run. apps/daily-update/daily-update.sh pulls merged work, locks the
  # checkout, moves the floating inputs and (where enabled) the T3 Code stable
  # pin, rebuilds the system and this configuration, commits the wrapper lock,
  # pins the devshells the collection has to keep, and collects the user store.
  # The marker it writes on exit wakes the root half of the collection
  # (apps/daily-update/system.nix). The pin had to run before the collection and
  # the collection after the switch; three timers used to encode that with clock
  # times, and now it is the order of one script's steps.
  systemd.user.services.daily-update = {
    Unit = {
      Description = "Daily pull, system and home switch, and store collection";
      IgnoreOnIsolate = true;
      X-SwitchMethod = "keep-old";
      # Persistent timers fire right after login, often before wifi is up.
      # Order after network-online so we don't fail on DNS on every boot.
      Wants = [ "network-online.target" ];
      After = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${hostConfig.dotsDir}/apps/daily-update/daily-update.sh ${lib.escapeShellArgs args}";
      # Type=oneshot disables the manager's start timeout, so a wedged run
      # would sit in "activating" and the next elapse would find the unit
      # already started. Twelve hours is a bound, not an expectation: it covers
      # a kernel that has to compile because the signed cache missed, a
      # from-scratch static devshell build in the pin, and a T3 Code bump.
      TimeoutStartSec = "12h";
      # No RemainAfterExit: it keeps the unit active after exit, which breaks
      # this timer's re-arm on the laptop (next elapse sticks at infinity).
    };
  };

  systemd.user.timers.daily-update = {
    Unit = {
      Description = "Timer for the daily update";
      # A desktop ties the run to its login session, so the switch lands while
      # somebody is there to see it and the collection happens right after. A
      # headless host has no graphical session to be part of: it relies on
      # hostConfig.dailyUpdate.linger so the user manager, and this timer with
      # it, starts at boot without a login.
      PartOf = lib.mkIf daily.graphicalSession [ "graphical-session.target" ];
    };
    Timer = {
      # Native wall-clock timer: fires daily at 08:30 and, with Persistent=true,
      # catches up shortly after wake if the machine was asleep at 08:30. The
      # simple systemd answer to "update once a day even when suspended".
      OnCalendar = "*-*-* 08:30:00";
      Persistent = true;
      RandomizedDelaySec = "30min";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
