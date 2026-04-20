{
  config,
  pkgs,
  jail,
  ...
}:
let
  home = config.home.homeDirectory;
in
{
  home.packages = [
    (jail "gnucash" pkgs.gnucash (
      c: with c; [
        gui
        (xdg-app home "gnucash")
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
