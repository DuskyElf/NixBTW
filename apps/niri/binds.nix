# Every keybind. Notification text comes from notify.nix, the wallpaper command
# from the wallpaper-guardian module, and the power modes from power.sh through
# the one sudo path this machine trusts.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  notify = import ./notify.nix { inherit pkgs; };
  wallpaperGuardian = config.services.wallpaper-guardian.package;
in
{
  programs.niri.settings.binds = with config.lib.niri.actions; {
    "Mod+Shift+Slash".action = show-hotkey-overlay;
    "Super+Alt+L".action = spawn "swaylock";

    "Mod+B".action =
      spawn "bash" "-c"
        "systemctl --user stop break-timer.service || true; systemctl --user restart break-timer.timer; id=$(cat /tmp/break_timer_id 2>/dev/null); [ -n \"$id\" ] && makoctl dismiss -n \"$id\" 2>/dev/null; rm -f /tmp/break_timer_id /tmp/break-timer-notify-id";

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

    "Mod+N".action = spawn "bash" "-c" "${lib.getExe wallpaperGuardian} next";

    "Mod+8".action = spawn "bash" "-c" ("sudo /usr/local/sbin/power.sh powersave");
    "Mod+9".action = spawn "bash" "-c" ("sudo /usr/local/sbin/power.sh performance");
    "Mod+0".action = spawn "bash" "-c" ("sudo /usr/local/sbin/power.sh ultra-powersave");

    "XF86AudioMute" = {
      allow-when-locked = true;
      action = spawn "bash" "-c" ("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle;" + notify.audio);
    };
    "XF86AudioRaiseVolume" = {
      allow-when-locked = true;
      action = spawn "bash" "-c" ("wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.1+;" + notify.audio);
    };
    "XF86AudioLowerVolume" = {
      allow-when-locked = true;
      action = spawn "bash" "-c" ("wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.1-;" + notify.audio);
    };

    "XF86MonBrightnessUp" = {
      allow-when-locked = true;
      action = spawn "bash" "-c" (
        "${pkgs.brightnessctl}/bin/brightnessctl set +10% > /dev/null 2>&1; ${notify.brightness}/bin/notify-brightness"
      );
    };
    "XF86MonBrightnessDown" = {
      allow-when-locked = true;
      action = spawn "bash" "-c" (
        "${pkgs.brightnessctl}/bin/brightnessctl set 10%- > /dev/null 2>&1; ${notify.brightness}/bin/notify-brightness"
      );
    };

    "Shift+XF86MonBrightnessUp" = {
      allow-when-locked = true;
      action = spawn "bash" "-c" (
        "${pkgs.brightnessctl}/bin/brightnessctl -d asus_screenpad set +10% > /dev/null 2>&1; ${notify.screenpadBrightness}/bin/notify-screenpad-brightness"
      );
    };
    "Shift+XF86MonBrightnessDown" = {
      allow-when-locked = true;
      action = spawn "bash" "-c" (
        "${pkgs.brightnessctl}/bin/brightnessctl -d asus_screenpad set 10%- > /dev/null 2>&1; ${notify.screenpadBrightness}/bin/notify-screenpad-brightness"
      );
    };

    "Mod+TouchpadScrollDown" = {
      allow-when-locked = true;
      action = spawn "bash" "-c" ("wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.02+;" + notify.audio);
    };
    "Mod+TouchpadScrollUp" = {
      allow-when-locked = true;
      action = spawn "bash" "-c" ("wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.02-;" + notify.audio);
    };

    "Mod+Alt+TouchpadScrollDown" = {
      allow-when-locked = true;
      action = spawn "bash" "-c" (
        "${pkgs.brightnessctl}/bin/brightnessctl set +1% > /dev/null 2>&1; ${notify.brightness}/bin/notify-brightness"
      );
    };
    "Mod+Alt+TouchpadScrollUp" = {
      allow-when-locked = true;
      action = spawn "bash" "-c" (
        "${pkgs.brightnessctl}/bin/brightnessctl set 1%- > /dev/null 2>&1; ${notify.brightness}/bin/notify-brightness"
      );
    };

    "Mod+Shift+TouchpadScrollDown" = {
      allow-when-locked = true;
      action = spawn "bash" "-c" (
        "${pkgs.brightnessctl}/bin/brightnessctl -d asus_screenpad set +1% > /dev/null 2>&1; ${notify.screenpadBrightness}/bin/notify-screenpad-brightness"
      );
    };
    "Mod+Shift+TouchpadScrollUp" = {
      allow-when-locked = true;
      action = spawn "bash" "-c" (
        "${pkgs.brightnessctl}/bin/brightnessctl -d asus_screenpad set 1%- > /dev/null 2>&1; ${notify.screenpadBrightness}/bin/notify-screenpad-brightness"
      );
    };

    # Temperature (gamma LUT only, brightness is hardware backlight)
    "Alt+TouchpadScrollDown" = {
      allow-when-locked = true;
      action = spawn "bash" "-c" (
        "${pkgs.systemd}/bin/busctl --user -- call rs.wl-gammarelay / rs.wl.gammarelay UpdateTemperature n -200; ${notify.temperature}/bin/notify-temperature"
      );
    };
    "Alt+TouchpadScrollUp" = {
      allow-when-locked = true;
      action = spawn "bash" "-c" (
        "${pkgs.systemd}/bin/busctl --user -- call rs.wl-gammarelay / rs.wl.gammarelay UpdateTemperature n 200; ${notify.temperature}/bin/notify-temperature"
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
        # Toggle the screenpad (bl_power: 0 = off, 4 = on). Turning it
        # on is bare on purpose: the DP link trains marginal and i915
        # rejects the modeset mid-training (EINVAL), so only a fresh
        # bl_power cycle re-trains it, and the kernel hotplug uevent
        # about 1.5s later auto-connects the output. No sleeps,
        # retries or flock: the retry is another Mod+1. `niri msg
        # output DP-2 on` exits 0 even on an unmapped connector, so
        # never trust its exit code.
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
}
