# Every app module, split by which configuration consumes it. Adding an app is a
# file in this directory plus one line below. A split app keeps its parts in a
# subdirectory and is reached through its own home.nix (see niri/). A helper that
# is not a module at all, like niri/notify.nix, is imported by the module that
# uses it.
#
# The rule for what belongs here: a file sets config for one app. Machine
# plumbing, and a bare `programs.<app>.enable` for something the machine just
# needs, stay in base/system.nix.
{
  homeModules = [
    ./sh.nix
    ./git.nix
    ./tmux.nix
    ./nvim.nix
    ./languages.nix
    ./local-llm.nix
    ./opencode.nix
    ./kitty.nix
    ./zen-browser.nix
    ./chromium.nix
    ./blender.nix
    ./gnucash.nix
    ./idle.nix
    ./niri/home.nix
    ./wallpaper.nix
    ./quickshell.nix
    ./gammarelay.nix
  ];

  systemModules = [
    ./niri/system.nix
    ./keyd.nix
  ];
}
