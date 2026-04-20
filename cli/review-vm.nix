{
  config,
  pkgs,
  ...
}:

{
  microvm = {
    hypervisor = "qemu";
    mem = 15360;
    vcpu = 12;

    interfaces = [
      {
        type = "user";
        id = "qemu";
        mac = "02:00:00:00:00:01";
      }
    ];

    writableStoreOverlay = "/nix/.rw-store";

    shares = [
      {
        proto = "9p";
        tag = "nixpkgs";
        source = "/home/duskyelf/Projects/nixpkgs";
        mountPoint = "/home/reviewer/nixpkgs-host";
        readOnly = true;
      }
    ];
  };

  # Automatically log in the reviewer user on the serial console
  services.getty.autologinUser = "reviewer";

  users.users.reviewer = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" ];
    password = ""; # No password for local login
  };

  # Ensure the reviewer user doesn't need a password for sudo just in case
  security.sudo.wheelNeedsPassword = false;

  # Increase root tmpfs size to prevent "No space left on device" errors during large builds
  fileSystems."/" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "size=12G" "mode=755" ];
  };

  # Setup reviewer environment
  systemd.services.setup-reviewer = {
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      # Create a fast, native git clone that shares the object database with the host
      # This completely bypasses all 9p permission/metadata issues while using zero extra RAM/disk
      if [ ! -d /home/reviewer/nixpkgs/.git ]; then
        ${pkgs.sudo}/bin/sudo -u reviewer ${pkgs.git}/bin/git clone --shared /home/reviewer/nixpkgs-host /home/reviewer/nixpkgs
      fi
    '';
  };

  # Enable Nix flakes
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Enable zram swap to survive heavy nix evaluation
  zramSwap.enable = true;
  zramSwap.memoryPercent = 100;

  environment.systemPackages = with pkgs; [
    nixpkgs-review
    gh
  ];

  programs.git = {
    enable = true;
    config = {
      safe.directory = "*";
    };
  };

  # Microvm requires a state version
  system.stateVersion = "25.11";
}
