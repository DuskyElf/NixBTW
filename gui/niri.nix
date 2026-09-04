{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
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

  setStartupTemperature = pkgs.writeShellScriptBin "set-startup-temperature" ''
    BUSCTL=${pkgs.systemd}/bin/busctl
    # Wait for the gamma daemon's D-Bus name (systemd reports a simple-type
    # service "started" before the name registers), then set the startup
    # color temperature. Signature is q (uint16), NOT n: a wrong signature
    # panics the daemon, killing gamma control until the session restarts.
    i=0
    while ! $BUSCTL --user get-property rs.wl-gammarelay / rs.wl.gammarelay Temperature > /dev/null 2>&1; do
      i=$((i + 1))
      [ "$i" -ge 50 ] && exit 1
      sleep 0.1
    done
    $BUSCTL --user set-property rs.wl-gammarelay / rs.wl.gammarelay Temperature q 5700
  '';
in
{
  services = {
    mako.enable = true;
    polkit-gnome.enable = true;
  };

  systemd.user.services.wallpaper-fetch = {
    Unit = {
      Description = "Fetch Guardian photos of the day into the wallpaper pool";
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Type = "oneshot";
      Environment = [
        "PATH=/run/current-system/sw/bin:%h/.nix-profile/bin"
        "WAYLAND_DISPLAY=wayland-1"
      ];
      ExecStart = "%h/.config/scripts/wallpaper.mjs fetch";
    };
  };

  systemd.user.timers.wallpaper-fetch = {
    Unit.Description = "Guardian wallpaper pool fetch";
    # Runs 15min after boot then every 12h of awake use, not at a fixed
    # 08:30. The laptop is suspended at odd hours; OnUnitActiveSec uses the
    # monotonic clock so sleep time does not count and the fetch fires shortly
    # after wake if the 12h boundary passed while asleep. Persistent= would
    # only help at boot anyway (known systemd regression on resume).
    Timer = {
      OnBootSec = "15min";
      OnUnitActiveSec = "12h";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  systemd.user.services.wallpaper-rotate = {
    Unit = {
      Description = "Rotate Guardian wallpaper";
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Type = "oneshot";
      Environment = [
        "PATH=/run/current-system/sw/bin:%h/.nix-profile/bin"
        "WAYLAND_DISPLAY=wayland-1"
      ];
      ExecStart = "%h/.config/scripts/wallpaper.mjs next";
    };
  };

  systemd.user.timers.wallpaper-rotate = {
    Unit.Description = "Rotate Guardian wallpaper every 6 minutes";
    Timer.OnCalendar = "*:0/6";
    Install.WantedBy = [ "timers.target" ];
  };

  systemd.user.services.wallpaper-resume = {
    Unit = {
      Description = "Re-apply wallpaper after suspend";
      After = [ "sleep.target" ];
    };
    Service = {
      Type = "oneshot";
      Environment = [
        "PATH=/run/current-system/sw/bin:%h/.nix-profile/bin"
        "WAYLAND_DISPLAY=wayland-1"
      ];
      ExecStart = "%h/.config/scripts/wallpaper.mjs next";
    };
    Install.WantedBy = [ "sleep.target" ];
  };

  # Daemons that niri used to spawn at startup, now owned by systemd so they
  # start/stop with the graphical session and restart independently of niri.
  systemd.user.services.wl-gammarelay = {
    Unit = {
      Description = "Wayland color temperature daemon";
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Environment = "WAYLAND_DISPLAY=wayland-1";
      ExecStart = "${pkgs.wl-gammarelay-rs}/bin/wl-gammarelay-rs";
      Restart = "on-failure";
      RestartSec = "1s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  # One-shot bootstrap: wait for the gamma daemon's D-Bus name (simple-type
  # service is "started" before the name registers), then set the startup color
  # temperature. Signature is q (uint16), NOT n: a wrong signature panics the
  # daemon, killing gamma control until the session restarts.
  systemd.user.services.gamma-temperature = {
    Unit = {
      Description = "Set startup color temperature";
      PartOf = [ "graphical-session.target" ];
      After = [ "wl-gammarelay.service" ];
    };
    Service = {
      Type = "oneshot";
      Environment = "WAYLAND_DISPLAY=wayland-1";
      ExecStart = "${setStartupTemperature}/bin/set-startup-temperature";
      Restart = "on-failure";
      RestartSec = "1s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.awww-daemon = {
    Unit = {
      Description = "Wallpaper daemon";
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Environment = "WAYLAND_DISPLAY=wayland-1";
      ExecStart = "${pkgs.awww}/bin/awww-daemon";
      Restart = "on-failure";
      RestartSec = "1s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.quickshell = {
    Unit = {
      Description = "Wallpaper overlay shell";
      PartOf = [ "graphical-session.target" ];
      # Keep the pre-systemd ordering: awww up before the overlay renders.
      After = [ "awww-daemon.service" ];
    };
    Service = {
      Environment = "WAYLAND_DISPLAY=wayland-1";
      ExecStart = "${pkgs.quickshell}/bin/quickshell";
      Restart = "on-failure";
      RestartSec = "1s";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  # Initial wallpaper apply. Must run after awww-daemon so applier.ensure()
  # finds the daemon instead of spawning a duplicate detached copy.
  systemd.user.services.wallpaper-startup = {
    Unit = {
      Description = "Apply initial wallpaper at session start";
      PartOf = [ "graphical-session.target" ];
      After = [ "awww-daemon.service" ];
    };
    Service = {
      Type = "oneshot";
      Environment = [
        "PATH=/run/current-system/sw/bin:%h/.nix-profile/bin"
        "WAYLAND_DISPLAY=wayland-1"
      ];
      ExecStart = "%h/.config/scripts/wallpaper.mjs next";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  # X11 support: niri 25.08+ spawns xwayland-satellite on demand when the
  # binary is in PATH, so no spawn-at-startup or systemd service is needed.
  home.packages = with pkgs; [
    awww
    quickshell
    wtype
    wl-gammarelay-rs
    brightnessctl
    xwayland-satellite
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
              "systemctl --user stop break-timer.service || true; systemctl --user restart break-timer.timer; makoctl dismiss -n $(cat /tmp/break_timer_id) || true; rm -f /tmp/break_timer_id";

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

          "Mod+N".action = spawn "bash" "-c" "~/.config/scripts/wallpaper.mjs next";

          "Mod+8".action = spawn "bash" "-c" ("sudo /usr/local/sbin/power.sh powersave");
          "Mod+9".action = spawn "bash" "-c" ("sudo /usr/local/sbin/power.sh performance");
          "Mod+0".action = spawn "bash" "-c" ("sudo /usr/local/sbin/power.sh ultra-powersave");

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
                sudo /usr/local/sbin/power.sh screenpad off || true
                notify-send "Secondary Display" "Turned OFF" -t 1000
              else
                sudo /usr/local/sbin/power.sh screenpad on || true
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
          { argv = [ "kitty" ]; }
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
              "/usr/local/sbin/power.sh"
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
