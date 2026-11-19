# The desktop policy: everything here assumes a monitor, a keyboard, a battery,
# and a person sitting in front of it. It is a module a host opts into, so a
# headless box does not get NetworkManager, tailscale, bluetooth, the root
# helpers, or the store-collection path unit. base/core.nix is the half every
# machine gets.
{
  config,
  lib,
  pkgs,
  jail,
  hostConfig,
  ...
}:
let
  # power.sh runs as root via NOPASSWD sudo, so the invariant is two parts:
  # an immutable body and pinned command lookups. The activation script links
  # this store copy into /usr/local/sbin, which is the only path sudo matches,
  # and runtimeInputs means sudo's inherited caller PATH cannot shadow a tool.
  # writeShellApplication emits a directory, so link its /bin/power.sh, not it.
  # Edits to scripts/power.sh only reach root on the next nixos-rebuild, and
  # the writable ~/.config/scripts copy never does, because sudo matches only
  # the /usr/local/sbin path.
  powerScript = pkgs.writeShellApplication {
    name = "power.sh";
    inheritPath = false;
    # The script owns its own errexit/nounset/pipefail, so the wrapper must not
    # add a second copy of them.
    bashOptions = [ ];
    runtimeInputs = [
      pkgs.auto-cpufreq
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.kmod
      pkgs.libnotify
      pkgs.sudo
    ];
    # ls -l | grep parses /proc/<pid>/fd symlink targets; a glob is not
    # equivalent, so this is the one shellcheck check worth excluding.
    excludeShellChecks = [ "SC2010" ];
    # The screenpad device is host data, so bake it into this root-only copy
    # instead of accepting it as an argument. The NOPASSWD rule allows power.sh
    # with any arguments, and a device argument would let that rule blank any
    # backlight, the internal panel included. The writable ~/.config copy has
    # no baked value and cannot write sysfs as the login user anyway.
    text = ''
      SCREENPAD_DEVICE=${
        lib.escapeShellArg (
          if hostConfig.hardware.screenpad == null then "" else hostConfig.hardware.screenpad.device
        )
      }
    ''
    + lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ../scripts/power.sh);
  };

  # The system half of the daily update (scripts/daily-update.sh) runs through
  # this store copy. The sudo rule below names this path, so the body has to be
  # immutable and every argument fixed: the account can ask for this rebuild and
  # cannot point nixos-rebuild at another flake, attribute, or bootloader
  # operation. What the rule does not do is make the tree trustworthy, because
  # nixos-rebuild evaluates the login user's checkout: whoever can write a
  # module can install a system generation as root on the next run. That is the
  # same power a hand rebuild has, only without the password, and the reason the
  # rule lives in AGENTS.md as a documented exception.
  #
  # /run/current-system/sw/bin/nixos-rebuild is the copy PATH resolves for a
  # hand run, and the running generation's copy is the one that exists while the
  # next one is being built. --no-write-lock-file keeps root from writing a
  # lock file it cannot own: scripts/daily-update.sh locks as the login user
  # before this runs.
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
      --cores 16
  '';
