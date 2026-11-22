# Zsh and the interactive tools that hang off it. A host takes this only if zsh
# is its shell; a machine that logs in with bash lists apps/bash.nix instead and
# never evaluates any of this.
{
  config,
  lib,
  ...
}:
let
  # `nx <name>` runs a nix-shell of one package. Both shells install it, so each
  # shell module carries the definition: a host that takes bash without zsh must
  # still get the function, and the two modules must not need each other.
  extraShelly = ''
    nx() {
      nix-shell -p "$1" --run "$1"
    }
  '';
in
{
  programs = {
    fzf.enable = true;
    starship = {
      enable = true;
      settings = {
        git_branch.disabled = true;
        git_commit.disabled = true;
        git_state.disabled = true;
        git_metrics.disabled = true;
        git_status.disabled = true;
      };
    };
    zoxide = {
      enable = true;
      options = [
        "--cmd"
        "cd"
      ];
    };

    zsh = {
      enable = true;
      dotDir = "${config.xdg.configHome}/zsh";
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
              # Only auto-attach inside foot (TERM=foot*), and never over ssh,
              # which forwards TERM from the local terminal. Other terms
              # (t3code, etc.) get plain zsh. TMUX still matters as the guard
              # for a configuration that gives panes TERM=foot.
              if command -v tmux &> /dev/null && [ -n "$PS1" ] && [[ "$TERM" == foot* ]] && [ -z "$SSH_CONNECTION" ] && [ -z "$TMUX" ]; then
                if tmux has-session -t main 2>/dev/null; then
                  tmux attach -t main
                else
                  tmux new -s main
                fi
              fi
            ''
            + extraShelly
          );
    };
  };
}
