{ config, inputs, pkgs, ... }:
{
  home.packages = [
    inputs.opencode.legacyPackages."x86_64-linux".opencode
    pkgs.libnotify
  ];

  xdg.configFile."opencode".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/opencodeBTW";
}
