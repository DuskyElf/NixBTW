{
  config,
  jail,
  pkgs,
  pkgs-unstable-small,
  ...
}:
let
  # Built from upstream main, not the tagged release in nixpkgs. The rev and
  # the fixed-output hashes live in t3code-main.lock.nix and move with the daily
  # flake auto-update (scripts/update-t3code-main.sh).
  t3code = import ./t3code-main.nix { pkgs = pkgs-unstable-small; };

  # T3's html_render and browser tool spawn their own Chrome for Testing
  # download. That binary wants /lib64/ld-linux-x86-64.so.2, which NixOS does
  # not have, so every spawn exits 127. T3 exposes no browser-path setting, and
  # the path is pinned to the downloaded version, so the smallest local fix is
  # to overwrite each download with a shim that execs the Nix Chromium. T3 only
  # stats the file, so a script satisfies it. Runs on switch; if a T3 upgrade
  # downloads a newer build before the next switch, run t3-headless-chrome-shim.
  t3HeadlessChromeShim = pkgs.writeShellScript "t3-headless-chrome-shim" ''
    set -eu
    root="$HOME/.t3/tools/chrome-headless-shell"
    chromium="$HOME/.nix-profile/bin/chromium"
    [ -d "$root" ] && [ -x "$chromium" ] || exit 0

    for bin in "$root"/*/*/chrome-headless-shell; do
      [ -f "$bin" ] || continue
      if head -c 2 "$bin" 2>/dev/null | grep -q '#!'; then
        continue
      fi
      printf '#!/bin/sh\nexec %s "$@"\n' "$chromium" > "$bin"
      chmod +x "$bin"
    done
  '';
in
{
  home.packages = [
    pkgs-unstable-small.opencode
    t3code
    #(jail "opencode" pkgs-unstable-small.opencode (
    #  c: with c; [
    #    network
    #    mount-cwd

    #    (xdg-app config.home.homeDirectory "opencode")

    #    # cached git clone inspections
    #    (readwrite "/home/duskyelf/.git-clones/")

    #    # can run any binary with limited file system access
    #    (readonly "/nix/store")
    #    (readonly "/run/current-system/sw/bin")
    #    (readonly "/home/duskyelf/.nix-profile/bin")
    #    (readonly "/home/duskyelf/dotfiles/deploy-system/")
    #    (set-env "PATH" "/run/current-system/sw/bin:/home/duskyelf/.nix-profile/bin")

    #    (set-env "EDITOR" "vim")

    #    # clipboard: wl-copy/wl-paste need the Wayland socket
    #    wayland

    #    # done-bell: system notification + audio + media pause (mirrors gui/idle.nix break-timer)
    #    notifications
    #    pipewire
    #    (dbus {
    #      talk = [
    #        "org.mpris.MediaPlayer2.*"
    #        "org.freedesktop.DBus"
    #      ];
    #    })
    #    (add-pkg-deps [
    #      pkgs.playerctl
    #      pkgs.mako
    #      pkgs.libnotify
    #      pkgs.sound-theme-freedesktop
    #      pkgs.wl-clipboard
    #    ])
    #  ]
    #))
  ];

  # T3's downloads are already on disk by the time a switch runs, so this
  # repairs them without a watcher. Any T3 upgrade that downloads a newer build
  # is healed by the next switch (the daily auto-update) or by running
  # t3-headless-chrome-shim by hand.
  home.activation.t3HeadlessChromeShim =
    config.lib.dag.entryAfter [ "writeBoundary" ] "run ${t3HeadlessChromeShim}";

  home.file.".config/opencode".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/opencodeBTW";
}
