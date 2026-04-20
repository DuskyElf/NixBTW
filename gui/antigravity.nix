{
  config,
  pkgs-unstable,
  jail,
  ...
}:
let
  home = config.home.homeDirectory;
in
{
  home.packages = [
    (jail "antigravity" pkgs-unstable.antigravity (
      c: with c; [
        gui
        gpu
        network
        (xdg-app home "antigravity")
        (dbus {
          talk = [
            "org.freedesktop.portal.Desktop"
            "org.freedesktop.portal.Documents"
          ];
        })
      ]
    ))
  ];
}
