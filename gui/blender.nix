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
    (jail "blender" pkgs.blender (c: with c; [
      gui
      gpu
      (xdg-app home "blender")
      (dbus {
        talk = [
          "org.freedesktop.portal.Desktop"
          "org.freedesktop.portal.Documents"
        ];
      })
    ]))
  ];
}
