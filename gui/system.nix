{
  config,
  pkgs,
  ...
}:
{
  programs.niri.enable = true;
  services.displayManager.ly.enable = true;

  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1"; # wayland support for some chromium applications
  };

  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
  ];
}
