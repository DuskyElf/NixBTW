{
  config,
  hostConfig,
  pkgs,
  lib,
  ...
}:
let
  extraShelly = ''
    nx() {
      nix-shell -p "$1" --run "$1"
    }
  '';
in
{
  home.shellAliases = {
    btw = "echo I use NixOS, btw";
    get-nob = "curl -o nob.h https://raw.githubusercontent.com/tsoding/nob.h/main/nob.h";
  };

  xdg.configFile."scripts/hm-switch.sh".source =
    config.lib.file.mkOutOfStoreSymlink "${hostConfig.dotsDir}/apps/home-switch/hm-switch.sh";

  # The old generation linked ~/.config/scripts to a directory outside the new
  # tree (a store copy or the live scripts/ dir). After the move that link
  # dangles, cleanup can skip it, and linkGeneration's mkdir -p then fails on
  # it. Drop any symlink at that path before linking; a real directory is left
  # alone, and readlink is empty for anything but a symlink.
  home.activation.dropStaleScriptsLink = config.lib.dag.entryBefore [ "linkGeneration" ] ''
    stale=$(readlink "$HOME/.config/scripts" 2>/dev/null || true)
    if [ -n "$stale" ]; then
      run rm -f "$HOME/.config/scripts"
    fi
  '';

  home.packages = with pkgs; [
    lm_sensors
    gnugrep
    fastfetch
  ];

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
              # Only auto-attach inside kitty (KITTY_WINDOW_ID). Other terms (t3code, etc.) get plain zsh.
              if command -v tmux &> /dev/null && [ -n "$PS1" ] && [ -n "$KITTY_WINDOW_ID" ] && [[ ! "$TERM" =~ screen ]] && [[ ! "$TERM" =~ tmux ]] && [ -z "$TMUX" ]; then
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

    bash = {
      enable = true;
      initExtra = extraShelly;
    };
  };
}
