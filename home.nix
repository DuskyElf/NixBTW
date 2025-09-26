{
  config,
  pkgs,
  ...
}:

{
  xdg.enable = true;
  home.username = "duskyelf";
  home.homeDirectory = "/home/duskyelf";

  stylix = {
    enable = true;
    polarity = "dark";
    fonts.monospace = {
      package = pkgs.nerd-fonts.jetbrains-mono;
      name = "JetBrainsMonoNerdFontMono";
    };
    base16Scheme = "${pkgs.base16-schemes}/share/themes/catppuccin-mocha.yaml";
  };

  # Don't change
  home.stateVersion = "25.05";
  programs.home-manager.enable = true;
}
