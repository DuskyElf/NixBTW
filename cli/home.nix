{ config, pkgs, ... }:
{
  imports = [
    ./sh.nix
    ./git.nix
    ./tmux.nix
    ./nvim.nix
  ];
}
