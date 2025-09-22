{ config, pkgs, lib, ... }:

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

    fzf.enable = true;
    starship.enable = true;

    zoxide = {
      enable = true;
      options = [
        "--cmd"
        "cd"
      ];
    };

    tmux = {
      enable = true;
      mouse = true;
      keyMode = "vi";
      customPaneNavigationAndResize = true;

      extraConfig = '' 
        set-option -g status-position top
      '';

      plugins = with pkgs; [
        {
          plugin = tmuxPlugins.catppuccin;
        }
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

      initContent = # bash
      ''
        bindkey -e
        # Search along with the command prefix
        bindkey '^p' history-search-backward
        bindkey '^n' history-search-forward

        # Case insensitive completions
        zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
        # Filename completion colors
        zstyle ':completion:*' list-colors "''${(s.:.)LS_COLORS}"
      ''
      + extraShelly;

      syntaxHighlighting.enable = true;
      plugins = [
        {
          name = "zsh-autosuggestions";
          src = pkgs.zsh-autosuggestions;
          file = "share/zsh-autosuggestions/zsh-autosuggestions.zsh";
        }
      ];
    };

    bash = {
      enable = true;
      inherit shellAliases;
      initExtra = extraShelly;
    };

    alacritty = {
      enable = true;
      settings = {
        window = {
          opacity = lib.mkForce 0.9;
          padding = {
            x = 10;
            y = 10;
          };
        };
      };
    };

    zen-browser = {
      enable = true;
    };

    niri = {
      package = pkgs.niri;

      settings = {
        input = {
          touchpad = {
            drag = false;
            middle-emulation = true;
          };
          warp-mouse-to-focus.enable = true;
          keyboard.xkb.options = "ctrl:swapcaps";
        };

        outputs = {
          "eDP-1" = {
            focus-at-startup = true;
            mode = {
              width = 3840;
              height = 2160;
            };
            position = {
              x = 0;
              y = 0;
            };
            scale = 2.5;
          };

          "DP-2" = {
            mode = {
              width = 3840;
              height = 1100;
            };
            position = {
              x = 0;
              y = 864;
            };
            scale = 2.5;
          };
        };

        cursor = {
          size = 48;
          hide-when-typing = true;
        };

        layout = {
          gaps = 32;
          border.enable = false;
          always-center-single-column = true;
          default-column-width.proportion = 0.85;

          empty-workspace-above-first = true;

          default-column-display = "tabbed";
          tab-indicator.hide-when-single-tab = true;

          focus-ring = {
            enable = true;
            width = 1;
          };

          shadow = {
            enable = true;
            spread = 10;
            softness = 15;
          };
        };

        window-rules = [
          {
            clip-to-geometry = true;
            geometry-corner-radius = {
              top-left = 7.0;
              top-right = 7.0;
              bottom-left = 7.0;
              bottom-right = 7.0;
            };
          }
        ];

        binds = with config.lib.niri.actions; {
          "Mod+Shift+Slash".action = show-hotkey-overlay;
          "Super+Alt+L".action = spawn "swaylock";

          "Mod+P" = {
            repeat = false;
            action = toggle-overview;
          };
          "Mod+C".action = center-column;
          "Mod+H".action = focus-column-left;
          "Mod+L".action = focus-column-right;
          "Mod+J".action = focus-window-or-workspace-down;
          "Mod+K".action = focus-window-or-workspace-up;
          "Mod+Shift+J".action = focus-monitor-down;
          "Mod+Shift+K".action = focus-monitor-up;
          "Mod+Shift+H".action = move-column-to-monitor-down;
          "Mod+Shift+L".action = move-column-to-monitor-up;

          "Mod+A".action = move-column-left;
          "Mod+D".action = move-column-right;
          "Mod+W".action = move-window-up-or-to-workspace-up;
          "Mod+S".action = move-window-down-or-to-workspace-down;
          "Mod+Comma".action = consume-window-into-column;
          "Mod+Period".action = expel-window-from-column;
          "Mod+BracketLeft".action = consume-or-expel-window-left;
          "Mod+BracketRight".action = consume-or-expel-window-right;

          "Mod+F".action = maximize-column;
          "Mod+Shift+F".action = fullscreen-window;
          "Mod+R".action = switch-preset-column-width;
          "Mod+Shift+R".action = switch-preset-window-height;
          "Mod+M".action = expand-column-to-available-width;
          "Mod+Minus".action = set-column-width "-10%";
          "Mod+Equal".action = set-column-width "+10%";
          "Mod+Shift+Minus".action = set-window-height "-10%";
          "Mod+Shift+Equal".action = set-window-height "+10%";

          "Mod+V".action = toggle-window-floating;
          "Mod+Shift+V".action = switch-focus-between-floating-and-tiling;

          "Mod+G".action = toggle-column-tabbed-display;

          "Mod+Q" = {
            repeat = false;
            action = close-window;
          };
          "Mod+T".action = spawn "alacritty";
          "Mod+O".action = spawn "fuzzel";

          "XF86AudioMute" = {
            allow-when-locked = true;
            action = spawn "wpctl" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle";
          };
          "XF86AudioRaiseVolume" = {
            allow-when-locked = true;
            action = spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.1+";
          };
          "XF86AudioLowerVolume" = {
            allow-when-locked = true;
            action = spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.1-";
          };

          "XF86MonBrightnessUp" = {
            allow-when-locked = true;
            action = spawn "brightnessctl" "--class=backlight" "set" "2%+";
          };
          "XF86MonBrightnessDown" = {
            allow-when-locked = true;
            action = spawn "brightnessctl" "--class=backlight" "set" "2%-";
          };

          "Mod+TouchpadScrollDown" = {
            allow-when-locked = true;
            action = spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.02+";
          };
          "Mod+TouchpadScrollUp" = {
            allow-when-locked = true;
            action = spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.02-";
          };

          "Mod+Alt+TouchpadScrollDown" = {
            allow-when-locked = true;
            action = spawn "brightnessctl" "--class=backlight" "set" "1+";
          };
          "Mod+Alt+TouchpadScrollUp" = {
            allow-when-locked = true;
            action = spawn "brightnessctl" "--class=backlight" "set" "1-";
          };

          "Print".action = screenshot;
          "Alt+Print".action = screenshot-window;

          "Mod+Escape" = {
            allow-inhibiting = false;
            action = toggle-keyboard-shortcuts-inhibit;
          };

          "Mod+Shift+E".action = quit;
        };

        prefer-no-csd = true;
        hotkey-overlay.skip-at-startup = true;
        spawn-at-startup = [
          { argv = [ "waybar" ]; }
        ];
      };
    };

    fuzzel.enable = true;
    waybar.enable = true;
    swaylock.enable = true;
  };

  services = {
    mako.enable = true;
    polkit-gnome.enable = true;
  };

  home.packages = with pkgs; [
    swaybg
    brightnessctl
  ];

  stylix = {
    enable = true;
    polarity = "dark";
    fonts.monospace = {
      package = pkgs.nerd-fonts.jetbrains-mono;
      name = "JetBrainsMonoNerdFontMono";
    };
    base16Scheme = "${pkgs.base16-schemes}/share/themes/catppuccin-mocha.yaml";
  };

  # Don't change
  home.stateVersion = "25.05";
  programs.home-manager.enable = true;
}
