{
  config,
  pkgs,
  lib,
  inputs,
  pkgs-unstable,
  ...
}:
let
  wallpaper = ../wallpapers/linux_fuck_nvidia.jpeg;

  notif =
    { title, message }:
    "notify-send \"${title}\" \"${message}\" --expire-time=500 -p --replace-id=$(cat '/tmp/niri-${title}') > '/tmp/niri-${title}' || notify-send \"${title}\" \"${message}\" --expire-time=500 -p > '/tmp/niri-${title}'";

  audio-notification = notif {
    title = "Audio";
    message = "$(wpctl get-volume @DEFAULT_AUDIO_SINK@)";
  };

  notifyBrightness = pkgs.writeShellScriptBin "notify-brightness" ''
    VAL=$(${pkgs.brightnessctl}/bin/brightnessctl get 2>/dev/null || echo 0)
    MAX=$(${pkgs.brightnessctl}/bin/brightnessctl max 2>/dev/null || echo 1)
    PCT=$(${pkgs.gawk}/bin/awk "BEGIN {printf \"%.0f\", $VAL / $MAX * 100}")
    notify-send "Brightness" "$PCT%" --expire-time=500 -p --replace-id=$(cat '/tmp/niri-Brightness' 2>/dev/null || echo 0) > '/tmp/niri-Brightness' || notify-send "Brightness" "$PCT%" --expire-time=500 -p > '/tmp/niri-Brightness'
  '';

  notifyScreenpadBrightness = pkgs.writeShellScriptBin "notify-screenpad-brightness" ''
    VAL=$(${pkgs.brightnessctl}/bin/brightnessctl -d asus_screenpad get 2>/dev/null || echo 0)
    MAX=$(cat /sys/class/backlight/asus_screenpad/max_brightness 2>/dev/null || echo 1)
    PCT=$(${pkgs.gawk}/bin/awk "BEGIN {printf \"%.0f\", $VAL / $MAX * 100}")
    notify-send "Screenpad Brightness" "$PCT%" --expire-time=500 -p --replace-id=$(cat '/tmp/niri-screenpad-brightness' 2>/dev/null || echo 0) > '/tmp/niri-screenpad-brightness' || notify-send "Screenpad Brightness" "$PCT%" --expire-time=500 -p > '/tmp/niri-screenpad-brightness'
  '';

  notifyTemperature = pkgs.writeShellScriptBin "notify-temperature" ''
    VAL=$(${pkgs.systemd}/bin/busctl --user get-property rs.wl-gammarelay / rs.wl.gammarelay Temperature 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $2}')
    VAL=''${VAL:-6500}
    notify-send "Temperature" "$VAL K" --expire-time=500 -p --replace-id=$(cat '/tmp/niri-Temperature' 2>/dev/null || echo 0) > '/tmp/niri-Temperature' || notify-send "Temperature" "$VAL K" --expire-time=500 -p > '/tmp/niri-Temperature'
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
    brightnessctl
  ];

  programs = {
    fuzzel.enable = true;

    niri = {
      package = inputs.niri.packages.${pkgs.system}.niri-unstable;

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

          "Mod+B".action =
            spawn "bash" "-c"
              "systemctl --user restart break-timer.service; makoctl dismiss -n $(cat /tmp/break_timer_id) || true; rm -f /tmp/break_timer_id";

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
            action = spawn "bash" "-c" (
              "${pkgs.brightnessctl}/bin/brightnessctl set +10% > /dev/null 2>&1; ${notifyBrightness}/bin/notify-brightness"
            );
          };
          "XF86MonBrightnessDown" = {
            allow-when-locked = true;
            action = spawn "bash" "-c" (
              "${pkgs.brightnessctl}/bin/brightnessctl set 10%- > /dev/null 2>&1; ${notifyBrightness}/bin/notify-brightness"
            );
          };

          "Shift+XF86MonBrightnessUp" = {
            allow-when-locked = true;
            action = spawn "bash" "-c" (
              "${pkgs.brightnessctl}/bin/brightnessctl -d asus_screenpad set +10% > /dev/null 2>&1; ${notifyScreenpadBrightness}/bin/notify-screenpad-brightness"
            );
          };
          "Shift+XF86MonBrightnessDown" = {
            allow-when-locked = true;
            action = spawn "bash" "-c" (
              "${pkgs.brightnessctl}/bin/brightnessctl -d asus_screenpad set 10%- > /dev/null 2>&1; ${notifyScreenpadBrightness}/bin/notify-screenpad-brightness"
            );
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
            action = spawn "bash" "-c" (
              "${pkgs.brightnessctl}/bin/brightnessctl set +1% > /dev/null 2>&1; ${notifyBrightness}/bin/notify-brightness"
            );
          };
          "Mod+Alt+TouchpadScrollUp" = {
            allow-when-locked = true;
            action = spawn "bash" "-c" (
              "${pkgs.brightnessctl}/bin/brightnessctl set 1%- > /dev/null 2>&1; ${notifyBrightness}/bin/notify-brightness"
            );
          };

          "Mod+Shift+TouchpadScrollDown" = {
            allow-when-locked = true;
            action = spawn "bash" "-c" (
              "${pkgs.brightnessctl}/bin/brightnessctl -d asus_screenpad set +1% > /dev/null 2>&1; ${notifyScreenpadBrightness}/bin/notify-screenpad-brightness"
            );
          };
          "Mod+Shift+TouchpadScrollUp" = {
            allow-when-locked = true;
            action = spawn "bash" "-c" (
              "${pkgs.brightnessctl}/bin/brightnessctl -d asus_screenpad set 1%- > /dev/null 2>&1; ${notifyScreenpadBrightness}/bin/notify-screenpad-brightness"
            );
          };

          # Temperature (gamma LUT only — brightness is hardware backlight)
          "Alt+TouchpadScrollDown" = {
            allow-when-locked = true;
            action = spawn "bash" "-c" (
              "${pkgs.systemd}/bin/busctl --user -- call rs.wl-gammarelay / rs.wl.gammarelay UpdateTemperature n -200; ${notifyTemperature}/bin/notify-temperature"
            );
          };
          "Alt+TouchpadScrollUp" = {
            allow-when-locked = true;
            action = spawn "bash" "-c" (
              "${pkgs.systemd}/bin/busctl --user -- call rs.wl-gammarelay / rs.wl.gammarelay UpdateTemperature n 200; ${notifyTemperature}/bin/notify-temperature"
            );
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
              # Toggle screenpad (bl_power: 0 = off, 4 = on). No waits, no
              # retries. Press again if the attach does not stick.
              if [ "$(cat /sys/class/backlight/asus_screenpad/bl_power 2>/dev/null)" = "4" ]; then
                niri msg output DP-2 off || true
                sudo ~/.config/scripts/power.sh screenpad off || true
                notify-send "Secondary Display" "Turned OFF" -t 1000
              else
                sudo ~/.config/scripts/power.sh screenpad on || true
                niri msg output DP-2 on || true
                notify-send "Secondary Display" "Turned ON" -t 1000
              fi
            '';
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
          {
            argv = [
              "${pkgs.brightnessctl}/bin/brightnessctl"
              "set"
              "10%"
            ];
          }
          { argv = [ "${pkgs.wl-gammarelay-rs}/bin/wl-gammarelay-rs" ]; }
          {
            # Wait for the gamma daemon to register its D-Bus name, then set
            # the startup color temperature (absolute, not a delta).
            # Signature is q (uint16), NOT n: a wrong signature panics the
            # daemon (rustbus UnVariant.get returns WrongSignature, setter
            # unwraps), killing gamma control until the session restarts.
            argv = [
              "bash"
              "-c"
              ''
                i=0
                while ! ${pkgs.systemd}/bin/busctl --user get-property rs.wl-gammarelay / rs.wl.gammarelay Temperature > /dev/null 2>&1; do
                  i=$((i + 1))
                  [ "$i" -ge 50 ] && exit 1
                  sleep 0.1
                done
                ${pkgs.systemd}/bin/busctl --user set-property rs.wl-gammarelay / rs.wl.gammarelay Temperature q 5700
              ''
            ];
          }
          { argv = [ "kitty" ]; }
          {
            argv = [
              "${pkgs.swaybg}/bin/swaybg"
              "-i"
              "${wallpaper}"
              "-m"
              "center"
            ];
          }
          {
            argv = [
              "bash"
              "-c"
              "niri msg output DP-2 off || true"
            ];
          }
          {
            argv = [
              "sudo"
              "~/.config/scripts/power.sh"
              "screenpad"
              "off"
            ];
          }
        ];
      };
    };
  };

  # Override the niri-flake's validated config source to skip validation,
  # which avoids triggering builtins.fetchGit for the smithay Cargo dependency.
  xdg.configFile."niri-config".source = lib.mkForce (
    pkgs.writeText "config.kdl" config.programs.niri.finalConfig
  );
}
