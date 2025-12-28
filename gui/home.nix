{ config, ... }:
{
  imports = [
    ./niri.nix
    ./ghostty.nix
    ./zen-browser.nix
    ./chromium.nix
    ./blender.nix
  ];
}
