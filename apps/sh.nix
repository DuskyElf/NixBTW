# The aliases and small tools every shell on a machine shares. The shells
# themselves are separate opt-ins (apps/zsh.nix, apps/bash.nix) and so is the
# home switch link (apps/home-switch.nix); this file only sets what does not
# depend on which shell reads it.
{
  pkgs,
  ...
}:
{
  home.shellAliases = {
    btw = "echo I use NixOS, btw";
    get-nob = "curl -o nob.h https://raw.githubusercontent.com/tsoding/nob.h/main/nob.h";
  };

  home.packages = with pkgs; [
    lm_sensors
    gnugrep
    fastfetch
  ];
}
