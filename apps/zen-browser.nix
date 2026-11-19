{
  config,
  pkgs,
  jail,
  inputs,
  ...
}:
let
  zen-browser = inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.beta;
  home = config.home.homeDirectory;
in
{
  home.packages = [
    (jail "zen-beta" zen-browser (
      c: with c; [
        gui
        gpu
        network
        notifications
        (xdg-app home "zen")
        (readwrite "${home}/Downloads/")
        (dbus {
          talk = [
            "org.freedesktop.portal.Desktop"
            "org.freedesktop.portal.Documents"
            "org.mpris.MediaPlayer2.*"
          ];
          own = [ "org.mpris.MediaPlayer2.*" ];
        })
      ]
    ))
  ];

  # The generated mimeinfo.cache lists the desktop files that claim a type in
  # alphabetical order, and `chromium-browser.desktop` sorts before
  # `zen-beta.desktop`, so chromium wins every shared type (http, html, xml)
  # unless they are stated here. base/home.nix owns the file.
  xdg.mimeApps.defaultApplications = {
    "x-scheme-handler/http" = "zen-beta.desktop";
    "x-scheme-handler/https" = "zen-beta.desktop";
    "text/html" = "zen-beta.desktop";
    "text/xml" = "zen-beta.desktop";
    "application/xml" = "zen-beta.desktop";
    "application/xhtml+xml" = "zen-beta.desktop";
  };

  # CSS only: this gates the browser chrome, not light/dark, which comes from
  # the portal dconf key in base/home-workstation.nix.
  stylix.targets.zen-browser.enable = false;
}
