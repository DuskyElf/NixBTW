# Identity of the one disk. The NixOS fileSystems and the disko layout both
# read this, so a label cannot drift between them.
{
  device = "/dev/disk/by-id/nvme-SAMSUNG_MZVLB1T0HALR-00000_S3W6NX0M825927";

  labels = {
    boot = "BOOT";
    root = "nixos";
    home = "home";
  };
}
