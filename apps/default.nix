# Every app module, in one registry: a name maps to the modules it contributes
# to each configuration. A host lists names in hosts/<name>/default.nix and
# lib/mkHost.nix resolves them, so an app can be home-only, system-only, or
# split across both (see niri/). A split app keeps its parts in a subdirectory
# and is reached through its own home.nix. A helper that is not a module at all,
# like niri/notify.nix, is imported by the module that uses it.
#
# The rule for what belongs here: a file sets config for one app. Machine
# plumbing, and a bare `programs.<app>.enable` for something the machine just
# needs, stay in base/.
{
  sh = {
    home = [ ./sh.nix ];
  };
  zsh = {
    home = [ ./zsh.nix ];
  };
  bash = {
    home = [ ./bash.nix ];
  };
  home-switch = {
    home = [ ./home-switch.nix ];
  };
  daily-update = {
    home = [ ./daily-update/home.nix ];
    system = [ ./daily-update/system.nix ];
  };
  git = {
    home = [ ./git.nix ];
  };
  tmux = {
    home = [ ./tmux.nix ];
  };
  nvim = {
    home = [ ./nvim.nix ];
  };
  languages = {
    home = [ ./languages.nix ];
  };
  local-llm = {
    home = [ ./local-llm.nix ];
  };
  opencode = {
    home = [ ./opencode.nix ];
  };
  kitty = {
    home = [ ./kitty.nix ];
  };
  zen-browser = {
    home = [ ./zen-browser.nix ];
  };
  chromium = {
    home = [ ./chromium.nix ];
  };
  blender = {
    home = [ ./blender.nix ];
  };
  gnucash = {
    home = [ ./gnucash.nix ];
  };
  idle = {
    home = [ ./idle.nix ];
  };
  niri = {
    home = [ ./niri/home.nix ];
    system = [ ./niri/system.nix ];
  };
  wallpaper = {
    home = [ ./wallpaper.nix ];
  };
  quickshell = {
    home = [ ./quickshell.nix ];
  };
  gammarelay = {
    home = [ ./gammarelay.nix ];
  };

  keyd = {
    system = [ ./keyd.nix ];
  };
  openssh = {
    system = [ ./openssh.nix ];
  };
  auto-cpufreq = {
    system = [ ./auto-cpufreq.nix ];
  };
  power = {
    system = [ ./power.nix ];
  };
}
