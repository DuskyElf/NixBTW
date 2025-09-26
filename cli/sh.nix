{ config, lib, ... }:
let
  shellAliases = {
    btw = "echo I use NixOS, btw";
  };

  extraShelly = # bash
    ''
      nx() {
        nix-shell -p "$1" --run "$1"
      }
    '';
in
{
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
