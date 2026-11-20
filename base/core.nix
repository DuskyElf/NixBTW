# What every machine in this repo gets: the account, the hostname, the time zone,
# the nix daemon settings, and the handful of packages that are useful without a
# desktop. Everything that assumes a screen, a battery, or a keyboard in front of
# a person lives in base/workstation.nix, and a host lists that file only if it is
# such a machine. The bootloader is per host too: it is hardware, and it lives in
# hosts/<name>/system.nix.
{
  lib,
  pkgs,
  hostConfig,
  ...
}:
{
  nixpkgs.config.allowUnfree = true;

  # The login account every machine has. Groups are policy, so they stay here;
  # a host with a different login name changes only config.nix.
  users.users.${hostConfig.user.name} = {
    isNormalUser = true;
    shell = pkgs.${hostConfig.user.shell};
    description = hostConfig.user.description;
    # The system account and home-manager must agree; both read one value.
    home = hostConfig.user.home;
    # A headless host has no login session to run the daily user timer, so its
    # user manager starts at boot instead. The laptop leaves this off: its timer
    # is part of the graphical session.
    linger = lib.mkIf hostConfig.dailyUpdate.linger true;
    extraGroups = [
      # No "input": that group reads /dev/input and could keylog the sudo
      # password. keyd runs as a system service; evdev tools get sudo instead.
      "wheel"
    ];
  };

  # The bootloader is per host (hosts/<name>/system.nix): it is hardware.

  boot.initrd.systemd.enable = true;

  networking = {
    hostName = hostConfig.hostName;
    # No LAN-facing services are declared here on purpose. t3code on 3773 is
    # reached over tailscale serve, never over the local network, which IOT
    # devices share. Keep the app's "Network access" toggle off so it binds
    # loopback only. A host that needs a LAN service opens that one port where
    # it declares the service: ssh.openLanPort in the host schema is one
    # example, and apps/hermes/system.nix opens the homelab's dashboard port
    # because hermes.dashboard.host names a LAN address.
    firewall.enable = true;
  };

  # A fresh sudo timestamp from any authenticated command would let the login
  # user run `sudo -n <anything>` for the timeout, which is exactly what the
  # NOPASSWD helper rules are meant to avoid. Every host has one now, so the
  # cache is off everywhere.
  security.sudo.extraConfig = "Defaults timestamp_timeout=0";

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

  # Regional formats only (dates, numbers, paper); strings stay at the default
  # locale. Null leaves every LC_* category alone.
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

  # Very bare bones setup for root, everything else is handled by
  # home-manager. A package that needs config of its own belongs in apps/
  # instead, so it stays findable by name. Only the core six are here; the
  # desktop tools are in base/workstation.nix so a headless host does not
  # install them.
  environment.systemPackages = [
    pkgs.vim
    pkgs.git
    pkgs.coreutils-full
    pkgs.btop
    pkgs.ripgrep
    pkgs.fd
  ];

  system.stateVersion = hostConfig.stateVersion.system; # Leave it as it is
}
