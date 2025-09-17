{ config, pkgs, ... }:

let
  shellAliases = {
    btw = "echo I use NixOS, btw";
  };

  extraShelly = /*bash*/''
    nx() {
      nix-shell -p "$1" --run "$1"
    }
  '';
in {
  home.username = "duskyelf";
  home.homeDirectory = "/home/duskyelf";

  xdg.enable = true;

  programs = {
    git = {
      enable = true;
      userName = "DuskyElf";
      userEmail = "91879372+DuskyElf@users.noreply.github.com";
      extraConfig = {
        init.defaultBranch = "main";
      };
    };

    fzf = {
      enable = true;
      enableZshIntegration = true;
    };

    zoxide = {
      enable = true;
      enableZshIntegration = true;
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

      initContent = /*bash*/''
        bindkey -e
        # Search along with the command prefix
        bindkey '^p' history-search-backward
        bindkey '^n' history-search-forward

        # Case insensitive completions
        zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
        # Filename completion colors
        zstyle ':completion:*' list-colors "''${(s.:.)LS_COLORS}"
      '' + extraShelly;

      syntaxHighlighting.enable = true;
      plugins = [{
        name = "zsh-autosuggestions";
        src = pkgs.zsh-autosuggestions;
        file = "share/zsh-autosuggestions/zsh-autosuggestions.zsh";
      }];
    };

    bash = {
      enable = true;
      inherit shellAliases;
      initExtra = extraShelly;
    };
  };

  # Don't change
  home.stateVersion = "25.05";
  programs.home-manager.enable = true;
}
