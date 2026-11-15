# How this host addresses its panel. Every caller needs a different shape of the
# same two facts: a bare binary for a script, a shell suffix for an inline
# command, and an argv pair for niri's spawn list. Computed once in mkHost and
# passed to the home modules, so no app repeats the -d rule.
{ pkgs, backlight }:
{
  bin = "${pkgs.brightnessctl}/bin/brightnessctl";

  # For a command line: " -d intel_backlight", or empty when the host has no
  # named device and brightnessctl picks.
  shellArgs = if backlight == null then "" else " -d ${backlight}";

  # For a spawn argv, where each argument is its own list element.
  argv =
    if backlight == null then
      [ ]
    else
      [
        "-d"
        backlight
      ];
}
