{
  config,
  lib,
  ...
}:
{
  programs.alacritty = {
    enable = true;
    settings = {
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
