{
  config,
  lib,
  pkgs,
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
    text = lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./scripts/power.sh);
  };
in
{
  options.hostOptions = {
    hostName = lib.mkOption {
      type = lib.types.str;
    };
  };

  config = {
    nixpkgs.config.allowUnfree = true;

    console.useXkbConfig = true;

    boot.loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    boot.initrd.systemd.enable = true;

    networking = {
      networkmanager.enable = true;
      hostName = config.hostOptions.hostName;
      # No LAN ports open on purpose. t3code on 3773 is reached over
      # tailscale serve, never over the local network, which IOT devices
      # share. Keep the app's "Network access" toggle off so it binds
      # loopback only.
      firewall.enable = true;
    };

    # Tailscale gives the phone a stable private route to the t3code
    # server on 3773 from any network. MagicDNS name: asus.<tailnet>.ts.net
    # --operator lets duskyelf run `tailscale serve`, which the t3code
    # desktop app calls to publish the backend over HTTPS on the tailnet.
    services.tailscale = {
      enable = true;
      openFirewall = true;
      extraSetFlags = [ "--operator=duskyelf" ];
    };

    services.blueman.enable = true;
    hardware.bluetooth.enable = true;

    # for better battery life keep it at 80%
    systemd.services.battery-threshold-control = {
      script = ''
        echo "80" > /sys/class/power_supply/BAT0/charge_control_end_threshold
      '';
      wantedBy = [ "multi-user.target" ];
    };

    services.auto-cpufreq = {
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

    time.timeZone = "Asia/Kolkata";
    i18n.defaultLocale = "en_US.UTF-8";

    nix.settings = {
      # Trusted users can make the daemon run a post-build hook as root and
      # disable the sandbox, so trust belongs to root only.
      trusted-users = lib.mkForce [ "root" ];

      substituters = [
        "https://cache.nixos.org"
        "https://cache.nixos-cuda.org"
        "https://duskyelf.github.io/NixBTW"
      ];

      trusted-public-keys = [
        "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
        # Custom kernel cache: narinfos on gh-pages, nars in GitHub releases.
        # Key name must match the NIX_SECRET_KEY signer exactly or lookups
        # miss silently and the kernel builds here instead.
        "i9-kernel-cache:4R0pqOZkrRj4utTbF4zP05Y58QSgShLqQ77KUPzFjwk="
      ];

      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };

    # Weekly store hygiene. The GC keeps 14 days of history and only drops
    # paths no generation, profile, or gcroot references. The optimiser
    # hardlinks identical files, which is why du and df disagree on /nix/store.
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
    nix.optimise = {
      automatic = true;
      dates = [ "weekly" ];
    };

    i18n.extraLocaleSettings = {
      LC_ADDRESS = "en_IN";
      LC_IDENTIFICATION = "en_IN";
      LC_MEASUREMENT = "en_IN";
      LC_MONETARY = "en_IN";
      LC_NAME = "en_IN";
      LC_NUMERIC = "en_IN";
      LC_PAPER = "en_IN";
      LC_TELEPHONE = "en_IN";
      LC_TIME = "en_IN";
    };

    system.activationScripts.powerScript = ''
      mkdir -p /usr/local/sbin
      ln -sfn ${lib.getExe powerScript} /usr/local/sbin/power.sh
    '';

    # Disable the credential cache: a fresh sudo timestamp (e.g. from a
    # rebuild) would otherwise let anything running as duskyelf
    # `sudo -n <anything>` within the window. NOPASSWD keybind rule is
    # unaffected, but every other sudo now prompts fresh.
    security.sudo.extraConfig = "Defaults timestamp_timeout=0";

    security.sudo.extraRules = [
      {
        users = [ "duskyelf" ];
        commands = [
          {
            command = "/usr/local/sbin/power.sh";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    system.stateVersion = "25.11"; # Leave it as it is
  };
}
