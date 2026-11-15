# The greeter starts the niri session, and niri itself is enabled here rather
# than in base/ because a machine without a compositor is not this machine.
{ ... }:
{
  programs.niri.enable = true;
  services.displayManager.ly.enable = true;
}
