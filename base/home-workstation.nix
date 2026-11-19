# The desktop half of the home configuration. base/home.nix is the part every
# machine gets; this module adds the theme, the portal key that makes dark mode
# real for GTK and zen, and the flake inputs only a desktop needs.
#
# The daily update is not part of this: it is the `daily-update` app
# (apps/daily-update/home.nix), which a headless host lists too.
#
# The flake inputs that only a desktop needs are imported here, not in
# lib/mkHost.nix, so a headless host does not evaluate niri or stylix at all.
{
  inputs,
  pkgs,
  ...
}:

{
  imports = [
    inputs.niri.homeModules.config
    inputs.niri.homeModules.stylix
    inputs.stylix.homeModules.stylix
    inputs.zen-browser.homeModules.beta
  ];

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

  # Hyprland is not used here, but home-manager imports every module and its
  # 26.05 default (lua) warns whenever the option itself is forced: the news
  # feed `home-manager switch` and `build` evaluate, or an `nix eval` that asks
  # for it. The activationPackage path does not force it, so hm-switch.sh never
  # warned. Pin the legacy value it asks for until stateVersion reaches 26.05.
  wayland.windowManager.hyprland.configType = "hyprlang";
}
