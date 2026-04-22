{
  config,
  pkgs,
  ...
}:

{
  xdg.enable = true;
  home.username = "duskyelf";
  home.homeDirectory = "/home/duskyelf";

  stylix = {
    enable = true;
    polarity = "dark";
    fonts.monospace = {
      package = pkgs.nerd-fonts.jetbrains-mono;
      name = "JetBrainsMonoNerdFontMono";
    };
    base16Scheme = "${pkgs.base16-schemes}/share/themes/gruvbox-material-dark-hard.yaml";
  };

  # Don't change
  home.stateVersion = "25.11";
  programs.home-manager.enable = true;

  # auto-update flakes and home-manager on login
  systemd.user.services.flake-auto-update = {
    Unit = {
      Description = "Auto-update flakes and switch home-manager on login";
      IgnoreOnIsolate = true;
    };
    Service = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.writeShellScript "flake-update-script" ''
        trap 'echo "Caught SIGTERM, exiting..."; exit 143' TERM

        # Change to the PRIVATE wrapper repo
        DEPLOY_DIR="/home/duskyelf/.deploy-system"
        cd "$DEPLOY_DIR" || exit 1

        echo "Starting flake auto-update at $(date)"

        # Update the inputs (this updates zen-browser and your dotfiles)
        echo "Updating flake inputs privately..."
        if nix flake update; then
          echo "Private flake update successful"

          # Commit the flake.lock changes PRIVATELY
          echo "Committing flake.lock privately..."
          git add flake.lock
          git commit -m "chore: private auto-update" --no-gpg-sign
        else
          echo "Flake update failed"
          ${pkgs.libnotify}/bin/notify-send -u critical "Update failed" "Failed to update flakes"
          exit 1
        fi

        # Switch home-manager using the PRIVATE wrapper
        echo "Switching home-manager configuration..."
        if home-manager switch --flake . --cores 16; then
          echo "Home-manager switch successful"
          ${pkgs.libnotify}/bin/notify-send "Update successful" "Successfully updated and switched privately"
        else
          echo "Home-manager switch failed"
          ${pkgs.libnotify}/bin/notify-send -u critical "Update failed" "Failed to switch configuration"
          exit 1
        fi

        echo "Flake auto-update completed at $(date)"
      ''}";
    };
  };

  systemd.user.timers.flake-auto-update = {
    Unit = {
      Description = "Timer for flake auto-update";
      PartOf = [ "graphical-session.target" ];
    };
    Timer = {
      OnBootSec = "2min"; # Run 2 minutes after login
      OnUnitActiveSec = "24h"; # Optional: run daily
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
