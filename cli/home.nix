{ config, pkgs, inputs, ... }:
{
  imports = [
    ./sh.nix
    ./git.nix
    ./tmux.nix
    ./nvim.nix
  ];

  home.packages = [
    inputs.opencode.packages."x86_64-linux".default
  ];
}
