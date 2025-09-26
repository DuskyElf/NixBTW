{ config, ... }:
{
  imports = [
    ./niri.nix
    ./alacritty.nix
    ./zen-browser.nix
  ];
}
