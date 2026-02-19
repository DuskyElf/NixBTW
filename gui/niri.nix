{
  config,
  pkgs,
  inputs,
  ...
}:
let
  niriNativeOverlay =
    final: prev:
    let
      niriOverlay = inputs.niri.overlays.niri;
      base = niriOverlay final prev;
    in
    base
    // {
      niri-unstable = base.niri-unstable.overrideAttrs (old: {
        env = (old.env or {}) // {
          RUSTFLAGS = (old.env.RUSTFLAGS or "") + " -C target-cpu=native";
        };
      });
    };

  niri-native-pkgs = pkgs.extend niriNativeOverlay;
in
{
  services = {
    mako.enable = true;
    polkit-gnome.enable = true;
  };

  home.packages = with pkgs; [
    swaybg
    wtype
  ];

  programs.voxtype = {
    enable = true;
    package = inputs.voxtype.packages."x86_64-linux".vulkan;
    model.name = "base.en";
    service.enable = true;

    # All config options go in settings (converted to config.toml)
    settings = {
      state_file = "auto";
      hotkey.enabled = false; # Use compositor keybindings instead
      audio = {
        device = "default";
        sample_rate = 16000;
        max_duration_secs = 60;

        feedback = {
          enabled = true;
          theme = "default";
          volume = 0.7;
        };
      };
      output.mode = "type";
      whisper.language = "en";
    };
  };

  programs = {
    fuzzel.enable = true;
    swaylock.enable = true;

    niri = {
      package = niri-native-pkgs.niri-unstable;

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
          gaps = 0;
          empty-workspace-above-first = true;
          always-center-single-column = true;
          default-column-width.proportion = 1.0;
          tab-indicator.hide-when-single-tab = true;

          focus-ring.enable = false;
          border.enable = false;
          shadow.enable = false;
        };

        binds = with config.lib.niri.actions; {
          # Vim-style keybindings via wtype
          "Alt+J".action = spawn "wtype" "-m" "alt" "-k" "down";
          "Alt+K".action = spawn "wtype" "-m" "alt" "-k" "up";
          "Alt+H".action = spawn "wtype" "-m" "alt" "-k" "left";
          "Alt+L".action = spawn "wtype" "-m" "alt" "-k" "right";
          "Alt+B".action = spawn "wtype" "-m" "alt" "-M" "ctrl" "-k" "left";
          "Alt+E".action = spawn "wtype" "-m" "alt" "-M" "ctrl" "-k" "right";
          "Alt+A".action = spawn "wtype" "-m" "alt" "-k" "home";
          "Alt+I".action = spawn "wtype" "-m" "alt" "-k" "end";
          "Alt+U".action = spawn "wtype" "-m" "alt" "-k" "page_up";
          "Alt+D".action = spawn "wtype" "-m" "alt" "-k" "page_down";
          "Alt+N".action = spawn "wtype" "-m" "alt" "-k" "down";
          "Alt+P".action = spawn "wtype" "-m" "alt" "-k" "up";
          "Alt+BRACKETLEFT".action = spawn "wtype" "-m" "alt" "-k" "escape";

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
          "Mod+T".action = spawn "kitty";
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

          # FIXME: tracked in https://github.com/sodiboo/niri-flake/issues/922
          "Print".action.screenshot = [ ];
          "Alt+Print".action.screenshot-screen = [ ];

          "Mod+Escape" = {
            allow-inhibiting = false;
            action = toggle-keyboard-shortcuts-inhibit;
          };

          "Mod+Shift+E".action = quit;

          "Mod+semicolon" = {
            repeat = false;
            action = spawn "voxtype" "record" "start";
          };

          "Mod+apostrophe" = {
            repeat = false;
            action = spawn "voxtype" "record" "stop";
          };
        };

        prefer-no-csd = true;
        hotkey-overlay.skip-at-startup = true;
        spawn-at-startup = [
          { argv = [ "kitty" ]; }
          {
            argv = [
              "voxtype"
              "daemon"
            ];
          }
        ];
      };
    };
  };
}
