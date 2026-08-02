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

    # FIXME: remove when stylix releases a 26.05 branch
    enableReleaseChecks = false;
    targets.gnome.enable = false;
  };

  gtk.gtk4.theme = config.gtk.theme;

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
      # No RemainAfterExit: it keeps the unit active after exit, which breaks
      # this timer's re-arm on this system (next elapse sticks at infinity).
      ExecStart = "${pkgs.writeShellScript "flake-update-script" ''
        trap 'echo "Caught SIGTERM, exiting..."; exit 143' TERM

        # Change to the PRIVATE wrapper repo
        DEPLOY_DIR="/home/duskyelf/.deploy-system"
        cd "$DEPLOY_DIR" || exit 1

        echo "Starting flake auto-update at $(date)"

        echo "Updating flake inputs..."
        if nix flake update nixpkgs nixpkgs-unstable-small zen-browser; then
          echo "Private flake update successful"
        else
          echo "Flake update failed"
          ${pkgs.libnotify}/bin/notify-send -u critical "Update failed" "Failed to update flakes"
          exit 1
        fi

        # Switch home-manager using the PRIVATE wrapper. The live-tree override
        # keeps it consistent with manual rebuilds (AGENTS.md): the pinned
        # my-dotfiles rev in the deploy lock goes stale whenever dotfiles commits
        # (e.g. the voxtype removal), and without the override the switch
        # evaluates that stale rev and fails to resolve its inputs.
        if home-manager switch --flake ~/.deploy-system --override-input my-dotfiles path:/home/duskyelf/dotfiles --cores 2; then
          echo "Home-manager switch successful"
          ${pkgs.libnotify}/bin/notify-send "Update successful" "Successfully updated and switched privately"

          echo "Committing flake.lock..."
          git add flake.lock
          git commit -m "chore: private auto-update" --no-gpg-sign \
            || echo "flake.lock unchanged, nothing to commit"
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
      # Native wall-clock timer: fires daily at 08:30 and, with Persistent=true,
      # catches up shortly after wake if the machine was asleep at 08:30. The
      # simple systemd answer to "update once a day even when suspended".
      OnCalendar = "*-*-* 08:30:00";
      Persistent = true;
      RandomizedDelaySec = "30min";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
