# The niri session: compositor config, binds, and the furniture the session
# itself needs (notification daemon, polkit agent, launcher). The wallpaper
# stack, quickshell overlay, and colour temperature daemon are their own apps.
{ pkgs, ... }:
{
  imports = [
    ./settings.nix
    ./binds.nix
  ];

  services = {
    mako.enable = true;
    polkit-gnome.enable = true;
  };

  # Terminal=true entries (btop, vim, nvim) open in foot. fuzzel runs them
  # through `terminal` and otherwise spawns them with no tty, where they die
  # silently.
  programs.fuzzel = {
    enable = true;
    settings.main.terminal = "foot";
  };

  # X11 support: niri 25.08+ spawns xwayland-satellite on demand when the
  # binary is in PATH, so no spawn-at-startup or systemd service is needed.
  # brightnessctl is here for the keybinds below and for apps/idle.nix.
  home.packages = with pkgs; [
    wtype
    brightnessctl
    xwayland-satellite
  ];
}
