{
  config,
  pkgs,
  ...
}:

{
  microvm = {
    hypervisor = "qemu";
    mem = 8192;
    vcpu = 12;

    interfaces = [
      {
        type = "user";
        id = "qemu";
        mac = "02:00:00:00:00:01";
      }
    ];

    shares = [
      {
        proto = "virtiofs";
        tag = "nixpkgs";
        source = "/home/duskyelf/Projects/nixpkgs";
        mountPoint = "/home/reviewer/nixpkgs";
      }
    ];
  };

  # Automatically log in the reviewer user on the serial console
  services.getty.autologinUser = "reviewer";

  users.users.reviewer = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    password = ""; # No password for local login
  };

  # Ensure the reviewer user doesn't need a password for sudo just in case
  security.sudo.wheelNeedsPassword = false;

  # Enable Nix flakes
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Install required packages
  environment.systemPackages = with pkgs; [
    nixpkgs-review
    git
    gh
  ];

  # Microvm requires a state version
  system.stateVersion = "24.11";
}
