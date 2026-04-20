{
  config,
  pkgs,
  inputs,
  pkgs-unstable,
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
        env = (old.env or { }) // {
          RUSTFLAGS = (old.env.RUSTFLAGS or "") + " -C target-cpu=native";
        };
      });
    };

  niri-native-pkgs = pkgs.extend niriNativeOverlay;

  notif =
    { title, message }:
    "notify-send \"${title}\" \"${message}\" --expire-time=500 -p --replace-id=$(cat '/tmp/niri-${title}') > '/tmp/niri-${title}' || notify-send \"${title}\" \"${message}\" --expire-time=500 -p > '/tmp/niri-${title}'";

  audio-notification = notif {
    title = "Audio";
    message = "$(wpctl get-volume @DEFAULT_AUDIO_SINK@)";
  };

  notifyBrightness = pkgs.writeShellScriptBin "notify-brightness" ''
    VAL=$(${pkgs.systemd}/bin/busctl --user get-property rs.wl-gammarelay / rs.wl.gammarelay Brightness | ${pkgs.gawk}/bin/awk '{print $2}')
    VAL=''${VAL:-1}
    PCT=$(${pkgs.gawk}/bin/awk "BEGIN {printf \"%.0f\", $VAL * 100}")
    notify-send "Brightness" "$PCT%" --expire-time=500 -p --replace-id=$(cat '/tmp/niri-Brightness' 2>/dev/null || echo 0) > '/tmp/niri-Brightness' || notify-send "Brightness" "$PCT%" --expire-time=500 -p > '/tmp/niri-Brightness'
  '';
