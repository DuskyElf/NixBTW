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
in
{
  config = {
    nixpkgs.config.allowUnfree = true;

    # The login account every machine has. Groups are policy, so they stay
    # here; a host with a different login name changes only config.nix.
    users.users.${hostConfig.user.name} = {
      isNormalUser = true;
      shell = pkgs.zsh;
      description = hostConfig.user.description;
      # The system account and home-manager must agree; both read one value.
      home = hostConfig.user.home;
      extraGroups = [
        "networkmanager"
        # No "input": that group reads /dev/input and could keylog the sudo
        # password. keyd runs as a system service; evdev tools get sudo instead.
        "wheel"
      ];
    };

    console.useXkbConfig = true;

    # Very bare bones setup for root, everything else is handled by
    # home-manager. A package that needs config of its own belongs in apps/
    # instead, so it stays findable by name.
    programs.zsh.enable = true;
    programs.gpu-screen-recorder.enable = true;
    programs.thunderbird.enable = true;

    environment.systemPackages = [
      pkgs.gcc
      pkgs.vim
      pkgs.git
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
      pkgs.btop
      pkgs.brightnessctl
      pkgs.coreutils-full

      pkgs.fd
      pkgs.fzf
      pkgs.bat
      pkgs.dust
      pkgs.ripgrep
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

    boot.loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    boot.initrd.systemd.enable = true;

    networking = {
      networkmanager.enable = true;
      hostName = hostConfig.hostName;
      # No LAN ports open on purpose. t3code on 3773 is reached over
      # tailscale serve, never over the local network, which IOT devices
      # share. Keep the app's "Network access" toggle off so it binds
      # loopback only.
      firewall.enable = true;
    };

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

    # Governs the CPU on battery and charger. It is a laptop policy, so a host
    # with no battery does not install it.
    services.auto-cpufreq = lib.mkIf (hostConfig.hardware.battery != null) {
      enable = true;
      settings = {
        battery = {
          governor = "powersave";
          turbo = "never";
        };
        charger = {
          governor = "powersave";
          turbo = "auto";
        };
      };
    };

    time.timeZone = hostConfig.timeZone;
    i18n.defaultLocale = hostConfig.locale.default;

    nix.settings = {
      # Trusted users can make the daemon run a post-build hook as root and
      # disable the sandbox, so trust belongs to root only.
      trusted-users = lib.mkForce [ "root" ];

      # Caches every host can use. A host that publishes its own builds adds
      # them, with the matching key, in its system.nix.
      substituters = [
        "https://cache.nixos.org"
        "https://cache.nixos-cuda.org"
      ];

      trusted-public-keys = [
        "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
      ];

      experimental-features = [
        "nix-command"
        "flakes"
      ];
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

    i18n.extraLocaleSettings = lib.mkIf (hostConfig.locale.extra != null) {
      LC_ADDRESS = hostConfig.locale.extra;
      LC_IDENTIFICATION = hostConfig.locale.extra;
      LC_MEASUREMENT = hostConfig.locale.extra;
      LC_MONETARY = hostConfig.locale.extra;
      LC_NAME = hostConfig.locale.extra;
      LC_NUMERIC = hostConfig.locale.extra;
      LC_PAPER = hostConfig.locale.extra;
      LC_TELEPHONE = hostConfig.locale.extra;
      LC_TIME = hostConfig.locale.extra;
    };

    system.activationScripts.powerScript = ''
      mkdir -p ${builtins.dirOf hostConfig.powerScriptPath}
      ln -sfn ${lib.getExe powerScript} ${hostConfig.powerScriptPath}
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
        ];
      }
    ];

    system.stateVersion = hostConfig.stateVersion.system; # Leave it as it is
  };
}
