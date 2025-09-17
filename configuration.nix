{ config, pkgs, hostName, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = hostName;
  networking.networkmanager.enable = true;

  services.displayManager.ly.enable = true;
  programs.niri.enable = true;
  programs.zsh.enable = true;
  programs.starship.enable = true;
  programs.firefox.enable = true;
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    vim
    git
    fzf
    wget

    wofi
    alacritty

    brightnessctl
  ];

  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  users.users.duskyelf = {
    shell = pkgs.zsh;
    isNormalUser = true;
    description = "DuskyElf";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [];
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
