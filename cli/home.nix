{ config, ... }:
{
  imports = [
    ./sh.nix
    ./git.nix
    ./tmux.nix
    ./nixvim.nix
  ];
}
