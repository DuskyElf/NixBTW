# Disk layout for the homelab box: one 500 GB HDD, so there is room for a data
# partition beside the system. The device and the labels come from
# hosts/homelab/disk.nix, the same file the NixOS fileSystems read, so a label
# cannot drift between them.
#
# ext4 rather than the laptop's f2fs: this is a spinning disk with no
# compression story, and noatime is the only tuning it needs. Reading the store
# off it is the slowest routine work this box does: a cold flake evaluation
# takes 54 s against 14 s warm, and the bay is SATA, so an SSD is the upgrade.
# A 100% partition is created last by disko, so root takes whatever the other
# two leave.
#
# Disk mode only. The disko imageSize default is unused here.
let
  disk = import ./disk.nix;
in
{
  disko.devices.disk.main = {
    type = "disk";
    device = disk.device;

    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1G";
          type = "EF00";
          label = disk.labels.boot;
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            extraArgs = [
              "-n"
              disk.labels.boot
            ];
            mountOptions = [
              "fmask=0077"
              "dmask=0077"
            ];
          };
        };

        storage = {
          size = "250G";
          label = disk.labels.storage;
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/mnt/personal-storage";
            extraArgs = [
              "-L"
              disk.labels.storage
            ];
            mountOptions = [ "noatime" ];
          };
        };

        root = {
          size = "100%";
          label = disk.labels.root;
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
            extraArgs = [
              "-L"
              disk.labels.root
            ];
            mountOptions = [ "noatime" ];
          };
        };
      };
    };
  };
}
