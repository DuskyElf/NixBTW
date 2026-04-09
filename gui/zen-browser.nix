{
  config,
  pkgs,
  jail,
  inputs,
  ...
}:
let
  zen-browser = inputs.zen-browser.packages.${pkgs.system}.beta;
  home = config.home.homeDirectory;
in
{
  home.packages = [
    (jail "zen-browser" zen-browser (c: with c; [
      gui
      gpu
      network
      notifications
      (xdg-app home "zen")
      (dbus {
        talk = [
          "org.freedesktop.portal.Desktop"
          "org.freedesktop.portal.Documents"
        ];
      })
    ]))
  ];

  stylix.targets.zen-browser.enable = false;
}
