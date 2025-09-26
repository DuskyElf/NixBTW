{
  config,
  pkgs,
  ...
}:
{
  # Very bare bones setup for root, everything else is handled by home-manager
  programs.zsh.enable = true;

  environment.systemPackages = with pkgs; [
    vim
    git
    wget
    brightnessctl
  ];
}
