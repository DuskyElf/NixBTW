{
  pkgs,
  jail,
  ...
}:
{
  # Very bare bones setup for root, everything else is handled by home-manager
  programs.zsh.enable = true;
  programs.gpu-screen-recorder.enable = true;

  environment.systemPackages = [
    pkgs.gcc
    pkgs.vim
    pkgs.git
    (jail "wget" pkgs.wget (
      c: with c; [
        network
        mount-cwd
      ]
    ))
    (jail "curl" pkgs.curl (
      c: with c; [
        network
        mount-cwd
      ]
    ))
    pkgs.btop
    pkgs.undervolt
    pkgs.brightnessctl
    pkgs.coreutils-full
    pkgs.intel-gpu-tools

    pkgs.fd
    pkgs.fzf
    pkgs.bat
    pkgs.dust
    pkgs.ripgrep
    pkgs.tealdeer

    pkgs.gpu-screen-recorder-gtk
  ];
}
