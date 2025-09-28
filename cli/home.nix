{ config, ... }:
{
  imports = [
    ./sh.nix
    ./git.nix
    ./tmux.nix
  ];
}
