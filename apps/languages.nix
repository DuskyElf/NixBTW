{ pkgs, ... }:
{
  home.packages = with pkgs; [
    rustc
    cargo
    clippy
    nodejs
    python3
  ];
}