in
{
  config = {
    # NetworkManager is the desktop radio/wifi stack; a server uses
    # systemd-networkd and says so in its own system.nix.
    networking.networkmanager.enable = true;

    users.users.${hostConfig.user.name}.extraGroups = [
      "networkmanager"
    ];

    console.useXkbConfig = true;

    # Very bare bones setup for root, everything else is handled by
    # home-manager. A package that needs config of its own belongs in apps/
    # instead, so it stays findable by name. The core six are in
    # base/core.nix and must not be repeated here.
    programs.zsh.enable = true;
    programs.gpu-screen-recorder.enable = true;
    programs.thunderbird.enable = true;

    environment.systemPackages = [
      pkgs.gcc
      (jail "wget" pkgs.wget (
        c: with c; [
          network
          mount-cwd
        ]
      ))
      (jail "curl" pkgs.curl (
        c: with c; [
          network
          mount-cwd
        ]
      ))
      pkgs.brightnessctl

      pkgs.fzf
      pkgs.bat
      pkgs.dust
      pkgs.tealdeer

      pkgs.gpu-screen-recorder-gtk
      pkgs.wl-clipboard
      pkgs.libnotify
    ];

    environment.sessionVariables = {
      NIXOS_OZONE_WL = "1"; # wayland support for some chromium applications
    };

    # Read by the greeter and the tty, not by the stylix terminal config.
    fonts.packages = with pkgs; [
      nerd-fonts.jetbrains-mono
    ];

    # Tailscale gives the phone a stable private route to the t3code
    # server on 3773 from any network. MagicDNS name:
    # <hostName>.<tailnet>.ts.net
    # --operator lets the login user run `tailscale serve`, which the t3code
    # desktop app calls to publish the backend over HTTPS on the tailnet.
    services.tailscale = {
      enable = true;
      openFirewall = true;
      extraSetFlags = [ "--operator=${hostConfig.user.name}" ];
    };

    services.blueman.enable = true;
    hardware.bluetooth.enable = true;

    # For better battery life the laptop stops charging at a set percentage.
    # A host without a battery skips the unit entirely.
    systemd.services.battery-threshold-control = lib.mkIf (hostConfig.hardware.battery != null) {
      script = ''
        echo "${toString hostConfig.hardware.battery.chargeLimit}" > /sys/class/power_supply/${hostConfig.hardware.battery.device}/charge_control_end_threshold
      '';
      wantedBy = [ "multi-user.target" ];
    };

    # Store hygiene runs at the tail of the daily user update, not on a clock.
    # The user half (scripts/daily-update.sh) collects the store and
    # home-manager's generations, which is everything the login account can
    # prune. Root's generations under /nix/var/nix/profiles are the part it
    # cannot reach, so when the script is done it touches
    # ~/.local/state/daily-update/gc-request and the path unit below runs the
    # root half. Firing on that marker instead of on a timer is what keeps the
    # collection right after the switch rather than in the middle of it, and a
    # boot no longer starts a collection with nothing to collect.
    # Two days of generations is deliberate: the daily lock update turns over
    # other large package closures every day, and a T3 Code stable bump adds
    # about 4 GiB of its own, so anything older than one spare rollback
    # generation is dead weight even though stable tags land infrequently. The
    # GC only drops paths no generation, profile, or gcroot references, so a
    # devshell pinned by scripts/projects.sh survives no matter its age.
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

    # The only trigger for root's collection is the marker the user script
    # writes, so if that ever stops, root's generations stop being pruned.
    systemd.paths.nix-gc-root = {
      description = "Root store collection after the daily update";
      wantedBy = [ "multi-user.target" ];
      # hostConfig.gcRequest is the same value the user unit passes to the
      # script, so the two halves cannot drift onto separate paths. A
      # user-writable trigger for a root command is the price of doing this
      # without sudo. It is repeatable, and each run is idempotent inside the
      # two-day window: what it adds is the ability to run today's collection a
      # few hours early, on generations the account cannot touch itself.
      pathConfig.PathChanged = hostConfig.gcRequest;
    };

    # The optimiser rewrites the whole store, so it moves from weekly to
    # monthly instead of joining the daily run: 1.6M files and 63.7 GiB at the
    # last count. Its
    # measured gain is nil right now (a walk of the store found zero files
    # with a second link, and the GC reports hard linking saving nothing), so
    # this is a cheap safety net for the day a closure with duplicated outputs
    # lands, not a space saver. The module's timer is persistent, so a month
    # start spent asleep catches up on wake, but the module also sets
    # ConditionACPower, so a start spent on battery is skipped and waits for
    # the next month.
    nix.optimise = {
      automatic = true;
      dates = [ "monthly" ];
    };

    # Both root helpers: the keybind one and the daily update's system half.
    # One snippet, so the two links cannot land in different activation runs.
    system.activationScripts.rootHelpers = ''
      mkdir -p ${builtins.dirOf hostConfig.powerScriptPath} ${builtins.dirOf hostConfig.systemSwitchPath}
      ln -sfn ${lib.getExe powerScript} ${hostConfig.powerScriptPath}
      ln -sfn ${systemSwitch} ${hostConfig.systemSwitchPath}
    '';

    # Disable the credential cache: a fresh sudo timestamp (e.g. from a
    # rebuild) would otherwise let anything running as the login user
    # `sudo -n <anything>` within the window. NOPASSWD keybind rule is
    # unaffected, but every other sudo now prompts fresh.
    security.sudo.extraConfig = "Defaults timestamp_timeout=0";

    security.sudo.extraRules = [
      {
        users = [ hostConfig.user.name ];
        commands = [
          {
            command = hostConfig.powerScriptPath;
            options = [ "NOPASSWD" ];
          }
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
  };
}
