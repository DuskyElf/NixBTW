# The client half of OpenSSH: this machine's ~/.ssh/config. Each entry in
# hostConfig.ssh.aliases becomes a Host block, so a short name stands in for the
# address on the command line.
#
# The file belongs to the switch: an editor that saves over it replaces the store
# link, and the next switch then refuses to clobber it. Add a block through
# ssh.aliases instead.
#
# The server half is apps/openssh/system.nix.
{
  hostConfig,
  lib,
  ...
}:
{
  programs.ssh = {
    enable = true;
    # True would warn on every switch that the module's default values will be
    # removed. Dropping them changes nothing except that ssh reads
    # ~/.ssh/known_hosts2 again, and no such file exists.
    enableDefaultConfig = false;
    settings = lib.mapAttrs (_: hostName: { HostName = hostName; }) hostConfig.ssh.aliases;
  };
}
