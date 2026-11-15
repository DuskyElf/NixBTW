# Everything specific to this laptop: firmware, kernel tuning, nvidia, the
# screenpad. The shared machine config is base/, app modules are in apps/, and
# lib/mkHost.nix is what joins them.
#
# config.nix holds the values modules read (user, panels, battery); system.nix
# holds the driver, kernel, and firmware work that only this machine needs.
#
# The home side needs nothing asus-specific yet. It is a key because mkHost
# checks for it; a host that needs one adds it here.
{
  config = [ ./config.nix ];
  system = [ ./system.nix ];
  home = [ ];
}
