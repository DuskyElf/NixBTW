# The system half of the daily update: the root helper the user timer calls and
# the root store collection it asks for with a marker file. A host opts in by
# importing this module and apps/daily-update/home.nix; lib/host.nix
# `dailyUpdate` shapes the run.
#
# The user half is apps/daily-update/home.nix; the run itself is
# apps/daily-update/daily-update.sh.
{
  config,
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
  # rebuild has, only without the password, and the reason a password-free root
  # path exists here at all. It is the second one, after apps/power/power.sh;
  # do not add a third without the same reasoning written beside it.
  #
  # This path is both the timer's own command and the hand-run command: a hand
  # run and the timer's run go through the same body and the same lock. A host
  # that has no helper yet runs that body by hand, with the password in front:
  #
  #   sudo nixos-rebuild switch \
  #     --no-write-lock-file \
  #     --flake "$HOME/dotfiles/deploy-system" \
  #     --override-input my-dotfiles "path:$HOME/dotfiles" \
  #     --cores <dailyUpdate.cores>
  #
  # The count is the host's dailyUpdate.cores: 16 on the laptop, 2 on the
  # homelab.
  #
  # A --target-host run reaches the target's switch-to-configuration directly
  # and cannot take that host's lock, so it still collides with the host's own
  # daily run: ssh in and run this helper there instead.
  #
  # The homelab rebuilds on the box, in its own checkout, because that switches
  # the pins that box's wrapper locked:
  #
  #   ssh homelab
  #   cd "$HOME/dotfiles" && git pull --rebase --autostash
  #   sudo /usr/local/sbin/nixos-switch.sh
  #   "$HOME/dotfiles/apps/home-switch/hm-switch.sh"
  #
  # Building the attribute on the laptop first catches an evaluation error
  # against the laptop's pin rather than after the pull:
  #
  #   nix build --no-link \
  #     "path:$dots/deploy-system#nixosConfigurations.homelab.config.system.build.toplevel" \
  #     --override-input my-dotfiles "path:$dots"
  #
  # with dots=$HOME/dotfiles.
  #
  # /run/current-system/sw/bin/nixos-rebuild is the copy PATH resolves for a
  # hand run, and the running generation's copy is the one that exists while the
  # next one is being built. --no-write-lock-file keeps root from writing a
  # lock file the login account cannot write: apps/daily-update/daily-update.sh
  # locks as the login user before this runs.
  systemSwitch = pkgs.writeShellScript "nixos-switch.sh" ''
    set -euo pipefail
    # sudo keeps the caller's PATH on this system (no secure_path), and the
    # caller is the login account. Pin it to the system profile, which has
    # every tool this script and nixos-rebuild's own lookups need.
    export PATH=/run/current-system/sw/bin
    # Keep root's working directory out of the checkout being evaluated.
    cd /root
    # A hand run and the timer's run can overlap, and both reach
    # switch-to-configuration as the same transient unit,
    # nixos-rebuild-switch-to-configuration. The loser aborts after the
    # activation has already happened, so its caller reports a failure that
    # did not occur. Serialise instead: the second run waits, then repeats a
    # switch that changes nothing.
    #
    # `>>` and never a recreate: the lock lives on the inode, so a replaced or
    # deleted file would hand the second run a lock of its own. The file is
    # created once, 0600, because flock works on a read-only descriptor too and
    # a world-readable lock lets another account hold it; the tmpfiles rule
    # below re-asserts that mode at boot, since a switch does not re-run
    # tmpfiles. Two runs racing on the first creation still land on one inode.
    if [ ! -e /run/nixos-switch.lock ]; then
      (umask 077; : >>/run/nixos-switch.lock)
    fi
    exec 9>>/run/nixos-switch.lock
    if ! ${pkgs.util-linux}/bin/flock -n 9; then
      echo "nixos-switch: another switch is running, waiting for it" >&2
      ${pkgs.util-linux}/bin/flock -w 3600 9 || {
        echo "nixos-switch: another switch has held the lock for an hour" >&2
        exit 1
      }
    fi
    # The live-tree override is what applies uncommitted edits and the pull's
    # work. Without it the wrapper evaluates its pinned my-dotfiles rev, which
    # can be older than this checkout and can point at a different
    # nixpkgs-fast-release, so the kernel build misses the signed cache.
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

  # There is no store optimiser on either host, and it should not be added back
  # without a measurement: the last audit found zero files in the store with a
  # second hard link and the GC reports hard linking saving nothing, while each
  # run's .tmp-link-* entries under /nix/store drive the two config watchers
  # that watch that directory on the laptop (auto-cpufreq's and kitty's
  # __watch_conf__) to about a core between them. Neither exists on the homelab.
  #
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

  # The helper's lock file. The helper creates it 0600 itself the first time it
  # runs; this rule re-asserts the mode at boot, which is the only time tmpfiles
  # runs. A world-readable lock would let another local account hold it and
  # stall the daily switch, because flock(2) works on a read-only descriptor.
  systemd.tmpfiles.rules = [ "f /run/nixos-switch.lock 0600 root root -" ];

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
