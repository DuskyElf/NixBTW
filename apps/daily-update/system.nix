# The system half of the daily update: the root helper the user timer calls, the
# root store collection it asks for with a marker file, and the optimiser that
# rides the same schedule. A host opts in by listing the `daily-update` app, and
# lib/host.nix `dailyUpdate` decides which of these it gets: the helper is always
# installed, the optimiser only when `optimise` is set.
#
# The user half is apps/daily-update/home.nix; the run itself is
# apps/daily-update/daily-update.sh.
{
  config,
  lib,
  pkgs,
  hostConfig,
  ...
}:
let
  daily = hostConfig.dailyUpdate;

  # The user script (apps/daily-update/daily-update.sh) runs this through sudo.
  # The sudo rule below names this path, so the body has to be immutable and
  # every argument fixed: the account can ask for this rebuild and cannot point
  # nixos-rebuild at another flake, attribute, or bootloader operation. What the
  # rule does not do is make the tree trustworthy, because nixos-rebuild
  # evaluates the login user's checkout: whoever can write a module can install
  # a system generation as root on the next run. That is the same power a hand
  # rebuild has, only without the password, and the reason the rule lives in
  # AGENTS.md as a documented exception.
  #
  # /run/current-system/sw/bin/nixos-rebuild is the copy PATH resolves for a
  # hand run, and the running generation's copy is the one that exists while the
  # next one is being built. --no-write-lock-file keeps root from writing a
  # lock file it cannot own: apps/daily-update/daily-update.sh locks as the
  # login user before this runs.
  systemSwitch = pkgs.writeShellScript "nixos-switch.sh" ''
    set -euo pipefail
    # sudo keeps the caller's PATH on this system (no secure_path), and the
    # caller is the login account. Pin it to the system profile, which has
    # every tool this script and nixos-rebuild's own lookups need.
    export PATH=/run/current-system/sw/bin
    # Keep root's working directory out of the checkout being evaluated.
    cd /root
    exec /run/current-system/sw/bin/nixos-rebuild switch \
      --no-write-lock-file \
      --flake ${hostConfig.dotsDir}/deploy-system \
      --override-input my-dotfiles path:${hostConfig.dotsDir} \
      --cores ${toString daily.cores}
  '';
in
{
  # The user script's last step touches hostConfig.gcRequest, and this path unit
  # turns that into root's collection. Firing on the marker instead of on a timer
  # is what keeps the collection right after the switch rather than in the middle
  # of it, and a boot no longer starts a collection with nothing to collect.
  # Two days of generations is deliberate: the daily lock update turns over other
  # large package closures every day, and a T3 Code stable bump adds about 4 GiB
  # of its own, so anything older than one spare rollback generation is dead
  # weight even though stable tags land infrequently. The GC only drops paths no
  # generation, profile, or gcroot references, so a devshell pinned by
  # apps/daily-update/projects.sh survives no matter its age.
  systemd.services.nix-gc-root = {
    description = "Nix garbage collector for root's profiles";
    serviceConfig = {
      Type = "oneshot";
      Nice = 19;
      IOSchedulingClass = "idle";
      CPUSchedulingPolicy = "idle";
      # A first run after a long gap can sweep far more than the daily one
      # (22s on a normal day); this is a hang guard, not a work limit.
      TimeoutStartSec = "1h";
    };
    script = ''
      exec ${config.nix.package}/bin/nix-collect-garbage --delete-older-than 2d
    '';
  };

  # The only trigger for root's collection is the marker the user script writes,
  # so if that ever stops, root's generations stop being pruned.
  systemd.paths.nix-gc-root = {
    description = "Root store collection after the daily update";
    wantedBy = [ "multi-user.target" ];
    # hostConfig.gcRequest is the same value the user unit passes to the script,
    # so the two halves cannot drift onto separate paths. A user-writable trigger
    # for a root command is the price of doing this without sudo. It is
    # repeatable, and each run is idempotent inside the two-day window: what it
    # adds is the ability to run today's collection a few hours early, on
    # generations the account cannot touch itself.
    pathConfig.PathChanged = hostConfig.gcRequest;
  };

  # The optimiser rewrites the whole store, so where it runs it moves from weekly
  # to monthly instead of joining the daily run: 1.6M files and 63.7 GiB at the
  # last count on the laptop. Its measured gain there is nil right now (a walk of
  # the store found zero files with a second link, and the GC reports hard
  # linking saving nothing), so it is a cheap safety net for the day a closure
  # with duplicated outputs lands, not a space saver. The module's timer is
  # persistent, so a month start spent asleep catches up on wake, but it also
  # sets ConditionACPower, so a start spent on battery is skipped and waits for
  # the next month.
  nix.optimise = lib.mkIf daily.optimise {
    automatic = true;
    dates = [ "monthly" ];
  };

  system.activationScripts.systemSwitchHelper = ''
    mkdir -p ${builtins.dirOf hostConfig.systemSwitchPath}
    ln -sfn ${systemSwitch} ${hostConfig.systemSwitchPath}
  '';

  security.sudo.extraRules = [
    {
      users = [ hostConfig.user.name ];
      commands = [
        {
          # The daily update's system half. The helper ignores its arguments,
          # and the empty argument string is what makes sudo enforce that: a
          # rule with a bare path lets any arguments through (sudoers(5)),
          # while "" allows the command only with none. Both halves are
          # needed, because the helper is what fixes the flake and the
          # override.
          command = ''${hostConfig.systemSwitchPath} ""'';
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
