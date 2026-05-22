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
      X-SwitchMethod = "keep-old";
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

        # Update the inputs
        echo "Updating flake inputs..."
        if nix flake update nixpkgs nixpkgs-unstable-small zen-browser; then
          echo "Private flake update successful"
        else
          echo "Flake update failed"
          ${pkgs.libnotify}/bin/notify-send -u critical "Update failed" "Failed to update flakes"
          exit 1
        fi

        # Switch home-manager using the PRIVATE wrapper
        echo "Switching home-manager configuration..."
        if home-manager switch --flake ~/.deploy-system --cores 2; then
          echo "Home-manager switch successful"
          ${pkgs.libnotify}/bin/notify-send "Update successful" "Successfully updated and switched privately"

          # Commit the flake.lock changes PRIVATELY
          echo "Committing flake.lock..."
          git add flake.lock
          git commit -m "chore: private auto-update" --no-gpg-sign
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
      OnCalendar = "daily";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
