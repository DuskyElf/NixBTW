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
    (jail "ungoogled-chromium" pkgs.ungoogled-chromium (c: with c; [
      gui
      gpu
      network
      notifications
      (xdg-app home "chromium")
      (dbus {
        talk = [
          "org.freedesktop.portal.Desktop"
          "org.freedesktop.portal.Documents"
        ];
      })
    ]))
  ];
}
