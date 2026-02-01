{ config, pkgs, lib, ... }:
let
  shellAliases = {
    btw = "echo I use NixOS, btw";
    get-nob = "curl -o nob.h https://raw.githubusercontent.com/tsoding/nob.h/main/nob.h";
  };

  extraShelly = # bash
    ''
      nx() {
        nix-shell -p "$1" --run "$1"
      }
    '';
in
{
  xdg.configFile."scripts" = {
    recursive = true;
    source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/scripts";
  };
  home.packages = with pkgs; [
    lm_sensors
    gnugrep
    fastfetch
  ];

  programs = {
    fzf.enable = true;
    starship.enable = true;
    zoxide = {
      enable = true;
      options = [
        "--cmd"
        "cd"
      ];
    };

    zsh = {
      enable = true;
      inherit shellAliases;
      history = {
        size = 6900;
        save = 6900;
        share = true;
        append = true;
        ignoreDups = true;
        findNoDups = true;
        saveNoDups = true;
        ignoreSpace = true;
        ignoreAllDups = true;
        path = "${config.xdg.dataHome}/zsh/zsh_history";
      };

      syntaxHighlighting.enable = true;
      autosuggestion.enable = true;

      initContent =
        lib.mkOrder 1500 # bash
          (
            ''
              bindkey -v
              bindkey '^f' forward-char # take completions

              # Search along with the command prefix
              bindkey '^p' history-search-backward
              bindkey '^n' history-search-forward
              bindkey -M viins '^?' backward-delete-char
              bindkey -M viins '^H' backward-delete-char

              # Case insensitive completions
              zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
              # Filename completion colors
              zstyle ':completion:*' list-colors "''${(s.:.)LS_COLORS}"
              if command -v tmux &> /dev/null && [ -n "$PS1" ] && [[ ! "$TERM" =~ screen ]] && [[ ! "$TERM" =~ tmux ]] && [ -z "$TMUX" ]; then
                if tmux has-session -t main 2>/dev/null; then
                  exec tmux attach -t main
                else
                  exec tmux new -s main
                fi
              fi
            ''
            + extraShelly
          );
    };

    bash = {
      enable = true;
      inherit shellAliases;
      initExtra = extraShelly;
    };
  };
}
