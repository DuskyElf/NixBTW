# Notification helpers for the keybinds, as plain functions: this is not a
# module, it is a factory. One bubble per title, because the id is stashed in
# /tmp and handed back with --replace-id, so a held key updates the bubble
# instead of stacking one per repeat.
#
# The panel and screenpad come from the host config. A host without a screenpad
# gets no screenpadBrightness, and binds.nix does not import it.
{
  pkgs,
  lib,
  brightness,
  screenpad,
}:
let
  notify =
    { title, message }:
    "notify-send \"${title}\" \"${message}\" --expire-time=500 -p --replace-id=$(cat '/tmp/niri-${title}') > '/tmp/niri-${title}' || notify-send \"${title}\" \"${message}\" --expire-time=500 -p > '/tmp/niri-${title}'";
in
{
  audio = notify {
    title = "Audio";
    message = "$(wpctl get-volume @DEFAULT_AUDIO_SINK@)";
  };

  panelBrightness = pkgs.writeShellScriptBin "notify-brightness" ''
    VAL=$(${brightness.bin}${brightness.shellArgs} get 2>/dev/null || echo 0)
    MAX=$(${brightness.bin}${brightness.shellArgs} max 2>/dev/null || echo 1)
    PCT=$(${pkgs.gawk}/bin/awk "BEGIN {printf \"%.0f\", $VAL / $MAX * 100}")
    notify-send "Brightness" "$PCT%" --expire-time=500 -p --replace-id=$(cat '/tmp/niri-Brightness' 2>/dev/null || echo 0) > '/tmp/niri-Brightness' || notify-send "Brightness" "$PCT%" --expire-time=500 -p > '/tmp/niri-Brightness'
  '';

  temperature = pkgs.writeShellScriptBin "notify-temperature" ''
    VAL=$(${pkgs.systemd}/bin/busctl --user get-property rs.wl-gammarelay / rs.wl.gammarelay Temperature 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $2}')
    VAL=''${VAL:-6500}
    notify-send "Temperature" "$VAL K" --expire-time=500 -p --replace-id=$(cat '/tmp/niri-Temperature' 2>/dev/null || echo 0) > '/tmp/niri-Temperature' || notify-send "Temperature" "$VAL K" --expire-time=500 -p > '/tmp/niri-Temperature'
  '';
}
// lib.optionalAttrs (screenpad != null) {
  screenpadBrightness = pkgs.writeShellScriptBin "notify-screenpad-brightness" ''
    VAL=$(${brightness.bin} -d ${screenpad.device} get 2>/dev/null || echo 0)
    MAX=$(cat /sys/class/backlight/${screenpad.device}/max_brightness 2>/dev/null || echo 1)
    PCT=$(${pkgs.gawk}/bin/awk "BEGIN {printf \"%.0f\", $VAL / $MAX * 100}")
    notify-send "Screenpad Brightness" "$PCT%" --expire-time=500 -p --replace-id=$(cat '/tmp/niri-screenpad-brightness' 2>/dev/null || echo 0) > '/tmp/niri-screenpad-brightness' || notify-send "Screenpad Brightness" "$PCT%" --expire-time=500 -p > '/tmp/niri-screenpad-brightness'
  '';
}
