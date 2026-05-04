{
  config,
  pkgs,
  jail,
  lib,
  ...
}:
let
  home = config.home.homeDirectory;
in
{
  # Install jailed ollama as home package
  home.packages = [
    (jail "ollama" pkgs.ollama (
      c: with c; [
        gpu
        network
        (xdg-app home "ollama")
      ]
    ))
  ];

  # Helper to manage ollama service
  home.shellAliases = {
    ollama-start = "systemctl --user start ollama";
    ollama-stop = "systemctl --user stop ollama";
    ollama-restart = "systemctl --user restart ollama";
    ollama-status = "systemctl --user status ollama";
  };

  systemd.user.services.ollama = {
    Unit = {
      Description = "Ollama Local LLM Server";
      After = [ "network.target" ];
      Wants = [ "network.target" ];
    };
    Service = {
      # Use the jailed ollama from home packages
      ExecStart = "${lib.getBin pkgs.ollama}/bin/ollama serve";
      Environment = [
        "OLLAMA_HOST=127.0.0.1:11434"
        "OLLAMA_MODELS=${config.xdg.dataHome}/ollama/models"
      ];
      Restart = "on-failure";
      RestartSec = 10;
      TimeoutStartSec = 300;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # Auto-start ollama on login via timer that runs immediately
  systemd.user.timers.ollama-autostart = {
    Unit = {
      Description = "Auto-start ollama on login";
      PartOf = [ "ollama.service" ];
    };
    Timer = {
      OnBootSec = "5sec";
      OnActiveSec = "5sec";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
