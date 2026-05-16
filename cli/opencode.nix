{
  config,
  pkgs,
  pkgs-unstable,
  ...
}:
{
  home.packages = [
    pkgs-unstable.opencode
    pkgs.libnotify
  ];

  xdg.configFile."opencode".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/opencodeBTW";
}
