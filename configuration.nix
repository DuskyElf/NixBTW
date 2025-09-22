{
  config,
  pkgs,
  hostName,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = hostName;
  networking.networkmanager.enable = true;

  services.displayManager.ly.enable = true;
  programs.zsh.enable = true;
  programs.niri.enable = true;
  programs.firefox.enable = true;

  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    vim
    git
    wget

    waydroid-helper
  ];

  virtualisation.waydroid.enable = true;

  console.useXkbConfig = true;
  services.xserver.xkbOptions = "ctrl:swapcaps";

  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
  ];

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

  hardware = {
    graphics = {
      enable = true;
      extraPackages = with pkgs; [
        intel-media-driver
        libvdpau-va-gl
        vpl-gpu-rt
        #intel-media-sdk # for older iGPUs
      ];
    };
  };
  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "iHD";
    NIXOS_OZONE_WL = "1";
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  users.users.duskyelf = {
    shell = pkgs.zsh;
    isNormalUser = true;
    description = "DuskyElf";
    extraGroups = [
      "networkmanager"
      "wheel"
    ];
    packages = with pkgs; [ ];
  };

  time.timeZone = "Asia/Kolkata";
  i18n.defaultLocale = "en_US.UTF-8";
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

  system.stateVersion = "25.05"; # Leave it as it is
}
