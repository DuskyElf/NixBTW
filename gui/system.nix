{
  pkgs,
  ...
}:
{
  programs.niri.enable = true;
  services.displayManager.ly.enable = true;

  programs.thunderbird.enable = true;

  environment.systemPackages = with pkgs; [
    wl-clipboard
    libnotify
  ];

  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1"; # wayland support for some chromium applications
  };

  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
  ];

  services.keyd = {
    enable = true;
    keyboards = {
      default = {
        ids = [ "*" ];

        settings = {
          global = {
            macro_sequence_timeout = 10;
          };
          main = {
            control = "capslock";
            capslock = "overload(control, escape)";
          };
        };
      };
    };
  };
}
