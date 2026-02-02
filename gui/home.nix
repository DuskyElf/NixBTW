{ config, ... }:
{
  imports = [
    ./niri.nix
    ./kitty.nix
    ./zen-browser.nix
    ./chromium.nix
    ./blender.nix
    ./antigravity.nix
  ];
}
