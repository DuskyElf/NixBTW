# The home-manager module every machine gets: the account, the XDG directories,
# and the state version. A machine with a desktop adds base/home-workstation.nix
# on top, which is where stylix, the dark-mode portal key, and the daily update
# timer live.
{
  hostConfig,
  ...
}:
{
  xdg.enable = true;
  home.username = hostConfig.user.name;
  home.homeDirectory = hostConfig.user.home;

  # Default applications are declared, not set at runtime. Enabling this makes
  # home-manager own ~/.config/mimeapps.list, a read-only store link that each
  # switch rewrites, so an app module under apps/ only states its defaults.
  # `force` replaces the file an app wrote before home-manager owned it; after
  # that the target is already a link and no switch conflicts.
  xdg.mimeApps.enable = true;
  xdg.configFile."mimeapps.list".force = true;
  xdg.dataFile."applications/mimeapps.list".force = true;

  # Don't change
  home.stateVersion = hostConfig.stateVersion.home;
  programs.home-manager.enable = true;

  # `home-manager switch` prints how many news items are unread (383 today) on
  # every switch. This silences that count; it does not save the evaluation
  # that produces it, only hm-switch.sh does. Migration notices for the next
  # stateVersion go quiet with it, so run `home-manager news` after a bump.
  news.display = "silent";
}
