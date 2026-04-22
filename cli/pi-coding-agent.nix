{
  config,
  pkgs-unstable,
  ...
}:
{
  home.packages = [
    pkgs-unstable.pi-coding-agent
  ];

  home.file.".pi".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/piBTW";
}