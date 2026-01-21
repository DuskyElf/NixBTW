{ config, inputs, pkgs, ... }:
{
  home.packages = [
    inputs.opencode.packages."x86_64-linux".default
    pkgs.libnotify
  ];

  xdg.configFile."opencode".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/opencodeBTW";
}
