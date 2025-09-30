{
  config,
  lib,
  ...
}:
{
  programs.alacritty = {
    enable = true;
    settings = {
      colors.primary.background = lib.mkForce "#181818";
      window = {
        opacity = lib.mkForce 0.85;
        padding.x = 10;
      };
      env = {
        TERM = "xterm-256color";
      };
    };
  };
}
