{
  config,
  inputs,
  pkgs,
  pkgs-unstable,
  ...
}:
{
  home.packages = [
    pkgs-unstable.opencode
    pkgs.libnotify
  ];

  xdg.configFile."opencode".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/opencodeBTW";

  systemd.user.services.opencode-web = {
    Unit = {
      Description = "Opencode Web Interface";
      After = [ "network.target" ];
    };
    Service = {
      ExecStart = "${
        pkgs-unstable.opencode
      }/bin/opencode web --port 4096";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
