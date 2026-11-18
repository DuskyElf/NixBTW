{
  config,
  hostConfig,
  pkgs,
  ...
}:

{
  xdg.enable = true;
  home.username = hostConfig.user.name;
  home.homeDirectory = hostConfig.user.home;

  # Stylix's gtk target sets gtk.gtk4.theme itself; adding that option by hand
  # duplicates the definition and fails the home-manager build.
  stylix = {
    enable = true;
    polarity = "dark";
    fonts.monospace = {
      package = pkgs.nerd-fonts.jetbrains-mono;
      name = "JetBrainsMonoNerdFontMono";
    };
    base16Scheme = "${pkgs.base16-schemes}/share/themes/gruvbox-material-dark-hard.yaml";
    targets.gnome.enable = false;
  };

  # Zen-browser (and other apps) read light/dark from the portal's
  # org.freedesktop.appearance interface, which maps to this GNOME dconf key.
  # Unset, the portal reports light and zen renders light despite polarity=dark.
  # (niri issue #2878)
  dconf.settings."org/gnome/desktop/interface".color-scheme = "prefer-dark";

  # Don't change
  home.stateVersion = hostConfig.stateVersion.home;
  programs.home-manager.enable = true;

  # Hyprland is not used here, but home-manager imports every module and its
  # 26.05 default (lua) warns whenever the option itself is forced: the news
  # feed `home-manager switch` and `build` evaluate, or an `nix eval` that asks
  # for it. The activationPackage path does not force it, so hm-switch.sh never
  # warned. Pin the legacy value it asks for until stateVersion reaches 26.05.
  wayland.windowManager.hyprland.configType = "hyprlang";

  # `home-manager switch` prints how many news items are unread (383 today) on
  # every switch. This silences that count; it does not save the evaluation
  # that produces it, only hm-switch.sh does. Migration notices for the next
  # stateVersion go quiet with it, so run `home-manager news` after a bump.
  news.display = "silent";

  # One daily run. scripts/daily-update.sh pulls merged work, locks the
  # checkout, moves the floating inputs and the T3 Code stable pin, rebuilds the
  # system and this configuration, commits the wrapper lock, pins the devshells
  # the collection has to keep, and collects the user store. The marker it
  # writes on exit wakes the root half of the collection (base/system.nix); the
  # monthly optimiser is the only other store unit. The pin had to run before the
  # collection and the collection after the switch; three timers used to encode
  # that with clock times, and now it is the order of one script's steps.
  # Part of the graphical session, so the collection needs a login; the switch
  # needs the user manager anyway. A machine left at the greeter collects
  # nothing until someone logs in, which is the price of collecting right after
  # the switch instead of on a clock.
  systemd.user.services.daily-update = {
    Unit = {
      Description = "Daily pull, system and home switch, and store collection";
      IgnoreOnIsolate = true;
      X-SwitchMethod = "keep-old";
      # Persistent timers fire right after login, often before wifi is up.
      # Order after network-online so we don't fail on DNS on every boot.
      Wants = [ "network-online.target" ];
      After = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      # hostConfig.gcRequest is the path the system unit watches, so the user
      # half and the root half cannot drift onto separate markers.
      # hostConfig.systemSwitchPath is the store-pinned helper the NOPASSWD rule
      # in base/system.nix names, so the script and the rule share one path.
      ExecStart = "%h/.config/scripts/daily-update.sh ${hostConfig.gcRequest} ${hostConfig.systemSwitchPath}";
      # Type=oneshot disables the manager's start timeout, so a wedged run
      # would sit in "activating" and the next elapse would find the unit
      # already started. Twelve hours is a bound, not an expectation: it covers
      # a kernel that has to compile because the signed cache missed, a
      # from-scratch static devshell build in the pin, and a T3 Code bump.
      TimeoutStartSec = "12h";
      # No RemainAfterExit: it keeps the unit active after exit, which breaks
      # this timer's re-arm on this system (next elapse sticks at infinity).
    };
  };

  systemd.user.timers.daily-update = {
    Unit = {
      Description = "Timer for the daily update";
      PartOf = [ "graphical-session.target" ];
    };
    Timer = {
      # Native wall-clock timer: fires daily at 08:30 and, with Persistent=true,
      # catches up shortly after wake if the machine was asleep at 08:30. The
      # simple systemd answer to "update once a day even when suspended".
      OnCalendar = "*-*-* 08:30:00";
      Persistent = true;
      RandomizedDelaySec = "30min";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
