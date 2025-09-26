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
      source-file ${config.xdg.configHome}/tmux/hotreloaded.conf
      bind R source-file ${config.xdg.configHome}/tmux/tmux.conf
    '';

    plugins = with pkgs; [
      {
        plugin = tmuxPlugins.resurrect;
        extraConfig = ''
          set -g @resurrect-save '^S'
          set -g @resurrect-restore '`'
          set -g @resurrect-strategy-nvim 'session'
        '';
      }
      {
        plugin = tmuxPlugins.tmux-sessionx;
        extraConfig = ''
          set -g @sessionx-bind '^O'
          set -g @sessionx-x-path ""
          set -g @sessionx-tree-mode 'on'
          set -g @sessionx-zoxide-mode 'on'
          set -g @sessionx-fzf-builtin-tmux 'on'
          set -g @sessionx-filter-current 'false'
        '';
      }
    ];
  };

  xdg.configFile."tmux/hotreloaded.conf".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/hot-configs/tmux.conf";

}
