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

  # Don't change
  home.stateVersion = hostConfig.stateVersion.home;
  programs.home-manager.enable = true;

  # `home-manager switch` prints how many news items are unread (383 today) on
  # every switch. This silences that count; it does not save the evaluation
  # that produces it, only hm-switch.sh does. Migration notices for the next
  # stateVersion go quiet with it, so run `home-manager news` after a bump.
  news.display = "silent";
}
