# The homelab box: a headless server reached over ssh from the laptop. There is
# no desktop here, so it does not list base/workstation.nix or any home app
# except bash; the home configuration is only the XDG directories, the shell,
# and the git identity in home.nix.
{
  config = [ ./config.nix ];
  system = [
    ./system.nix
    ./hardware.nix
  ];
  home = [ ./home.nix ];

  apps = {
    system = [
      "openssh"
      "auto-cpufreq"
    ];
    home = [ "bash" ];
  };

  # Only the installer reads this; it is what nixos-anywhere formats with.
  disko = ./disko.nix;
}
