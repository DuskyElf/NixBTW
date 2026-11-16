# Disk layout for the ZenBook Pro Duo UX581GV.
#
# The device and the filesystem labels come from hosts/asus/disk.nix, the same
# file the NixOS fileSystems read, so a label cannot drift between them.
#
# Sizes match the pre-migration table: p1 1 GiB, p2 115 GiB, p3 the
# remainder. / stays btrfs because the Nix store needs compression. /home
# becomes f2fs because random 4K writes are what churn this disk.
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

        nixos = {
          size = "115G";
          label = disk.labels.root;
          content = {
            type = "btrfs";
            extraArgs = [
              "-f"
              "-L"
              disk.labels.root
            ];
            subvolumes."@" = {
              mountpoint = "/";
              mountOptions = [
                "noatime"
                "compress=zstd"
              ];
            };
          };
        };

        home = {
          size = "100%";
          label = disk.labels.home;
          content = {
            type = "filesystem";
            format = "f2fs";
            mountpoint = "/home";
            extraArgs = [
              "-l"
              disk.labels.home
            ];
            mountOptions = [ "noatime" ];
          };
        };
      };
    };
  };
}
