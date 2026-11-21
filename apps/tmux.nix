{
  config,
  hostConfig,
  pkgs,
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

  # Hot-reloaded from the checkout, not the store: tmux.conf is a live link, so
  # an edit applies on the next `source-file`, while the rest of this module
  # still needs a home switch.
  xdg.configFile."tmux/hotreloaded.conf".source =
    config.lib.file.mkOutOfStoreSymlink "${hostConfig.dotsDir}/apps/tmux/tmux.conf";

}
