{
  config,
  pkgs,
  ...
}:
{
  # Very bare bones setup for root, everything else is handled by home-manager
  programs.zsh.enable = true;
  programs.gpu-screen-recorder.enable = true;

  environment.systemPackages = with pkgs; [
    gcc
    vim
    git
    wget
    curl
    brightnessctl
    coreutils-full

    fd
    fzf
    bat
    dust
    ripgrep
    tealdeer

    gpu-screen-recorder-gtk
  ];
}