in
{
  services = {
    mako.enable = true;
    polkit-gnome.enable = true;
  };

  home.packages = with pkgs; [
    swaybg
    wtype
    wl-gammarelay-rs
  ];

  systemd.user.services.voxtype = {
    Unit = {
      Description = "VoxType push-to-talk voice-to-text daemon";
      Documentation = "https://voxtype.io";
      PartOf = [ "graphical-session.target" ];
      After = [
        "graphical-session.target"
        "pipewire.service"
        "pipewire-pulse.service"
      ];
    };

    Service = {
      Type = "simple";
      # Wait for the Wayland environment variable to be exported by the compositor
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'while ! ${pkgs.systemd}/bin/systemctl --user show-environment | ${pkgs.gnugrep}/bin/grep -q WAYLAND_DISPLAY; do ${pkgs.coreutils}/bin/sleep 1; done'";
      # Fetch the latest environment variables right before execution to ensure they are picked up
      ExecStart = "${pkgs.bash}/bin/bash -c 'export WAYLAND_DISPLAY=$(${pkgs.systemd}/bin/systemctl --user show-environment | ${pkgs.gnugrep}/bin/grep ^WAYLAND_DISPLAY= | ${pkgs.coreutils}/bin/cut -d= -f2-); exec ${config.programs.voxtype.package}/bin/voxtype daemon'";
      Restart = "always";
      RestartSec = 3;
    };

    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };

  programs.voxtype = {
    enable = true;
    package = pkgs-unstable.voxtype-vulkan;
    model.name = "base.en";

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

    niri = {
      package = niri-native-pkgs.niri-unstable;

      settings = {
        input = {
          touchpad = {
            drag = false;
            middle-emulation = true;
          };
          warp-mouse-to-focus.enable = true;
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

        overview = {
          zoom = 0.25;
        };

        environment = {
          WLR_DRM_NO_MODIFIERS = "1";
        };

        binds = with config.lib.niri.actions; {
          "Ctrl+Return".action =
            spawn "bash" "-c"
              "[ -f '/tmp/niri-vmn' ] || notify-send 'Vim Mode' --urgency=critical -p > /tmp/niri-vmn";
          "Ctrl+Shift+Return".action =
            spawn "bash" "-c"
              "notify-send '' --replace-id=$(cat /tmp/niri-vmn) --expire-time=1; rm -f /tmp/niri-vmn";
          "Ctrl+Alt+Return".action =
            spawn "bash" "-c"
              "notify-send 'Visual Mode' --replace-id=$(cat /tmp/niri-vmn)";
          "Ctrl+Alt+Shift+Return".action =
            spawn "bash" "-c"
              "notify-send 'Vim Mode' --urgency=critical --replace-id=$(cat /tmp/niri-vmn)";

          "Mod+Shift+Slash".action = show-hotkey-overlay;
          "Super+Alt+L".action = spawn "swaylock";

          "Mod+B".action = spawn "bash" "-c" "systemctl --user restart break-timer.service; makoctl dismiss -n $(cat /tmp/break_timer_id) || true; rm -f /tmp/break_timer_id";

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

          "Mod+8".action = spawn "bash" "-c" ("sudo ~/.config/scripts/power.sh powersave");
          "Mod+9".action = spawn "bash" "-c" ("sudo ~/.config/scripts/power.sh performance");
          "Mod+0".action = spawn "bash" "-c" ("sudo ~/.config/scripts/power.sh ultra-powersave");

          "XF86AudioMute" = {
            allow-when-locked = true;
            action = spawn "bash" "-c" ("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle;" + audio-notification);
          };
          "XF86AudioRaiseVolume" = {
            allow-when-locked = true;
            action = spawn "bash" "-c" ("wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.1+;" + audio-notification);
          };
          "XF86AudioLowerVolume" = {
            allow-when-locked = true;
            action = spawn "bash" "-c" ("wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.1-;" + audio-notification);
          };

          "XF86MonBrightnessUp" = {
            allow-when-locked = true;
            action = spawn "bash" "-c" ("${pkgs.systemd}/bin/busctl --user call rs.wl-gammarelay / rs.wl.gammarelay UpdateBrightness d -- 0.05; ${notifyBrightness}/bin/notify-brightness");
          };
          "XF86MonBrightnessDown" = {
            allow-when-locked = true;
            action = spawn "bash" "-c" ("${pkgs.systemd}/bin/busctl --user call rs.wl-gammarelay / rs.wl.gammarelay UpdateBrightness d -- -0.05; ${notifyBrightness}/bin/notify-brightness");
          };

          "Mod+TouchpadScrollDown" = {
            allow-when-locked = true;
            action = spawn "bash" "-c" ("wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.02+;" + audio-notification);
          };
          "Mod+TouchpadScrollUp" = {
            allow-when-locked = true;
            action = spawn "bash" "-c" ("wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.02-;" + audio-notification);
          };

          "Mod+Alt+TouchpadScrollDown" = {
            allow-when-locked = true;
            action = spawn "bash" "-c" ("${pkgs.systemd}/bin/busctl --user call rs.wl-gammarelay / rs.wl.gammarelay UpdateBrightness d -- 0.005; ${notifyBrightness}/bin/notify-brightness");
          };
          "Mod+Alt+TouchpadScrollUp" = {
            allow-when-locked = true;
            action = spawn "bash" "-c" ("${pkgs.systemd}/bin/busctl --user call rs.wl-gammarelay / rs.wl.gammarelay UpdateBrightness d -- -0.005; ${notifyBrightness}/bin/notify-brightness");
          };

          # FIXME: tracked in https://github.com/sodiboo/niri-flake/issues/922
          "Print".action.screenshot = [ ];
          "Alt+Print".action.screenshot-screen = [ ];

          "Mod+Escape" = {
            allow-inhibiting = false;
            action = toggle-keyboard-shortcuts-inhibit;
          };

          "Mod+Shift+E".action = quit;

          "Mod+1" = {
            allow-when-locked = true;
            action = spawn "bash" "-c" ''
              STATE_FILE="/tmp/dp2_state"
              if [ ! -f "$STATE_FILE" ]; then
                echo "off" > "$STATE_FILE"
              fi
              STATE=$(cat "$STATE_FILE")
              if [ "$STATE" = "off" ]; then
                niri msg output DP-2 on
                sudo ~/.config/scripts/power.sh screenpad on || true
                echo "on" > "$STATE_FILE"
                notify-send "Secondary Display" "Turned ON" -t 1000 -p > /tmp/niri-dp2-notif
              else
                niri msg output DP-2 off
                sudo ~/.config/scripts/power.sh screenpad off || true
                echo "off" > "$STATE_FILE"
                notify-send "Secondary Display" "Turned OFF" -t 1000 -p > /tmp/niri-dp2-notif
              fi
            '';
          };

          "Mod+semicolon" = {
            repeat = false;
            action = spawn "voxtype" "record" "start";
          };

          "Mod+apostrophe" = {
            repeat = false;
            action = spawn "voxtype" "record" "stop";
          };
        };

        # explicitly only use iGPU and leave the dGPU alone
        debug = {
          ignore-drm-device = "/dev/dri/by-path/pci-0000:01:00.0-render";
          render-drm-device = "/dev/dri/by-path/pci-0000:00:02.0-render";
        };

        prefer-no-csd = true;
        hotkey-overlay.skip-at-startup = true;
        spawn-at-startup = [
          { argv = [ "${pkgs.brightnessctl}/bin/brightnessctl" "set" "80%" ]; }
          { argv = [ "${pkgs.wl-gammarelay-rs}/bin/wl-gammarelay-rs" ]; }
          { argv = [ "bash" "-c" "for i in {1..20}; do if ${pkgs.systemd}/bin/busctl --user set-property rs.wl-gammarelay / rs.wl.gammarelay Brightness d 0.7 && ${pkgs.systemd}/bin/busctl --user set-property rs.wl-gammarelay / rs.wl.gammarelay Temperature q 4500; then break; fi; sleep 0.5; done" ]; }
          { argv = [ "kitty" ]; }
          {
            argv = [
              "niri"
              "msg"
              "output"
              "DP-2"
              "off"
            ];
          }
        ];
      };
    };
  };
}
