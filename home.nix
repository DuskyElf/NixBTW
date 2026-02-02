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
  home.stateVersion = "25.05";
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

        cd /home/duskyelf/dotfiles
        echo "Starting flake auto-update at $(date)"

        # Update specific flakes
        echo "Updating zen-browser flakes..."
        if nix flake update zen-browser; then
          echo "Flake update successful"

          # Commit the flake.lock changes
          echo "Committing flake.lock changes..."
          git add flake.lock
          git commit -m "chore: nix flake update zen-browser" --no-gpg-sign

        else
          echo "Flake update failed"
          notify-send -u critical "Update failed" "Failed to update zen-browser flakes"
          exit 1
        fi

        # Switch home-manager
        echo "Switching home-manager configuration..."
        if home-manager switch --flake . --cores 16; then
          echo "Home-manager switch successful"
          notify-send "Update successful" "Successfully updated flakes and switched home-manager configuration"
        else
          echo "Home-manager switch failed"
          notify-send -u critical "Update failed" "Failed to switch home-manager configuration"
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
