{ config, pkgs, ... }:

{
  home.username = "duskyelf";
  home.homeDirectory = "/home/duskyelf";

  programs = {
    git = {
      enable = true;
      userName = "DuskyElf";
      userEmail = "91879372+DuskyElf@users.noreply.github.com";
      extraConfig = {
        init.defaultBranch = "main";
      };
    };

    bash = {
      enable = true;
      shellAliases = {
        btw = "echo I use NixOS, btw";
      };
    };
  };

  # Don't change
  home.stateVersion = "25.05";
  programs.home-manager.enable = true;
}
