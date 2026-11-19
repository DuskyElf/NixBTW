# Identity of the one disk. Only the disko layout reads this file, and the
# fileSystems entries come from the partition labels disko writes, so these
# strings are the one place the disk is named.
{
  device = "/dev/disk/by-id/ata-TOSHIBA_MQ01ABD0_45URP321T";

  labels = {
    boot = "BOOT";
    root = "nixos";
    storage = "personal-storage";
  };
}
