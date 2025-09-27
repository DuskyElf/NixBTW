{
  config,
  pkgs,
  lib,
  ...
}:
{
  programs.tmux = {
    enable = true;

    extraConfig = ''
      unbind -a

      run-shell ${pkgs.tmuxPlugins.resurrect.rtp}
      run-shell ${pkgs.tmuxPlugins.tmux-sessionx.rtp}

      source-file ${config.xdg.configHome}/tmux/hotreloaded.conf
      bind R source-file ${config.xdg.configHome}/tmux/tmux.conf
    '';
  };

  xdg.configFile."tmux/hotreloaded.conf".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/hot-configs/tmux.conf";

}
