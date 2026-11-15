# Every keybind. Notification text comes from notify.nix, the wallpaper command
# from the wallpaper-guardian module, and the power modes from power.sh through
# the one sudo path this machine trusts.
#
# Binds that need a screenpad are added only when the host declares one, so a
# laptop without that panel does not carry keys that quietly do nothing.
{
  config,
  hostConfig,
  brightness,
  pkgs,
  lib,
  ...
}:
let
  screenpad = hostConfig.hardware.screenpad;

  notify = import ./notify.nix {
    inherit pkgs lib brightness;
    screenpad = hostConfig.hardware.screenpad;
  };

  wallpaperGuardian = config.services.wallpaper-guardian.package;

  # The panel's command line, e.g. ".../brightnessctl -d intel_backlight".
  panel = "${brightness.bin}${brightness.shellArgs}";
in
{
  programs.niri.settings.binds =
    with config.lib.niri.actions;
    {
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

      "Mod+8".action = spawn "bash" "-c" ("sudo ${hostConfig.powerScriptPath} powersave");
      "Mod+9".action = spawn "bash" "-c" ("sudo ${hostConfig.powerScriptPath} performance");
      "Mod+0".action = spawn "bash" "-c" ("sudo ${hostConfig.powerScriptPath} ultra-powersave");

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
          "${panel} set +10% > /dev/null 2>&1; ${notify.panelBrightness}/bin/notify-brightness"
        );
      };
      "XF86MonBrightnessDown" = {
        allow-when-locked = true;
        action = spawn "bash" "-c" (
          "${panel} set 10%- > /dev/null 2>&1; ${notify.panelBrightness}/bin/notify-brightness"
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
          "${panel} set +1% > /dev/null 2>&1; ${notify.panelBrightness}/bin/notify-brightness"
        );
      };
      "Mod+Alt+TouchpadScrollUp" = {
        allow-when-locked = true;
        action = spawn "bash" "-c" (
          "${panel} set 1%- > /dev/null 2>&1; ${notify.panelBrightness}/bin/notify-brightness"
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
    }
    // lib.optionalAttrs (screenpad != null) {
      "Shift+XF86MonBrightnessUp" = {
        allow-when-locked = true;
        action = spawn "bash" "-c" (
          "${brightness.bin} -d ${screenpad.device} set +10% > /dev/null 2>&1; ${notify.screenpadBrightness}/bin/notify-screenpad-brightness"
        );
      };
      "Shift+XF86MonBrightnessDown" = {
        allow-when-locked = true;
        action = spawn "bash" "-c" (
          "${brightness.bin} -d ${screenpad.device} set 10%- > /dev/null 2>&1; ${notify.screenpadBrightness}/bin/notify-screenpad-brightness"
        );
      };

      "Mod+Shift+TouchpadScrollDown" = {
        allow-when-locked = true;
        action = spawn "bash" "-c" (
          "${brightness.bin} -d ${screenpad.device} set +1% > /dev/null 2>&1; ${notify.screenpadBrightness}/bin/notify-screenpad-brightness"
        );
      };
      "Mod+Shift+TouchpadScrollUp" = {
        allow-when-locked = true;
        action = spawn "bash" "-c" (
          "${brightness.bin} -d ${screenpad.device} set 1%- > /dev/null 2>&1; ${notify.screenpadBrightness}/bin/notify-screenpad-brightness"
        );
      };

      "Mod+1" = {
        allow-when-locked = true;
        action = spawn "bash" "-c" ''
          # Toggle the screenpad (bl_power: 0 = off, 4 = on). Turning it
          # on is bare on purpose: the DP link trains marginal and i915
          # rejects the modeset mid-training (EINVAL), so only a fresh
          # bl_power cycle re-trains it, and the kernel hotplug uevent
          # about 1.5s later auto-connects the output. No sleeps,
          # retries or flock: the retry is another Mod+1. `niri msg
          # output ${screenpad.output} on` exits 0 even on an unmapped
          # connector, so never trust its exit code.
          if [ "$(cat /sys/class/backlight/${screenpad.device}/bl_power 2>/dev/null)" = "4" ]; then
            niri msg output ${screenpad.output} off || true
            sudo ${hostConfig.powerScriptPath} screenpad off || true
            notify-send "Secondary Display" "Turned OFF" -t 1000
          else
            sudo ${hostConfig.powerScriptPath} screenpad on || true
            niri msg output ${screenpad.output} on || true
            notify-send "Secondary Display" "Turned ON" -t 1000
          fi
        '';
      };
    };
}
