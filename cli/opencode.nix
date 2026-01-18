{ config, inputs, ... }:
{
  home.packages = [
    inputs.opencode.packages."x86_64-linux".default
  ];

  xdg.configFile."opencode".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/opencodeBTW";
}
