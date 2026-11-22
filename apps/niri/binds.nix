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

  # Only forced when a host declares a screenpad, so a null never reaches the
  # script's text.
  screenpadToggle = import ./screenpad.nix {
    inherit pkgs;
    screenpad = hostConfig.hardware.screenpad;
    inherit (hostConfig) powerScriptPath;
  };

  wallpaperGuardian = config.services.wallpaper-guardian.package;

  # The panel's command line, e.g. ".../brightnessctl -d intel_backlight".
  panel = "${brightness.bin}${brightness.shellArgs}";
in
{
  # The binary Mod+1 runs, also reachable from a terminal so the panel can be
  # blanked when a bind or niri misbehaves.
  home.packages = lib.optional (screenpad != null) screenpadToggle;

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
      "Mod+T".action = spawn "foot";
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
        repeat = false;
        action = spawn "${lib.getExe screenpadToggle}";
      };
    };
}
