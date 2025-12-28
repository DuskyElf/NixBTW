{
  config,
  lib,
  ...
}:
{
  programs.ghostty = {
    enable = true;
    settings = {
      background = "#181818";
      custom-shader = "cursor_warp.glsl";
    };
  };

  xdg.configFile."ghostty/cursor_warp.glsl".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/hot-configs/ghostty/cursor_warp.glsl";
}
