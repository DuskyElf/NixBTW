{ ... }:
{
  imports = [
    ./sh.nix
    ./git.nix
    ./tmux.nix
    ./nvim.nix
    ./languages.nix
    ./local-llm.nix
    ./pi-coding-agent.nix
    ./opencode.nix
  ];
}
